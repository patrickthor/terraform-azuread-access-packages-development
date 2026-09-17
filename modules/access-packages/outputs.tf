# ==============================================================================
# Outputs
#
# This module runs last, so its outputs are the verification surface for the whole system.
# Two jobs: publish what was built, and make the gaps loud. A gap that exists only in a code
# comment is a gap that gets lost between two repos.
#
# Everything package-shaped is keyed on PACKAGE NAME, and carries a `kind` so a consumer can
# tell access packages from approver packages without string-matching the name.
# ==============================================================================

output "catalogs" {
  description = <<-EOT
    Label → catalog ID, display name, and whether it was created or adopted.

    `was_adopted = true` means the catalog belongs to someone else and this module only added
    resources to it. Its description, visibility and published state were left alone.
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
    Which packages landed in which catalog, of BOTH kinds.

    A catalog is a delegation boundary — whoever holds a catalog role can manage every package
    inside it — so this is a security-relevant listing rather than a convenience. Read it
    together with `catalogs.*.delegated_to`, and note that it now includes the approver
    packages: whoever can manage a catalog can manage who approves in it.
  EOT
  value = {
    for label in local.catalog_labels : label => {
      for name, kind in local.package_kind : name => {
        kind              = kind
        access_package_id = module.access_package[name].access_package_id
      }
      if local.package_catalog[name] == label
    }
  }
}

output "packages" {
  description = <<-EOT
    Every package, of both kinds.

    `kind` is `"access"` (grants role groups) or `"approver"` (grants only the scope's approver
    group). `source` is `"named"` when the caller declared it in var.packages, `"scope"` when it
    was generated one-per-scope, and `"approver"` for a generated approver package.
  EOT
  value = {
    for name, kind in local.package_kind : name => merge(
      {
        kind              = kind
        display_name      = local.effective[name].display_name
        scope             = local.package_scope[name]
        catalog           = local.package_catalog[name]
        access_package_id = module.access_package[name].access_package_id
        duration_days     = local.effective[name].assignment_duration_days
      },
      kind == "approver" ? {
        source              = "approver"
        approver_group_name = local.scopes_with_approver_group[local.package_scope[name]]
        declared_role_keys  = []
        attached_role_keys  = []
        excluded_role_keys  = []
        } : {
        source              = local.using_explicit_packages ? "named" : "scope"
        approver_group_name = null
        declared_role_keys  = local.resolvable_access_packages[name].role_keys
        attached_role_keys  = local.managed_roles_by_package[name]
        excluded_role_keys  = local.excluded_roles_by_package[name]
      },
    )
  }
}

output "approver_packages" {
  description = <<-EOT
    Scope → the package that grants peer-approval rights over it.

    One per scope, granting only the approver group. Gate 1 is the scope's systemeier, never
    the approver group itself — approvers appointing approvers is an escalation loop with no
    terminating authority, so the chain ends at the systemeier, who are named in the contract
    and are not themselves vended.

    A scope with an approver group but no entry here has been explicitly opted out with
    `approver_packages = { "<scope>" = { enabled = false } }`, and will appear in
    `peer_approval_status` with `deadlock_risk = true` if it has fewer than two systemeier.
  EOT
  value = {
    for s, name in local.approver_package_name : s => {
      package_name      = name
      access_package_id = module.access_package[name].access_package_id
      group_name        = local.scopes_with_approver_group[s]
      group_object_id   = local.v.scopes[s].approver_group_object_id
      catalog           = local.catalog_of_scope[s]
      duration_days     = local.effective[name].assignment_duration_days
      gate_1_approvers  = local.v.scopes[s].systemeier
    }
  }
}

output "access_package_ids" {
  description = "Access package ID per package name, both kinds."
  value       = { for name, m in module.access_package : name => m.access_package_id }
}

output "assignment_policy_ids" {
  description = "Gate 1 assignment policy ID per package name, both kinds."
  value       = { for name, m in module.access_package : name => m.assignment_policy_id }
}

output "scopes" {
  description = <<-EOT
    Scopes present in the contract. Not configured anywhere in this repo — if this looks wrong,
    the contract being passed in is wrong.
  EOT
  value       = local.scope_keys
}

