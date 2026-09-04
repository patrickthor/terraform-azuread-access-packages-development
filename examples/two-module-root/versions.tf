# ~> and a committed lockfile, because this is a root. Both modules use >= so neither
# becomes a version ceiling.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.7"
    }
  }

  # A real customer root adds its backend here. Left out so the example validates without
  # a storage account.
  #
  #   backend "azurerm" {}
  #
  # One state for both modules is the whole point of this shape: the contract never
  # touches a state file that the other side has to read back.
}
