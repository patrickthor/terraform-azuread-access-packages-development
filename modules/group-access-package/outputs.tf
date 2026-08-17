output "access_package_id" {
  description = "ID på access package-en."
  value       = azuread_access_package.this.id
}

output "access_package_display_name" {
  description = "Visningsnavn på access package-en, som det vises i MyAccess."
  value       = azuread_access_package.this.display_name
}

output "assignment_policy_id" {
  description = "ID på tildelingspolicyen."
  value       = azuread_access_package_assignment_policy.this.id
}

output "catalog_association_id" {
  description = "ID på koblingen mellom katalogen og gruppen."
  value       = azuread_access_package_resource_catalog_association.this.id
}

output "effective_policy" {
  description = "Oppsummering av policyen som ble satt, for verifisering."
  value = {
    duration_in_days       = var.duration_in_days
    access_type            = var.access_type
    approval_required      = length(var.approval_stages) > 0
    approval_stage_count   = length(var.approval_stages)
    justification_required = var.requestor_justification_required
    requestor_scope_type   = var.requestor_scope_type
  }
}
