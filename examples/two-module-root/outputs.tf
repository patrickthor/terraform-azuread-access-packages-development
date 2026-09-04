# Repo 2 runs last, so its outputs are the verification surface for the whole system.
#
# `one(module.x[*].attr)` rather than `try(...)`: the module is count'd, so the splat
# yields a 0- or 1-element list and one() turns that into the value or null. No try(),
# because try() hides real errors as well as absent ones.

output "catalogs" {
  description = "Label → catalog ID, display name, and whether it was created or adopted. Null when the request layer is disabled."
  value       = one(module.access_packages[*].catalogs)
}

output "packages_by_catalog" {
  description = "Which packages landed in which catalog. Security-relevant: a catalog is a delegation boundary."
  value       = one(module.access_packages[*].packages_by_catalog)
}

output "gate_1_approvers" {
  description = "Per package, the systemeier acting as named approvers."
  value       = one(module.access_packages[*].gate_1_approvers)
}

output "gate_2_approvers" {
  description = "Repo 1's activation rules, republished per role."
  value       = one(module.access_packages[*].gate_2_approvers)
}

output "verification_summary" {
  description = "One line per package."
  value       = one(module.access_packages[*].verification_summary)
}

output "manual_steps_required" {
  description = "What Terraform could not do. Read this before believing the apply."
  value       = one(module.access_packages[*].manual_steps_required)
}

output "excluded_resource_roles" {
  description = "Groups whose required access type the provider cannot express."
  value       = one(module.access_packages[*].excluded_resource_roles)
}
