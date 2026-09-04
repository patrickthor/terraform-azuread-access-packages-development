# No provider blocks. Provider configuration is inherited from the caller so this module
# can be used with count, for_each and depends_on.
#
# >= rather than ~> so the module never becomes a version ceiling for a consumer. Roots
# pin with ~> and commit a lockfile.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.7"
    }
  }
}
