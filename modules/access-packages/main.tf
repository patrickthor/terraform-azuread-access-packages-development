# ==============================================================================
# access-packages — the consumable module
#
# One catalog per label, one access package per scope, one assignment policy per
# package — all of it derived from repo 1's contract. This repo writes no group name,
# no scope key and no catalog label.
#
#   catalog (per label)
#     └─ catalog resource association   one per (catalog, group), created HERE
#          └─ access package            one per scope
#               ├─ resource package association   one per granted group
#               └─ assignment policy              GATE 1
#
# The catalog associations live in this module rather than in the access-package leaf.
# They are unique per (catalog, group), and under peer approval the same approver
# group attaches to several packages in the same catalog — creating the association in
# the leaf would produce duplicates and fail.
#
# NO PROVIDER BLOCKS here or in either child module. That is what lets a caller use
# count, for_each and depends_on on this module, and the reference customer config uses
# count on it.
# ==============================================================================

# ------------------------------------------------------------------------------
# Catalogs
#
# for_each over the contract's own catalogs map. A catalog is a delegation boundary,
# so which packages land in which catalog is a security-relevant fact — see the
# packages_by_catalog output.
# ------------------------------------------------------------------------------

module "catalog" {
  source   = "./modules/access-package-catalog"
  for_each = local.v.catalogs

  display_name       = local.catalog_settings[each.key].display_name
  description        = local.catalog_settings[each.key].description
  externally_visible = local.catalog_settings[each.key].externally_visible
  published          = local.catalog_settings[each.key].published
  adopt_existing     = local.catalog_settings[each.key].adopt_existing

  # Standing package-management rights for the people who already approve gate 1.
  # Empty unless delegate_to_systemeier was set for this label.
  delegated_principals = {
    for upn in local.catalog_delegated_upns[each.key] :
    upn => data.azuread_user.systemeier[upn].object_id
  }
  delegated_role_name = local.catalog_settings[each.key].systemeier_catalog_role
}

# ------------------------------------------------------------------------------
# Register groups as catalog resources
#
# Done for ALL role groups, including the ones the provider cannot attach with the
# access type they require. Registration is access-type agnostic — the access type is
# chosen later, on the package association — so registering them costs nothing and
# reduces the manual portal step to picking "Eligible Member" on a resource that is
# already there.
#
# Keyed on the composite role key. Because one group belongs to exactly one role in
# exactly one scope, and a scope sits in exactly one catalog, that key IS a
# (catalog, group) key. See the duplicate-association guard in locals.tf for the case
# where that reasoning does not extend to approver groups.
# ------------------------------------------------------------------------------

resource "azuread_access_package_resource_catalog_association" "role_group" {
  for_each = local.v.roles

  catalog_id             = module.catalog[local.catalog_of_scope[each.value.scope]].catalog_id
  resource_origin_id     = each.value.group_object_id
  resource_origin_system = "AadGroup"
}

# Approver groups are per scope, not per role, so they need their own association set.
# Only created when the approver group is actually attached to a package — without that
# there is no manual follow-up step that would justify registering it.
resource "azuread_access_package_resource_catalog_association" "approver_group" {
  for_each = toset(local.approver_group_scopes)

  catalog_id             = module.catalog[local.catalog_of_scope[each.value]].catalog_id
  resource_origin_id     = local.v.scopes[each.value].approver_group_object_id
  resource_origin_system = "AadGroup"
}

# ------------------------------------------------------------------------------
# Gate 1 approvers — resolve systemeier UPNs to object IDs
#
# Needs User.Read.All as an application permission. A 403 here rather than a not-found
# usually means that permission was never granted.
# ------------------------------------------------------------------------------

data "azuread_user" "systemeier" {
  for_each = local.all_systemeier_upns

  user_principal_name = each.value
}

# ------------------------------------------------------------------------------
# One package per scope
#
# A package grants everything in it atomically, so its natural unit is "membership of
# the team that works on this scope", not "one individual permission". That works
# because repo 1's groups are PIM-managed: membership is not privilege, activation is.
# The package says "you belong here, here is your baseline plus your escalation paths",
# and PIM still gates each escalation.
# ------------------------------------------------------------------------------

module "access_package" {
  source   = "./modules/access-package"
  for_each = local.v.scopes

  catalog_id   = module.catalog[each.value.catalog].catalog_id
  display_name = local.effective[each.key].display_name
  description  = local.effective[each.key].description
  hidden       = local.effective[each.key].hidden

  resource_roles = local.resource_roles_by_scope[each.key]

