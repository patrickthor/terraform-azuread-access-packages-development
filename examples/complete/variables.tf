variable "tenant_id" {
  description = "Entra tenant ID."
  type        = string
}

variable "catalog_display_name" {
  description = "Display name of the catalog created by this example."
  type        = string
  default     = "Cloud Access (example)"
}
