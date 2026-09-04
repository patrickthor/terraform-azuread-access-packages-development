# ==============================================================================
# Root — split-state reference configuration
#
# THE REFERENCE ARCHITECTURE IS NOT THIS ONE. In the architecture both repos are
# built for, a customer root calls both modules and the contract flows in memory:
#
#   module "access_vending"  { source = "git::...access-vending//modules/access-vending?ref=v1.0.0"  ... }
#   module "access_packages" { source = "git::...access-packages//modules/access-packages?ref=v1.0.0"
#                              vending = module.access_vending.contract }
#
# One root, one state, one apply, one committed terraform.tfvars — and the apply order
# becomes a property of the dependency graph rather than a convention. See
# examples/two-module-root for that shape.
#
# This root exists because repo 2 cannot vendor repo 1's module, and because the POC
# tenant is currently deployed as two separate states. It is the documented
# split-state variant: the remote state read lives HERE, in a root, never in the
# module. The module takes a plain typed object precisely so that where the contract
# comes from stays the caller's decision.
#
# The cost of this variant is real and worth naming: with two states, nothing forces
# repo 1 to be applied first. The plan cannot resolve without repo 1's state, which
# catches the empty case, but a *stale* state still plans cleanly. For pim_for_groups
# roles that matters — it is the act of writing the PIM policy that onboards a group to
# PIM for Groups, and until then the platform does not offer EligibleMember at all.
# ==============================================================================

data "terraform_remote_state" "vending" {
  backend = "azurerm"

  config = {
    resource_group_name  = var.state_resource_group_name
    storage_account_name = var.state_storage_account_name
    container_name       = var.state_container_name
    key                  = var.vending_state_key
    use_azuread_auth     = var.state_use_azuread_auth
  }
}

module "access_packages" {
  source = "./modules/access-packages"

  # Repo 1 exposes exactly one machine-readable output and this module accepts exactly
  # one machine-readable input. They are the same object, so there is nothing to
  # assemble here and no field to guard with try(). A try() around a contract field is
  # how a missing access_type silently becomes standing access; contract_version is
  # what handles compatibility, and it fails loudly.
  vending = data.terraform_remote_state.vending.outputs.contract

  catalogs        = var.catalogs
  defaults        = var.defaults
  scope_overrides = var.scope_overrides

  manage_pim_for_groups_roles      = var.manage_pim_for_groups_roles
  acknowledge_m3_active_membership = var.acknowledge_m3_active_membership
}
