# ==============================================================================
# Root outputs — forwarded from the module
#
# Read `manual_steps_required` first. A successful apply does not mean the access model
# holds: parts of it cannot be expressed in Terraform today, and those parts are listed
# there rather than in a comment.
# ==============================================================================

output "catalogs" {
  description = "Label → catalog ID, display name, whether it was created or adopted, and any standing delegation."
  value       = module.access_packages.catalogs
}

output "packages_by_catalog" {
  description = "Which packages landed in which catalog. A catalog is a delegation boundary, so this is security-relevant."
  value       = module.access_packages.packages_by_catalog
}

output "access_package_ids" {
  description = "Access package ID per scope."
  value       = module.access_packages.access_package_ids
}

output "assignment_policy_ids" {
  description = "Gate 1 assignment policy ID per scope."
  value       = module.access_packages.assignment_policy_ids
}

output "granted_groups_by_package" {
  description = "What each package actually grants, after exclusions."
  value       = module.access_packages.granted_groups_by_package
}

output "effective_policies" {
  description = "What each package enforces after defaults and overrides were layered."
  value       = module.access_packages.effective_policies
}

output "gate_1_approvers" {
  description = "Per package, the systemeier acting as named approvers. The only approval gate this repo owns."
  value       = module.access_packages.gate_1_approvers
}

output "gate_2_approvers" {
  description = "Repo 1's activation rules, republished per role and interpreted nowhere."
  value       = module.access_packages.gate_2_approvers
}

output "excluded_resource_roles" {
  description = "Groups left out of Terraform because the provider cannot express the access type they require."
  value       = module.access_packages.excluded_resource_roles
}

output "manual_steps_required" {
  description = "What Terraform could not do, with the portal path. Read this before believing an apply."
  value       = module.access_packages.manual_steps_required
}

output "peer_approval_status" {
  description = "Where the single-systemeier deadlock is resolved and where it is not."
  value       = module.access_packages.peer_approval_status
}

output "verification_summary" {
  description = "One line per package, for reading a plan quickly."
  value       = module.access_packages.verification_summary
}

output "contract_version" {
  description = "The contract version consumed from repo 1."
  value       = module.access_packages.contract_version
}
