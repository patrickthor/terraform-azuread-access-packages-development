# ==============================================================================
# examples/github-consumption — consuming the module the way another team would
#
# Two things differ from examples/complete, and they are the reason both exist:
#   - the contract comes from repo 1's live remote state, not a literal fixture
#   - the module is sourced from a pinned git ref rather than a relative path
#
# Because the module declares no provider blocks, it can be sourced from git and
# still be used with count, for_each and depends_on by the caller.
# ==============================================================================

data "terraform_remote_state" "vending" {
  backend = "azurerm"

  config = {
    resource_group_name  = var.state_resource_group_name
    storage_account_name = var.state_storage_account_name
    container_name       = var.state_container_name
    key                  = var.vending_state_key
    use_azuread_auth     = true
  }
}

locals {
  v = data.terraform_remote_state.vending.outputs
}

module "access_packages" {
  # THIS is the line a real consumer writes, once the repo has a tag:
  #
  #   source = "git::https://github.com/patrickthor/terraform-azuread-access-packages-development.git//modules/access-packages?ref=v1.0.0"
  #
  # Pin to a tag or a commit, never to a branch. The module derives its whole
  # package set from repo 1's state, so with a floating ref a module change and a
  # taxonomy change can land in the same plan with nothing to tell them apart.
  #
  # The relative path is used here instead so that `terraform validate` passes in CI
  # without network access and without the repo having been tagged yet. Swap the two
  # lines when you copy this example out.
  source = "../../modules/access-packages"

  vending = {
    group_names                = local.v.group_names
    group_object_ids           = local.v.group_object_ids
    access_package_access_type = local.v.access_package_access_type
    jit_mechanism              = local.v.jit_mechanism

    systemeier_by_scope            = local.v.systemeier_by_scope
    approver_group_object_ids      = local.v.approver_group_object_ids
    approver_group_names           = local.v.approver_group_names
    approver_group_is_managed_here = local.v.approver_group_is_managed_here

    approvers_by_role               = try(local.v.approvers_by_role, {})
    access_model                    = try(local.v.access_model, {})
    activation_settings             = try(local.v.activation_settings, {})
    entra_activation_governance_gap = try(local.v.entra_activation_governance_gap, {})
  }

  catalog_display_name = var.catalog_display_name

  defaults = {
    assignment_duration_days = var.assignment_duration_days
    approval_timeout_days    = 7
    require_justification    = true
    grant_approver_group     = true
  }

  scope_overrides = var.scope_overrides
}
