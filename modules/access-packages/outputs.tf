# ==============================================================================
# Outputs
#
# Two jobs here. First, publish what was built. Second, make the gaps loud: the
# roles Terraform could not express, the gate-2 rules it does not own, and the
# manual steps that remain. A gap that only exists in a code comment is a gap that
# gets lost between two repos.
# ==============================================================================

output "catalog_id" {
  description = "ID of the catalog holding every package."
  value       = module.catalog.catalog_id
}

output "catalog_display_name" {
  description = "Display name of the catalog, as shown in MyAccess."
  value       = module.catalog.display_name
}

output "access_package_ids" {
  description = "Access package ID per scope."
  value       = { for s, m in module.access_package : s => m.access_package_id }
}

output "assignment_policy_ids" {
  description = "Gate 1 assignment policy ID per scope."
  value       = { for s, m in module.access_package : s => m.assignment_policy_id }
}

output "scopes" {
  description = <<-EOT
    Scopes derived from repo 1's state, one package each. This list is not
    configured anywhere in repo 2 — if it looks wrong, the state being read is
    wrong.
  EOT
  value       = local.scopes
}

output "roles_by_scope" {
  description = "Composite role keys grouped by the package they belong to, including any excluded by blocker 2.1."
  value       = local.roles_by_scope
}

output "catalog_resource_association_ids" {
  description = <<-EOT
    Catalog resource association ID per group. Includes groups excluded from
    Terraform by blocker 2.1, since registration happens for every group regardless
    of access type.
  EOT
  value = merge(
    { for k, a in azuread_access_package_resource_catalog_association.role_group : k => a.id },
    { for s, a in azuread_access_package_resource_catalog_association.approver_group : "${s}--approvers" => a.id },
  )
}

# ------------------------------------------------------------------------------
# Gate 1 — what this repo owns
# ------------------------------------------------------------------------------

output "gate_1_approvers" {
  description = <<-EOT
    Who approves the request to enter each scope, resolved from
    systemeier_by_scope. This is the only approval gate repo 2 owns.

    A scope showing exactly one approver is workable at gate 1 — a systemeier can
    approve someone else's request — but see peer_approval_status for why one is not
    enough at gate 2.
  EOT
  value = {
    for s in local.scopes : s => {
      systemeier_upns = local.v.systemeier_by_scope[s]
      object_ids      = [for upn in local.v.systemeier_by_scope[s] : data.azuread_user.systemeier[upn].object_id]
      subject_type    = "singleUser"
      stage_count     = 1
      timeout_days    = local.effective[s].approval_timeout_days
    }
  }
}

output "effective_policies" {
  description = <<-EOT
    What each package actually enforces, after defaults and scope_overrides were
    layered. Read this rather than the tfvars when verifying intent — the tfvars
    show only the deviations.
  EOT
  value       = { for s, m in module.access_package : s => m.effective_policy }
}

output "granted_groups_by_package" {
  description = "Groups each package actually grants, with the access type Terraform set."
  value = {
    for s in local.scopes : s => {
      for label, role in local.resource_roles_by_scope[s] : label => {
        group_name        = try(local.v.group_names[label], try(local.v.approver_group_names[s], "approver group for ${s}"))
        access_type       = role.access_type
        is_approver_group = contains(local.approver_group_scopes, s) && label == try(local.approver_role_label[s], "")
      }
    }
  }
}

# ------------------------------------------------------------------------------
# Gate 2 — what repo 1 owns, republished so both gates are visible at once
# ------------------------------------------------------------------------------

output "gate_2_approvers" {
  description = <<-EOT
    Repo 1's approvers_by_role, forwarded verbatim. Repo 2 does not implement or
    interpret gate 2 — PIM activation approval is built in repo 1 — but publishing
    it here means one `terraform output` shows a user's whole journey.

    A value of "not managed by Terraform" means the role is an Entra directory role
    whose activation rules the azuread provider cannot set. For those, gate 1 is the
    only Terraform-enforced control. See trap 6.7.
  EOT
  value       = local.v.approvers_by_role
}

output "entra_activation_governance_gap" {
  description = <<-EOT
    Repo 1's report of what it cannot manage for entra_role (M4) roles, forwarded so
    the gap does not fall between the two repos. Trap 6.4.
  EOT
  value       = local.v.entra_activation_governance_gap
}

# ------------------------------------------------------------------------------
# The gaps — blocker 2.1 and the manual steps
# ------------------------------------------------------------------------------

