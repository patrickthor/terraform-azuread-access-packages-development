# ==============================================================================
# Root outputs — forwarded from the module
#
# Read `manual_steps_required` and `excluded_resource_roles` first. A successful
# apply here does not mean the access model holds; parts of it cannot be expressed
# in Terraform today and those parts are listed there.
# ==============================================================================

output "catalog_id" {
  description = "ID of the catalog holding every package."
  value       = module.access_packages.catalog_id
}

output "catalog_display_name" {
  description = "Display name of the catalog, as shown in MyAccess."
  value       = module.access_packages.catalog_display_name
}

output "scopes" {
  description = "Scopes derived from repo 1's state. One access package each."
  value       = module.access_packages.scopes
}

output "access_package_ids" {
  description = "Access package ID per scope."
  value       = module.access_packages.access_package_ids
}

output "assignment_policy_ids" {
  description = "Gate 1 assignment policy ID per scope."
  value       = module.access_packages.assignment_policy_ids
}

output "roles_by_scope" {
  description = "Composite role keys grouped by the package they belong to."
  value       = module.access_packages.roles_by_scope
}

output "granted_groups_by_package" {
  description = "Groups each package grants, with the access type Terraform set."
  value       = module.access_packages.granted_groups_by_package
}

output "effective_policies" {
  description = "What each package actually enforces, after defaults and overrides were layered."
  value       = module.access_packages.effective_policies
}

# ------------------------------------------------------------------------------
# The two gates
# ------------------------------------------------------------------------------

output "gate_1_approvers" {
  description = "Who approves entry to each scope. The only approval gate repo 2 owns."
  value       = module.access_packages.gate_1_approvers
}

output "gate_2_approvers" {
  description = "Repo 1's approvers_by_role, forwarded. PIM activation approval, which repo 1 owns."
  value       = module.access_packages.gate_2_approvers
}

output "entra_activation_governance_gap" {
  description = "Repo 1's report of what it cannot manage for entra_role activation. Trap 6.4."
  value       = module.access_packages.entra_activation_governance_gap
}

# ------------------------------------------------------------------------------
# Honesty outputs
# ------------------------------------------------------------------------------

output "excluded_resource_roles" {
  description = "Groups left out of Terraform because the provider cannot express their access type. Blocker 2.1."
  value       = module.access_packages.excluded_resource_roles
}

output "manual_steps_required" {
  description = "Everything that must be finished outside Terraform for the model to actually hold."
  value       = module.access_packages.manual_steps_required
}

output "peer_approval_status" {
  description = "Whether peer approval is viable per scope, and where a lone systemeier would deadlock."
  value       = module.access_packages.peer_approval_status
}

output "verification_summary" {
  description = "Counts to compare against the acceptance criteria in section 8 of the steering document."
  value       = module.access_packages.verification_summary
}
