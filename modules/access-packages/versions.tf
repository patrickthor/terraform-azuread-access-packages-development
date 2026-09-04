# No provider blocks in this module or its children. That is what lets a caller use
# count, for_each and depends_on on it, and the reference customer config uses count.
#
# >= rather than ~> so the module never becomes a version ceiling for a consumer. Roots
# pin with ~> and commit a lockfile.
#
# azurerm is deliberately absent: this module touches no ARM resources.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.7"
    }
  }
}
