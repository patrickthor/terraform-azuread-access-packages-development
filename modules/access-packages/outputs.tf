# ==============================================================================
# Outputs
#
# This module runs last, so its outputs are the verification surface for the whole system.
# Two jobs: publish what was built, and make the gaps loud. A gap that exists only in a
# code comment is a gap that gets lost between two repos.
#
# Everything package-shaped is keyed on PACKAGE NAME. When var.packages is empty those
# names are scope names, so the default output shape is unchanged from before named
# packages existed.
# ==============================================================================

output "catalogs" {
  description = <<-EOT
    Label → catalog ID, display name, and whether it was created or adopted.

    `was_adopted = true` means the catalog belongs to someone else and this module only
    added resources to it. Its description, visibility and published state were left alone.
  EOT
  value = {
    for label, m in module.catalog : label => {
      catalog_id              = m.catalog_id
      display_name            = m.display_name
      was_adopted             = m.was_adopted
      delegated_to            = keys(m.delegated_role_assignments)
      delegated_role          = local.catalog_settings[label].systemeier_catalog_role
      has_standing_delegation = length(m.delegated_role_assignments) > 0
      scope_keys              = local.v.catalogs[label].scope_keys
    }
  }
}

output "packages_by_catalog" {
  description = <<-EOT
    Which packages landed in which catalog.

    A catalog is a delegation boundary — whoever holds a catalog role can manage every
    package inside it — so this is a security-relevant listing rather than a convenience.
    Read it together with `catalogs.*.delegated_to`.

    With named packages a catalog can hold several packages over the same scope, which is
    the point of putting a privileged tier in its own catalog.
  EOT
  value = {
    for label in local.catalog_labels : label => {
      for name in keys(local.resolvable_packages) :
      name => module.access_package[name].access_package_id
      if local.package_catalog[name] == label
    }
  }
}

output "packages" {
  description = <<-EOT
    What each package is, before and after the EligibleMember exclusion.

    `source = "scope"` means this package was generated from a scope because var.packages
    was empty; `"named"` means the caller declared it.
  EOT
  value = {
    for name, p in local.resolvable_packages : name => {
      source                = local.using_explicit_packages ? "named" : "scope"
      display_name          = local.effective[name].display_name
      scope                 = local.package_scope[name]
      catalog               = local.package_catalog[name]
      declared_role_keys    = p.role_keys
      attached_role_keys    = local.managed_roles_by_package[name]
      excluded_role_keys    = local.excluded_roles_by_package[name]
      grants_approver_group = contains(local.packages_granting_approver_group, name)
      access_package_id     = module.access_package[name].access_package_id
    }
  }
}

output "access_package_ids" {
  description = "Access package ID per package name."
  value       = { for name, m in module.access_package : name => m.access_package_id }
}

output "assignment_policy_ids" {
  description = "Gate 1 assignment policy ID per package name."
  value       = { for name, m in module.access_package : name => m.assignment_policy_id }
}

output "scopes" {
  description = <<-EOT
    Scopes present in the contract. Not configured anywhere in this repo — if this looks
    wrong, the contract being passed in is wrong.
  EOT
  value       = local.scope_keys
}

output "granted_groups_by_package" {
  description = <<-EOT
    What each package actually grants, after exclusions, with the access type Terraform set
    and what the group leads to on the target side.

    `permanent_access = true` is the baseline, active as soon as the assignment lands.
    Everything else still requires activation at gate 2.
  EOT
  value = {
    for name in keys(local.resolvable_packages) : name => {
      for label, role in local.resource_roles_by_package[name] : label => (
        contains(keys(local.v.roles), label)
        ? {
          group_name        = local.v.roles[label].group_name
          access_type       = role.access_type
          jit_mechanism     = local.v.roles[label].jit_mechanism
          target            = local.v.roles[label].target
          permanent_access  = local.v.roles[label].permanent_access
          is_approver_group = false
        }
        : {
          group_name        = local.scopes_with_approver_group[local.package_scope[name]]
          access_type       = role.access_type
          jit_mechanism     = "n/a"
          target            = "peer approval rights for the ${local.package_scope[name]} scope"
          permanent_access  = true
          is_approver_group = true
        }
      )
    }
  }
}

output "effective_policies" {
  description = <<-EOT
    What each package enforces after the package definition, package_overrides and defaults
    were layered. Read this rather than the tfvars when verifying intent — the tfvars show
    only the deviations.
  EOT
  value       = { for name, m in module.access_package : name => m.effective_policy }
}

# ------------------------------------------------------------------------------
# The two gates
# ------------------------------------------------------------------------------

