# ==============================================================================
# access-package-catalog — katalog som rommer access packages
#
# Sky-agnostisk. Katalogen er et rent Entra-begrep og er identisk uansett om
# pakkene gir tilgang til Azure, AWS, GCP eller GitHub.
# ==============================================================================

variable "display_name" {
  description = "Visningsnavn på katalogen."
  type        = string
}

variable "description" {
  description = "Beskrivelse av katalogen."
  type        = string
}

variable "externally_visible" {
  description = "Om katalogen er synlig for brukere utenfor tenanten."
  type        = bool
  default     = false
}

variable "published" {
  description = "Om katalogen er publisert og dermed tilgjengelig for forespørsler."
  type        = bool
  default     = true
}

resource "azuread_access_package_catalog" "this" {
  display_name       = var.display_name
  description        = var.description
  externally_visible = var.externally_visible
  published          = var.published
}

output "catalog_id" {
  description = "ID på katalogen."
  value       = azuread_access_package_catalog.this.id
}

output "display_name" {
  description = "Visningsnavn på katalogen."
  value       = azuread_access_package_catalog.this.display_name
}
