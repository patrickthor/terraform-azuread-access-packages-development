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

    The module takes a plain typed object rather than reading a remote state itself. In the
    reference architecture both modules live in one root config and this value flows in
    memory as module.access_vending.contract, which makes the apply order a property of the
    dependency graph instead of a convention. A caller who wants split states can still feed
    this from a remote state read in their own root — that is their choice, not the module's.

    `roles` is keyed on the composite "{scope}--{role}". `scopes` is keyed on the scope key.
    `catalogs` is keyed on the catalog LABEL. The `role_keys` and `scope_keys` lists exist so
    that iteration sources provably come from configuration rather than from repo 1's
    resource attributes — see the note in main.tf.

    CONTRACT VERSION 2. For pim_for_groups roles, `group_object_id` is now a PLAIN,
    non-PIM-managed group that repo 1 makes an eligible member of the PIM-managed group.
    `access_type` is therefore "Member" for every mechanism, and `pim_group_name` /
    `pim_group_object_id` name the PIM-managed group the plain group confers eligibility on.
    That is what removed the EligibleMember gap: the access package attaches plain Member to
    a plain group, which the provider fully supports.
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

      # v2, pim_for_groups only. The PIM-managed group that group_object_id confers
      # eligibility on. Null for every other mechanism.
      pim_group_name      = optional(string)
      pim_group_object_id = optional(string)
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

  validation {
    condition     = var.vending.contract_version == 2
    error_message = <<-EOT
      Unsupported contract_version. This module supports version 2 and received a different
      one.

      Version 2 changed how pim_for_groups roles are represented: repo 1 now creates a plain
      group that is an eligible member of the PIM-managed group, so access_type is "Member"
      for every mechanism and pim_group_name / pim_group_object_id name the PIM-managed group
      behind it.

      Version 1 is deliberately NOT accepted with a branch. Under v1, pim_for_groups roles
      required access_type "EligibleMember", which the azuread provider cannot express, and
      this module excluded them and reported the gap. Supporting both shapes would mean
      carrying that dead path plus a silent behaviour difference between two callers running
      the same module version. Pin both repos to matching tags instead.

      Never wrap a contract field in try() to bridge a version gap: that is how a missing
      access_type silently becomes standing access.
    EOT
  }

  validation {
    condition     = alltrue([for k in keys(var.vending.roles) : length(split("--", k)) == 2])
    error_message = <<-EOT
      Every key in vending.roles must be a composite "{scope}--{role}".

      Repo 1 reserves "--" and validates it out of both scope keys and role keys, so a key of
      any other shape means the object being passed in is not repo 1's contract, or comes
      from an incompatible version of it.
    EOT
  }

  validation {
    condition     = length(var.vending.roles) > 0
    error_message = <<-EOT
      vending.roles is empty, so there are no groups to build packages around and the apply
      would produce empty catalogs.

      The usual cause is that repo 1 has not been applied yet, or that its access_scopes input
      is empty.
    EOT
  }

  validation {
    # v2 promises a plain group for pim_for_groups, so nothing should ask for an access type
    # the provider cannot set. Checked rather than assumed: this is the single field whose
    # silent mishandling turns just-in-time eligibility into standing cloud access.
    condition = alltrue([
      for r in values(var.vending.roles) : contains(["Member", "Owner"], r.access_type)
    ])
    error_message = <<-EOT
      A role has an access_type other than "Member" or "Owner".

      Under contract v2 every role — pim_for_groups included — is attached as plain Member on
      a plain group, so "EligibleMember" should no longer appear. Seeing it means repo 1 is
      emitting v1 shapes while claiming version 2.

      azuread_access_package_resource_package_association.access_type is validated
      client-side to Member and Owner only, so this cannot be applied as given. It is rejected
      here rather than downgraded, because a silent downgrade to Member is exactly the failure
      that grants standing access where eligibility was intended.
    EOT
  }

  validation {
    # A pim_for_groups role without its PIM group named is a contract that cannot be reported
    # honestly: granted_groups_by_package would show the plain group and imply it is the
    # access, when the access is activation on the group behind it.
    condition = alltrue([
      for r in values(var.vending.roles) : r.pim_group_object_id != null
      if r.jit_mechanism == "pim_for_groups"
    ])
    error_message = <<-EOT
      A pim_for_groups role is missing pim_group_object_id.

      Under contract v2 these roles are two groups: a plain group the access package attaches,
      and the PIM-managed group it confers eligibility on. Without the second one this module
      cannot report what the package actually leads to, and the expiry ceiling would appear to
      come from nowhere.
    EOT
  }
}

# ------------------------------------------------------------------------------
# Catalogs
# ------------------------------------------------------------------------------

