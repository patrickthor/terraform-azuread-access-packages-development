# ==============================================================================
# Inputs
#
# There is no scope list, no role list and no group name here. All of it arrives in
# `vending` — repo 1's single contract output. Adding a scope, a role or a catalog in
# repo 1 requires no change to this module or to the caller's tfvars.
# ==============================================================================

# ------------------------------------------------------------------------------
# The contract from repo 1 (access-vending)
# ------------------------------------------------------------------------------

variable "vending" {
  description = <<-EOT
    Repo 1's `contract` output, passed straight through by the caller.

    The module takes a plain typed object rather than reading a remote state itself. In
    the reference architecture both modules live in one root config and this value flows
    in memory as module.access_vending.contract, which makes the apply order a property
    of the dependency graph instead of a convention. A caller who wants split states can
    still feed this from a remote state read in their own root — that is their choice,
    not the module's.

    `roles` is keyed on the composite "{scope}--{role}". `scopes` is keyed on the scope
    key. `catalogs` is keyed on the catalog LABEL. The `role_keys` and `scope_keys` lists
    exist so that iteration sources provably come from configuration rather than from
    repo 1's resource attributes — see the note in main.tf.
  EOT

  type = object({
    contract_version = number

    roles = map(object({
      scope               = string
      role                = string
      group_name          = string
      group_object_id     = string
      access_type         = string
      jit_mechanism       = string
      permanent_access    = bool
      target              = string
      max_assignment_days = optional(number)
    }))

    scopes = map(object({
      catalog                  = string
      cloud                    = string
      scope_id                 = optional(string)
      systemeier               = list(string)
      approver_group_name      = optional(string)
      approver_group_object_id = optional(string)
      role_keys                = list(string)
    }))

    catalogs = map(object({
      scope_keys = list(string)
    }))
  })

  # Three validations, not eleven. Everything the old cross-map key-consistency checks
  # caught is now a type error, which is a better error: the type system reports the
  # missing attribute by name instead of a hand-written message inferring it.

  validation {
    condition     = var.vending.contract_version == 1
    error_message = <<-EOT
      Unsupported contract_version. This module supports version 1.

      The contract is the interface between repo 1 and repo 2, and the version is bumped
      whenever a field is removed, renamed, or changes meaning. A mismatch means the two
      repos are pinned to incompatible tags — fix the pin rather than working around the
      shape difference. Never wrap a contract field in try() to paper this over: that is
      how a missing access_type silently becomes standing access.
    EOT
  }

  validation {
    condition     = alltrue([for k in keys(var.vending.roles) : length(split("--", k)) == 2])
    error_message = <<-EOT
      Every key in vending.roles must be a composite "{scope}--{role}".

      Repo 1 reserves "--" and validates it out of both scope keys and role keys, so a key
      of any other shape means the object being passed in is not repo 1's contract, or
      comes from an incompatible version of it.
    EOT
  }

  validation {
    condition     = length(var.vending.roles) > 0
    error_message = <<-EOT
      vending.roles is empty, so there are no groups to build packages around and the
      apply would produce empty catalogs.

      The usual cause is that repo 1 has not been applied yet, or that its access_scopes
      input is empty. Repo 1 must always come first — not only so the groups exist, but
      because for pim_for_groups roles it is the act of writing the PIM policy that
      onboards the group to PIM for Groups, and until that has happened the platform does
      not offer EligibleMember as a resource role at all.
    EOT
  }
}

# ------------------------------------------------------------------------------
# Catalogs
# ------------------------------------------------------------------------------

variable "catalogs" {
  description = <<-EOT
    Per-catalog settings, keyed on the catalog LABEL from repo 1's contract.

    Every key is optional — a label with no entry here gets the defaults, so the simple
    case needs no configuration at all. A key that does not appear in the contract is
    rejected, because an override with no effect is the accepted-and-ignored pattern this
    project refuses.

    A catalog in Entra is a delegation boundary: it controls who may add resources to it
    and manage the packages inside it. The label should therefore track ownership, not
    environment. One identity team owning everything means one catalog is correct.
  EOT

  type = map(object({
    display_name       = optional(string)
    description        = optional(string)
    externally_visible = optional(bool, false)
    published          = optional(bool, true)

    # Adopt an existing catalog instead of creating one. Real customers usually have a
    # catalog already, owned by an identity team that will not hand over creation rights.
    adopt_existing = optional(bool, false)

    # Make each contained scope's systemeier a catalog role holder, so package management
    # is delegated to the people who already approve gate 1. Off by default: it is a
    # standing grant, and standing grants are this project's default no.
    delegate_to_systemeier  = optional(bool, false)
    systemeier_catalog_role = optional(string, "Access package manager")
  }))

  default = {}

  validation {
    # Nulls are filtered in the `for` clause rather than guarded with `c.description ==
    # null || ...`. Terraform's || does not reliably short-circuit, so the second operand
    # is still evaluated and a function receiving the null fails with "argument must not
    # be null" instead of the message below.
    condition = alltrue([
      for c in values(var.catalogs) : c.adopt_existing == false
      if c.description != null
    ])
    error_message = <<-EOT
      A catalog entry sets both `description` and `adopt_existing = true`.

      Adopting means the catalog belongs to someone else. Rewriting its description would
      silently alter another team's delegation boundary. Either drop the description, or
      create the catalog rather than adopting it.
    EOT
  }
}

