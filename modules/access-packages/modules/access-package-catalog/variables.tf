variable "display_name" {
  description = <<-EOT
    Display name of the catalog. When adopt_existing is true this is the lookup key,
    so it must match an existing catalog exactly.
  EOT
  type        = string
}

variable "description" {
  description = "Description of the catalog. Ignored when adopting, and rejected in that case rather than silently dropped."
  type        = string
  default     = null
}

variable "externally_visible" {
  description = <<-EOT
    Whether the catalog is visible to users outside the tenant. Left false: every scope
    in this system grants cloud access, and none of it is meant for guests.
  EOT
  type        = bool
  default     = false
}

variable "published" {
  description = "Whether the catalog is published, and therefore whether its packages are requestable."
  type        = bool
  default     = true
}

variable "adopt_existing" {
  description = <<-EOT
    Look the catalog up instead of creating it. Most real tenants already have a
    catalog, owned by an identity team that will not delegate creation rights.

    When true, this module creates nothing. The catalog's own settings — description,
    externally_visible, published — stay with whoever owns it.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = var.adopt_existing == false || var.description == null
    error_message = <<-EOT
      description cannot be set together with adopt_existing = true.

      Adopting means the catalog belongs to someone else. Rewriting its description
      would be an invisible change to another team's delegation boundary, and accepting
      the field while ignoring it is the accepted-and-ignored pattern this project
      refuses. Drop the description, or create the catalog instead of adopting it.
    EOT
  }
}

variable "delegated_principals" {
  description = <<-EOT
    Principals to grant a catalog role to, as a map of label => object ID.

    Keys are labels from configuration — UPNs, in practice — because for_each keys must
    be known at plan time and the object IDs are resolved from a data source.

    Empty by default. A catalog role assignment is a STANDING grant with no expiry and
    no activation step, which is the opposite of what the rest of this system does.
  EOT
  type        = map(string)
  default     = {}
}

variable "delegated_role_name" {
  description = <<-EOT
    Catalog role granted to delegated_principals.

    "Access package manager" rather than "Catalog owner" on purpose: a catalog owner can
    add arbitrary resources to the catalog, which routes around repo 1 entirely and lets
    someone grant access that no PIM policy governs.
  EOT
  type        = string
  default     = "Access package manager"
}
