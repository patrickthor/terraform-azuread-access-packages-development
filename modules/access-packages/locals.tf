# ==============================================================================
# Derivation — the whole package set comes from repo 1's state
#
# Nothing in this file reads a scope list or a role list from configuration. That
# is the point: adding a role in repo 1 and re-applying repo 2 picks it up with no
# config change, and removing one drops it the same way.
#
# This is also the part that gets replaced when packages become personas spanning
# several scopes (section 5.2). The resource wiring in main.tf survives that
# change; the mapping below does not.
# ==============================================================================

locals {
  v = var.vending

  # Composite keys, "{scope}--{role}". Approver groups are NOT in here — they are
  # keyed on scope alone in a separate output, because one approver group serves
  # every role under its scope.
  role_keys = sort(keys(local.v.group_names))

  # One package per scope. sort() keeps plan output and for_each ordering stable.
  scopes = sort(distinct([for k in local.role_keys : split("--", k)[0]]))

  roles_by_scope = {
    for s in local.scopes :
    s => [for k in local.role_keys : k if split("--", k)[0] == s]
  }

  # ----------------------------------------------------------------------------
  # Blocker 2.1 — split the roles the provider can express from the ones it cannot
  #
  # The split is driven by access_package_access_type rather than by
  # jit_mechanism, because the provider limitation is about the access type. Repo 1
  # only ever returns EligibleMember for pim_for_groups today, but keying off the
  # value itself means a future mechanism that also needs eligibility is caught
  # automatically instead of slipping through as active membership.
  # ----------------------------------------------------------------------------

  provider_supported_access_types = ["Member", "Owner"]

  unsupported_role_keys = [
    for k in local.role_keys : k
    if !contains(local.provider_supported_access_types, local.v.access_package_access_type[k])
  ]

  excluded_role_keys = var.manage_pim_for_groups_roles ? [] : local.unsupported_role_keys

  managed_role_keys = [
    for k in local.role_keys : k
    if !contains(local.excluded_role_keys, k)
  ]

  managed_roles_by_scope = {
    for s in local.scopes :
    s => [for k in local.roles_by_scope[s] : k if contains(local.managed_role_keys, k)]
  }

  # Downgrade only ever applies to opted-in roles: when
  # manage_pim_for_groups_roles is false, excluded_role_keys already removed every
  # unsupported value, so this coalesce is a no-op. When it is true, the operator
  # has acknowledged that eligibility becomes active membership.
  effective_access_type = {
    for k in local.managed_role_keys :
    k => contains(local.provider_supported_access_types, local.v.access_package_access_type[k]) ? local.v.access_package_access_type[k] : "Member"
  }

  # What the operator has to finish by hand, per group. Surfaced as an output so
  # the gap shows up in `terraform output` and not only in a comment.
  excluded_resource_roles = {
    for k in local.excluded_role_keys : k => {
      scope                 = split("--", k)[0]
      role                  = split("--", k)[1]
      group_name            = local.v.group_names[k]
      group_object_id       = local.v.group_object_ids[k]
      jit_mechanism         = local.v.jit_mechanism[k]
      required_access_type  = local.v.access_package_access_type[k]
      access_package        = split("--", k)[0]
      catalog_resource_done = true
    }
  }

  # ----------------------------------------------------------------------------
  # Section 5.5 option A — the approver group as a resource role
  #
  # Repo 1 seeds each approver group with its scope's systemeier, so `dual` roles
  # work on the first apply. But an approver cannot approve their own request, so a
  # scope with exactly one systemeier deadlocks: the lone owner cannot activate
  # their own dual role and the request times out after 24 hours. Attaching the
  # approver group to the package makes every member of the scope a peer approver,
  # which resolves that.
  #
  # Keyed on scope, and only for scopes that actually have an approver group —
  # repo 1 creates one only where some role uses approval_type = "dual".
  # ----------------------------------------------------------------------------

  approver_group_scopes = var.defaults.grant_approver_group ? sort(keys(local.v.approver_group_object_ids)) : []

  # Role key "approvers" is reserved in repo 1 precisely so it cannot collide with
  # an approver group name, which means "{scope}--approvers" is guaranteed free as
  # a resource_roles label here.
  approver_role_label = { for s in local.approver_group_scopes : s => "${s}--approvers" }

  # ----------------------------------------------------------------------------
  # Effective per-scope settings: scope_overrides layered over defaults
  # ----------------------------------------------------------------------------

  effective = {
    for s in local.scopes : s => {
      display_name = coalesce(
        try(var.scope_overrides[s].display_name, null),
        s,
      )
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

  # ----------------------------------------------------------------------------
  # Gate 1 approvers — the scope's systemeier, resolved from UPN to object ID
  #
  # Flattened across scopes only for the data lookup, so each UPN is resolved once
  # even when the same person owns several scopes.
  # ----------------------------------------------------------------------------

  all_systemeier_upns = toset(flatten([
    for s in local.scopes : local.v.systemeier_by_scope[s]
  ]))

  # ----------------------------------------------------------------------------
  # Trap 6.1 — which packages are subject to the M3 expiry ceiling
  # ----------------------------------------------------------------------------

  m3_scopes = sort(distinct([
    for k in local.role_keys : split("--", k)[0]
    if local.v.jit_mechanism[k] == "pim_for_groups"
  ]))

  m3_scopes_over_ceiling = [
    for s in local.m3_scopes : s
    if local.effective[s].assignment_duration_days > var.m3_max_duration_days
  ]

  # ----------------------------------------------------------------------------
  # Resource roles per package, assembled for the leaf module
  # ----------------------------------------------------------------------------

  resource_roles_by_scope = {
    for s in local.scopes : s => merge(
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

  # Scopes whose package would grant nothing. Computed here so the precondition in
  # main.tf can name them; see the error message there for why this is fatal.
  empty_scopes = [
    for s in local.scopes : s
    if length(local.managed_roles_by_scope[s]) == 0 && !contains(local.approver_group_scopes, s)
  ]

  # Scope keys named in scope_overrides that do not exist in repo 1's state.
  unknown_override_scopes = [
    for s in keys(var.scope_overrides) : s
    if !contains(local.scopes, s)
  ]
}
