# No provider blocks. Provider configuration is inherited from the caller, which is
# what allows count, for_each and depends_on to be used on this module.
#
# azurerm is deliberately absent: repo 2 touches no ARM resources, so there is no
# features {} block to worry about and the root can stay genuinely thin.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.7"
    }
  }
}
