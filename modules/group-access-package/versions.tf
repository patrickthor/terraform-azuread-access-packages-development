# Sky-agnostisk. Pakken kobler seg til en Entra-gruppe; hvilken sky gruppen gir
# tilgang til er utenfor denne modulens kunnskap.
terraform {
  required_version = ">= 1.5"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.7"
    }
  }
}
