# ==============================================================================
# Derivation
#
# Everything here comes from the contract plus, optionally, var.packages. This repo
# writes no scope key, role key, group name or catalog label of its own.
#
# THE UNIT IS A PACKAGE, NOT A SCOPE. One package per scope is the DEFAULT, produced
# by generating a package definition per scope when var.packages is empty. It is not a
# separate code path: everything below keys on package name, and the per-scope shape is
# just one way of filling package_defs. That is what lets named packages express
# "engineers get reader+contributor, admins get reader+contributor+owner" over the same
# groups without forking the resource wiring.
#
# ITERATION SOURCES. Where this file feeds a for_each it uses contract keys, the
# contract's explicit role_keys / scope_keys lists, or var.packages — never
# `distinct([for k in keys(roles) : split("--", k)[0]])`. Repo 1 guarantees its keys and
# lists are derivable from its input variables alone, so they are known at plan time.
# Recomputing them here would work today and break the plan the moment repo 1 populated
# a list from a resource attribute, with the error surfacing in this module for a change
# made in the other repo.
#
# Values inside the maps may be unknown until apply — group_object_id always is. That is
# fine. Unknown values are only a problem in for_each and count.
# ==============================================================================

locals {
  v = var.vending

  catalog_labels = keys(local.v.catalogs)
  scope_keys     = keys(local.v.scopes)
  role_keys      = keys(local.v.roles)

  catalog_of_scope = { for s, cfg in local.v.scopes : s => cfg.catalog }

  # ----------------------------------------------------------------------------
  # Catalog settings: var.catalogs layered over the defaults
  # ----------------------------------------------------------------------------

  # Split out because `description` below branches on it, and a `for` expression building
  # an object cannot reference a sibling attribute of that same object.
  catalog_adopt = {
    for label in local.catalog_labels : label =>
    coalesce(try(var.catalogs[label].adopt_existing, null), false)
  }

  catalog_settings = {
    for label in local.catalog_labels : label => {
      display_name = coalesce(try(var.catalogs[label].display_name, null), label)

      # azuread_access_package_catalog.description is a REQUIRED provider argument, so a
      # null fails the apply with "The argument description is required" — after a clean
      # plan, and contradicting this module's promise that a catalog label needs no
      # configuration at all.
      #
      # But the leaf rejects a non-null description when adopting, because the catalog
      # belongs to another team and rewriting its description would silently alter their
      # delegation boundary. So: a default when creating, null when adopting.
      description = (
        local.catalog_adopt[label] ? null : coalesce(
          try(var.catalogs[label].description, null),
          "Access packages for Terraform-vended cloud access. Catalog \"${label}\".",
        )
      )

      externally_visible      = coalesce(try(var.catalogs[label].externally_visible, null), false)
      published               = coalesce(try(var.catalogs[label].published, null), true)
      adopt_existing          = local.catalog_adopt[label]
      delegate_to_systemeier  = coalesce(try(var.catalogs[label].delegate_to_systemeier, null), false)
      systemeier_catalog_role = coalesce(try(var.catalogs[label].systemeier_catalog_role, null), "Access package manager")
    }
  }

  unknown_catalog_labels = [
    for label in keys(var.catalogs) : label
    if !contains(local.catalog_labels, label)
  ]

  # Systemeier to delegate a catalog role to, per catalog: the union across the scopes the
  # catalog contains. Keyed on UPN so the for_each key comes from configuration rather than
  # from a data source.
  catalog_delegated_upns = {
    for label in local.catalog_labels : label => (
      local.catalog_settings[label].delegate_to_systemeier
      ? toset(flatten([for s in local.v.catalogs[label].scope_keys : local.v.scopes[s].systemeier]))
      : toset([])
    )
  }

  # ----------------------------------------------------------------------------
  # The EligibleMember gap
  #
  # Driven by the VALUE of access_type rather than by jit_mechanism, because the provider
  # limitation is about the access type. Repo 1 only returns EligibleMember for
  # pim_for_groups today, but keying off the value means a future mechanism that also
  # needs eligibility is caught automatically instead of slipping through as standing
  # membership.
  # ----------------------------------------------------------------------------

  provider_supported_access_types = ["Member", "Owner"]

  unsupported_role_keys = [
    for k in local.role_keys : k
    if !contains(local.provider_supported_access_types, local.v.roles[k].access_type)
  ]

  excluded_role_keys = var.manage_pim_for_groups_roles ? [] : local.unsupported_role_keys

  managed_role_keys = [
    for k in local.role_keys : k
    if !contains(local.excluded_role_keys, k)
  ]

  # The downgrade only ever applies to opted-in roles. With manage_pim_for_groups_roles
  # false, excluded_role_keys already removed every unsupported value, so this is a no-op.
  # With it true, the operator has acknowledged that eligibility becomes standing active
  # membership.
  effective_access_type = {
    for k in local.managed_role_keys :
    k => contains(local.provider_supported_access_types, local.v.roles[k].access_type) ? local.v.roles[k].access_type : "Member"
  }

  # ============================================================================
  # PACKAGE DEFINITIONS
  #
  # Either the caller's named packages, or one per scope containing every role in that
  # scope. `role_keys` here is the DECLARED set, before the EligibleMember exclusion —
  # the exclusion is applied later, and the expiry ceiling deliberately uses the declared
  # set (see the ceiling section for why).
  # ============================================================================

  using_explicit_packages = length(var.packages) > 0

  package_defs = local.using_explicit_packages ? {
    for name, p in var.packages : name => { role_keys = p.role_keys }
    } : {
    # DEFAULT: one package per scope, named after the scope, holding every role in it.
    # Preserves the zero-config promise exactly — a caller who sets nothing gets what
    # this module produced before named packages existed.
    for s, cfg in local.v.scopes : s => { role_keys = cfg.role_keys }
  }

  package_names = keys(local.package_defs)

  # Role keys a package names that the contract does not contain. Rejected in a
  # precondition rather than skipped: a package silently missing a role grants less than
  # it claims, and nothing in the portal would say so.
  unknown_role_keys_by_package = {
    for name, p in local.package_defs : name => [
      for k in p.role_keys : k if !contains(local.role_keys, k)
    ]
  }

  packages_with_unknown_roles = [
    for name, ks in local.unknown_role_keys_by_package : name if length(ks) > 0
  ]

  # Packages whose every role key resolves. Everything downstream derives from this, so
  # that a bad role key produces a precondition failure rather than an index error deep
  # in a local — locals are evaluated eagerly, and `local.v.roles[unknown]` would blow up
  # before any precondition could report it.
  resolvable_packages = {
    for name, p in local.package_defs : name => p
    if length(local.unknown_role_keys_by_package[name]) == 0 && length(p.role_keys) > 0
  }

  # Every scope a package touches. Decision (c) in the feature brief: a package spanning
  # scopes is REJECTED for now, so this is expected to be a single element.
  package_scopes = {
    for name, p in local.resolvable_packages : name => distinct([
      for k in p.role_keys : local.v.roles[k].scope
    ])
  }

  cross_scope_packages = [
    for name, scopes in local.package_scopes : name if length(scopes) > 1
  ]

  # The one scope a package belongs to. Safe to index [0]: resolvable_packages guarantees
  # a non-empty role_keys list, so the scope list has at least one element. A cross-scope
  # package takes the first, which is meaningless but harmless — the precondition fails
  # the plan before anything is created.
  package_scope = {
    for name, scopes in local.package_scopes : name => scopes[0]
  }

  # Catalog per package: an explicit per-package override, else the catalog of its scope.
  #
  # A per-package catalog is what makes "engineers in the platform catalog, admins in the
  # privileged catalog" possible. It is also exactly why catalog associations cannot be
  # keyed on the role alone any more — see catalog_role_pairs.
  package_catalog = {
    for name in keys(local.resolvable_packages) : name => coalesce(
      try(var.packages[name].catalog, null),
      local.v.scopes[local.package_scope[name]].catalog,
    )
  }

  # A package naming a catalog label the contract does not define. Repo 1 owns the label
  # set — the catalog is a label on a scope there — so this module creates no catalog that
  # repo 1 has not declared.
  packages_with_unknown_catalog = [
    for name, label in local.package_catalog : name
    if !contains(local.catalog_labels, label)
  ]

  # Roles the contract vended that no package grants. Not an error — a caller using
  # explicit packages may deliberately not expose a role — but it IS reported, because a
  # role with no package is access that was created and cannot be requested.
  packaged_role_keys = distinct(flatten([
    for name, p in local.resolvable_packages : p.role_keys
  ]))

  unpackaged_role_keys = [
    for k in local.role_keys : k if !contains(local.packaged_role_keys, k)
  ]

  # ----------------------------------------------------------------------------
  # Roles per package, after the EligibleMember exclusion
  # ----------------------------------------------------------------------------

  managed_roles_by_package = {
    for name, p in local.resolvable_packages :
    name => [for k in p.role_keys : k if contains(local.managed_role_keys, k)]
  }

  excluded_roles_by_package = {
    for name, p in local.resolvable_packages :
    name => [for k in p.role_keys : k if contains(local.excluded_role_keys, k)]
  }

  excluded_resource_roles = {
    for k in local.excluded_role_keys : k => {
      scope                = local.v.roles[k].scope
      role                 = local.v.roles[k].role
      cloud                = local.v.scopes[local.v.roles[k].scope].cloud
      group_name           = local.v.roles[k].group_name
      group_object_id      = local.v.roles[k].group_object_id
      jit_mechanism        = local.v.roles[k].jit_mechanism
      target               = local.v.roles[k].target
      required_access_type = local.v.roles[k].access_type
      # Which packages wanted this role, and in which catalog the manual step has to be
      # done. A role can now appear in more than one package.
      packages = [for name, ks in local.excluded_roles_by_package : name if contains(ks, k)]
      catalogs = distinct([
        for name, ks in local.excluded_roles_by_package : local.package_catalog[name]
        if contains(ks, k)
      ])
      # Registration happens regardless of access type, so the manual step is one click
      # on a resource that is already in the catalog.
      catalog_resource_registered = true
    }
  }

  # ----------------------------------------------------------------------------
  # Peer approval — the approver group as a resource role
  #
  # Repo 1 seeds each approver group with its scope's systemeier, so dual-approval roles
  # work on the first apply. But PIM blocks self-approval, so a group with exactly one
  # member cannot approve that member's own request: it sits until it times out after 24
  # hours, a timeout nobody can configure. Attaching the approver group makes everyone
  # holding the package a peer approver.
  #
  # Per PACKAGE now, not per scope, and that is the point: with named packages the
  # junior/senior split is just two packages over the same scope where only one sets
  # grant_approver_group. Seniors approve; juniors request and activate but never appear
  # as an approver.
  # ----------------------------------------------------------------------------

  # Scope => approver group name, for scopes that have one. Pre-filtered so no later
  # expression tests approver_group_name for null inside a compound condition — see the
  # null-handling note in the ceiling section.
  scopes_with_approver_group = {
    for s in local.scope_keys : s => local.v.scopes[s].approver_group_name
    if local.v.scopes[s].approver_group_name != null
  }

  # Whether each package grants its scope's approver group: per-package override, else the
  # global default, and only where the scope actually has one.
  packages_granting_approver_group = [
    for name in keys(local.resolvable_packages) : name
    if coalesce(
      try(var.packages[name].grant_approver_group, null),
      var.defaults.grant_approver_group,
    ) && contains(keys(local.scopes_with_approver_group), local.package_scope[name])
  ]

  # Scopes where a lone systemeier cannot approve their own request and no package adds a
  # peer. Iterates the pre-filtered map, so the null is gone before the comparison.
  scopes_granted_approver_group = distinct([
    for name in local.packages_granting_approver_group : local.package_scope[name]
  ])

  deadlocked_approver_scopes = [
    for s, group_name in local.scopes_with_approver_group : s
    if length(local.v.scopes[s].systemeier) < 2 && !contains(local.scopes_granted_approver_group, s)
  ]

  # Role key "approvers" is reserved in repo 1 so it cannot collide with an approver group
  # name, which makes "{scope}--approvers" guaranteed free as a resource_roles label.
  approver_role_label = {
    for name in local.packages_granting_approver_group :
    name => "${local.package_scope[name]}--approvers"
  }

  # ----------------------------------------------------------------------------
  # Effective per-package settings: package_overrides layered over defaults
  #
  # For explicit packages, display_name/description also come from the package definition
  # itself, which is the more natural place to put them.
  # ----------------------------------------------------------------------------

  effective = {
    for name in keys(local.resolvable_packages) : name => {
      display_name = coalesce(
        try(var.package_overrides[name].display_name, null),
        try(var.packages[name].display_name, null),
        name,
      )
      description = coalesce(
        try(var.package_overrides[name].description, null),
        try(var.packages[name].description, null),
        "Membership of the ${local.package_scope[name]} scope. Grants the roles in this package plus their escalation paths; each escalation is still gated by PIM.",
      )
      assignment_duration_days = coalesce(
        try(var.package_overrides[name].assignment_duration_days, null),
        try(var.packages[name].assignment_duration_days, null),
        var.defaults.assignment_duration_days,
      )
      requestor_scope_type = coalesce(
        try(var.package_overrides[name].requestor_scope_type, null),
        try(var.packages[name].requestor_scope_type, null),
        var.defaults.requestor_scope_type,
      )
      require_justification = coalesce(
        try(var.package_overrides[name].require_justification, null),
        try(var.packages[name].require_justification, null),
        var.defaults.require_justification,
      )
      approval_timeout_days = coalesce(
        try(var.package_overrides[name].approval_timeout_days, null),
        try(var.packages[name].approval_timeout_days, null),
        var.defaults.approval_timeout_days,
      )
      question_text = coalesce(
        try(var.package_overrides[name].question_text, null),
        try(var.packages[name].question_text, null),
        "Why do you need access to the ${local.package_scope[name]} scope, and for how long?",
      )
      hidden = coalesce(
        try(var.package_overrides[name].hidden, null),
        try(var.packages[name].hidden, null),
        false,
      )
      requests_accepted = coalesce(
        try(var.package_overrides[name].requests_accepted, null),
        try(var.packages[name].requests_accepted, null),
        true,
      )
    }
  }

  unknown_override_packages = [
    for name in keys(var.package_overrides) : name
    if !contains(local.package_names, name)
  ]

  # ----------------------------------------------------------------------------
  # Gate 1 approvers
  #
  # DECISION (c). A package's gate 1 approvers are the systemeier of its single scope.
  # Packages that span scopes are rejected rather than resolved, because the two
  # resolutions on offer are both wrong today:
  #
  #   (a) union of every touched scope's systemeier — an owner of scope A could then
  #       approve entry to scope B, which is a quiet privilege expansion
  #   (b) approval from each scope's systemeier in turn — not expressible; the provider
  #       allows one approval stage per assignment policy
  #
  # Every case in front of us is single-scope, so rejecting is the honest option. Revisit
  # when a genuine cross-scope persona appears — at which point this is the comment to
  # come back to, and (a) with an explicit acknowledgement flag is the likely answer.
  # ----------------------------------------------------------------------------

  all_systemeier_upns = toset(flatten([
    for s in local.scope_keys : local.v.scopes[s].systemeier
  ]))

  # ----------------------------------------------------------------------------
  # The expiry ceiling
  #
  # Repo 1 emits max_assignment_days as a number per role, so nothing here parses
  # ISO-8601. A package's ceiling is the minimum non-null value across THE PACKAGE'S
  # roles — not the scope's, which is the point of the feature: an engineers package
  # holding only reader and contributor is not constrained by an owner role it does not
  # grant.
  #
  # Computed over the package's DECLARED roles, including any excluded by the
  # EligibleMember gap. Those are expected to be added by hand in the portal, and once
  # they are, their PIM eligibility expiry constrains the package just the same. Using
  # only the managed roles would let a too-long duration pass the plan and then start
  # silently dropping access after the manual step.
  #
  # NULL HANDLING. Every null is filtered out in a `for` clause, and each map is keyed
  # only on the packages that survived. Nothing here guards a null with
  # `x != null && <compare x>` or a `x == null ? ... : ...` ternary. That is not a style
  # preference: Terraform does not dependably short-circuit && or ||, so the second
  # operand is still evaluated and a comparison against null fails the whole expression
  # with "argument must not be null". Whether it short-circuits varies by Terraform
  # version and by whether the operands are known at plan time, which makes the bug
  # appear only in some consumers' plans.
  #
  # So ceiling_by_package deliberately has NO entry for a package with no ceiling. Use
  # lookup(local.ceiling_by_package, name, null) where a value is needed for every
  # package, as verification_summary does.
  # ----------------------------------------------------------------------------

  ceiling_candidates_by_package = {
    for name, p in local.resolvable_packages : name => {
      for k in p.role_keys : k => local.v.roles[k].max_assignment_days
      if local.v.roles[k].max_assignment_days != null
    }
  }

  ceiling_by_package = {
    for name, cands in local.ceiling_candidates_by_package : name => min(values(cands)...)
    if length(cands) > 0
  }

  # The role that set the binding ceiling, so the error can name it. Iterating
  # ceiling_by_package means `ceiling` is non-null by construction, and the inner list is
  # guaranteed non-empty because the ceiling came from those very candidates via min().
  binding_ceiling_role_by_package = {
    for name, ceiling in local.ceiling_by_package : name => [
      for k, days in local.ceiling_candidates_by_package[name] : k
      if days == ceiling
    ][0]
  }

  packages_over_ceiling = [
    for name, ceiling in local.ceiling_by_package : name
    if local.effective[name].assignment_duration_days > ceiling
  ]

  # ----------------------------------------------------------------------------
  # Catalog resource associations, keyed on (catalog, role)
  #
  # azuread_access_package_resource_catalog_association is unique per (catalog, group).
  #
  # Before named packages, keying on the role key alone was already keying on
  # (catalog, group): a role belongs to one scope, and a scope sits in one catalog, so
  # role -> catalog was 1:1. A per-package catalog breaks that. Two packages in DIFFERENT
  # catalogs can now share a role, and that legitimately needs TWO associations — one per
  # catalog — which a role-keyed map cannot represent. It would silently create one and
  # the second package's resource association would fail at APPLY.
  #
  # Two packages in the SAME catalog sharing a role is the other direction: one catalog
  # association, two package associations. The map below collapses those to one entry
  # because the composite key is identical, which is exactly right — and is already how
  # the approver group attaches to several packages.
  #
  # merge() over a concat with a leading {} so the call always has at least one argument,
  # even when resolvable_packages is empty.
  # ----------------------------------------------------------------------------

  catalog_role_pairs = merge(concat([{}], [
    for name, p in local.resolvable_packages : {
      for k in p.role_keys :
      "${local.package_catalog[name]}|${k}" => {
        catalog  = local.package_catalog[name]
        role_key = k
      }
    }
  ])...)

  catalog_approver_pairs = merge(concat([{}], [
    for name in local.packages_granting_approver_group : {
      "${local.package_catalog[name]}|${local.package_scope[name]}--approvers" = {
        catalog = local.package_catalog[name]
        scope   = local.package_scope[name]
      }
    }
  ])...)

  # "|" is the separator in the composite keys above. A catalog label containing one would
  # make two different (catalog, role) pairs collide on the same key, so it is rejected
  # rather than silently mis-keyed.
  catalog_labels_with_separator = [
    for label in local.catalog_labels : label if strcontains(label, "|")
  ]

  # ----------------------------------------------------------------------------
  # Resource roles per package
  # ----------------------------------------------------------------------------

  resource_roles_by_package = {
    for name in keys(local.resolvable_packages) : name => merge(
      {
        for k in local.managed_roles_by_package[name] : k => {
          catalog_resource_association_id = azuread_access_package_resource_catalog_association.role_group["${local.package_catalog[name]}|${k}"].id
          access_type                     = local.effective_access_type[k]
        }
      },
      contains(local.packages_granting_approver_group, name) ? {
        (local.approver_role_label[name]) = {
          catalog_resource_association_id = azuread_access_package_resource_catalog_association.approver_group["${local.package_catalog[name]}|${local.package_scope[name]}--approvers"].id
          access_type                     = "Member"
        }
      } : {},
    )
  }

  empty_packages = [
    for name in keys(local.resolvable_packages) : name
    if length(local.managed_roles_by_package[name]) == 0 && !contains(local.packages_granting_approver_group, name)
  ]

  # ----------------------------------------------------------------------------
  # Duplicate-association guard for approver groups
  #
  # Role groups are safe by construction: the (catalog, role) key IS the uniqueness
  # constraint. Approver groups are not, because approver_group_name may point at a group
  # repo 1 does not manage, and two scopes could name the same one. Two scopes sharing an
  # approver group across DIFFERENT catalogs is fine and must produce two associations —
  # which is why the key cannot be the group alone. Sharing one inside the SAME catalog is
  # a duplicate the provider only reports at apply, partway through, with resources
  # already created.
  # ----------------------------------------------------------------------------

  approver_group_catalog_pairs = distinct([
    for name in local.packages_granting_approver_group :
    "${local.package_catalog[name]} / ${local.scopes_with_approver_group[local.package_scope[name]]}"
  ])

  # (catalog, approver group name) => the distinct SCOPES that would each register it.
  # More than one scope means two associations for the same (catalog, group), because the
  # association key includes the scope.
  approver_pair_scopes = {
    for pair in local.approver_group_catalog_pairs : pair => distinct([
      for name in local.packages_granting_approver_group : local.package_scope[name]
      if "${local.package_catalog[name]} / ${local.scopes_with_approver_group[local.package_scope[name]]}" == pair
    ])
  }

  duplicate_approver_group_pairs = [
    for pair, scopes in local.approver_pair_scopes : pair if length(scopes) > 1
  ]
}
