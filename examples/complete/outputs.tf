# The interesting outputs for this example are the honesty ones. A clean apply does
# not mean the model holds — read what was left out before believing it.

output "scopes" {
  description = "Scopes derived from the fixture. Four, one package each."
  value       = module.access_packages.scopes
}

output "verification_summary" {
  description = <<-EOT
    Expected for this fixture: 1 catalog, 4 packages, 11 role groups in the contract,
    8 attached, 3 excluded, 3 approver groups attached, 14 catalog resource
    associations, 11 resource package associations.
  EOT
  value       = module.access_packages.verification_summary
}

output "excluded_resource_roles" {
  description = "The three aws-jaws-* roles, left out because the provider cannot express EligibleMember."
  value       = module.access_packages.excluded_resource_roles
}

output "manual_steps_required" {
  description = "What is still needed outside Terraform for this fixture to be a working access model."
  value       = module.access_packages.manual_steps_required
}

output "peer_approval_status" {
  description = "Should show viable = true for tommer, morkanaught and jaws, and false for tenant, which has no approver group."
  value       = module.access_packages.peer_approval_status
}

output "gate_1_approvers" {
  description = "The systemeier per scope, as resolved for the assignment policies."
  value       = module.access_packages.gate_1_approvers
}

output "gate_2_approvers" {
  description = "Repo 1's per-role approval rules, forwarded. Note the two 'not managed by Terraform' entries on the tenant scope."
  value       = module.access_packages.gate_2_approvers
}

output "granted_groups_by_package" {
  description = "What each package actually grants. Note that jaws grants only its approver group."
  value       = module.access_packages.granted_groups_by_package
}
