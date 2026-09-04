output "catalog_id" {
  description = "ID of the catalog."
  value       = azuread_access_package_catalog.this.id
}

output "display_name" {
  description = "Display name of the catalog."
  value       = azuread_access_package_catalog.this.display_name
}
