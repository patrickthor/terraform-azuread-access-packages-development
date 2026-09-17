# ==============================================================================
# Root inputs
#
# Note what is absent: no scope list, no role list, no group name, no catalog label.
# All of it comes from repo 1's contract. Adding a scope, a role or a catalog in repo 1
# needs no change here.
#
# The field reference for `packages`, `catalogs`, `defaults` and `package_overrides` lives in
# modules/access-packages/README.md and is deliberately not duplicated into tfvars
# comments — copied reference tables end up in user files and never get updated.
# ==============================================================================

variable "tenant_id" {
  description = "Entra tenant ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

# ------------------------------------------------------------------------------
# Where repo 1's state lives
#
# Only needed by this split-state root. A customer using the reference architecture
# calls both modules from one root and needs none of these.
# ------------------------------------------------------------------------------

variable "state_resource_group_name" {
  description = "Resource group holding the storage account with repo 1's state."
  type        = string
}

variable "state_storage_account_name" {
  description = "Storage account holding repo 1's state. This identity needs at least Storage Blob Data Reader on it."
  type        = string
}

variable "state_container_name" {
  description = "Blob container holding the state files."
  type        = string
  default     = "tfstate"
}

variable "vending_state_key" {
  description = <<-EOT
    State key for repo 1 (access-vending). This is repo 1's key, which this root reads.
    Repo 2 writes its own state to a different key, configured in backend.hcl — pointing
    the backend at this key would destroy the contract this root depends on.
  EOT
  type        = string
  default     = "access-vending.tfstate"
}

variable "state_use_azuread_auth" {
  description = <<-EOT
    Authenticate to the state storage account with an Entra identity rather than a storage
    account key. Leave true: an account key is a second long-lived credential to manage,
    and container RBAC is auditable.
  EOT
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# Passthrough to the module
# ------------------------------------------------------------------------------

variable "catalogs" {
  description = <<-EOT
    Per-catalog settings, keyed on the catalog LABEL from repo 1's contract. Every key is
    optional; a label with no entry gets the defaults, so the simple case needs nothing
    here.
  EOT
  type = map(object({
    display_name            = optional(string)
    description             = optional(string)
    externally_visible      = optional(bool, false)
    published               = optional(bool, true)
    adopt_existing          = optional(bool, false)
    delegate_to_systemeier  = optional(bool, false)
    systemeier_catalog_role = optional(string, "Access package manager")
  }))
  default = {}
}

variable "defaults" {
  description = "Request-side settings applied to every package unless overridden per package."
  type = object({
    assignment_duration_days = optional(number, 14)
    requestor_scope_type     = optional(string, "AllExistingDirectoryMemberUsers")
    require_justification    = optional(bool, true)
    approval_timeout_days    = optional(number, 7)

    # Setting this turns reviews on for EVERY package, with no per-package opt-out. Leave unset
    # and configure per package if you want reviews on some only.
    access_reviews = optional(object({
      review_frequency                = optional(string)
      review_type                     = optional(string)
      duration_in_days                = optional(number)
      timeout_behavior                = optional(string)
      approver_justification_required = optional(bool)
    }))

    # Declared with NO default, and passed through, so that a caller who still sets it gets
    # the module's explanation of what replaced it rather than a bare "unsupported argument".
    # A default here would trip that rejection on every apply.
    grant_approver_group = optional(bool)
  })
  default = {}
}

variable "packages" {
  description = <<-EOT
    Named access packages, keyed on package name. Leave empty for the default: one package
    per scope containing every role in that scope.

    Set it when one scope needs more than one audience — "engineers get reader and
    contributor, admins also get owner" over the same groups. Field reference in
    modules/access-packages/README.md.
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

    # Presence means this package gets a recurring review. No `enabled` field by design.
    access_reviews = optional(object({
      review_frequency                = optional(string)
      review_type                     = optional(string)
      duration_in_days                = optional(number)
      timeout_behavior                = optional(string)
      approver_justification_required = optional(bool)
    }))

    # Passed through only so the module can reject it by name. See var.approver_packages.
    grant_approver_group = optional(bool)
  }))
  default = {}
}

variable "package_overrides" {
  description = "Per-package deviations from `defaults`, keyed on package name. When `packages` is empty, package names are scope names."
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

variable "approver_packages" {
  description = <<-EOT
    Peer-approval rights as their own access package, keyed on SCOPE key.

    One is created by default for every scope whose contract entry has an approver group, so
    this is only needed to deviate — or to opt a scope out with `enabled = false`.

    The approver group is no longer a resource role on the access package. Holding the access
    and holding approval rights are separate grants with separate expiries. Field reference in
    modules/access-packages/README.md.
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

variable "enable_access_reviews" {
  description = <<-EOT
    MASTER SWITCH for recurring access reviews. When false, no review block is written to any
    assignment policy regardless of what `access_reviews` configuration exists.

    Intended to be driven from a pipeline checkbox, so the configuration can be written, reviewed
    and merged before it goes live. Configuration is still resolved and reported when this is
    false — see the `access_reviews` and `access_reviews_configured_not_deployed` outputs.
  EOT
  type        = bool
  default     = false
}
