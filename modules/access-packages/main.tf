# ==============================================================================
# access-packages — the consumable module
#
# Builds one catalog, one access package per scope, and one assignment policy per
# package, entirely from repo 1's state. No group name and no scope key is written
# anywhere in this repo.
#
# Layout:
#   catalog                        (leaf module)
#     └─ catalog resource association   one per group, created HERE
#          └─ access package            one per scope (leaf module)
#               ├─ resource package association   one per granted group
#               └─ assignment policy              gate 1
#
# The catalog associations live in this module rather than in the access-package
# leaf module on purpose. They are unique per (catalog, group), but under the
# peer-approval model the same approver group is attached to more than one package.
# Creating the association inside the leaf would produce duplicates and fail.
#
# NO PROVIDER BLOCKS in this module or its children. That is what lets callers use
# count, for_each and depends_on on it.
# ==============================================================================

module "catalog" {
  source = "./modules/access-package-catalog"

  display_name       = var.catalog_display_name
  description        = var.catalog_description
  externally_visible = var.catalog_externally_visible
  published          = var.catalog_published
}

# ------------------------------------------------------------------------------
# Register every group as a catalog resource
#
# Done for ALL role groups, including the ones excluded from Terraform by blocker
# 2.1. Registration is access-type agnostic — the access type is chosen later, on
# the package association — so registering the excluded groups here costs nothing
# and reduces the manual portal step to picking "Eligible Member" on an
# already-registered resource.
# ------------------------------------------------------------------------------

resource "azuread_access_package_resource_catalog_association" "role_group" {
  for_each = local.v.group_object_ids

  catalog_id             = module.catalog.catalog_id
  resource_origin_id     = each.value
  resource_origin_system = "AadGroup"
}

# Approver groups are keyed on scope, not on the composite key, so they need their
# own association set. Only created when option A is in effect; without it there is
# no manual follow-up step that would justify registering them.
resource "azuread_access_package_resource_catalog_association" "approver_group" {
  for_each = toset(local.approver_group_scopes)

  catalog_id             = module.catalog.catalog_id
  resource_origin_id     = local.v.approver_group_object_ids[each.value]
  resource_origin_system = "AadGroup"
}

# ------------------------------------------------------------------------------
# Gate 1 approvers — resolve systemeier UPNs to object IDs
#
# Requires User.Read.All as an application permission. A 403 here rather than a
# "not found" usually means the permission was never granted.
# ------------------------------------------------------------------------------

data "azuread_user" "systemeier" {
  for_each = local.all_systemeier_upns

  user_principal_name = each.value
}

# ------------------------------------------------------------------------------
# One package per scope
# ------------------------------------------------------------------------------

module "access_package" {
  source   = "./modules/access-package"
  for_each = toset(local.scopes)

  catalog_id   = module.catalog.catalog_id
  display_name = local.effective[each.value].display_name
  description  = local.effective[each.value].description
  hidden       = local.effective[each.value].hidden

  resource_roles = local.resource_roles_by_scope[each.value]

  policy_display_name = "Request access to ${each.value}"
  policy_description  = "Gate 1 for the ${each.value} scope: the systemeier decide who may enter. Privilege elevation within the scope is gated separately by the PIM policies in repo 1."

  duration_in_days                 = local.effective[each.value].assignment_duration_days
  requestor_scope_type             = local.effective[each.value].requestor_scope_type
  requests_accepted                = local.effective[each.value].requests_accepted
  requestor_justification_required = local.effective[each.value].require_justification
  question_text                    = local.effective[each.value].question_text

  # Exactly one stage, holding the scope's systemeier as named approvers. One
  # signature from any of them is enough. A second stage is possible on this
  # resource — it is the only place in the system where sequential approval is
  # achievable — but gate 1 answers a single question, so one stage is correct.
  approval_stages = [{
    timeout_days                    = local.effective[each.value].approval_timeout_days
    approver_justification_required = true
    approvers = [
      for upn in local.v.systemeier_by_scope[each.value] : {
        object_id    = data.azuread_user.systemeier[upn].object_id
        subject_type = "singleUser"
      }
    ]
  }]

  depends_on = [
    azuread_access_package_resource_catalog_association.role_group,
    azuread_access_package_resource_catalog_association.approver_group,
  ]
}

# ==============================================================================
# Plan-time preconditions
#
# These fail the plan rather than warning, which is why they are terraform_data
# preconditions and not `check` blocks — a check block reports and continues, so
# an apply would still go through and produce the broken configuration.
#
# Each one guards a failure that would otherwise be silent: an apply that succeeds
# and leaves something subtly wrong in the portal.
# ==============================================================================

resource "terraform_data" "validate_derivation" {
  input = {
    scopes    = local.scopes
    role_keys = local.role_keys
  }

  lifecycle {
    precondition {
      condition     = length(local.scopes) > 0
      error_message = <<-EOT
        No scopes could be derived from repo 1's state, so there is nothing to
        build.

        vending.group_names had entries but none of them yielded a scope, which
        should be impossible given the key-shape validation on the variable. If you
        see this, the state being read is not repo 1's.
      EOT
    }

    precondition {
      condition     = length(local.unknown_override_scopes) == 0
      error_message = <<-EOT
        scope_overrides names scopes that do not exist in repo 1's state: ${join(", ", local.unknown_override_scopes)}

        Known scopes are: ${join(", ", local.scopes)}

        An override on an unknown scope has no effect at all, so the deviation you
        intended silently does not happen — the package keeps the default duration
        or timeout and you would only find out by reading the portal. The usual
        cause is a typo, or a scope that was renamed in repo 1 (which is
        destructive there; see trap 6.6).
      EOT
    }
  }
}

