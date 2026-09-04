# No backend block: this example runs on local state on purpose, so it can be validated
# and planned without access to any storage account.
#
# ~> because this is a root. The modules use >= so they never become a version ceiling.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.7"
    }
  }
}
