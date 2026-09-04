# No provider blocks. Provider configuration is inherited from the caller so that
# this module can be used with count, for_each and depends_on.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.7"
    }
  }
}