variable "catalogs" {
  description = <<-EOT
    Per-catalog settings, keyed on the catalog LABEL from repo 1's contract.

    Every key is optional — a label with no entry here gets the defaults, so the simple case
    needs no configuration at all. A key that does not appear in the contract is rejected,
    because an override with no effect is the accepted-and-ignored pattern this project
    refuses.

    A catalog in Entra is a delegation boundary: it controls who may add resources to it and
    manage the packages inside it. The label should therefore track ownership, not
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

    # Make each contained scope's systemeier a catalog role holder, so package management is
    # delegated to the people who already approve gate 1. Off by default: it is a standing
    # grant, and standing grants are this project's default no.
    delegate_to_systemeier  = optional(bool, false)
    systemeier_catalog_role = optional(string, "Access package manager")
  }))

  default = {}

  validation {
    # Nulls are filtered in the `for` clause rather than guarded with `c.description == null
    # || ...`. Terraform's || does not reliably short-circuit, so the second operand is still
    # evaluated and a function receiving the null fails with "argument must not be null"
    # instead of the message below.
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
# Access packages
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Access reviews
# ------------------------------------------------------------------------------

variable "enable_access_reviews" {
  description = <<-EOT
    MASTER SWITCH for recurring access reviews. When false, no review block is emitted on any
    assignment policy regardless of what `access_reviews` configuration exists.

    A single boolean the caller sets — deliberately not inferred from whether review settings are
    present, so a pipeline can drive it from one checkbox and the configuration can be written,
    reviewed and merged before it goes live.

    Configuration is still resolved and reported when this is false: the `access_reviews` output
    shows the intended shape with `deployed = false`, and `manual_steps_required` calls out the
    configured-but-not-deployed state. That combination is exactly what someone would otherwise
    misread as "reviews are on".

    Turning this from true to false REMOVES the review block, which is an in-place update of the
    assignment policy — no assignment is dropped and nobody loses access. What is lost is the
    review campaign and its history, which is the audit trail.
  EOT
  type        = bool
  default     = false
}

# The shape reused on `defaults`, each `packages` entry and each `approver_packages` entry.
# Terraform has no type aliases, so it is repeated below; this comment is the single description.
#
#   review_frequency                weekly | monthly | quarterly | halfyearly | annual
#   review_type                     Reviewers | Self        ("Manager" is rejected)
#   duration_in_days                how long each campaign stays open
#   timeout_behavior                keepAccess | removeAccess
#   approver_justification_required defaults true
#
# PRESENCE MEANS ON. There is no `enabled` field, on purpose: an `enabled` here plus the master
# switch would be two switches at the same granularity with no obvious precedence.
#
# Consequence worth knowing: setting `defaults.access_reviews` turns reviews on for EVERY package,
# and there is no per-package opt-out. If you want reviews on some packages only, leave the
# default unset and set the block on the packages that need it.
#
# `starting_on` and `access_recommendation_enabled` are not exposed. See the leaf module's
# variables.tf for why.

variable "packages" {
  description = <<-EOT
    Named access packages, keyed on package name. OPTIONAL — leave it empty and the module
    behaves as it always has: one package per scope, containing every role in that scope.

    Set it when one scope needs more than one audience. A package grants everything in it
    atomically, so a scope-wide package cannot express "engineers get reader and contributor,
    admins also get owner". Named packages can, over the same groups:

      packages = {
        "engineers" = {
          display_name = "Prod Engineer Access"
          role_keys    = ["prod--reader", "prod--contributor"]
        }
        "admins" = {
          display_name             = "Prod Admin Access"
          role_keys                = ["prod--reader", "prod--contributor", "prod--owner"]
          assignment_duration_days = 7
        }
      }

    Setting this replaces the per-scope default entirely — it is not merged with it. Any role
    you do not name is reported in the unpackaged_roles output rather than quietly dropped.

    Every entry in role_keys must exist in the contract; unknown keys fail the plan.

    A package must stay within ONE scope. Gate 1 approval comes from the scope's systemeier,
    and a package spanning scopes has no single answer — see the gate 1 note in locals.tf.

    `catalog` defaults to the catalog of the package's scope. Naming a different one is how a
    privileged package gets its own delegation boundary, and it must still be a label the
    contract defines: repo 1 owns the catalog label set.

    These packages grant ROLE GROUPS ONLY. Peer-approval rights are a separate package — see
    var.approver_packages.
  EOT

  type = map(object({
    role_keys = list(string)

    display_name = optional(string)
    description  = optional(string)
    catalog      = optional(string)

    assignment_duration_days = optional(number)
    requestor_scope_type     = optional(string)
    require_justification    = optional(bool)
    approval_timeout_days    = optional(number)
    question_text            = optional(string)
    hidden                   = optional(bool)
    requests_accepted        = optional(bool)

    # Presence means this package gets a recurring review. See the note above the variable.
    access_reviews = optional(object({
      review_frequency                = optional(string)
      review_type                     = optional(string)
      duration_in_days                = optional(number)
      timeout_behavior                = optional(string)
      approver_justification_required = optional(bool)
    }))

    # Removed. Declared only so that setting it fails with an explanation rather than
    # "unsupported argument". See the validation below.
    grant_approver_group = optional(bool)
  }))

  default = {}

  validation {
    condition = alltrue([
      for p in values(var.packages) : p.grant_approver_group == null
    ])
    error_message = <<-EOT
      `grant_approver_group` on a package is no longer supported. Use var.approver_packages.

      It used to attach the scope's approver group as an extra resource role on this package,
      which coupled two different rights: anyone who requested the access automatically became
      a peer approver, and nobody could hold approval rights without also holding the access.

      The approver group is now its own access package, one per scope, granting only that
      group. So the decision moved from per-package to per-scope and the field would mean
      something different from what it used to — which is why it is rejected rather than
      reinterpreted.

        approver_packages = {
          "prod" = {
            display_name             = "Prod Approver Rights"
            assignment_duration_days = 90
          }
        }

      One approver package per scope is created by default for every scope whose contract
      entry has an approver group, so in most cases the field can simply be deleted.
    EOT
  }

  validation {
    condition     = alltrue([for p in values(var.packages) : length(p.role_keys) > 0])
    error_message = <<-EOT
      Every package must name at least one role in role_keys.

      A package with no roles is still requestable and still approvable, so it appears in
      MyAccess as working access while granting nothing. That is worse than the package not
      existing.
    EOT
  }

  validation {
    condition = alltrue([
      for p in values(var.packages) : length(p.role_keys) == length(distinct(p.role_keys))
    ])
    error_message = <<-EOT
      A package lists the same role key twice in role_keys.

      Duplicates are rejected rather than deduplicated: the map of resource roles is keyed on
      the role key, so a repeat would silently collapse and the package would look like it
      grants more than it does.
    EOT
  }
}

variable "package_overrides" {
  description = <<-EOT
    Per-package deviations from `defaults`, keyed on PACKAGE name. Omitted fields fall back to
    the package definition, then to `defaults`.

    Applies to approver packages too — their names are generated, and `approver_packages` is
    the more natural place to configure those.

    When `packages` is empty, access package names are scope names.

    Every key must match a package that exists. A typo is rejected rather than silently having
    no effect.
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
# Approver packages
# ------------------------------------------------------------------------------

variable "approver_packages" {
  description = <<-EOT
    Peer-approval rights as their own access package, keyed on SCOPE key.

    WHY THIS IS SEPARATE. Repo 1 seeds each approver group with the scope's systemeier and
    marks dual-approval roles as needing that group's sign-off. Attaching the group as a
    resource role on the access package — which is what this module used to do — welds two
    unrelated rights together: everyone who requests the access becomes an approver, and
    nobody can be an approver without also holding the access. Splitting them gives two
    independent grants with two independent expiries, and lets the approver population differ
    from the requester population.

      request access package    -> systemeier approve -> hold / activate the access
      request approver package  -> systemeier approve -> can approve other people

    ONE PER SCOPE, not per package. Repo 1 creates one approver group per scope, so a second
    approver package for a second audience in the same scope would grant the identical group
    twice.

    DEFAULT: one is created for every scope whose contract entry has a non-null
    approver_group_name, using `defaults`. That preserves the previous default-on behaviour.
    Every key here is optional; set one only to deviate, or `enabled = false` to opt out.

    Gate 1 on an approver package is always the scope's SYSTEMEIER, never the approver group
    itself. Approvers appointing approvers is an escalation loop with no terminating
    authority. The chain ends at the systemeier, who are named in the contract and are not
    themselves vended.

    The package lives in the same catalog as its scope, and is not separately configurable —
    approval rights over a scope belong to whoever owns that scope's delegation boundary.
  EOT

  type = map(object({
    enabled = optional(bool, true)

    display_name = optional(string)
    description  = optional(string)

    assignment_duration_days = optional(number)
    requestor_scope_type     = optional(string)
    require_justification    = optional(bool)
    approval_timeout_days    = optional(number)
    question_text            = optional(string)
    hidden                   = optional(bool)
    requests_accepted        = optional(bool)

    # Approver packages arguably need reviews most: approver rights are standing and confer
    # authority over other people's access, with no activation step in between.
    access_reviews = optional(object({
      review_frequency                = optional(string)
      review_type                     = optional(string)
      duration_in_days                = optional(number)
      timeout_behavior                = optional(string)
      approver_justification_required = optional(bool)
    }))
  }))

  default = {}
}

# ------------------------------------------------------------------------------
# Request-side defaults
# ------------------------------------------------------------------------------

variable "defaults" {
  description = <<-EOT
    Request-side settings applied to every package unless overridden. Defaults fail safe:
    approval is always required at gate 1 and the assignment always expires.
  EOT

  type = object({
    assignment_duration_days = optional(number, 14)
    requestor_scope_type     = optional(string, "AllExistingDirectoryMemberUsers")
    require_justification    = optional(bool, true)
    approval_timeout_days    = optional(number, 7)

    # Setting this turns reviews on for EVERY package, with no per-package opt-out. Leave it
    # unset and configure per package if you want reviews on some only. See the note above
    # var.packages.
    access_reviews = optional(object({
      review_frequency                = optional(string)
      review_type                     = optional(string)
      duration_in_days                = optional(number)
      timeout_behavior                = optional(string)
      approver_justification_required = optional(bool)
    }))

    # Removed. Declared only so that setting it fails with an explanation.
    grant_approver_group = optional(bool)
  })

  default = {}

  validation {
    condition     = var.defaults.grant_approver_group == null
    error_message = <<-EOT
      `defaults.grant_approver_group` is no longer supported. Use var.approver_packages.

      It used to attach the scope's approver group as an extra resource role on each access
      package. The approver group is now its own package, one per scope, granting only that
      group — so the decision moved from "attach it here" to "does this scope get an approver
      package", which is a different question with a different answer shape.

      Rejected rather than reinterpreted, because the old field's meaning does not survive
      the change. One approver package per scope is created by default for every scope whose
      contract entry has an approver group, so the usual fix is to delete the field. To opt a
      scope out:

        approver_packages = {
          "prod" = { enabled = false }
        }
    EOT
  }

  validation {
    condition     = var.defaults.assignment_duration_days >= 1 && var.defaults.assignment_duration_days <= 3650
    error_message = <<-EOT
      defaults.assignment_duration_days must be between 1 and 3650.

      A short duration is a control in its own right: the assignment expires and the user has to
      ask again, with nobody in the loop. Note two constraints pulling opposite ways — individual
      packages have a lower ceiling from the contract's max_assignment_days, and any package with
      an access_reviews block needs a duration LONGER than its review interval.
    EOT
  }

  validation {
    condition     = var.defaults.approval_timeout_days >= 1 && var.defaults.approval_timeout_days <= 60
    error_message = <<-EOT
      defaults.approval_timeout_days must be between 1 and 60.

      This timeout governs the access package request — gate 1 — only. PIM activation at gate
      2 has its own fixed 24-hour timeout that neither repo can change.
    EOT
  }
}

# ------------------------------------------------------------------------------
# Removed flags, kept only to fail loudly
# ------------------------------------------------------------------------------

variable "manage_pim_for_groups_roles" {
  description = <<-EOT
    REMOVED under contract v2. Declared only so that setting it fails with an explanation
    rather than "unsupported argument".
  EOT
  type        = bool
  default     = null

  validation {
    condition     = var.manage_pim_for_groups_roles == null
    error_message = <<-EOT
      `manage_pim_for_groups_roles` no longer applies and must not be set.

      It used to force pim_for_groups roles into their access package by downgrading the
      required "EligibleMember" access type to "Member" — trading just-in-time eligibility for
      standing membership, because the azuread provider cannot express EligibleMember.

      Contract v2 removes the need entirely. Repo 1 now creates a plain, non-PIM group per
      pim_for_groups role and makes it an eligible member of the PIM-managed group. The access
      package attaches plain Member to the plain group, which the provider fully supports, and
      the user still activates through PIM to reach the real access.

      So there is no longer a downgrade to opt into. Remove the flag.
    EOT
  }
}

variable "acknowledge_m3_active_membership" {
  description = <<-EOT
    REMOVED under contract v2. Declared only so that setting it fails with an explanation.
  EOT
  type        = bool
  default     = null

  validation {
    condition     = var.acknowledge_m3_active_membership == null
    error_message = <<-EOT
      `acknowledge_m3_active_membership` no longer applies and must not be set.

      It was the second of two flags acknowledging that forcing pim_for_groups roles into a
      package converted eligibility into standing active membership.

      Contract v2 removes the trade-off: eligibility now comes from a plain group that repo 1
      makes an eligible member of the PIM-managed group, so membership of the group the package
      grants is not itself privileged access. There is nothing left to acknowledge.

      Remove the flag. If you are looking for the security regression it used to guard, it no
      longer exists in this design.
    EOT
  }
}
