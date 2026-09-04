# No azurerm and no msgraph. This repo talks only to Entra: catalogs, access
# packages and assignment policies.
#
# The azurerm *backend* is used for state, which needs no azurerm provider — the
# backend is built into Terraform. The `time` provider that earlier versions used to
# wait out group-name propagation is gone too: object IDs now come from repo 1's
# state, so there is nothing to wait for.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.7"
    }
  }

  # Partial configuration. Fill it with:
  #   terraform init -backend-config=backend.hcl
  backend "azurerm" {}
}
