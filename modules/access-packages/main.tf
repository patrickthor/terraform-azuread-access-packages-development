# ==============================================================================
# access-packages — the consumable module
#
# Catalogs, access packages, and one assignment policy per package — derived from repo 1's
# contract v2 plus optional named packages.
#
#   catalog (per label)
#     └─ catalog resource association   one per (catalog, group), created HERE
#          └─ access package            one per package definition, of either KIND
#               ├─ resource package association   one per granted group
#               └─ assignment policy              GATE 1
#
# TWO KINDS OF PACKAGE, one set of wiring:
#
#   kind = "access"    grants role groups. One per scope by default.
#   kind = "approver"  grants only the scope's approver group. One per scope.
#
# The split exists because the two rights are different. When the approver group was a
# resource role on the access package, everyone who requested the access became a peer
# approver, and nobody could approve without also holding the access. Now:
#
#   request access package    -> systemeier approve -> hold / activate the access
#   request approver package  -> systemeier approve -> can approve other people
#
# Two independent grants, two independent expiries, and the approver population is no longer
# forced to equal the requester population.
#
# NO PROVIDER BLOCKS here or in either child module. That is what lets a caller use count,
# for_each and depends_on on this module, and the reference customer config uses count.
# ==============================================================================

# ------------------------------------------------------------------------------
# Catalogs
# ------------------------------------------------------------------------------

module "catalog" {
  source   = "./modules/access-package-catalog"
  for_each = local.v.catalogs

  display_name       = local.catalog_settings[each.key].display_name
  description        = local.catalog_settings[each.key].description
  externally_visible = local.catalog_settings[each.key].externally_visible
  published          = local.catalog_settings[each.key].published
  adopt_existing     = local.catalog_settings[each.key].adopt_existing

  delegated_principals = {
    for upn in local.catalog_delegated_upns[each.key] :
    upn => data.azuread_user.systemeier[upn].object_id
  }
  delegated_role_name = local.catalog_settings[each.key].systemeier_catalog_role
}

# ------------------------------------------------------------------------------
# Register role groups as catalog resources, one per (catalog, group)
#
# Under contract v2 the group registered here is the PLAIN group for pim_for_groups roles.
# Repo 1 has already made it an eligible member of the PIM-managed group, so plain Member on
# this group is what produces just-in-time access — the provider's lack of an EligibleMember
# access type no longer matters.
# ------------------------------------------------------------------------------

resource "azuread_access_package_resource_catalog_association" "role_group" {
  for_each = local.catalog_role_pairs

  catalog_id             = module.catalog[each.value.catalog].catalog_id
  resource_origin_id     = local.v.roles[each.value.role_key].group_object_id
  resource_origin_system = "AadGroup"
}

