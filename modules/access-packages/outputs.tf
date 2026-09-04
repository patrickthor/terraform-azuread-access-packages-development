# ==============================================================================
# Outputs
#
# This module runs last, so its outputs are the verification surface for the whole
# system. Two jobs: publish what was built, and make the gaps loud. A gap that exists
# only in a code comment is a gap that gets lost between two repos.
# ==============================================================================

output "catalogs" {
  description = <<-EOT
    Label → catalog ID, display name, and whether it was created or adopted.

    `was_adopted = true` means the catalog belongs to someone else and this module only
    added resources to it. Its description, visibility and published state were left
    alone.
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
  EOT
  value = {
    for label in local.catalog_labels : label => {
      for s in local.v.catalogs[label].scope_keys :
      s => module.access_package[s].access_package_id
    }
  }
}

output "access_package_ids" {
  description = "Access package ID per scope."
  value       = { for s, m in module.access_package : s => m.access_package_id }
}

output "assignment_policy_ids" {
  description = "Gate 1 assignment policy ID per scope."
  value       = { for s, m in module.access_package : s => m.assignment_policy_id }
}

output "granted_groups_by_package" {
  description = <<-EOT
    What each package actually grants, after exclusions, with the access type Terraform
    set and what the group leads to on the target side.

    `permanent_access = true` is the scope's baseline, active as soon as the assignment
    lands. Everything else still requires activation at gate 2.
  EOT
  value = {
    for s in local.scope_keys : s => {
      for label, role in local.resource_roles_by_scope[s] : label => (
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
          group_name        = local.v.scopes[s].approver_group_name
          access_type       = role.access_type
          jit_mechanism     = "n/a"
          target            = "peer approval rights for the ${s} scope"
          permanent_access  = true
          is_approver_group = true
        }
      )
    }
  }
}

output "effective_policies" {
  description = <<-EOT
    What each package enforces after defaults and scope_overrides were layered. Read this
    rather than the tfvars when verifying intent — the tfvars show only the deviations.
  EOT
  value       = { for s, m in module.access_package : s => m.effective_policy }
}

# ------------------------------------------------------------------------------
# The two gates
# ------------------------------------------------------------------------------

output "gate_1_approvers" {
  description = <<-EOT
    Per package, the systemeier acting as named approvers. This is the only approval gate
    this module owns.

    One approver is workable at gate 1 — a systemeier can approve someone else's request.
    See peer_approval_status for why one is not enough at gate 2.
  EOT
  value = {
    for s in local.scope_keys : s => {
      systemeier_upns = local.v.scopes[s].systemeier
      object_ids      = [for upn in local.v.scopes[s].systemeier : data.azuread_user.systemeier[upn].object_id]
      subject_type    = "singleUser"
      stage_count     = 1
      timeout_days    = local.effective[s].approval_timeout_days
    }
  }
}

output "gate_2_approvers" {
  description = <<-EOT
    Repo 1's activation rules, republished per role and interpreted nowhere. Gate 2 is
    whether someone may hold a privilege right now, and repo 1 owns it.

    Note what the contract does and does not carry. It gives the mechanism, whether access
    is permanent, and the expiry ceiling — enough to see where activation applies and where
    Terraform governs it at all. It does not carry repo 1's per-role `approval_type`, so
    this output cannot name the gate-2 approver for an individual role. The scope's
    systemeier and approver group are listed because those are the two pools repo 1 draws
    from, not because this module worked out which applies.

    `terraform_governs_activation = false` means an Entra directory role, for which the
    azuread provider has no policy resource at all. For those, gate 1 is the only gate
    Terraform enforces — but "no approval from Terraform" means "governed by tenant admins
    outside Terraform", since active Privileged Role Administrator and Global Administrator
    do act as default approvers. It does not mean the role is open.
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
      approver_pool_group          = local.v.scopes[r.scope].approver_group_name
    }
  }
}

# ------------------------------------------------------------------------------
# The gaps
# ------------------------------------------------------------------------------

output "excluded_resource_roles" {
  description = <<-EOT
    Per-group detail for the roles left out of Terraform because their required access type
    is "EligibleMember", which the azuread provider validates away. Empty when
    manage_pim_for_groups_roles is true.

    These are not forgotten and not broken — they are the honest split. Each still needs its
    resource role added by hand.
  EOT
  value       = local.excluded_resource_roles
}

