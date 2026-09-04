# Provider configuration belongs to the root, never to modules/access-packages.
# A module without provider blocks can be used with count, for_each and depends_on;
# one with them cannot.
provider "azuread" {
  tenant_id = var.tenant_id
}