# One per approver package. The key shape is unchanged from when the approver group was a
# resource role on the access package, so this association is reused rather than recreated.
resource "azuread_access_package_resource_catalog_association" "approver_group" {
  for_each = local.catalog_approver_pairs

  catalog_id             = module.catalog[each.value.catalog].catalog_id
  resource_origin_id     = local.v.scopes[each.value.scope].approver_group_object_id
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
# Every package, of either kind
#
# One module call for both. The kinds differ only in which resource roles go in, which is
# what stops the split from forking the wiring.
# ------------------------------------------------------------------------------

module "access_package" {
  source   = "./modules/access-package"
  for_each = local.package_kind

  catalog_id   = module.catalog[local.package_catalog[each.key]].catalog_id
  display_name = local.effective[each.key].display_name
  description  = local.effective[each.key].description
  hidden       = local.effective[each.key].hidden

  resource_roles = local.resource_roles_by_package[each.key]

  policy_display_name = "Request ${local.effective[each.key].display_name}"
  policy_description = (
    each.value == "approver"
    ? "Gate 1 for peer-approval rights over the ${local.package_scope[each.key]} scope. The systemeier decide who may approve other people's requests. Deliberately NOT approved by the approver group itself: approvers appointing approvers is an escalation loop with no terminating authority."
    : "Gate 1 for the ${local.package_scope[each.key]} scope: the systemeier decide who may enter. Privilege elevation within the scope is gated separately by the PIM policies in repo 1."
  )

  duration_in_days                 = local.effective[each.key].assignment_duration_days
  requestor_scope_type             = local.effective[each.key].requestor_scope_type
  requests_accepted                = local.effective[each.key].requests_accepted
  requestor_justification_required = local.effective[each.key].require_justification
  question_text                    = local.effective[each.key].question_text

  # Exactly one stage, holding the systemeier of the package's scope as named approvers.
  #
  # For an APPROVER package this is the load-bearing rule: the approvers are the systemeier,
  # never the approver group. Letting the group approve requests for its own membership would
  # make the approver population self-perpetuating with no authority outside it. The
  # systemeier are named in the contract and are not themselves vended, so the chain ends
  # there.
  approval_stages = [{
    timeout_days                    = local.effective[each.key].approval_timeout_days
    approver_justification_required = true
    approvers = [
      for upn in local.v.scopes[local.package_scope[each.key]].systemeier : {
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
# terraform_data + precondition rather than `check` blocks. A check block reports and lets the
# apply proceed, which is wrong for every failure mode in this system: they all end with a
# successful apply and something subtly wrong in the portal.
# ==============================================================================

resource "terraform_data" "validate_configuration" {
  input = {
    catalogs = local.catalog_labels
    scopes   = local.scope_keys
    packages = local.all_package_names
  }

  lifecycle {
    precondition {
      condition     = length(local.unknown_catalog_labels) == 0
      error_message = <<-EOT
        var.catalogs names catalog labels that the contract does not contain: ${join(", ", local.unknown_catalog_labels)}

        Known labels are: ${join(", ", local.catalog_labels)}

        Settings for an unknown label have no effect at all, so the display name, adoption or
        delegation you configured silently does not happen. The usual cause is a typo, or a
        label that was renamed in repo 1's access_scopes.
      EOT
    }

    precondition {
      condition     = length(local.unknown_override_packages) == 0
      error_message = <<-EOT
        package_overrides names packages that do not exist: ${join(", ", local.unknown_override_packages)}

        Known packages are: ${join(", ", local.all_package_names)}

        An override on an unknown package has no effect, so the deviation you intended silently
        does not happen. Approver package names are generated as "{scope}-approvers".
      EOT
    }

    precondition {
      condition     = length(local.unknown_approver_package_scopes) == 0
      error_message = <<-EOT
        approver_packages names scopes that have no approver group: ${join(", ", local.unknown_approver_package_scopes)}

        Scopes with an approver group are: ${join(", ", keys(local.scopes_with_approver_group))}

        Repo 1 creates an approver group only for scopes where some role uses dual approval, so
        there is nothing for this entry to configure and it would be silently ignored. Either
        the scope key is a typo, or the scope has no dual-approval role and needs one in repo 1
        before peer approval means anything there.
      EOT
    }

    precondition {
      condition = alltrue([
        for s in local.scope_keys : contains(local.catalog_labels, local.v.scopes[s].catalog)
      ])
      error_message = <<-EOT
        These scopes name a catalog label missing from contract.catalogs: ${join(", ", [for s in local.scope_keys : "${s} -> ${local.v.scopes[s].catalog}" if !contains(local.catalog_labels, local.v.scopes[s].catalog)])}

        contract.catalogs is the authoritative label set and every scope must appear under one
        of its scope_keys lists. A scope pointing at a label with no catalog entry means repo 1
        assembled the contract inconsistently, and the package would have nowhere to live.
      EOT
    }

    precondition {
      condition     = length(local.catalog_labels_with_separator) == 0
      error_message = <<-EOT
        These catalog labels contain a "|": ${join(", ", local.catalog_labels_with_separator)}

        Catalog resource associations are keyed on "{catalog}|{group}", because a group can
        appear in packages that live in different catalogs and each needs its own association.
        A "|" inside a label would make two different pairs collide on one key, so one
        association would silently go missing and its package association would fail at apply.

        Rename the label in repo 1's access_scopes.
      EOT
    }
  }
}

resource "terraform_data" "validate_packages" {
  input = {
    kinds      = local.package_kind
    role_count = { for name, p in local.access_package_defs : name => length(p.role_keys) }
  }

  lifecycle {
    # Unknown role keys are rejected, never skipped. A package silently missing a role grants
    # less than it claims and nothing in the portal says so.
    precondition {
      condition     = length(local.packages_with_unknown_roles) == 0
      error_message = <<-EOT
        These packages name role keys that the contract does not contain:
        ${join("\n", [for name in local.packages_with_unknown_roles : "  ${name}: ${join(", ", local.unknown_role_keys_by_package[name])}"])}

        Known role keys are:
        ${join("\n", [for k in local.role_keys : "  ${k}"])}

        Role keys are the composite "{scope}--{role}" from repo 1's contract, not display names.
        A key that does not resolve is a package that would grant less than it says, so it fails
        the plan rather than being skipped.
      EOT
    }

    # Package names are a shared namespace: var.packages keys and generated approver package
    # names live in the same map. Renaming either one silently would hide which package grants
    # what, so the collision is reported instead.
    precondition {
      condition     = length(local.reserved_name_collisions) == 0
      error_message = <<-EOT
        These package names collide with generated approver package names: ${join(", ", local.reserved_name_collisions)}

        Approver packages are named "{scope}-approvers", and one is generated for every scope
        whose contract entry has an approver group. That name is reserved.

        Neither package is silently renamed, because the name is how every output identifies a
        package — a rename would make packages_by_catalog and verification_summary describe
        something other than what you asked for. Rename your package in var.packages, or opt the
        approver package out with approver_packages = { "<scope>" = { enabled = false } } if you
        genuinely want to manage that grant yourself.
      EOT
    }

    precondition {
      condition     = length(local.cross_scope_packages) == 0
      error_message = <<-EOT
        These packages span more than one scope:
        ${join("\n", [for name in local.cross_scope_packages : "  ${name}: ${join(", ", local.access_package_scopes[name])}"])}

        Gate 1 approval comes from the scope's systemeier, and a package covering several scopes
        has no single answer. The two ways out are both wrong today:

          - the union of every touched scope's systemeier would let an owner of one scope approve
            entry to another, which is a quiet privilege expansion
          - requiring each scope's systemeier in turn is not expressible: the provider allows one
            approval stage per assignment policy

        Every case in front of us is single-scope, so this is rejected rather than resolved. Split
        the package by scope.
      EOT
    }

    precondition {
      condition     = length(local.packages_with_unknown_catalog) == 0
      error_message = <<-EOT
        These packages name a catalog the contract does not define:
        ${join("\n", [for name in local.packages_with_unknown_catalog : "  ${name} -> ${local.package_catalog[name]}"])}

        Known labels are: ${join(", ", local.catalog_labels)}

        Repo 1 owns the catalog label set — the catalog is a label on a scope there — so this
        module creates no catalog repo 1 has not declared.
      EOT
    }

    # Kept STRICT. Under contract v2 nothing is excluded for pim_for_groups roles: the package
    # attaches plain Member on a plain group, so an all-pim_for_groups scope's access package
    # grants real memberships rather than nothing. Relaxing this check would only hide a
    # genuinely empty package.
    precondition {
      condition     = length(local.empty_packages) == 0
      error_message = <<-EOT
        These packages would grant no group memberships at all: ${join(", ", local.empty_packages)}

        A package with no resource roles is still requestable and still approvable, so it appears
        in MyAccess as working access while granting nothing. That is worse than the package not
        existing.

        Under contract v2 this should not happen for a package with any role in it: every
        mechanism attaches plain Member on a plain group, so nothing is excluded for provider
        reasons. If you are seeing it, a role's access_type is something the provider cannot
        express — check excluded_resource_roles, which lists exactly those.
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

        The systemeier are gate 1 for both kinds of package: they decide who may enter the scope,
        and who may approve other people. With none, no request can be satisfied by anyone, so
        every request sits until it times out and the access is never granted. The package looks
        perfectly healthy in MyAccess the whole time.

        This is also why the approver group cannot stand in for them: it would make the approver
        population self-perpetuating with no authority outside it. Fix this in repo 1 by giving
        the scope a systemeier.
      EOT
    }
  }
}

resource "terraform_data" "validate_assignment_expiry_ceiling" {
  input = {
    ceilings  = local.ceiling_by_package
    durations = { for name in local.all_package_names : name => local.effective[name].assignment_duration_days }
  }

  lifecycle {
    precondition {
      condition     = length(local.packages_over_ceiling) == 0
      error_message = <<-EOT
        These packages have an assignment duration above the ceiling repo 1 set for a role they contain:
        ${join("\n", [for name in local.packages_over_ceiling : "  ${name}: ${local.effective[name].assignment_duration_days} days requested, ceiling ${local.ceiling_by_package[name]} days, set by role '${local.binding_ceiling_role_by_package[name]}'"])}

        The ceiling is repo 1's max_assignment_days, derived from the PIM-MANAGED group's
        active_assignment_expire_after — not from the plain group the package attaches. The
        package assignment governs membership of the plain group; if that outlives the PIM
        eligibility, the user keeps the membership and silently loses the ability to activate,
        while Entitlement Management still lists them as assigned.

        Lower assignment_duration_days on the package, or raise active_assignment_expire_after on
        the named role in repo 1. Do not work around it here — the ceiling is a fact about the PIM
        policy, not a preference.

        The ceiling is the minimum across the roles THIS PACKAGE grants, so a package that does
        not grant the short-lived role is not limited by it. That is one reason to split audiences
        into named packages.
      EOT
    }
  }
}

resource "terraform_data" "validate_no_duplicate_catalog_resources" {
  input = local.approver_group_catalog_pairs

  lifecycle {
    precondition {
      condition     = length(local.duplicate_approver_group_pairs) == 0
      error_message = <<-EOT
        More than one scope names the same approver group inside the same catalog: ${join("; ", local.duplicate_approver_group_pairs)}

        A catalog resource association is unique per (catalog, group), so registering that group
        once per scope would be a duplicate and the apply would fail partway through with
        resources already created.

        This happens when approver_group_name points at a group repo 1 does not manage and two
        scopes share it. Either give those scopes separate approver groups, or move them into
        different catalogs — the same group in two different catalogs is legitimate and needs one
        association in each.
      EOT
    }
  }
}

resource "terraform_data" "validate_peer_approval_viability" {
  input = { approver_package_scopes = local.approver_package_scopes }

  lifecycle {
    # A lone systemeier is a real state repo 1 can produce, and the approver package is what
    # resolves it — it lets extra people be granted approval rights without also being granted
    # the access. This fires only when the scope has no approver package, leaving the deadlock
    # in place with nothing to fix it.
    precondition {
      condition     = length(local.deadlocked_approver_scopes) == 0
      error_message = <<-EOT
        These scopes have an approver group and fewer than two systemeier, and no approver package: ${join(", ", [for s in local.deadlocked_approver_scopes : "${s} (${local.scopes_with_approver_group[s]}, ${length(local.v.scopes[s].systemeier)} systemeier)"])}

        Repo 1 seeds each approver group with its scope's systemeier, so the group is never empty.
        But PIM blocks self-approval, so a group with exactly one member cannot approve that
        member's own activation request. Their dual-approval roles are un-activatable by them
        alone, and the request times out after 24 hours — a timeout nobody can configure.

        An approver package is created for every scope with an approver group by default, so
        seeing this means one was explicitly disabled:

          approver_packages = { "${try(local.deadlocked_approver_scopes[0], "<scope>")}" = { enabled = false } }

        Either re-enable it, or add a second member to those approver groups by hand before
        testing gate 2 and record that as a manual prerequisite.
      EOT
    }
  }
}