# ------------------------------------------------------------------------------
# Request-side defaults
# ------------------------------------------------------------------------------

variable "defaults" {
  description = <<-EOT
    Request-side settings applied to every package unless overridden per scope.

    Defaults fail safe, following repo 1's instinct: approval is always required at gate 1
    and the assignment always expires. Forgetting a field here gives you more control, not
    less.
  EOT

  type = object({
    assignment_duration_days = optional(number, 14)
    requestor_scope_type     = optional(string, "AllExistingDirectoryMemberUsers")
    require_justification    = optional(bool, true)
    approval_timeout_days    = optional(number, 7)
    grant_approver_group     = optional(bool, true)
  })

  default = {}

  validation {
    condition     = var.defaults.assignment_duration_days >= 1 && var.defaults.assignment_duration_days <= 3650
    error_message = <<-EOT
      defaults.assignment_duration_days must be between 1 and 3650.

      Short durations are this system's substitute for access reviews: the assignment
      expires and the user has to ask again. Note that individual packages have their own
      lower ceiling, taken from repo 1's max_assignment_days for the roles they grant.
    EOT
  }

  validation {
    condition     = var.defaults.approval_timeout_days >= 1 && var.defaults.approval_timeout_days <= 60
    error_message = <<-EOT
      defaults.approval_timeout_days must be between 1 and 60.

      This timeout governs the access package request — gate 1 — only. PIM activation at
      gate 2 has its own fixed 24-hour timeout that neither repo can change.
    EOT
  }
}

variable "scope_overrides" {
  description = <<-EOT
    Per-scope deviations from `defaults`, keyed on scope key. Omitted fields fall back to
    `defaults`.

    Every key must match a scope that exists in the contract. A typo is rejected rather
    than silently having no effect.
  EOT

  type = map(object({
    display_name             = optional(string)
    description              = optional(string)
    assignment_duration_days = optional(number)
    requestor_scope_type     = optional(string)
    require_justification    = optional(bool)
    approval_timeout_days    = optional(number)
    question_text            = optional(string)
    hidden                   = optional(bool)
    requests_accepted        = optional(bool)
  }))

  default = {}
}

# ------------------------------------------------------------------------------
# The EligibleMember gap
# ------------------------------------------------------------------------------

variable "manage_pim_for_groups_roles" {
  description = <<-EOT
    Whether to attach roles whose contract access_type is "EligibleMember" anyway,
    downgraded to "Member".

    Default false, which is the documented behaviour: those roles get their *catalog*
    association created but not their *package* association, and are reported in the
    excluded_resource_roles and manual_steps_required outputs. The manual portal step is
    then one click on an already-registered resource.

    Setting this true trades the just-in-time model for full IaC coverage: the user becomes
    an *active* member of the group the moment the assignment lands, with standing access to
    the target cloud. Because that is a security regression rather than a config
    preference, it additionally requires acknowledge_m3_active_membership = true.
  EOT
  type        = bool
  default     = false
}

variable "acknowledge_m3_active_membership" {
  description = <<-EOT
    Explicit acknowledgement that enabling manage_pim_for_groups_roles converts
    just-in-time eligibility into standing active membership.

    Two flags instead of one because the failure mode is invisible: the apply succeeds, the
    portal looks correct, and the only symptom is that users hold access they should have
    had to activate for.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = var.manage_pim_for_groups_roles == false || var.acknowledge_m3_active_membership == true
    error_message = <<-EOT
      manage_pim_for_groups_roles = true also requires acknowledge_m3_active_membership = true.

      azuread_access_package_resource_package_association.access_type is validated
      client-side to "Member" and "Owner" only. There is no "EligibleMember", even though
      the Entra platform offers that role in the portal for PIM-managed groups — the sole
      barrier is an allowlist on the provider's schema field.

      So enabling this flag does not produce eligibility. It produces active membership,
      and the affected users get standing access to AWS, GCP or GitHub instead of having to
      activate through PIM. Nothing about that is visible in a plan or an apply.

      If you accept it knowingly, set acknowledge_m3_active_membership = true. If not,
      leave both false and complete those roles in the portal using the list in the
      excluded_resource_roles output.
    EOT
  }
}