output "granted_groups_by_package" {
  description = <<-EOT
    What each package actually grants.

    For pim_for_groups roles this shows BOTH groups: `group_name` is the plain group the
    package attaches, and `confers_eligibility_on` is the PIM-managed group that membership of
    the plain group makes you eligible for. Without the second, the listing would imply the
    plain group IS the access, when the access is activation on the group behind it.

    `permanent_access = true` is the baseline, active as soon as the assignment lands.
    Everything else still requires activation at gate 2.
  EOT
  value = {
    for name, kind in local.package_kind : name => {
      for label, role in local.resource_roles_by_package[name] : label => (
        contains(keys(local.v.roles), label)
        ? {
          group_name             = local.v.roles[label].group_name
          access_type            = role.access_type
          jit_mechanism          = local.v.roles[label].jit_mechanism
          target                 = local.v.roles[label].target
          permanent_access       = local.v.roles[label].permanent_access
          confers_eligibility_on = local.v.roles[label].pim_group_name
          is_approver_group      = false
        }
        : {
          group_name             = local.scopes_with_approver_group[local.package_scope[name]]
          access_type            = role.access_type
          jit_mechanism          = "n/a"
          target                 = "the right to approve other people's requests for the ${local.package_scope[name]} scope"
          permanent_access       = true
          confers_eligibility_on = null
          is_approver_group      = true
        }
      )
    }
  }
}

output "effective_policies" {
  description = <<-EOT
    What each package enforces after the package definition, package_overrides and defaults
    were layered. Read this rather than the tfvars when verifying intent — the tfvars show only
    the deviations.
  EOT
  value       = { for name, m in module.access_package : name => m.effective_policy }
}

# ------------------------------------------------------------------------------
# The two gates
# ------------------------------------------------------------------------------

