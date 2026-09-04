output "scopes" {
  description = "Scopes derived from repo 1's state. One package each."
  value       = module.access_packages.scopes
}

output "access_package_ids" {
  description = "Access package ID per scope."
  value       = module.access_packages.access_package_ids
}

output "verification_summary" {
  description = "Counts to check against what repo 1 vended."
  value       = module.access_packages.verification_summary
}

output "manual_steps_required" {
  description = "What still has to be done outside Terraform. Read this before calling the deployment complete."
  value       = module.access_packages.manual_steps_required
}

output "excluded_resource_roles" {
  description = "Groups the provider cannot attach with the access type they require. Blocker 2.1."
  value       = module.access_packages.excluded_resource_roles
}