output "excluded_resource_roles" {
  description = <<-EOT
    Groups deliberately left out of Terraform because their required access type is
    "EligibleMember", which the azuread provider cannot express. Empty when
    manage_pim_for_groups_roles is true.

    Blocker 2.1, option 1. These are not forgotten and not broken — they are the
    honest split. Each one still needs its resource role added by hand.
  EOT
  value       = local.excluded_resource_roles
}

output "manual_steps_required" {
  description = <<-EOT
    Everything that must be finished outside Terraform for the model to actually
    hold. An empty list would be a lie in this tenant; read it before declaring the
    POC done.
  EOT
  value = concat(
    length(local.excluded_role_keys) == 0 ? [] : [
      <<-EOT
        Add ${length(local.excluded_role_keys)} resource role(s) by hand, in Identity Governance → Catalogs → ${var.catalog_display_name} → the package named below → Resource roles.
        Pick "Eligible Member", NOT "Member". The groups are already registered as catalog resources, so they will appear in the picker immediately.
        ${join("\n", [for k, r in local.excluded_resource_roles : "  package '${r.access_package}' ← group '${r.group_name}' as ${r.required_access_type}"])}
        Verify afterwards that the user is eligible and not active: an active membership means blocker 2.1 bit you anyway.
      EOT
    ],
    length(local.m3_scopes) == 0 ? [] : [
      "Confirm repo 1's active_assignment_expire_after for the pim_for_groups groups in scope(s) ${join(", ", local.m3_scopes)} is at least ${var.m3_max_duration_days} days. This module enforces the ceiling it was told about, not the value repo 1 actually set.",
    ],
    [
      for s in local.scopes : "Set PIM activation rules (MFA, approval, maximum duration) by hand for the entra_role roles in scope '${s}'. The azuread provider has no resource for directory role management policies, so gate 1 is the only control Terraform enforces on this package. Trap 6.7."
      if length([for k in local.roles_by_scope[s] : k if local.v.jit_mechanism[k] == "entra_role"]) > 0
    ],
    [
      for s in keys(local.v.approver_group_object_ids) : "Add a second member to the approver group for scope '${s}'. It has ${length(local.v.systemeier_by_scope[s])} systemeier, and PIM blocks self-approval, so dual-approval roles there cannot be activated by that person alone."
      if length(local.v.systemeier_by_scope[s]) < 2 && !var.defaults.grant_approver_group
    ],
  )
}

output "peer_approval_status" {
  description = <<-EOT
    Whether the peer-approval model from section 4.3 is actually viable per scope.

    `viable` means the scope's package grants approver-group membership, so anyone
    assigned the package can approve a peer's activation. `deadlock_risk` means the
    approver group has fewer than two members and nothing in this configuration adds
    more, so a lone systemeier cannot activate their own dual role.
  EOT
  value = {
    for s in local.scopes : s => {
      has_approver_group      = contains(keys(local.v.approver_group_object_ids), s)
      approver_group_name     = try(local.v.approver_group_names[s], null)
      managed_outside_vending = try(local.v.approver_group_is_managed_here[s], null) == false
      granted_by_package      = contains(local.approver_group_scopes, s)
      systemeier_count        = length(local.v.systemeier_by_scope[s])
      viable                  = contains(local.approver_group_scopes, s)
      deadlock_risk = (
        contains(keys(local.v.approver_group_object_ids), s)
        && !contains(local.approver_group_scopes, s)
        && length(local.v.systemeier_by_scope[s]) < 2
      )
    }
  }
}

output "verification_summary" {
  description = <<-EOT
    One-glance check against the acceptance criteria in section 8. Compare the
    counts here with what repo 1 vended before trusting the apply.
  EOT
  value = {
    catalogs_created                 = 1
    packages_created                 = length(local.scopes)
    role_groups_in_contract          = length(local.role_keys)
    role_groups_attached             = length(local.managed_role_keys)
    role_groups_excluded             = length(local.excluded_role_keys)
    approver_groups_attached         = length(local.approver_group_scopes)
    catalog_resource_associations    = length(local.v.group_object_ids) + length(local.approver_group_scopes)
    resource_package_associations    = length(local.managed_role_keys) + length(local.approver_group_scopes)
    assignment_policies              = length(local.scopes)
    m3_scopes                        = local.m3_scopes
    m3_expiry_ceiling_days           = var.m3_max_duration_days
    eligibility_downgraded_to_active = var.manage_pim_for_groups_roles
  }
}
