output "access_package_id" {
  description = "ID of the access package."
  value       = azuread_access_package.this.id
}

output "access_package_display_name" {
  description = "Display name of the package, as shown in MyAccess."
  value       = azuread_access_package.this.display_name
}

output "assignment_policy_id" {
  description = "ID of the assignment policy."
  value       = azuread_access_package_assignment_policy.this.id
}

output "resource_package_association_ids" {
  description = "Association ID per granted group, keyed by the caller's label."
  value = {
    for k, a in azuread_access_package_resource_package_association.this :
    k => a.id
  }
}

output "effective_policy" {
  description = <<-EOT
    Summary of what was actually configured, for verification against the intent.
    Read this rather than trusting the tfvars, since defaults and coalescing are
    applied on the way in.
  EOT
  value = {
    duration_in_days       = var.duration_in_days
    granted_groups         = keys(var.resource_roles)
    access_types           = { for k, r in var.resource_roles : k => r.access_type }
    approval_required      = length(var.approval_stages) > 0
    approval_stage_count   = length(var.approval_stages)
    justification_required = var.requestor_justification_required
    requestor_scope_type   = var.requestor_scope_type
  }
}
