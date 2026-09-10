# No provider blocks. Provider configuration is inherited from the caller so this module
# can be used with count, for_each and depends_on.
#
# >= rather than ~> so the module never becomes a version ceiling for a consumer. Only
# roots pin, and they pin to patch level since no lock file is committed.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.7"
    }
  }
}