output "gate_1_approvers" {
  description = <<-EOT
    Per package, the systemeier acting as named approvers. This is the only approval gate this
    module owns, and it is the systemeier for BOTH kinds of package.

    For approver packages that is deliberate and load-bearing: if the approver group approved
    requests for approver rights, the approver population would be self-perpetuating with no
    authority outside it.

    One approver is workable at gate 1 — a systemeier can approve someone else's request. See
    peer_approval_status for why one is not enough at gate 2.
  EOT
  value = {
    for name, kind in local.package_kind : name => {
      kind            = kind
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
    Repo 1's activation rules, republished per role and interpreted nowhere. Gate 2 is whether
    someone may hold a privilege right now, and repo 1 owns it.

    Note what the contract does and does not carry. It gives the mechanism, whether access is
    permanent, the expiry ceiling and — for pim_for_groups — the PIM-managed group behind the
    plain one. It does not carry repo 1's per-role `approval_type`, so this cannot name the
    gate-2 approver for an individual role. The scope's systemeier and approver group are listed
    because those are the two pools repo 1 draws from, not because this module worked out which
    applies.

    `terraform_governs_activation = false` means an Entra directory role, for which the azuread
    provider has no policy resource at all. For those, gate 1 is the only gate Terraform
    enforces — but "no approval from Terraform" means "governed by tenant admins outside
    Terraform", since active Privileged Role Administrator and Global Administrator do act as
    default approvers. It does not mean the role is open.
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
      attached_group               = r.group_name
      activation_group             = r.pim_group_name
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
    Roles the provider cannot attach with the access type they require.

    EXPECTED TO BE EMPTY under contract v2. Repo 1 now creates a plain group per
    pim_for_groups role and makes it an eligible member of the PIM-managed group, so every role
    is attached as plain Member and the EligibleMember gap no longer applies.

    Kept rather than deleted, for two reasons: it still covers anything else the provider
    cannot express, and an empty list is the useful signal — it is the thing you read to
    confirm nothing is being left out silently.
  EOT
  value       = local.excluded_resource_roles
}

output "unpackaged_roles" {
  description = <<-EOT
    Roles the contract vended that no access package grants.

    Always empty when var.packages is unset, since the generated per-scope packages cover every
    role. Non-empty means repo 1 created a group, an RBAC binding and a PIM policy for access
    that nobody can request — either a deliberate omission or a forgotten role_keys entry.
    Reported rather than assumed either way.
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
    What Terraform could not do, with the portal path.

    Shorter under contract v2 than it used to be: the EligibleMember portal step is gone, because
    plain Member on a plain group is now what produces just-in-time access. What remains is real
    and mostly lives outside Entra.
  EOT
  value = concat(
    length(local.excluded_role_keys) == 0 ? [] : [
      <<-EOT
        Add resource role(s) by hand, in Identity Governance → Catalogs → the catalog named below → Access packages → the package named below → Resource roles.
        ${join("\n", flatten([
      for k, r in local.excluded_resource_roles : [
        for pkg in r.packages : "  catalog '${local.package_catalog[pkg]}' / package '${local.effective[pkg].display_name}' ← group '${r.group_name}' as ${r.required_access_type}  (${r.cloud}, grants ${r.target})"
      ]
]))}
        This should not happen under contract v2 — every role is plain Member on a plain group. Check why repo 1 asked for an access type the provider cannot set.
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
  for label in local.catalog_labels : "Catalog '${local.catalog_settings[label].display_name}' has standing '${local.catalog_settings[label].systemeier_catalog_role}' rights delegated to ${length(local.catalog_delegated_upns[label])} systemeier. This is the one non-expiring, non-activated grant in the system, and it now also covers who can manage the approver packages in that catalog. Review it as you would a permanent role assignment."
  if length(local.catalog_delegated_upns[label]) > 0
],
[
  for s in local.scope_keys : "Set PIM activation rules (MFA, approval, maximum duration) by hand for the entra_role roles in scope '${s}': ${join(", ", [for k in local.v.scopes[s].role_keys : local.v.roles[k].target if local.v.roles[k].jit_mechanism == "entra_role"])}. The azuread provider has no resource for directory role management policies, so gate 1 is the only control Terraform enforces on packages in this scope."
  if length([for k in local.v.scopes[s].role_keys : k if local.v.roles[k].jit_mechanism == "entra_role"]) > 0
],
[
  for s in local.scope_keys : "Complete SCIM provisioning for scope '${s}' on the ${local.v.scopes[s].cloud} side. Terraform stops at the tenant boundary: the groups exist and the PIM-managed one is onboarded, but nothing connects it to the target cloud."
  if length([for k in local.v.scopes[s].role_keys : k if local.v.roles[k].jit_mechanism == "pim_for_groups"]) > 0
],
[
  for s in local.deadlocked_approver_scopes : "Add a second member to the approver group '${local.scopes_with_approver_group[s]}' for scope '${s}'. It has ${length(local.v.scopes[s].systemeier)} systemeier, PIM blocks self-approval, and its approver package is disabled — so dual-approval roles there cannot be activated by that person alone."
],
length(local.reviews_configured_not_deployed) == 0 ? [] : [
  "Access reviews are CONFIGURED BUT NOT DEPLOYED on ${length(local.reviews_configured_not_deployed)} package(s): ${join(", ", local.reviews_configured_not_deployed)}. enable_access_reviews is false, so no review block was written to any assignment policy. The settings are in the access_reviews output for review, but nothing recurring is in force — do not read the presence of configuration as reviews being on. Set enable_access_reviews = true to deploy them.",
],
length(local.packages_with_review_config) == 0 || !var.enable_access_reviews ? [] : [
  "Access reviews are live on ${length(local.packages_with_review_config)} package(s). Two things need confirming by hand, because neither is verifiable from Terraform: that a B2B guest can actually be recorded as a reviewer in this tenant, and that the first campaign opens with a non-empty subject list. A review with an empty subject list runs to its timeout and enforces nothing.",
],
)
}

output "access_reviews" {
  description = <<-EOT
    Package name → the recurring access review configured for it, with the resolved reviewers and
    whether it is actually deployed.

    `deployed` is the master switch. **A package appears here with `deployed = false` when review
    settings exist but `enable_access_reviews` is false** — that is the configured-but-not-live
    state, and it is reported precisely because it is the one someone would misread as "reviews
    are on". Nothing is written to the assignment policy until the switch is on.

    Packages with no review configuration are absent from this map entirely.

    `reviewer_upns` are the scope's systemeier, the same people who approve at gate 1, resolved
    from the same data lookup. Empty for `review_type = "Self"`, where the assignee answers.
  EOT
  value = {
    for name in local.packages_with_review_config : name => {
      kind             = local.package_kind[name]
      scope            = local.package_scope[name]
      deployed         = var.enable_access_reviews
      review_frequency = local.review_effective[name].review_frequency
      review_type      = local.review_effective[name].review_type
      duration_in_days = local.review_effective[name].duration_in_days
      timeout_behavior = local.review_effective[name].timeout_behavior

      approver_justification_required = local.review_effective[name].approver_justification_required
      reviewer_upns                   = local.review_reviewer_upns[name]

      # The interval check that matters: the assignment has to outlive the review for the
      # campaign to have anyone in it.
      assignment_duration_days = local.effective[name].assignment_duration_days
      review_interval_days     = lookup(local.review_interval_days, local.review_effective[name].review_frequency, null)
      expiry_ceiling_days      = lookup(local.ceiling_by_package, name, null)
    }
  }
}

output "access_reviews_configured_not_deployed" {
  description = <<-EOT
    Packages that have review configuration while `enable_access_reviews` is false. Empty when the
    master switch is on, or when nothing is configured.

    Broken out as its own output rather than left for someone to notice inside `access_reviews`,
    because "configured" and "in force" look identical if you only read the settings.
  EOT
  value       = local.reviews_configured_not_deployed
}

output "peer_approval_status" {
  description = <<-EOT
    Per scope: whether peer approval is viable, and which package grants it.

    `approver_package` names the package that grants the approver group. It replaces the old
    `granted_by_packages` list, which existed when the group was attached to whichever access
    packages had the flag set — there is now exactly one package per scope that grants it, and
    holding it does not require holding the access.

    `deadlock_risk` means the approver group has fewer than two members and the scope has no
    approver package, so a lone systemeier cannot activate their own dual-approval role.
  EOT
  value = {
    for s in local.scope_keys : s => {
      has_approver_group  = contains(keys(local.scopes_with_approver_group), s)
      approver_group_name = lookup(local.scopes_with_approver_group, s, null)
      approver_package    = lookup(local.approver_package_name, s, null)
      systemeier_count    = length(local.v.scopes[s].systemeier)
      viable              = contains(local.approver_package_scopes, s)
      deadlock_risk       = contains(local.deadlocked_approver_scopes, s)
    }
  }
}

output "verification_summary" {
  description = <<-EOT
    One line per package, grouped by kind. This is the output people read to confirm the
    access/approver split actually landed, so the two kinds are reported separately rather than
    interleaved in one map.

    `access` entries should grant role groups and nothing else; `approver` entries should grant
    exactly one group each. If an access package still shows an approver group, the split did
    not land.
  EOT
  value = {
    access = {
      for name, p in local.resolvable_access_packages : name => {
        scope                  = local.package_scope[name]
        catalog                = local.package_catalog[name]
        cloud                  = local.v.scopes[local.package_scope[name]].cloud
        roles_declared         = length(p.role_keys)
        roles_attached         = length(local.managed_roles_by_package[name])
        roles_excluded         = length(local.excluded_roles_by_package[name])
        resource_roles_total   = length(local.resource_roles_by_package[name])
        grants_approver_group  = false
        duration_days          = local.effective[name].assignment_duration_days
        expiry_ceiling_days    = lookup(local.ceiling_by_package, name, null)
        gate_1_approver_count  = length(local.v.scopes[local.package_scope[name]].systemeier)
        pim_backed_roles       = [for k in p.role_keys : local.v.roles[k].role if local.v.roles[k].jit_mechanism == "pim_for_groups"]
        gate_2_unmanaged_roles = [for k in p.role_keys : local.v.roles[k].role if local.v.roles[k].jit_mechanism == "entra_role"]

        # "none" when no review is configured. The suffix is deliberate noise: a frequency shown
        # without it would read as in force.
        review = (
          contains(local.packages_with_review_config, name)
          ? "${local.review_effective[name].review_frequency}${var.enable_access_reviews ? "" : " — CONFIGURED, NOT DEPLOYED"}"
          : "none"
        )
      }
    }
    approver = {
      for s, name in local.approver_package_name : name => {
        scope                 = s
        catalog               = local.catalog_of_scope[s]
        grants_group          = local.scopes_with_approver_group[s]
        resource_roles_total  = length(local.resource_roles_by_package[name])
        duration_days         = local.effective[name].assignment_duration_days
        gate_1_approver_count = length(local.v.scopes[s].systemeier)
        gate_1_is_systemeier  = true

        review = (
          contains(local.packages_with_review_config, name)
          ? "${local.review_effective[name].review_frequency}${var.enable_access_reviews ? "" : " — CONFIGURED, NOT DEPLOYED"}"
          : "none"
        )
      }
    }
    totals = {
      access_packages   = length(local.resolvable_access_packages)
      approver_packages = length(local.approver_package_name)
      catalogs          = length(local.catalog_labels)
      roles_in_contract = length(local.role_keys)
      roles_excluded    = length(local.excluded_role_keys)
      roles_unpackaged  = length(local.unpackaged_role_keys)
      contract_version  = local.v.contract_version

      access_reviews_enabled    = var.enable_access_reviews
      packages_with_review      = length(local.packages_with_review_config)
      reviews_actually_deployed = var.enable_access_reviews ? length(local.packages_with_review_config) : 0
    }
  }
}

output "contract_version" {
  description = "The contract version this module consumed, echoed so a mismatch is visible in outputs as well as in errors."
  value       = local.v.contract_version
}
