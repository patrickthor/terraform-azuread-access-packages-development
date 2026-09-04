output "catalog_id" {
  description = "ID of the catalog, whether it was created here or adopted."
  value       = local.catalog_id
}

output "display_name" {
  description = "Display name of the catalog."
  value       = local.catalog_display_name
}

output "was_adopted" {
  description = <<-EOT
    Whether this catalog was adopted rather than created. Surfaced because it changes who
    owns the delegation boundary, which is not visible from the catalog ID alone.
  EOT
  value       = var.adopt_existing
}

output "delegated_role_assignments" {
  description = <<-EOT
    Catalog role assignment ID per delegated principal label. Non-empty here means
    standing, non-expiring package-management rights exist on this catalog.
  EOT
  value = {
    for k, a in azuread_access_package_catalog_role_assignment.delegated : k => a.id
  }
}
