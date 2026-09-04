# Provider configuration lives in the root, never in either module. That is the other half
# of the no-provider-blocks rule, and it is what makes `count` on the access-packages
# module legal in main.tf.
provider "azuread" {
  tenant_id = var.tenant_id
}
