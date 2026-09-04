terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.7"
    }
  }

  # A real consumer adds their own backend here. Left out so the example can be
  # validated without a storage account:
  #
  #   backend "azurerm" {}
  #
  # Note that this is the consumer's own state, which must use a different key from
  # repo 1's access-vending.tfstate — that one is read through
  # data.terraform_remote_state above.
}
