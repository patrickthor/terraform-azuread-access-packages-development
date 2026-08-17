output "catalog_id" {
  description = "ID på katalogen som rommer pakkene."
  value       = module.catalog.catalog_id
}

output "catalog_display_name" {
  description = "Visningsnavn på katalogen."
  value       = module.catalog.display_name
}

output "access_package_ids" {
  description = "Access package-ID per composite-key \"{sub}--{rolle}\"."
  value       = { for k, m in module.access_package : k => m.access_package_id }
}

output "access_package_names" {
  description = "Pakkenavn per composite-key, som de vises i MyAccess."
  value       = { for k, m in module.access_package : k => m.access_package_display_name }
}

output "resolved_group_names" {
  description = <<-EOT
    Gruppenavnene som faktisk ble slått opp, per composite-key. Sammenlign med
    `terraform output group_names` i vending-repoet — de skal være identiske.
  EOT
  value       = { for k, inst in local.role_instances : k => inst.group_name }
}

output "resolved_group_object_ids" {
  description = "Object-ID per oppslått gruppe, for verifisering mot vending-repoet."
  value       = { for k, g in data.azuread_group.role_groups : k => g.object_id }
}

output "effective_policies" {
  description = "Effektiv policy per pakke: varighet, access_type, antall godkjenningssteg."
  value       = { for k, m in module.access_package : k => m.effective_policy }
}
