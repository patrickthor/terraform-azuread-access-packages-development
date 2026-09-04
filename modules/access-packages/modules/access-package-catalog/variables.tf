variable "display_name" {
  description = "Display name of the catalog."
  type        = string
}

variable "description" {
  description = "Description of the catalog."
  type        = string
}

variable "externally_visible" {
  description = "Whether the catalog is visible to users outside the tenant."
  type        = bool
  default     = false
}

variable "published" {
  description = "Whether the catalog is published and therefore available for requests."
  type        = bool
  default     = true
}
