# No azurerm and no msgraph. This root talks only to Entra: catalogs, access packages
# and assignment policies. The azurerm *backend* used for state is built into Terraform
# and needs no provider.
#
# Pinned to PATCH level because this is a root and no lock file is committed: ~> 3.9.0
# allows 3.9.x only, where ~> 3.9 would admit every future minor. required_providers is
# the single source of truth for provider versions — see .gitignore for what dropping the
# lock file costs.
#
# Every provider this configuration resolves must be declared here, even one the root
# never references itself: with no lock file, an undeclared provider is unbounded forever.
# Today that is azuread alone. terraform_data comes from the builtin terraform provider,
# which takes no constraint.
#
# The modules use >= so they never become a version ceiling for a consumer.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9.0"
    }
  }

  # Partial configuration. Fill it with:
  #   terraform init -backend-config=backend.hcl
  backend "azurerm" {}
}