output "manual_steps_required" {
  description = <<-EOT
    What Terraform could not do, with the portal path. An empty list would be a lie in most
    tenants; read this before believing an apply.
  EOT
  value = concat(
    length(local.excluded_role_keys) == 0 ? [] : [
      <<-EOT
        Add ${length(local.excluded_role_keys)} resource role(s) by hand, in Identity Governance → Catalogs → the catalog named below → Access packages → the package named below → Resource roles.
        Pick "Eligible Member", NOT "Member". The groups are already registered as catalog resources, so they appear in the picker immediately.
        ${join("\n", [for k, r in local.excluded_resource_roles : "  catalog '${r.catalog}' / package '${r.access_package}' ← group '${r.group_name}' as ${r.required_access_type}  (${r.cloud}, grants ${r.target})"])}
        Verify afterwards that the user is eligible and NOT active. An active membership means the gap bit you anyway.
      EOT
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
      for s in local.scope_keys : "Set PIM activation rules (MFA, approval, maximum duration) by hand for the entra_role roles in scope '${s}': ${join(", ", [for k in local.v.scopes[s].role_keys : local.v.roles[k].target if local.v.roles[k].jit_mechanism == "entra_role"])}. The azuread provider has no resource for directory role management policies, so gate 1 is the only control Terraform enforces on this package."
      if length([for k in local.v.scopes[s].role_keys : k if local.v.roles[k].jit_mechanism == "entra_role"]) > 0
    ],
    [
      for s in local.scope_keys : "Complete SCIM provisioning for scope '${s}' on the ${local.v.scopes[s].cloud} side. Terraform stops at the tenant boundary: the group exists and is PIM-managed, but nothing connects it to the target cloud."
      if length([for k in local.v.scopes[s].role_keys : k if local.v.roles[k].jit_mechanism == "pim_for_groups"]) > 0
    ],
    [
      for s in local.scope_keys : "Add a second member to the approver group '${local.v.scopes[s].approver_group_name}' for scope '${s}'. It has ${length(local.v.scopes[s].systemeier)} systemeier, and PIM blocks self-approval, so dual-approval roles there cannot be activated by that person alone."
      if local.v.scopes[s].approver_group_name != null && length(local.v.scopes[s].systemeier) < 2 && !var.defaults.grant_approver_group
    ],
  )
}

output "peer_approval_status" {
  description = <<-EOT
    Where the single-systemeier deadlock is resolved and where it is not.

    `viable` means the scope's package grants approver-group membership, so anyone holding
    the package can approve a peer's activation. `deadlock_risk` means the approver group has
    fewer than two members and nothing here adds more, so a lone systemeier cannot activate
    their own dual-approval role.
  EOT
  value = {
    for s in local.scope_keys : s => {
      has_approver_group  = local.v.scopes[s].approver_group_name != null
      approver_group_name = local.v.scopes[s].approver_group_name
      granted_by_package  = contains(local.approver_group_scopes, s)
      systemeier_count    = length(local.v.scopes[s].systemeier)
      viable              = contains(local.approver_group_scopes, s)
      deadlock_risk = (
        local.v.scopes[s].approver_group_name != null
        && !contains(local.approver_group_scopes, s)
        && length(local.v.scopes[s].systemeier) < 2
      )
    }
  }
}

output "verification_summary" {
  description = <<-EOT
    One line per package, for reading a plan quickly and for checking the result against
    what repo 1 vended.
  EOT
  value = {
    for s in local.scope_keys : s => {
      catalog                 = local.catalog_of_scope[s]
      cloud                   = local.v.scopes[s].cloud
      roles_in_scope          = length(local.v.scopes[s].role_keys)
      roles_attached          = length(local.managed_roles_by_scope[s])
      roles_excluded          = length([for k in local.v.scopes[s].role_keys : k if contains(local.excluded_role_keys, k)])
      approver_group_attached = contains(local.approver_group_scopes, s)
      resource_roles_total    = length(local.resource_roles_by_scope[s])
      duration_days           = local.effective[s].assignment_duration_days
      expiry_ceiling_days     = local.ceiling_by_scope[s]
      gate_1_approver_count   = length(local.v.scopes[s].systemeier)
      gate_2_unmanaged_roles  = [for k in local.v.scopes[s].role_keys : local.v.roles[k].role if local.v.roles[k].jit_mechanism == "entra_role"]
    }
  }
}

output "contract_version" {
  description = "The contract version this module consumed, echoed so a mismatch is visible in outputs as well as in errors."
  value       = local.v.contract_version
}
