# Provider configuration lives in the example, not in the module. This is the other
# half of the no-provider-blocks rule: the module inherits whatever the caller
# configures, so the same module works here on local state and in the root against a
# remote backend.
provider "azuread" {
  tenant_id = var.tenant_id
}
