# ==============================================================================
# access-packages — the consumable module
#
# Catalogs, one access package per PACKAGE DEFINITION, and one assignment policy per
# package — derived from repo 1's contract plus optional named packages. This repo writes
# no group name, scope key or catalog label.
#
#   catalog (per label)
#     └─ catalog resource association   one per (catalog, group), created HERE
#          └─ access package            one per package definition
#               ├─ resource package association   one per granted group
#               └─ assignment policy              GATE 1
#
# One package per scope is the DEFAULT, not a separate code path: when var.packages is
# empty, locals.tf generates a package definition per scope and everything below is
# unchanged. That is what keeps named packages non-breaking.
#
# The catalog associations live in this module rather than in the access-package leaf. They
# are unique per (catalog, group), and several packages in one catalog legitimately share a
# group — creating the association in the leaf would produce duplicates and fail.
#
# NO PROVIDER BLOCKS here or in either child module. That is what lets a caller use count,
# for_each and depends_on on this module, and the reference customer config uses count.
# ==============================================================================

# ------------------------------------------------------------------------------
# Catalogs
#
# for_each over the contract's own catalogs map. A catalog is a delegation boundary, so
# which packages land in which catalog is a security-relevant fact — see the
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

  # Standing package-management rights for the people who already approve gate 1. Empty
  # unless delegate_to_systemeier was set for this label.
  delegated_principals = {
    for upn in local.catalog_delegated_upns[each.key] :
    upn => data.azuread_user.systemeier[upn].object_id
  }
  delegated_role_name = local.catalog_settings[each.key].systemeier_catalog_role
}

# ------------------------------------------------------------------------------
# Register groups as catalog resources, one per (catalog, group)
#
# Done for every role any package names, INCLUDING roles the provider cannot attach with
# the access type they require. Registration is access-type agnostic — the access type is
# chosen later, on the package association — so registering them costs nothing and reduces
# the manual portal step to picking "Eligible Member" on a resource that is already there.
#
# Keyed on "{catalog}|{role_key}". Not on the role alone: a per-package catalog means two
# packages in different catalogs can share a role, and that needs two associations. See
# catalog_role_pairs in locals.tf.
# ------------------------------------------------------------------------------

resource "azuread_access_package_resource_catalog_association" "role_group" {
  for_each = local.catalog_role_pairs

  catalog_id             = module.catalog[each.value.catalog].catalog_id
  resource_origin_id     = local.v.roles[each.value.role_key].group_object_id
  resource_origin_system = "AadGroup"
}

# Approver groups are per scope, not per role, so they need their own association set. Only
# created for packages that actually attach one.
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
# One access package per package definition
#
# A package grants everything in it atomically, so its unit is an audience for a scope:
# "membership of the team that works on this scope" by default, or a named tier when the
# caller supplies var.packages. That works because repo 1's groups are PIM-managed —
# membership is not privilege, activation is — so a package can hand someone their baseline
# plus their escalation paths and PIM still gates each escalation.
# ------------------------------------------------------------------------------

module "access_package" {
  source   = "./modules/access-package"
  for_each = local.resolvable_packages

  catalog_id   = module.catalog[local.package_catalog[each.key]].catalog_id
  display_name = local.effective[each.key].display_name
  description  = local.effective[each.key].description
  hidden       = local.effective[each.key].hidden

  resource_roles = local.resource_roles_by_package[each.key]

  policy_display_name = "Request ${local.effective[each.key].display_name}"
  policy_description  = "Gate 1 for the ${local.package_scope[each.key]} scope: the systemeier decide who may enter. Privilege elevation within the scope is gated separately by the PIM policies in repo 1."

  duration_in_days                 = local.effective[each.key].assignment_duration_days
  requestor_scope_type             = local.effective[each.key].requestor_scope_type
  requests_accepted                = local.effective[each.key].requests_accepted
  requestor_justification_required = local.effective[each.key].require_justification
  question_text                    = local.effective[each.key].question_text

