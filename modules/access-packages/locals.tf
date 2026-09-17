# ==============================================================================
# Derivation
#
# Everything here comes from the contract plus, optionally, var.packages and
# var.approver_packages. This repo writes no scope key, role key, group name or catalog
# label of its own.
#
# THE UNIT IS A PACKAGE. Two KINDS of package exist and they share all the resource wiring:
#
#   kind = "access"    grants role groups. One per scope by default, or several per scope
#                      when var.packages names them.
#   kind = "approver"  grants only {cloud}-{scope}-approvers, nothing else. One per scope.
#
# They are merged into one map keyed on package name before anything is built, so main.tf
# has a single module call and a single set of associations. The only thing that differs is
# which resource roles go in.
#
# ITERATION SOURCES. Where this file feeds a for_each it uses contract keys, the contract's
# explicit role_keys / scope_keys lists, or the caller's variables — never
# `distinct([for k in keys(roles) : split("--", k)[0]])`. Repo 1 guarantees its keys and
# lists are derivable from its input variables alone, so they are known at plan time.
# Recomputing them here would work today and break the plan the moment repo 1 populated a
# list from a resource attribute, with the error surfacing in this module for a change made
# in the other repo.
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

  # Split out because `description` below branches on it, and a `for` expression building an
  # object cannot reference a sibling attribute of that same object.
  catalog_adopt = {
    for label in local.catalog_labels : label =>
    coalesce(try(var.catalogs[label].adopt_existing, null), false)
  }

  catalog_settings = {
    for label in local.catalog_labels : label => {
      display_name = coalesce(try(var.catalogs[label].display_name, null), label)

      # azuread_access_package_catalog.description is a REQUIRED provider argument, so a null
      # fails the apply with "The argument description is required" — after a clean plan, and
      # contradicting this module's promise that a catalog label needs no configuration at all.
      #
      # But the leaf rejects a non-null description when adopting, because the catalog belongs
      # to another team and rewriting its description would silently alter their delegation
      # boundary. So: a default when creating, null when adopting.
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
  # Access type
  #
  # Under contract v2 every role is attached as plain Member (or Owner) on a plain group, so
  # there is nothing to exclude and nothing to downgrade. The exclusion machinery is kept
  # because the check is about what the PROVIDER can express, not about one mechanism: if
  # repo 1 ever emits an access type the provider rejects, it is caught and reported rather
  # than applied wrongly. Under v2 the variable validation already refuses such a contract,
  # so in practice these lists stay empty — and an empty excluded_resource_roles is the
  # useful signal, not a reason to delete the output.
  # ----------------------------------------------------------------------------

  provider_supported_access_types = ["Member", "Owner"]

  excluded_role_keys = [
    for k in local.role_keys : k
    if !contains(local.provider_supported_access_types, local.v.roles[k].access_type)
  ]

  managed_role_keys = [
    for k in local.role_keys : k
    if !contains(local.excluded_role_keys, k)
  ]

  effective_access_type = {
    for k in local.managed_role_keys : k => local.v.roles[k].access_type
  }

  # Roles whose real access is activation on a second, PIM-managed group. Reported so that
  # granted_groups_by_package does not imply the plain group IS the access.
  pim_backed_role_keys = [
    for k in local.role_keys : k if local.v.roles[k].jit_mechanism == "pim_for_groups"
  ]

  # ============================================================================
  # ACCESS PACKAGE DEFINITIONS
  #
  # Either the caller's named packages, or one per scope containing every role in that
  # scope. `role_keys` is the DECLARED set; the expiry ceiling deliberately uses it rather
  # than the attached set (see the ceiling section).
  # ============================================================================

  using_explicit_packages = length(var.packages) > 0

  access_package_defs = local.using_explicit_packages ? {
    for name, p in var.packages : name => { role_keys = p.role_keys }
    } : {
    # DEFAULT: one package per scope, named after the scope, holding every role in it.
    for s, cfg in local.v.scopes : s => { role_keys = cfg.role_keys }
  }

  # Role keys a package names that the contract does not contain. Rejected in a precondition
  # rather than skipped: a package silently missing a role grants less than it claims, and
  # nothing in the portal would say so.
  unknown_role_keys_by_package = {
    for name, p in local.access_package_defs : name => [
      for k in p.role_keys : k if !contains(local.role_keys, k)
    ]
  }

  packages_with_unknown_roles = [
    for name, ks in local.unknown_role_keys_by_package : name if length(ks) > 0
  ]

  # Access packages whose every role key resolves. Everything downstream derives from this,
  # so that a bad role key produces a precondition failure rather than an index error deep in
  # a local — locals are evaluated eagerly, and `local.v.roles[unknown]` would blow up before
  # any precondition could report it.
  resolvable_access_packages = {
    for name, p in local.access_package_defs : name => p
    if length(local.unknown_role_keys_by_package[name]) == 0 && length(p.role_keys) > 0
  }

  # Every scope an access package touches. A package spanning scopes is REJECTED — see the
  # gate 1 note below.
  access_package_scopes = {
    for name, p in local.resolvable_access_packages : name => distinct([
      for k in p.role_keys : local.v.roles[k].scope
    ])
  }

  cross_scope_packages = [
    for name, scopes in local.access_package_scopes : name if length(scopes) > 1
  ]

  # ============================================================================
  # APPROVER PACKAGE DEFINITIONS
  #
  # One per scope that has an approver group, granting only that group.
  #
  # Per scope and not per package because repo 1 creates one approver group per scope: a
  # second approver package for a second audience in the same scope would grant the
  # identical group twice.
  # ============================================================================

  # Scope => approver group name, for scopes that have one. Pre-filtered so no later
  # expression tests approver_group_name for null inside a compound condition — see the
  # null-handling note in the ceiling section.
  scopes_with_approver_group = {
    for s in local.scope_keys : s => local.v.scopes[s].approver_group_name
    if local.v.scopes[s].approver_group_name != null
  }

  # Default on: every scope with an approver group gets one unless explicitly disabled.
  approver_package_scopes = [
    for s in keys(local.scopes_with_approver_group) : s
    if coalesce(try(var.approver_packages[s].enabled, null), true)
  ]

  # The generated name. Package names are a namespace shared with var.packages, so a
  # collision is rejected rather than silently resolved in either direction.
  approver_package_name = { for s in local.approver_package_scopes : s => "${s}-approvers" }

  # Reverse lookup, used when assembling resource roles and reporting.
  approver_package_scope_by_name = {
    for s, name in local.approver_package_name : name => s
  }

  reserved_name_collisions = [
    for s, name in local.approver_package_name : name
    if contains(keys(var.packages), name)
  ]

  # Approver package keys named in var.approver_packages that are not scopes with an approver
  # group. Configuring one has no effect, so it is rejected.
  unknown_approver_package_scopes = [
    for s in keys(var.approver_packages) : s
    if !contains(keys(local.scopes_with_approver_group), s)
  ]

  # ============================================================================
  # THE MERGED PACKAGE SET
  #
  # From here down there is one kind-agnostic package map. main.tf builds every package from
  # this, which is what keeps the two kinds from forking the resource wiring.
  # ============================================================================

  package_kind = merge(
    { for name in keys(local.resolvable_access_packages) : name => "access" },
    { for s, name in local.approver_package_name : name => "approver" },
  )

  all_package_names = keys(local.package_kind)

  # The one scope a package belongs to. Safe to index [0] for access packages:
  # resolvable_access_packages guarantees a non-empty role_keys list. A cross-scope package
  # takes the first, which is meaningless but harmless — the precondition fails the plan
  # before anything is created.
  package_scope = merge(
    { for name, scopes in local.access_package_scopes : name => scopes[0] },
    { for s, name in local.approver_package_name : name => s },
  )

  # Catalog per package.
  #
  # Access packages may name their own, which is how a privileged tier gets its own
  # delegation boundary. Approver packages always follow their scope: approval rights over a
  # scope belong to whoever owns that scope's delegation boundary, so making it configurable
  # would let approval be delegated somewhere the access itself is not.
  package_catalog = merge(
    {
      for name in keys(local.resolvable_access_packages) : name => coalesce(
        try(var.packages[name].catalog, null),
        local.v.scopes[local.package_scope[name]].catalog,
      )
    },
    { for s, name in local.approver_package_name : name => local.catalog_of_scope[s] },
  )

  packages_with_unknown_catalog = [
    for name, label in local.package_catalog : name
    if !contains(local.catalog_labels, label)
  ]

  # ----------------------------------------------------------------------------
  # Roles per access package
  # ----------------------------------------------------------------------------

  managed_roles_by_package = {
    for name, p in local.resolvable_access_packages :
    name => [for k in p.role_keys : k if contains(local.managed_role_keys, k)]
  }

  excluded_roles_by_package = {
    for name, p in local.resolvable_access_packages :
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
      packages             = [for name, ks in local.excluded_roles_by_package : name if contains(ks, k)]
      catalogs = distinct([
        for name, ks in local.excluded_roles_by_package : local.package_catalog[name]
        if contains(ks, k)
      ])
      catalog_resource_registered = true
    }
  }

  # Roles the contract vended that no access package grants. Not an error — a caller using
  # explicit packages may deliberately not expose a role — but it IS reported, because a role
  # with no package is access that was created and cannot be requested.
  packaged_role_keys = distinct(flatten([
    for name, p in local.resolvable_access_packages : p.role_keys
  ]))

  unpackaged_role_keys = [
    for k in local.role_keys : k if !contains(local.packaged_role_keys, k)
  ]

  # ----------------------------------------------------------------------------
  # Effective per-package settings
  #
  # package_overrides layered over the package definition, layered over defaults. Approver
  # packages read var.approver_packages[scope] as their definition.
  # ----------------------------------------------------------------------------

  effective = {
    for name in local.all_package_names : name => {
      display_name = coalesce(
        try(var.package_overrides[name].display_name, null),
        try(var.packages[name].display_name, null),
        try(var.approver_packages[local.package_scope[name]].display_name, null),
        local.package_kind[name] == "approver" ? "${local.package_scope[name]} approver rights" : name,
      )
      description = coalesce(
        try(var.package_overrides[name].description, null),
        try(var.packages[name].description, null),
        try(var.approver_packages[local.package_scope[name]].description, null),
        local.package_kind[name] == "approver"
        ? "Peer-approval rights for the ${local.package_scope[name]} scope. Grants membership of ${lookup(local.scopes_with_approver_group, local.package_scope[name], "the approver group")} and nothing else: it confers the right to approve other people's activation requests, not the access itself."
        : "Membership of the ${local.package_scope[name]} scope. Grants the roles in this package plus their escalation paths; each escalation is still gated by PIM.",
      )
      assignment_duration_days = coalesce(
        try(var.package_overrides[name].assignment_duration_days, null),
        try(var.packages[name].assignment_duration_days, null),
        try(var.approver_packages[local.package_scope[name]].assignment_duration_days, null),
        var.defaults.assignment_duration_days,
      )
      requestor_scope_type = coalesce(
        try(var.package_overrides[name].requestor_scope_type, null),
        try(var.packages[name].requestor_scope_type, null),
        try(var.approver_packages[local.package_scope[name]].requestor_scope_type, null),
        var.defaults.requestor_scope_type,
      )
      require_justification = coalesce(
        try(var.package_overrides[name].require_justification, null),
        try(var.packages[name].require_justification, null),
        try(var.approver_packages[local.package_scope[name]].require_justification, null),
        var.defaults.require_justification,
      )
      approval_timeout_days = coalesce(
        try(var.package_overrides[name].approval_timeout_days, null),
        try(var.packages[name].approval_timeout_days, null),
        try(var.approver_packages[local.package_scope[name]].approval_timeout_days, null),
        var.defaults.approval_timeout_days,
      )
      question_text = coalesce(
        try(var.package_overrides[name].question_text, null),
        try(var.packages[name].question_text, null),
        try(var.approver_packages[local.package_scope[name]].question_text, null),
        local.package_kind[name] == "approver"
        ? "Why should you be able to approve other people's access to the ${local.package_scope[name]} scope?"
        : "Why do you need access to the ${local.package_scope[name]} scope, and for how long?",
      )
      hidden = coalesce(
        try(var.package_overrides[name].hidden, null),
        try(var.packages[name].hidden, null),
        try(var.approver_packages[local.package_scope[name]].hidden, null),
        false,
      )
      requests_accepted = coalesce(
        try(var.package_overrides[name].requests_accepted, null),
        try(var.packages[name].requests_accepted, null),
        try(var.approver_packages[local.package_scope[name]].requests_accepted, null),
        true,
      )
    }
  }

  unknown_override_packages = [
    for name in keys(var.package_overrides) : name
    if !contains(local.all_package_names, name)
  ]

  # ----------------------------------------------------------------------------
  # Gate 1 approvers
  #
  # ALWAYS the systemeier of the package's single scope — for both kinds.
  #
  # For approver packages that is the load-bearing rule, not a convenience: if the approver
  # group approved requests for the approver package, approvers would appoint approvers and
  # the escalation loop would have no terminating authority. The chain has to end at the
  # systemeier, who are named in the contract and are not themselves vended by this system.
  #
  # For access packages, a package spanning scopes is REJECTED rather than resolved. The two
  # resolutions on offer are both wrong today:
  #
  #   (a) union of every touched scope's systemeier — an owner of scope A could then approve
  #       entry to scope B, which is a quiet privilege expansion
  #   (b) approval from each scope's systemeier in turn — not expressible; the provider allows
  #       one approval stage per assignment policy
  #
  # Every case in front of us is single-scope, so rejecting is the honest option. Revisit when
  # a genuine cross-scope persona appears — this is the comment to come back to, and (a) with
  # an explicit acknowledgement flag is the likely answer.
  # ----------------------------------------------------------------------------

  all_systemeier_upns = toset(flatten([
    for s in local.scope_keys : local.v.scopes[s].systemeier
  ]))

  # ----------------------------------------------------------------------------
  # The expiry ceiling
  #
  # Repo 1 emits max_assignment_days as a number per role, so nothing here parses ISO-8601. A
  # package's ceiling is the minimum non-null value across THE PACKAGE'S roles — not the
  # scope's: an engineers package holding only reader and contributor is not constrained by an
  # owner role it does not grant.
  #
  # For pim_for_groups roles the ceiling still comes from the PIM-MANAGED group's
  # active_assignment_expire_after, not from the plain group the package attaches. The package
  # assignment governs membership of the plain group; if that outlives the PIM eligibility the
  # user keeps the membership and silently loses the ability to activate.
  #
  # Computed over the package's DECLARED roles, including any the provider cannot express.
  # Approver packages have no entry: the approver group is a plain group with no PIM policy
  # and therefore no expiry to drift against.
  #
  # NULL HANDLING. Every null is filtered out in a `for` clause, and each map is keyed only on
  # the packages that survived. Nothing here guards a null with `x != null && <compare x>` or
  # a `x == null ? ... : ...` ternary. That is not a style preference: Terraform does not
  # dependably short-circuit && or ||, so the second operand is still evaluated and a
  # comparison against null fails the whole expression with "argument must not be null".
  # Whether it short-circuits varies by Terraform version and by whether the operands are
  # known at plan time, which makes the bug appear only in some consumers' plans.
  #
  # So ceiling_by_package deliberately has NO entry for a package with no ceiling. Use
  # lookup(local.ceiling_by_package, name, null) where a value is needed for every package.
  # ----------------------------------------------------------------------------

  ceiling_candidates_by_package = {
    for name, p in local.resolvable_access_packages : name => {
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
  # Catalog resource associations, keyed on (catalog, group)
  #
  # azuread_access_package_resource_catalog_association is unique per (catalog, group).
  #
  # Keying on the role key alone would only be safe while catalog is derived from scope,
  # making role -> catalog 1:1. A per-package catalog breaks that: two packages in DIFFERENT
  # catalogs can share a role, and that legitimately needs TWO associations — one per catalog
  # — which a role-keyed map cannot represent. It would silently create one and the second
  # package's resource association would fail at APPLY.
  #
  # Two packages in the SAME catalog sharing a role is the other direction: one catalog
  # association, two package associations. The maps below collapse those to one entry because
  # the composite key is identical, which is exactly right.
  #
  # merge() over a concat with a leading {} so the call always has at least one argument, even
  # when the package set is empty.
  # ----------------------------------------------------------------------------

  catalog_role_pairs = merge(concat([{}], [
    for name, p in local.resolvable_access_packages : {
      for k in p.role_keys :
      "${local.package_catalog[name]}|${k}" => {
        catalog  = local.package_catalog[name]
        role_key = k
      }
    }
  ])...)

  # One per approver package. The key shape is unchanged from when the approver group was a
  # resource role on the access package, so the association is reused rather than recreated.
  catalog_approver_pairs = {
    for s in local.approver_package_scopes :
    "${local.catalog_of_scope[s]}|${s}--approvers" => {
      catalog = local.catalog_of_scope[s]
      scope   = s
    }
  }

  # "|" is the separator in the composite keys above. A catalog label containing one would
  # make two different (catalog, group) pairs collide on the same key, so it is rejected
  # rather than silently mis-keyed.
  catalog_labels_with_separator = [
    for label in local.catalog_labels : label if strcontains(label, "|")
  ]

  # ----------------------------------------------------------------------------
  # Resource roles per package
  #
  # Access packages grant role groups ONLY — the approver-group branch that used to live here
  # is gone, which is the whole point of the split. Approver packages grant exactly one group.
  # ----------------------------------------------------------------------------

  resource_roles_by_package = merge(
    {
      for name in keys(local.resolvable_access_packages) : name => {
        for k in local.managed_roles_by_package[name] : k => {
          catalog_resource_association_id = azuread_access_package_resource_catalog_association.role_group["${local.package_catalog[name]}|${k}"].id
          access_type                     = local.effective_access_type[k]
        }
      }
    },
    {
      for s, name in local.approver_package_name : name => {
        "${s}--approvers" = {
          catalog_resource_association_id = azuread_access_package_resource_catalog_association.approver_group["${local.catalog_of_scope[s]}|${s}--approvers"].id
          access_type                     = "Member"
        }
      }
    },
  )

  empty_packages = [
    for name in local.all_package_names : name
    if length(local.resource_roles_by_package[name]) == 0
  ]

  # ----------------------------------------------------------------------------
  # Peer-approval viability
  #
  # Repo 1 seeds each approver group with its scope's systemeier, so dual-approval roles work
  # on the first apply. But PIM blocks self-approval, so a group with exactly one member
  # cannot approve that member's own request: it sits until it times out after 24 hours, a
  # timeout nobody can configure.
  #
  # The approver package is what fixes that — it lets additional people be granted approval
  # rights without also being granted the access. So the test is whether the scope HAS an
  # approver package, not whether some access package attaches the group.
  # ----------------------------------------------------------------------------

  deadlocked_approver_scopes = [
    for s, group_name in local.scopes_with_approver_group : s
    if length(local.v.scopes[s].systemeier) < 2 && !contains(local.approver_package_scopes, s)
  ]

  # ----------------------------------------------------------------------------
  # Duplicate-association guard for approver groups
  #
  # Role groups are safe by construction: the (catalog, role) key IS the uniqueness
  # constraint. Approver groups are not, because approver_group_name may point at a group repo
  # 1 does not manage, and two scopes could name the same one. Two scopes sharing an approver
  # group across DIFFERENT catalogs is fine and must produce two associations — which is why
  # the key cannot be the group alone. Sharing one inside the SAME catalog is a duplicate the
  # provider only reports at apply, partway through, with resources already created.
  # ----------------------------------------------------------------------------

  approver_group_catalog_pairs = distinct([
    for s in local.approver_package_scopes :
    "${local.catalog_of_scope[s]} / ${local.scopes_with_approver_group[s]}"
  ])

  approver_pair_scopes = {
    for pair in local.approver_group_catalog_pairs : pair => distinct([
      for s in local.approver_package_scopes : s
      if "${local.catalog_of_scope[s]} / ${local.scopes_with_approver_group[s]}" == pair
    ])
  }

  duplicate_approver_group_pairs = [
    for pair, scopes in local.approver_pair_scopes : pair if length(scopes) > 1
  ]
}
