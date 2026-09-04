# ==============================================================================
# Root — thin passthrough to modules/access-packages
#
# The root does exactly two things: read repo 1's state, and hand it to the module.
# All logic lives in the module so that it can be consumed from a pinned git ref by
# anyone else, with a different state layout or none at all.
#
# PREREQUISITE: repo 1 (access-vending) must have applied first. Under this design
# that is not a convention you have to remember — the plan physically cannot resolve
# without repo 1's state, so getting the order wrong fails instead of silently
# producing active membership where eligibility was intended. See trap 6.2.
# ==============================================================================

# ------------------------------------------------------------------------------
# The contract from repo 1
#
# Remote state rather than looking groups up by display_name. A name lookup sounds
# more loosely coupled, but to look a group up by name repo 2 would have to know
# every scope key and role key independently — its own copy of the taxonomy, which
# is the duplication worth avoiding. Add a role in repo 1, forget it here, and it
# would silently have no access package. See section 3.1.
#
# Requires Storage Blob Data Reader on repo 1's state storage account.
# ------------------------------------------------------------------------------

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

locals {
  v = data.terraform_remote_state.vending.outputs
}

module "access_packages" {
  source = "./modules/access-packages"

  # The taxonomy. Assembled explicitly rather than passed as a whole object so that
  # a missing or renamed output in repo 1 fails here, by name, instead of surfacing
  # as a confusing type error deeper in the module.
  vending = {
    group_names                = local.v.group_names
    group_object_ids           = local.v.group_object_ids
    access_package_access_type = local.v.access_package_access_type
    jit_mechanism              = local.v.jit_mechanism

    systemeier_by_scope            = local.v.systemeier_by_scope
    approver_group_object_ids      = local.v.approver_group_object_ids
    approver_group_names           = local.v.approver_group_names
    approver_group_is_managed_here = local.v.approver_group_is_managed_here

    # Reference only — forwarded to outputs, never interpreted. try() because these
    # describe gate 2, which repo 1 owns; if an older repo 1 does not publish them,
    # repo 2 still builds a correct gate 1 and simply has less to report.
    approvers_by_role               = try(local.v.approvers_by_role, {})
    access_model                    = try(local.v.access_model, {})
    activation_settings             = try(local.v.activation_settings, {})
    entra_activation_governance_gap = try(local.v.entra_activation_governance_gap, {})
  }

  catalog_display_name = var.catalog_display_name
  catalog_description  = var.catalog_description

  defaults        = var.defaults
  scope_overrides = var.scope_overrides

  manage_pim_for_groups_roles      = var.manage_pim_for_groups_roles
  acknowledge_m3_active_membership = var.acknowledge_m3_active_membership
  m3_max_duration_days             = var.m3_max_duration_days
}