output "gate_1_approvers" {
  description = <<-EOT
    Per package, the systemeier acting as named approvers. This is the only approval gate
    this module owns.

    The approvers are those of the package's single scope. Packages spanning scopes are
    rejected at plan time rather than resolved — see the gate 1 note in locals.tf.

    One approver is workable at gate 1: a systemeier can approve someone else's request. See
    peer_approval_status for why one is not enough at gate 2.
  EOT
  value = {
    for name in keys(local.resolvable_packages) : name => {
      scope           = local.package_scope[name]
      systemeier_upns = local.v.scopes[local.package_scope[name]].systemeier
      object_ids = [
        for upn in local.v.scopes[local.package_scope[name]].systemeier :
        data.azuread_user.systemeier[upn].object_id
      ]
      subject_type = "singleUser"
      stage_count  = 1
      timeout_days = local.effective[name].approval_timeout_days
    }
  }
}

output "gate_2_approvers" {
  description = <<-EOT
    Repo 1's activation rules, republished per role and interpreted nowhere. Gate 2 is
    whether someone may hold a privilege right now, and repo 1 owns it.

    Note what the contract does and does not carry. It gives the mechanism, whether access is
    permanent, and the expiry ceiling — enough to see where activation applies and where
    Terraform governs it at all. It does not carry repo 1's per-role `approval_type`, so this
    cannot name the gate-2 approver for an individual role. The scope's systemeier and
    approver group are listed because those are the two pools repo 1 draws from, not because
    this module worked out which applies.

    `terraform_governs_activation = false` means an Entra directory role, for which the
    azuread provider has no policy resource at all. For those, gate 1 is the only gate
    Terraform enforces — but "no approval from Terraform" means "governed by tenant admins
    outside Terraform", since active Privileged Role Administrator and Global Administrator do
    act as default approvers. It does not mean the role is open.
  EOT
  value = {
    for k, r in local.v.roles : k => {
      scope                        = r.scope
      role                         = r.role
      jit_mechanism                = r.jit_mechanism
      permanent_access             = r.permanent_access
      requires_activation          = !r.permanent_access
      target                       = r.target
      max_assignment_days          = r.max_assignment_days
      terraform_governs_activation = r.jit_mechanism != "entra_role"
      approver_pool_systemeier     = local.v.scopes[r.scope].systemeier
      approver_pool_group          = lookup(local.scopes_with_approver_group, r.scope, null)
      granted_by_packages          = [for name, ks in local.managed_roles_by_package : name if contains(ks, k)]
    }
  }
}

# ------------------------------------------------------------------------------
# The gaps
# ------------------------------------------------------------------------------

output "excluded_resource_roles" {
  description = <<-EOT
    Per-group detail for roles left out of Terraform because their required access type is
    "EligibleMember", which the azuread provider validates away. Empty when
    manage_pim_for_groups_roles is true.

    `packages` and `catalogs` say where the manual step has to be done — a role can now
    appear in more than one package, and a package can sit in its own catalog.

    These are not forgotten and not broken. They are the honest split.
  EOT
  value       = local.excluded_resource_roles
}

output "unpackaged_roles" {
  description = <<-EOT
    Roles the contract vended that no package grants.

    Always empty when var.packages is unset, since the generated per-scope packages cover
    every role. Non-empty means repo 1 created a group, an RBAC binding and a PIM policy for
    access that nobody can request — either a deliberate omission or a forgotten role_keys
    entry. Reported rather than assumed either way.
  EOT
  value = {
    for k in local.unpackaged_role_keys : k => {
      scope      = local.v.roles[k].scope
      role       = local.v.roles[k].role
      group_name = local.v.roles[k].group_name
      target     = local.v.roles[k].target
    }
  }
}

