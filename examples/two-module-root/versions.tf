# Pinned to PATCH level because this is a root, and no lock file is committed. Both
# modules use >= so neither becomes a version ceiling.
#
# A real customer root must also declare every provider its module tree resolves, not just
# the ones it references: repo 1 pulls in azurerm and time, so a root calling both modules
# declares azuread, azurerm and time. With no lock file, whatever is left undeclared is
# unbounded.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9.0"
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