resource "terraform_data" "validate_gate_1_approvers" {
  input = { for s in local.scopes : s => length(local.v.systemeier_by_scope[s]) }

  lifecycle {
    precondition {
      condition = alltrue([
        for s in local.scopes : length(local.v.systemeier_by_scope[s]) > 0
      ])
      error_message = <<-EOT
        These scopes have an empty systemeier list in repo 1's state: ${join(", ", [for s in local.scopes : s if length(local.v.systemeier_by_scope[s]) == 0])}

        Gate 1 requires at least one approver. With none, the approval stage cannot
        be satisfied by anyone, so every request for the package sits until it times
        out after ${var.defaults.approval_timeout_days} days and the access is never
        granted. The package would look perfectly healthy in MyAccess the whole
        time.

        Fix this in repo 1 by giving the scope a systemeier, rather than by
        disabling approval here. An unapproved package on these scopes would hand
        out cloud access to anyone who asks.
      EOT
    }
  }
}

resource "terraform_data" "validate_packages_grant_something" {
  input = { for s in local.scopes : s => length(local.resource_roles_by_scope[s]) }

  lifecycle {
    precondition {
      condition     = length(local.empty_scopes) == 0
      error_message = <<-EOT
        These packages would grant no group memberships at all: ${join(", ", local.empty_scopes)}

        A package with no resource roles is still requestable and still approvable,
        so it appears in MyAccess as working access while granting nothing. That is
        worse than the package not existing.

        Every role in the scope was excluded because its access type is
        "EligibleMember", which the azuread provider cannot express (blocker 2.1),
        and defaults.grant_approver_group is false so no approver group was attached
        either. Choose one:

          - set defaults.grant_approver_group = true, if the scope has an approver
            group in repo 1, so the package at least grants peer-approval rights
          - build the scope's packages by hand in the portal and accept that this
            scope is not IaC-managed
          - set manage_pim_for_groups_roles = true, accepting that eligibility
            becomes standing active membership

        The excluded_resource_roles output lists the affected groups.
      EOT
    }
  }
}

resource "terraform_data" "validate_m3_expiry_ceiling" {
  input = {
    ceiling_days = var.m3_max_duration_days
    m3_scopes    = local.m3_scopes
  }

  lifecycle {
    # Trap 6.1. Repo 1 defaults active_assignment_expire_after to P30D for
    # pim_for_groups roles. If the package assignment outlives that, PIM expires the
    # eligibility while Entitlement Management still shows the user as assigned.
    precondition {
      condition     = length(local.m3_scopes_over_ceiling) == 0
      error_message = <<-EOT
        These packages contain pim_for_groups roles but have an assignment duration
        above the ${var.m3_max_duration_days}-day ceiling: ${join(", ", [for s in local.m3_scopes_over_ceiling : "${s} (${local.effective[s].assignment_duration_days}d)"])}

        Repo 1 sets active_assignment_expire_after on those groups' PIM policies,
        defaulting to P30D. When the access package assignment lasts longer than the
        group's eligible-assignment expiry, Entitlement Management and PIM drift
        apart: PIM expires the eligibility, the user loses access, and the package
        still lists them as assigned. Nothing errors, and the user's own MyAccess
        page contradicts what they can actually do.

        Either lower assignment_duration_days for these scopes in scope_overrides,
        or raise m3_max_duration_days to match the value repo 1 actually sets — but
        only after checking repo 1's activation_settings output, not by assumption.
      EOT
    }
  }
}

resource "terraform_data" "validate_peer_approval_viability" {
  input = {
    approver_group_scopes = local.approver_group_scopes
  }

  lifecycle {
    # Section 4.5. Not fatal: a lone systemeier is a real state repo 1 can produce,
    # and option A is what fixes it. This precondition only fires when option A is
    # switched off, leaving the deadlock in place with nothing to resolve it.
    precondition {
      condition = var.defaults.grant_approver_group == true || length([
        for s in keys(local.v.approver_group_object_ids) : s
        if length(local.v.systemeier_by_scope[s]) < 2
      ]) == 0
      error_message = <<-EOT
        defaults.grant_approver_group is false, and these scopes have an approver
        group but fewer than two systemeier: ${join(", ", [for s in keys(local.v.approver_group_object_ids) : s if length(local.v.systemeier_by_scope[s]) < 2])}

        Repo 1 seeds each approver group with its scope's systemeier, so the group is
        never empty. But PIM blocks self-approval, so a group with exactly one member
        cannot approve that member's own activation request. Their dual-approval
        roles are un-activatable by them alone, and the request times out after 24
        hours — a timeout that is not configurable.

        Attaching the approver group to the scope's package (option A in section 5.5,
        defaults.grant_approver_group = true) makes every member of the scope a peer
        approver and resolves it. If you keep this false, add a second member to
        those approver groups by hand before testing gate 2, and record that as a
        manual prerequisite.
      EOT
    }
  }
}
