# ==============================================================================
# examples/two-module-root — THE REFERENCE ARCHITECTURE
#
# One root config, one state, one apply, one committed terraform.tfvars. A customer adds
# a subscription and three roles to access_scopes, runs one apply, and gets groups, RBAC,
# PIM policies, a catalog and a requestable access package.
#
# What this shape buys, and why it is the target rather than the split-state root:
#
#   - The contract flows in memory as module.access_vending.contract. Nothing is written
#     to a state file for the other side to read, so there is no state layout coupling
#     and no Storage Blob Data Reader grant.
#   - Apply order is a property of the dependency graph. Repo 2's resources reference
#     repo 1's outputs, so a single apply physically cannot get the order wrong. That
#     matters concretely: for pim_for_groups roles it is the act of writing the PIM
#     policy that onboards the group to PIM for Groups, and until then the platform does
#     not offer EligibleMember as a resource role at all.
#   - One committed tfvars is the governance record. For an access system, the
#     configuration IS the audit trail of who may reach what.
#
# Both modules are pinned to tags. Never a branch: repo 2 derives its entire package set
# from repo 1's contract, so with a floating ref a module change and a taxonomy change
# can land in the same plan with nothing to tell them apart. A branch pin in a customer
# root is a review finding.
# ==============================================================================

# ------------------------------------------------------------------------------
# Repo 1 — WHICH access grants exist
#
# Commented out because this repo cannot vendor repo 1's module and CI validates this
# example without network access. The fixture below stands in for its `contract` output.
# Uncomment this block, delete the fixture, and swap the `vending` argument to
# module.access_vending.contract.
# ------------------------------------------------------------------------------

# module "access_vending" {
#   source = "git::https://github.com/patrickthor/terraform-azuread-access-vending-development.git//modules/access-vending?ref=v1.0.0"
#
#   access_scopes   = var.access_scopes
#   default_catalog = var.default_catalog
#   tenant_id       = var.tenant_id
# }

locals {
  # STANDS IN FOR module.access_vending.contract.
  #
  # Deliberately minimal — two roles in one scope, one catalog — because this example is
  # about the wiring, not about coverage. examples/complete has the full-fidelity fixture
  # with all three mechanisms, two catalogs and the EligibleMember exclusion.
  access_vending_contract = {
    contract_version = 1

    roles = {
      "sandbox--reader" = {
        scope            = "sandbox", role = "reader"
        group_name       = "azure-sandbox-reader", group_object_id = "00000000-0000-0000-0000-0000000000f1"
        access_type      = "Member", jit_mechanism = "azure_pim"
        permanent_access = true, target = "Reader", max_assignment_days = null
      }
      "sandbox--contributor" = {
        scope            = "sandbox", role = "contributor"
        group_name       = "azure-sandbox-contributor", group_object_id = "00000000-0000-0000-0000-0000000000f2"
        access_type      = "Member", jit_mechanism = "azure_pim"
        permanent_access = false, target = "Contributor", max_assignment_days = null
      }
    }

    scopes = {
      "sandbox" = {
        catalog                  = "platform"
        cloud                    = "azure"
        scope_id                 = "/subscriptions/33333333-3333-3333-3333-333333333333"
        systemeier               = ["patrick@example.onmicrosoft.com", "edgar@example.onmicrosoft.com"]
        approver_group_name      = "azure-sandbox-approvers"
        approver_group_object_id = "00000000-0000-0000-0000-0000000000fc"
        role_keys                = ["sandbox--contributor", "sandbox--reader"]
      }
    }

    catalogs = {
      "platform" = { scope_keys = ["sandbox"] }
    }
  }
}

# ------------------------------------------------------------------------------
# Repo 2 — WHO can receive them
#
# `count` is used here on purpose, not incidentally. It is only legal because neither
# this module nor any of its children declares a provider block, and it is what lets a
# customer stage the rollout: vend the groups and RBAC first, add the request layer once
# the licensing question is settled.
# ------------------------------------------------------------------------------

module "access_packages" {
  source = "../../modules/access-packages"
  count  = var.enable_access_packages ? 1 : 0

  # In the real thing: vending = module.access_vending.contract
  vending = local.access_vending_contract

  catalogs        = var.catalogs
  defaults        = var.defaults
  scope_overrides = var.scope_overrides
}
