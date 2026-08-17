# Ingen azurerm og ingen msgraph. Dette repoet snakker kun med Entra:
# access packages, kataloger og gruppeoppslag.
terraform {
  required_version = ">= 1.5"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
