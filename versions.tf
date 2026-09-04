# No azurerm and no msgraph. This root talks only to Entra: catalogs, access packages
# and assignment policies. The azurerm *backend* used for state is built into Terraform
# and needs no provider.
#
# ~> here and a committed lockfile, because this is a root. The modules use >= so they
# never become a version ceiling for a consumer.
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
