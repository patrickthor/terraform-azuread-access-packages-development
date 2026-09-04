# ==============================================================================
# Inputs
#
# There is no scope list and no role list here. Both are derived from repo 1's
# state, which is passed in as the `vending` object. Adding a scope or a role in
# repo 1 requires no change to this module or to the caller's tfvars.
# ==============================================================================

# ------------------------------------------------------------------------------
# The contract from repo 1 (access-vending)
# ------------------------------------------------------------------------------

variable "vending" {
  description = <<-EOT
    Repo 1's outputs, read by the caller from its remote state.

    The caller passes this in rather than the module reading the state itself, so
    that examples/complete can run against literal values on local state. A module
    with a hardcoded `data "terraform_remote_state"` could not be tested without a
    live storage account.

    Keys: most maps are keyed on the composite "{scope}--{role}". The three
    approver_group_* maps are keyed on "{scope}" alone, because one approver group
    serves every role under a scope. Splitting on "--" is safe: repo 1 reserves the
    separator and validates it out of both scope keys and role keys.
  EOT

  type = object({
    # Keyed on composite "{scope}--{role}" — the primary contract
    group_names                = map(string)
    group_object_ids           = map(string)
    access_package_access_type = map(string)
    jit_mechanism              = map(string)

    # Keyed on "{scope}"
    systemeier_by_scope            = map(list(string))
    approver_group_object_ids      = optional(map(string), {})
    approver_group_names           = optional(map(string), {})
    approver_group_is_managed_here = optional(map(bool), {})

    # Forwarded verbatim to outputs, never interpreted here. These describe gate 2
    # (PIM activation), which repo 1 owns. Repo 2 republishes them so that one
    # `terraform output` shows both gates, but it must not re-implement them.
    approvers_by_role               = optional(any, {})
    access_model                    = optional(any, {})
    activation_settings             = optional(any, {})
    entra_activation_governance_gap = optional(any, {})
  })

  validation {
    condition     = length(var.vending.group_names) > 0
    error_message = <<-EOT
      vending.group_names is empty, so there are no groups to build packages
      around and the apply would produce an empty catalog.

      The usual cause is that repo 1 has not been applied yet, or that the remote
      state key points at the wrong state file. Repo 1 must always apply first —
      not only so the groups exist, but because for pim_for_groups roles it is the
      act of writing the PIM policy that onboards the group to PIM for Groups. See
      trap 6.2 in ASSIGNMENT-2-STEERING.md.
    EOT
  }

  validation {
    condition = alltrue([
      for k in keys(var.vending.group_names) : length(split("--", k)) == 2
    ])
    error_message = <<-EOT
      Every key in vending.group_names must be a composite "{scope}--{role}".

      The scope half of that key is what this module groups packages by, so a key
      without exactly one "--" separator cannot be assigned to a package. Repo 1
      reserves "--" and validates it out of both scope keys and role keys, so a key
      of the wrong shape means the state being read is not repo 1's, or is from an
      incompatible version of it.
    EOT
  }

  validation {
    condition = alltrue([
      for k in keys(var.vending.group_names) :
      contains(keys(var.vending.group_object_ids), k)
    ])
    error_message = <<-EOT
      Every key in vending.group_names must also appear in
      vending.group_object_ids.

      The object ID is what registers the group as a catalog resource
      (resource_origin_id); the name alone cannot. A key present in one map and
      missing from the other means the two outputs were read from different states
      or at different times.
    EOT
  }

  validation {
    condition = alltrue([
      for k in keys(var.vending.group_names) :
      contains(keys(var.vending.access_package_access_type), k)
    ])
    error_message = <<-EOT
      Every key in vending.group_names must also appear in
      vending.access_package_access_type.

      This module refuses to guess the access type. Defaulting a missing entry to
      "Member" is exactly the silent failure described in blocker 2.1: an
      EligibleMember role would become an active membership, granting standing
      access instead of just-in-time access, and nothing would fail.
    EOT
  }

  validation {
    condition = alltrue([
      for k in keys(var.vending.group_names) :
      contains(keys(var.vending.jit_mechanism), k)
    ])
    error_message = <<-EOT
      Every key in vending.group_names must also appear in vending.jit_mechanism.

      The mechanism decides whether the trap 6.1 expiry ceiling applies to the
      package that contains this role. Without it the ceiling cannot be enforced,
      and an over-long assignment duration would let Entitlement Management and PIM
      drift apart silently.
    EOT
  }

  validation {
    condition = alltrue([
      for scope in distinct([for k in keys(var.vending.group_names) : split("--", k)[0]]) :
      contains(keys(var.vending.systemeier_by_scope), scope)
    ])
    error_message = <<-EOT
      Every scope present in vending.group_names must have an entry in
      vending.systemeier_by_scope.

      The systemeier are gate 1: they decide who may enter the scope at all. A
      package with no gate-1 approver is either an unapprovable package whose
      requests time out, or an unguarded one that hands out access on request. This
      module will not build either, so a missing scope is rejected instead of
      defaulted.
    EOT
  }

  validation {
    condition = alltrue([
      for scope in keys(var.vending.approver_group_object_ids) :
      contains(distinct([for k in keys(var.vending.group_names) : split("--", k)[0]]), scope)
    ])
    error_message = <<-EOT
      vending.approver_group_object_ids contains a scope that has no roles in
      vending.group_names.

      An approver group whose scope has no roles has no package to attach to, so
      the entry would be accepted and then quietly dropped. That is the
      accepted-and-ignored pattern this project rejects. Either the states being
      read are inconsistent, or a scope's roles were removed in repo 1 while its
      approver group was left behind.
    EOT
  }
}