  policy_display_name = "Request access to ${each.key}"
  policy_description  = "Gate 1 for the ${each.key} scope: the systemeier decide who may enter. Privilege elevation within the scope is gated separately by the PIM policies in repo 1."

  duration_in_days                 = local.effective[each.key].assignment_duration_days
  requestor_scope_type             = local.effective[each.key].requestor_scope_type
  requests_accepted                = local.effective[each.key].requests_accepted
  requestor_justification_required = local.effective[each.key].require_justification
  question_text                    = local.effective[each.key].question_text

  # Exactly one stage, holding the scope's systemeier as named approvers. One signature
  # from any of them is enough. A second stage is possible on this resource — it is the
  # only place in the system where sequential approval is achievable — but gate 1 answers
  # a single question, so one stage is correct.
  approval_stages = [{
    timeout_days                    = local.effective[each.key].approval_timeout_days
    approver_justification_required = true
    approvers = [
      for upn in each.value.systemeier : {
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
# terraform_data + precondition rather than `check` blocks. A check block reports and
# lets the apply proceed, which is wrong for every failure mode in this system: they
# all end with a successful apply and something subtly wrong in the portal.
# ==============================================================================

resource "terraform_data" "validate_configuration" {
  input = {
    catalogs = local.catalog_labels
    scopes   = local.scope_keys
  }

  lifecycle {
    precondition {
      condition     = length(local.unknown_catalog_labels) == 0
      error_message = <<-EOT
        var.catalogs names catalog labels that the contract does not contain: ${join(", ", local.unknown_catalog_labels)}

        Known labels are: ${join(", ", local.catalog_labels)}

        Settings for an unknown label have no effect at all, so the display name, adoption
        or delegation you configured silently does not happen. The usual cause is a typo,
        or a label that was renamed in repo 1's access_scopes.
      EOT
    }

    precondition {
      condition     = length(local.unknown_override_scopes) == 0
      error_message = <<-EOT
        scope_overrides names scopes that the contract does not contain: ${join(", ", local.unknown_override_scopes)}

        Known scopes are: ${join(", ", local.scope_keys)}

        An override on an unknown scope has no effect, so the deviation you intended
        silently does not happen — the package keeps the default duration or timeout and
        only the portal would tell you. Renaming a scope key in repo 1 is destructive
        there, so check whether that is what happened.
      EOT
    }

    precondition {
      condition = alltrue([
        for s in local.scope_keys : contains(local.catalog_labels, local.v.scopes[s].catalog)
      ])
      error_message = <<-EOT
        These scopes name a catalog label that is missing from contract.catalogs: ${join(", ", [for s in local.scope_keys : "${s} -> ${local.v.scopes[s].catalog}" if !contains(local.catalog_labels, local.v.scopes[s].catalog)])}

        contract.catalogs is the authoritative label set and every scope must appear under
        one of its scope_keys lists. A scope pointing at a label with no catalog entry means
        repo 1 assembled the contract inconsistently, and the package would have nowhere to
        live.
      EOT
    }
  }
}

resource "terraform_data" "validate_gate_1_approvers" {
  input = { for s in local.scope_keys : s => length(local.v.scopes[s].systemeier) }

  lifecycle {
    precondition {
      condition = alltrue([
        for s in local.scope_keys : length(local.v.scopes[s].systemeier) > 0
      ])
      error_message = <<-EOT
        These scopes have an empty systemeier list: ${join(", ", [for s in local.scope_keys : s if length(local.v.scopes[s].systemeier) == 0])}

        The systemeier are gate 1: they decide who may enter the scope at all. With none,
        the approval stage cannot be satisfied by anyone, so every request for the package
        sits until it times out and the access is never granted. The package looks perfectly
        healthy in MyAccess the whole time.

        Fix this in repo 1 by giving the scope a systemeier, not here by disabling approval.
        An unapproved package on these scopes would hand out cloud access to anyone who asks.
      EOT
    }
  }
}

resource "terraform_data" "validate_packages_grant_something" {
  input = { for s in local.scope_keys : s => length(local.resource_roles_by_scope[s]) }

  lifecycle {
    precondition {
      condition     = length(local.empty_scopes) == 0
      error_message = <<-EOT
        These packages would grant no group memberships at all: ${join(", ", local.empty_scopes)}

        A package with no resource roles is still requestable and still approvable, so it
        appears in MyAccess as working access while granting nothing. That is worse than the
        package not existing.

        Every role in the scope was excluded because its access_type is "EligibleMember",
        which the azuread provider cannot express, and defaults.grant_approver_group is false
        so no approver group was attached either. Choose one:

          - set defaults.grant_approver_group = true, if the scope has an approver group in
            repo 1, so the package at least grants peer-approval rights
          - build the scope's package by hand in the portal and accept that it is not
            IaC-managed
          - set manage_pim_for_groups_roles = true, accepting that eligibility becomes
            standing active membership

        The excluded_resource_roles output lists the affected groups.
      EOT
    }
  }
}

resource "terraform_data" "validate_assignment_expiry_ceiling" {
  input = {
    ceilings  = local.ceiling_by_scope
    durations = { for s in local.scope_keys : s => local.effective[s].assignment_duration_days }
  }

  lifecycle {
    # If a package assignment outlives the group's eligible-assignment expiry, PIM expires
    # the eligibility while Entitlement Management still lists the user as assigned. They
    # lose access without losing the assignment, nothing errors, and their own MyAccess page
    # contradicts what they can do.
    precondition {
      condition     = length(local.scopes_over_ceiling) == 0
      error_message = <<-EOT
        These packages have an assignment duration above the ceiling repo 1 set for a role they contain:
        ${join("\n", [for s in local.scopes_over_ceiling : "  ${s}: ${local.effective[s].assignment_duration_days} days requested, ceiling ${local.ceiling_by_scope[s]} days, set by role '${local.binding_ceiling_role_by_scope[s]}'"])}

        The ceiling is repo 1's max_assignment_days, derived from the group's
        active_assignment_expire_after in its PIM policy. When the access package assignment
        lasts longer than that, Entitlement Management and PIM drift apart: PIM expires the
        eligibility, the user loses access, and the package still lists them as assigned.

        Lower assignment_duration_days for these scopes in scope_overrides, or raise
        active_assignment_expire_after on the named role in repo 1. Do not work around it
        here — the ceiling is a fact about the PIM policy, not a preference.

        Note that the ceiling is computed across every role in the scope, including any
        excluded from Terraform by the EligibleMember gap. Those are expected to be added by
        hand in the portal, and once they are, their expiry constrains the package too.
      EOT
    }
  }
}

resource "terraform_data" "validate_no_duplicate_catalog_resources" {
  input = local.approver_group_catalog_pairs

  lifecycle {
    # A catalog resource association is unique per (catalog, group). Two scopes sharing an
    # approver group across different catalogs is fine and produces two associations. Two
    # scopes sharing one inside the SAME catalog is a duplicate, and the provider reports it
    # at apply rather than at plan.
    precondition {
      condition     = length(local.duplicate_approver_group_pairs) == 0
      error_message = <<-EOT
        More than one scope names the same approver group inside the same catalog: ${join("; ", local.duplicate_approver_group_pairs)}

        A catalog resource association is unique per (catalog, group), so registering that
        group once per scope would be a duplicate and the apply would fail partway through
        with resources already created.

        This happens when approver_group_name points at a group repo 1 does not manage and
        two scopes share it. Either give those scopes separate approver groups, or move them
        into different catalogs — the same group in two different catalogs is legitimate and
        needs one association in each.
      EOT
    }
  }
}

resource "terraform_data" "validate_peer_approval_viability" {
  input = { approver_group_scopes = local.approver_group_scopes }

  lifecycle {
    # A lone systemeier is a real state repo 1 can produce, and attaching the approver group
    # is what resolves it. This only fires when that is switched off, leaving the deadlock in
    # place with nothing to fix it.
    precondition {
      # deadlocked_approver_scopes is already empty when grant_approver_group is true,
      # so no separate guard on the flag is needed.
      condition     = length(local.deadlocked_approver_scopes) == 0
      error_message = <<-EOT
        defaults.grant_approver_group is false, and these scopes have an approver group but fewer than two systemeier: ${join(", ", [for s in local.deadlocked_approver_scopes : "${s} (${local.scopes_with_approver_group[s]}, ${length(local.v.scopes[s].systemeier)} systemeier)"])}

        Repo 1 seeds each approver group with its scope's systemeier, so the group is never
        empty. But PIM blocks self-approval, so a group with exactly one member cannot approve
        that member's own activation request. Their dual-approval roles are un-activatable by
        them alone, and the request times out after 24 hours — a timeout nobody can configure.

        Attaching the approver group to the scope's package
        (defaults.grant_approver_group = true) makes everyone in the scope a peer approver and
        resolves it. If you keep this false, add a second member to those approver groups by
        hand before testing gate 2, and record that as a manual prerequisite.
      EOT
    }
  }
}
