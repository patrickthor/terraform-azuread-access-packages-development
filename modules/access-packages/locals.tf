# ==============================================================================
# Derivation
#
# Everything here comes from the contract. No scope key, role key, group name or
# catalog label is written in this repo's source.
#
# ITERATION SOURCES. Where this file feeds a for_each, it uses the contract's own
# keys and its explicit `role_keys` / `scope_keys` lists — never
# `distinct([for k in keys(roles) : split("--", k)[0]])`. Repo 1 guarantees those
# keys and lists are derivable from its input variables alone, so they are known at
# plan time. Recomputing them here would work today and would break the plan the
# moment repo 1 populated a list from a resource attribute, with the error surfacing
# in this module for a change made in the other repo.
#
# Values inside the maps may be unknown until apply — `group_object_id` always is.
# That is fine. Unknown values are only a problem in `for_each` and `count`.
# ==============================================================================

locals {
  v = var.vending

  catalog_labels = keys(local.v.catalogs)
  scope_keys     = keys(local.v.scopes)
  role_keys      = keys(local.v.roles)

  # Which catalog each scope's package belongs to.
  catalog_of_scope = { for s, cfg in local.v.scopes : s => cfg.catalog }

  # ----------------------------------------------------------------------------
  # Catalog settings: var.catalogs layered over the defaults
  #
  # The display name defaults to the label itself, so a customer who adds a catalog in
  # repo 1 gets a working catalog here with no configuration at all.
  # ----------------------------------------------------------------------------

  catalog_settings = {
    for label in local.catalog_labels : label => {
      display_name            = coalesce(try(var.catalogs[label].display_name, null), label)
      description             = try(var.catalogs[label].description, null)
      externally_visible      = coalesce(try(var.catalogs[label].externally_visible, null), false)
      published               = coalesce(try(var.catalogs[label].published, null), true)
      adopt_existing          = coalesce(try(var.catalogs[label].adopt_existing, null), false)
      delegate_to_systemeier  = coalesce(try(var.catalogs[label].delegate_to_systemeier, null), false)
      systemeier_catalog_role = coalesce(try(var.catalogs[label].systemeier_catalog_role, null), "Access package manager")
    }
  }

  # Catalog labels named in var.catalogs that the contract does not contain.
  unknown_catalog_labels = [
    for label in keys(var.catalogs) : label
    if !contains(local.catalog_labels, label)
  ]

  # Systemeier to delegate per catalog: the union across the scopes it contains.
  # Keyed on UPN so the for_each key comes from configuration, not from a data source.
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
  # Driven by the *value* of access_type rather than by jit_mechanism, because the
  # provider limitation is about the access type. Repo 1 only returns EligibleMember
  # for pim_for_groups today, but keying off the value means a future mechanism that
  # also needs eligibility is caught automatically instead of slipping through as
  # standing membership.
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

  managed_roles_by_scope = {
    for s in local.scope_keys :
    s => [for k in local.v.scopes[s].role_keys : k if contains(local.managed_role_keys, k)]
  }

  # The downgrade only ever applies to opted-in roles. With
  # manage_pim_for_groups_roles false, excluded_role_keys already removed every
  # unsupported value, so this is a no-op. With it true, the operator has
  # acknowledged that eligibility becomes standing active membership.
  effective_access_type = {
    for k in local.managed_role_keys :
    k => contains(local.provider_supported_access_types, local.v.roles[k].access_type) ? local.v.roles[k].access_type : "Member"
  }

  excluded_resource_roles = {
    for k in local.excluded_role_keys : k => {
      scope                = local.v.roles[k].scope
      role                 = local.v.roles[k].role
      cloud                = local.v.scopes[local.v.roles[k].scope].cloud
      catalog              = local.catalog_of_scope[local.v.roles[k].scope]
      group_name           = local.v.roles[k].group_name
      group_object_id      = local.v.roles[k].group_object_id
      jit_mechanism        = local.v.roles[k].jit_mechanism
      target               = local.v.roles[k].target
      required_access_type = local.v.roles[k].access_type
      access_package       = local.v.roles[k].scope
      # Registration happens regardless of access type, so the manual step is one
      # click on a resource that is already in the catalog.
      catalog_resource_registered = true
    }
  }

  # ----------------------------------------------------------------------------
  # Peer approval — the approver group as a resource role
  #
  # Repo 1 seeds each approver group with its scope's systemeier, so dual-approval
  # roles work on the first apply. But PIM blocks self-approval, so a group with
  # exactly one member cannot approve that member's own request: the request sits
  # until it times out after 24 hours, a timeout nobody can configure. Attaching the
  # approver group to the package makes everyone in the scope a peer approver.
  #
  # Only scopes that actually have an approver group — repo 1 creates one only where
  # some role uses dual approval.
  # ----------------------------------------------------------------------------

  approver_group_scopes = var.defaults.grant_approver_group ? [
    for s in local.scope_keys : s
    if local.v.scopes[s].approver_group_name != null
  ] : []

  # Role key "approvers" is reserved in repo 1 so it cannot collide with an approver
  # group name, which makes "{scope}--approvers" guaranteed free as a label here.
  approver_role_label = { for s in local.approver_group_scopes : s => "${s}--approvers" }

  # ----------------------------------------------------------------------------
  # Effective per-scope settings
  # ----------------------------------------------------------------------------

  effective = {
    for s in local.scope_keys : s => {
      display_name = coalesce(try(var.scope_overrides[s].display_name, null), s)
      description = coalesce(
        try(var.scope_overrides[s].description, null),
        "Membership of the ${s} scope. Grants the scope's permanent baseline plus its escalation paths; each escalation is still gated by PIM.",
      )
      assignment_duration_days = coalesce(
        try(var.scope_overrides[s].assignment_duration_days, null),
        var.defaults.assignment_duration_days,
      )
      requestor_scope_type = coalesce(
        try(var.scope_overrides[s].requestor_scope_type, null),
        var.defaults.requestor_scope_type,
      )
      require_justification = coalesce(
        try(var.scope_overrides[s].require_justification, null),
        var.defaults.require_justification,
      )
      approval_timeout_days = coalesce(
        try(var.scope_overrides[s].approval_timeout_days, null),
        var.defaults.approval_timeout_days,
      )
      question_text = coalesce(
        try(var.scope_overrides[s].question_text, null),
        "Why do you need access to the ${s} scope, and for how long?",
      )
      hidden            = coalesce(try(var.scope_overrides[s].hidden, null), false)
      requests_accepted = coalesce(try(var.scope_overrides[s].requests_accepted, null), true)
    }
  }

  unknown_override_scopes = [
    for s in keys(var.scope_overrides) : s
    if !contains(local.scope_keys, s)
  ]

  # ----------------------------------------------------------------------------
  # Gate 1 approvers — systemeier UPNs resolved to object IDs
  #
  # Flattened across scopes for the data lookup so a person owning several scopes is
  # resolved once.
  # ----------------------------------------------------------------------------

  all_systemeier_upns = toset(flatten([
    for s in local.scope_keys : local.v.scopes[s].systemeier
  ]))

  # ----------------------------------------------------------------------------
  # The expiry ceiling
  #
  # repo 1 emits max_assignment_days as a number per role, so nothing here parses
  # ISO-8601. The ceiling for a package is the minimum non-null value across the roles
  # in its scope.
  #
  # Deliberately computed over ALL roles in the scope, not only the ones Terraform
  # attaches. A role excluded by the EligibleMember gap is expected to be added by hand
  # in the portal, and once it is, its PIM eligibility expiry constrains the package
  # just the same. Using only the managed roles would let a too-long duration pass the
  # plan and then start silently dropping access after the manual step.
  #
  # Nulls are filtered in the `for` clause, not guarded with `||`.
  # ----------------------------------------------------------------------------

  ceiling_candidates_by_scope = {
    for s in local.scope_keys : s => {
      for k in local.v.scopes[s].role_keys : k => local.v.roles[k].max_assignment_days
      if local.v.roles[k].max_assignment_days != null
    }
  }

  ceiling_by_scope = {
    for s in local.scope_keys : s => (
      length(local.ceiling_candidates_by_scope[s]) > 0
      ? min(values(local.ceiling_candidates_by_scope[s])...)
      : null
    )
  }

  # The role that set the binding ceiling, so the error can name it. The ceiling comes
  # from one role's PIM policy and the operator needs to know which one.
  binding_ceiling_role_by_scope = {
    for s in local.scope_keys : s => (
      local.ceiling_by_scope[s] == null ? null : [
        for k, days in local.ceiling_candidates_by_scope[s] : k
        if days == local.ceiling_by_scope[s]
      ][0]
    )
  }

  scopes_over_ceiling = [
    for s in local.scope_keys : s
    if local.ceiling_by_scope[s] != null
    && local.effective[s].assignment_duration_days > local.ceiling_by_scope[s]
  ]

  # ----------------------------------------------------------------------------
  # Resource roles per package
  # ----------------------------------------------------------------------------

  resource_roles_by_scope = {
    for s in local.scope_keys : s => merge(
      {
        for k in local.managed_roles_by_scope[s] : k => {
          catalog_resource_association_id = azuread_access_package_resource_catalog_association.role_group[k].id
          access_type                     = local.effective_access_type[k]
        }
      },
      contains(local.approver_group_scopes, s) ? {
        (local.approver_role_label[s]) = {
          catalog_resource_association_id = azuread_access_package_resource_catalog_association.approver_group[s].id
          access_type                     = "Member"
        }
      } : {},
    )
  }

  empty_scopes = [
    for s in local.scope_keys : s
    if length(local.managed_roles_by_scope[s]) == 0 && !contains(local.approver_group_scopes, s)
  ]

  # ----------------------------------------------------------------------------
  # Duplicate-association guard
  #
  # A catalog resource association is unique per (catalog, group). Role groups are safe
  # by repo 1's invariant — one group belongs to one role in one scope, and a scope sits
  # in exactly one catalog — so keying them on the role key is already keying on
  # (catalog, group).
  #
  # Approver groups are not automatically safe. `approver_group_name` may point at a
  # group repo 1 does not manage, and two scopes could name the same one. If those two
  # scopes share a catalog, keying on scope would try to register the same group twice
  # in the same catalog and fail at APPLY. Detected here so it fails at plan instead.
  #
  # Note that two scopes sharing an approver group across *different* catalogs is fine
  # and must still produce two associations, which is exactly why the key cannot be the
  # group alone.
  # ----------------------------------------------------------------------------

  approver_group_catalog_pairs = [
    for s in local.approver_group_scopes :
    "${local.catalog_of_scope[s]} / ${local.v.scopes[s].approver_group_name}"
  ]

  duplicate_approver_group_pairs = distinct([
    for pair in local.approver_group_catalog_pairs : pair
    if length([for p in local.approver_group_catalog_pairs : p if p == pair]) > 1
  ])
}
