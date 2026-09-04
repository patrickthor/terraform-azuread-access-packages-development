# The interesting outputs here are the honesty ones. A clean apply does not mean the
# model holds — read what was left out before believing it.

output "catalogs" {
  description = "Two catalogs: platform and privileged. Both created, neither adopted, no standing delegation."
  value       = module.access_packages.catalogs
}

output "packages_by_catalog" {
  description = "platform gets jaws, morkanaught and tommer; privileged gets tenant on its own."
  value       = module.access_packages.packages_by_catalog
}

output "verification_summary" {
  description = <<-EOT
    One line per package. Expected for this fixture: tommer 3 roles attached + approver
    group, morkanaught 3 + approver group, jaws 0 attached and 3 excluded but with its
    approver group, tenant 2 attached and no approver group.
  EOT
  value       = module.access_packages.verification_summary
}

output "excluded_resource_roles" {
  description = "The three aws-jaws-* roles, left out because the provider validates EligibleMember away."
  value       = module.access_packages.excluded_resource_roles
}

output "manual_steps_required" {
  description = "What is still needed outside Terraform: three portal resource roles, the entra_role PIM rules, and SCIM on the AWS side."
  value       = module.access_packages.manual_steps_required
}

output "peer_approval_status" {
  description = "viable = true for tommer, morkanaught and jaws; false for tenant, which has no approver group."
  value       = module.access_packages.peer_approval_status
}

output "gate_1_approvers" {
  description = "The systemeier per scope, as resolved for the assignment policies."
  value       = module.access_packages.gate_1_approvers
}

output "gate_2_approvers" {
  description = "Republished per role. Note terraform_governs_activation = false on both tenant roles."
  value       = module.access_packages.gate_2_approvers
}

output "granted_groups_by_package" {
  description = "What each package actually grants. Note that jaws grants only its approver group."
  value       = module.access_packages.granted_groups_by_package
}