output "manual_steps_required" {
  description = <<-EOT
    What Terraform could not do, with the portal path. An empty list would be a lie in most
    tenants; read this before believing an apply.
  EOT
  value = concat(
    length(local.excluded_role_keys) == 0 ? [] : [
      <<-EOT
        Add resource role(s) by hand, in Identity Governance → Catalogs → the catalog named below → Access packages → the package named below → Resource roles.
        Pick "Eligible Member", NOT "Member". The groups are already registered as catalog resources, so they appear in the picker immediately.
        ${join("\n", flatten([
      for k, r in local.excluded_resource_roles : [
        for pkg in r.packages : "  catalog '${local.package_catalog[pkg]}' / package '${local.effective[pkg].display_name}' ← group '${r.group_name}' as ${r.required_access_type}  (${r.cloud}, grants ${r.target})"
      ]
]))}
        Verify afterwards that the user is eligible and NOT active. An active membership means the gap bit you anyway.
      EOT
],
length(local.unpackaged_role_keys) == 0 ? [] : [
  "These roles exist in the contract but no package grants them, so nobody can request them: ${join(", ", local.unpackaged_role_keys)}. Either add them to a package's role_keys or remove them from repo 1.",
],
[
  for label in local.catalog_labels : "Catalog '${local.catalog_settings[label].display_name}' is adopted, not created. Confirm its owner is content for these packages to live there, and that its published and externally_visible settings match this system's assumptions — this module deliberately does not change them."
  if local.catalog_settings[label].adopt_existing
],
[
  for label in local.catalog_labels : "Catalog '${local.catalog_settings[label].display_name}' has standing '${local.catalog_settings[label].systemeier_catalog_role}' rights delegated to ${length(local.catalog_delegated_upns[label])} systemeier. This is the one non-expiring, non-activated grant in the system. Review it as you would a permanent role assignment."
  if length(local.catalog_delegated_upns[label]) > 0
],
[
  for s in local.scope_keys : "Set PIM activation rules (MFA, approval, maximum duration) by hand for the entra_role roles in scope '${s}': ${join(", ", [for k in local.v.scopes[s].role_keys : local.v.roles[k].target if local.v.roles[k].jit_mechanism == "entra_role"])}. The azuread provider has no resource for directory role management policies, so gate 1 is the only control Terraform enforces on packages in this scope."
  if length([for k in local.v.scopes[s].role_keys : k if local.v.roles[k].jit_mechanism == "entra_role"]) > 0
],
[
  for s in local.scope_keys : "Complete SCIM provisioning for scope '${s}' on the ${local.v.scopes[s].cloud} side. Terraform stops at the tenant boundary: the group exists and is PIM-managed, but nothing connects it to the target cloud."
  if length([for k in local.v.scopes[s].role_keys : k if local.v.roles[k].jit_mechanism == "pim_for_groups"]) > 0
],
[
  for s in local.deadlocked_approver_scopes : "Add a second member to the approver group '${local.scopes_with_approver_group[s]}' for scope '${s}'. It has ${length(local.v.scopes[s].systemeier)} systemeier, PIM blocks self-approval, and no package grants that group — so dual-approval roles there cannot be activated by that person alone."
],
)
}

output "peer_approval_status" {
  description = <<-EOT
    Where the single-systemeier deadlock is resolved and where it is not, per scope.

    `granted_by_packages` lists the packages that attach the approver group. With named
    packages this is the senior tier: an admins package grants it, an engineers package over
    the same scope does not, so juniors can request and activate but never appear as an
    approver.

    `deadlock_risk` means the approver group has fewer than two members and no package adds
    any, so a lone systemeier cannot activate their own dual-approval role.
  EOT
  value = {
    for s in local.scope_keys : s => {
      has_approver_group  = contains(keys(local.scopes_with_approver_group), s)
      approver_group_name = lookup(local.scopes_with_approver_group, s, null)
      systemeier_count    = length(local.v.scopes[s].systemeier)
      granted_by_packages = [
        for name in local.packages_granting_approver_group : name
        if local.package_scope[name] == s
      ]
      viable        = contains(local.scopes_granted_approver_group, s)
      deadlock_risk = contains(local.deadlocked_approver_scopes, s)
    }
  }
}

output "verification_summary" {
  description = <<-EOT
    One line per package, for reading a plan quickly and checking the result against what
    repo 1 vended.
  EOT
  value = {
    for name, p in local.resolvable_packages : name => {
      scope                   = local.package_scope[name]
      catalog                 = local.package_catalog[name]
      cloud                   = local.v.scopes[local.package_scope[name]].cloud
      roles_declared          = length(p.role_keys)
      roles_attached          = length(local.managed_roles_by_package[name])
      roles_excluded          = length(local.excluded_roles_by_package[name])
      approver_group_attached = contains(local.packages_granting_approver_group, name)
      resource_roles_total    = length(local.resource_roles_by_package[name])
      duration_days           = local.effective[name].assignment_duration_days
      # lookup with a null default: ceiling_by_package deliberately omits packages with no
      # ceiling rather than storing a null. See locals.tf.
      expiry_ceiling_days    = lookup(local.ceiling_by_package, name, null)
      gate_1_approver_count  = length(local.v.scopes[local.package_scope[name]].systemeier)
      gate_2_unmanaged_roles = [for k in p.role_keys : local.v.roles[k].role if local.v.roles[k].jit_mechanism == "entra_role"]
    }
  }
}

output "contract_version" {
  description = "The contract version this module consumed, echoed so a mismatch is visible in outputs as well as in errors."
  value       = local.v.contract_version
}