  # Exactly one stage, holding the systemeier of the package's single scope as named
  # approvers. One signature from any of them is enough. A second stage is possible on this
  # resource — the only place in the system where sequential approval is achievable — but
  # gate 1 answers a single question, so one stage is correct.
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
# terraform_data + precondition rather than `check` blocks. A check block reports and lets
# the apply proceed, which is wrong for every failure mode in this system: they all end
# with a successful apply and something subtly wrong in the portal.
# ==============================================================================

resource "terraform_data" "validate_configuration" {
  input = {
    catalogs = local.catalog_labels
    scopes   = local.scope_keys
    packages = local.package_names
  }

  lifecycle {
    precondition {
      condition     = length(local.unknown_catalog_labels) == 0
      error_message = <<-EOT
        var.catalogs names catalog labels that the contract does not contain: ${join(", ", local.unknown_catalog_labels)}

        Known labels are: ${join(", ", local.catalog_labels)}

        Settings for an unknown label have no effect at all, so the display name, adoption
        or delegation you configured silently does not happen. The usual cause is a typo, or
        a label that was renamed in repo 1's access_scopes.
      EOT
    }

    precondition {
      condition     = length(local.unknown_override_packages) == 0
      error_message = <<-EOT
        package_overrides names packages that do not exist: ${join(", ", local.unknown_override_packages)}

        Known packages are: ${join(", ", local.package_names)}

        An override on an unknown package has no effect, so the deviation you intended
        silently does not happen. When var.packages is empty, package names are scope names.
      EOT
    }

    precondition {
      condition = alltrue([
        for s in local.scope_keys : contains(local.catalog_labels, local.v.scopes[s].catalog)
      ])
      error_message = <<-EOT
        These scopes name a catalog label missing from contract.catalogs: ${join(", ", [for s in local.scope_keys : "${s} -> ${local.v.scopes[s].catalog}" if !contains(local.catalog_labels, local.v.scopes[s].catalog)])}

        contract.catalogs is the authoritative label set and every scope must appear under
        one of its scope_keys lists. A scope pointing at a label with no catalog entry means
        repo 1 assembled the contract inconsistently, and the package would have nowhere to
        live.
      EOT
    }

    precondition {
      condition     = length(local.catalog_labels_with_separator) == 0
      error_message = <<-EOT
        These catalog labels contain a "|": ${join(", ", local.catalog_labels_with_separator)}

        Catalog resource associations are keyed on "{catalog}|{role_key}", because a role can
        now appear in packages that live in different catalogs and each needs its own
        association. A "|" inside a label would make two different (catalog, role) pairs
        collide on one key, so one association would silently go missing and its package
        association would fail at apply.

        Rename the label in repo 1's access_scopes.
      EOT
    }
  }
}

resource "terraform_data" "validate_packages" {
  input = {
    packages   = local.package_names
    role_count = { for name, p in local.package_defs : name => length(p.role_keys) }
  }

  lifecycle {
    # Unknown role keys are rejected, never skipped. A package silently missing a role
    # grants less than it claims and nothing in the portal says so.
    precondition {
      condition     = length(local.packages_with_unknown_roles) == 0
      error_message = <<-EOT
        These packages name role keys that the contract does not contain:
        ${join("\n", [for name in local.packages_with_unknown_roles : "  ${name}: ${join(", ", local.unknown_role_keys_by_package[name])}"])}

        Known role keys are:
        ${join("\n", [for k in local.role_keys : "  ${k}"])}

        Role keys are the composite "{scope}--{role}" from repo 1's contract, not display
        names. A key that does not resolve is a package that would grant less than it says,
        so it fails the plan rather than being skipped. If repo 1 renamed a scope or role,
        note that renaming is destructive there — the group is deleted and recreated.
      EOT
    }

    # DECISION (c). See the gate 1 note in locals.tf for why the alternatives were
    # rejected rather than picked.
    precondition {
      condition     = length(local.cross_scope_packages) == 0
      error_message = <<-EOT
        These packages span more than one scope:
        ${join("\n", [for name in local.cross_scope_packages : "  ${name}: ${join(", ", local.package_scopes[name])}"])}

        Gate 1 approval comes from the scope's systemeier, and a package covering several
        scopes has no single answer. The two ways out are both wrong today:

          - the union of every touched scope's systemeier would let an owner of one scope
            approve entry to another, which is a quiet privilege expansion
          - requiring each scope's systemeier in turn is not expressible: the provider
            allows one approval stage per assignment policy

        Every case in front of us is single-scope, so this is rejected rather than resolved.
        Split the package by scope. When a genuine cross-scope persona appears, the gate 1
        note in locals.tf is where to reopen the decision.
      EOT
    }

    precondition {
      condition     = length(local.packages_with_unknown_catalog) == 0
      error_message = <<-EOT
        These packages name a catalog the contract does not define:
        ${join("\n", [for name in local.packages_with_unknown_catalog : "  ${name} -> ${local.package_catalog[name]}"])}

        Known labels are: ${join(", ", local.catalog_labels)}

        Repo 1 owns the catalog label set — the catalog is a label on a scope there — so this
        module creates no catalog repo 1 has not declared. Add the label to the scope in
        repo 1's access_scopes, then name it here.
      EOT
    }

    precondition {
      condition     = length(local.empty_packages) == 0
      error_message = <<-EOT
        These packages would grant no group memberships at all: ${join(", ", local.empty_packages)}

        A package with no resource roles is still requestable and still approvable, so it
        appears in MyAccess as working access while granting nothing. That is worse than the
        package not existing.

        Every role in the package was excluded because its access_type is "EligibleMember",
        which the azuread provider cannot express, and no approver group was attached
        either. Choose one:

          - set grant_approver_group on the package, if its scope has an approver group in
            repo 1, so it at least grants peer-approval rights
          - build the package by hand in the portal and accept that it is not IaC-managed
          - set manage_pim_for_groups_roles = true, accepting that eligibility becomes
            standing active membership

        The excluded_resource_roles output lists the affected groups.
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

        The systemeier are gate 1: they decide who may enter the scope at all. With none, the
        approval stage cannot be satisfied by anyone, so every request for a package in that
        scope sits until it times out and the access is never granted. The package looks
        perfectly healthy in MyAccess the whole time.

        Fix this in repo 1 by giving the scope a systemeier, not here by disabling approval.
        An unapproved package would hand out cloud access to anyone who asks.
      EOT
    }
  }
}

resource "terraform_data" "validate_assignment_expiry_ceiling" {
  input = {
    ceilings  = local.ceiling_by_package
    durations = { for name in keys(local.resolvable_packages) : name => local.effective[name].assignment_duration_days }
  }

  lifecycle {
    # If a package assignment outlives the group's eligible-assignment expiry, PIM expires
    # the eligibility while Entitlement Management still lists the user as assigned. They
    # lose access without losing the assignment, nothing errors, and their own MyAccess page
    # contradicts what they can do.
    precondition {
      condition     = length(local.packages_over_ceiling) == 0
      error_message = <<-EOT
        These packages have an assignment duration above the ceiling repo 1 set for a role they contain:
        ${join("\n", [for name in local.packages_over_ceiling : "  ${name}: ${local.effective[name].assignment_duration_days} days requested, ceiling ${local.ceiling_by_package[name]} days, set by role '${local.binding_ceiling_role_by_package[name]}'"])}

        The ceiling is repo 1's max_assignment_days, derived from the group's
        active_assignment_expire_after in its PIM policy. When the access package assignment
        lasts longer than that, Entitlement Management and PIM drift apart: PIM expires the
        eligibility, the user loses access, and the package still lists them as assigned.

        Lower assignment_duration_days on the package, or raise active_assignment_expire_after
        on the named role in repo 1. Do not work around it here — the ceiling is a fact about
        the PIM policy, not a preference.

        The ceiling is the minimum across the roles THIS PACKAGE grants, including any
        excluded from Terraform by the EligibleMember gap: those are expected to be added by
        hand in the portal, and once they are, their expiry constrains the package too. A
        package that does not grant the short-lived role is not limited by it, which is one
        reason to split audiences into named packages.
      EOT
    }
  }
}

resource "terraform_data" "validate_no_duplicate_catalog_resources" {
  input = local.approver_group_catalog_pairs

  lifecycle {
    # Role groups are safe by construction: their association key IS (catalog, role).
    # Approver groups are not, because approver_group_name may point at a group repo 1 does
    # not manage and two scopes could share it. Sharing across different catalogs is fine and
    # must produce two associations. Sharing inside the SAME catalog is a duplicate the
    # provider only reports at apply, partway through, with resources already created.
    precondition {
      condition     = length(local.duplicate_approver_group_pairs) == 0
      error_message = <<-EOT
        More than one scope names the same approver group inside the same catalog: ${join("; ", local.duplicate_approver_group_pairs)}

        A catalog resource association is unique per (catalog, group), so registering that
        group once per scope would be a duplicate and the apply would fail partway through
        with resources already created.

        This happens when approver_group_name points at a group repo 1 does not manage and two
        scopes share it. Either give those scopes separate approver groups, or move them into
        different catalogs — the same group in two different catalogs is legitimate and needs
        one association in each.
      EOT
    }
  }
}

resource "terraform_data" "validate_peer_approval_viability" {
  input = { packages_granting_approver_group = local.packages_granting_approver_group }

  lifecycle {
    # A lone systemeier is a real state repo 1 can produce, and attaching the approver group
    # is what resolves it. This fires only when no package in that scope attaches one,
    # leaving the deadlock in place with nothing to fix it.
    precondition {
      condition     = length(local.deadlocked_approver_scopes) == 0
      error_message = <<-EOT
        These scopes have an approver group and fewer than two systemeier, and no package grants that group: ${join(", ", [for s in local.deadlocked_approver_scopes : "${s} (${local.scopes_with_approver_group[s]}, ${length(local.v.scopes[s].systemeier)} systemeier)"])}

        Repo 1 seeds each approver group with its scope's systemeier, so the group is never
        empty. But PIM blocks self-approval, so a group with exactly one member cannot approve
        that member's own activation request. Their dual-approval roles are un-activatable by
        them alone, and the request times out after 24 hours — a timeout nobody can configure.

        Set grant_approver_group on at least one package in the scope, which makes everyone
        holding that package a peer approver. With named packages this is the senior tier: the
        admins package grants the approver group, the engineers package does not.

        If you keep it off everywhere, add a second member to those approver groups by hand
        before testing gate 2, and record that as a manual prerequisite.
      EOT
    }
  }
}