# ------------------------------------------------------------------------------
# Catalog
# ------------------------------------------------------------------------------

variable "catalog_display_name" {
  description = "Display name of the single catalog holding every package."
  type        = string
}

variable "catalog_description" {
  description = "Description of the catalog."
  type        = string
  default     = "Access packages for Terraform-vended cloud access. Managed by repo 2 (access-packages)."
}

variable "catalog_externally_visible" {
  description = <<-EOT
    Whether the catalog is visible to users outside the tenant. Left false: every
    scope in this POC grants cloud access, and none of it is intended for guests.
  EOT
  type        = bool
  default     = false
}

variable "catalog_published" {
  description = "Whether the catalog is published, and therefore whether its packages are requestable."
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# Request-side defaults
# ------------------------------------------------------------------------------

variable "defaults" {
  description = <<-EOT
    Request-side settings applied to every package unless overridden per scope.

    Defaults fail safe, following repo 1's instinct: approval is always required at
    gate 1 and the assignment expires on its own. Forgetting a field here gives you
    more control, not less.
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

      Short durations are this POC's substitute for access reviews: the assignment
      expires and the user has to ask again. Note the separate, lower ceiling for
      packages containing pim_for_groups roles — see m3_max_duration_days.
    EOT
  }

  validation {
    condition     = var.defaults.approval_timeout_days >= 1 && var.defaults.approval_timeout_days <= 60
    error_message = <<-EOT
      defaults.approval_timeout_days must be between 1 and 60.

      This timeout governs the access package request (gate 1) only. PIM activation
      requests (gate 2) have their own non-configurable 24-hour timeout, which
      neither repo can change.
    EOT
  }
}

variable "scope_overrides" {
  description = <<-EOT
    Per-scope deviations from `defaults`, keyed on scope key. Omitted fields fall
    back to `defaults`.

    Every key must match a scope that actually exists in repo 1's state. A typo is
    rejected rather than silently having no effect.
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
# Blocker 2.1 — roles the provider cannot express
# ------------------------------------------------------------------------------

variable "manage_pim_for_groups_roles" {
  description = <<-EOT
    Whether to attach roles whose access type is "EligibleMember" to their
    package anyway, downgraded to "Member".

    Default false, which implements option 1 from blocker 2.1: those roles are left
    out of Terraform, listed in the `excluded_resource_roles` output, and added by
    hand in the portal where "Eligible Member" is selectable. Their catalog
    associations are still created here, so the manual step is one click per group
    rather than a full resource registration.

    Setting this true trades the just-in-time model for full IaC coverage: the user
    becomes an *active* member of the group the moment the assignment lands, with
    standing access to the target cloud. Because that is a security regression and
    not merely a config change, it additionally requires
    acknowledge_m3_active_membership = true.
  EOT
  type        = bool
  default     = false
}

variable "acknowledge_m3_active_membership" {
  description = <<-EOT
    Explicit acknowledgement that enabling manage_pim_for_groups_roles converts
    just-in-time eligibility into standing active membership.

    Two flags instead of one because the failure mode here is invisible: the apply
    succeeds, the portal looks correct, and the only symptom is that users hold
    access they should have had to activate for.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = var.manage_pim_for_groups_roles == false || var.acknowledge_m3_active_membership == true
    error_message = <<-EOT
      manage_pim_for_groups_roles = true also requires
      acknowledge_m3_active_membership = true.

      The azuread provider accepts only "Member" and "Owner" for
      azuread_access_package_resource_package_association.access_type. It has no
      "EligibleMember", even though the Entra platform offers that role in the
      portal for PIM-managed groups. So enabling this flag does not produce
      eligibility — it produces active membership, and the affected users get
      standing access to AWS, GCP or GitHub instead of having to activate through
      PIM.

      Nothing about that failure is visible in a plan or an apply. If you accept it
      knowingly, set acknowledge_m3_active_membership = true. If you do not, leave
      both false and complete those roles in the portal using the list in the
      excluded_resource_roles output.
    EOT
  }
}

variable "m3_max_duration_days" {
  description = <<-EOT
    Ceiling on assignment_duration_days for any package containing a
    pim_for_groups role. Must stay at or below repo 1's
    active_assignment_expire_after, whose default is P30D.

    If the package outlives the group's eligible-assignment expiry, Entitlement
    Management and PIM drift apart: PIM expires the eligibility while the package
    still shows the user as assigned, so they lose access without losing the
    assignment. See trap 6.1.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.m3_max_duration_days >= 1 && var.m3_max_duration_days <= 3650
    error_message = "m3_max_duration_days must be between 1 and 3650."
  }
}
