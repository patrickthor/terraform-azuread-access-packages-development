variable "tenant_id" {
  description = "Entra tenant ID."
  type        = string
}

variable "enable_access_packages" {
  description = <<-EOT
    Whether to build the request layer at all.

    Drives `count` on the access-packages module, which is only legal because that module
    declares no provider blocks. Useful for staging a rollout: vend groups, RBAC and PIM
    policies first, then add the request layer once the Entitlement Management licensing
    question is settled — eligible group membership in access packages needs Entra ID
    Governance or Entra Suite, not P2 alone.
  EOT
  type        = bool
  default     = true
}

variable "default_catalog" {
  description = <<-EOT
    Catalog label applied to scopes that do not name one. Passed to repo 1, which validates
    the string and passes it through in the contract — it creates no catalog itself.
  EOT
  type        = string
  default     = "platform"
}

variable "catalogs" {
  description = "Per-catalog settings for repo 2, keyed on the label repo 1 emitted."
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

    access_reviews = optional(object({
      review_frequency                = optional(string)
      review_type                     = optional(string)
      duration_in_days                = optional(number)
      timeout_behavior                = optional(string)
      approver_justification_required = optional(bool)
    }))

    # No default: passed through only so the module can reject it by name if a caller still
    # sets it. A default here would trip that rejection on every apply.
    grant_approver_group = optional(bool)
  })
  default = {}
}

variable "enable_access_reviews" {
  description = <<-EOT
    MASTER SWITCH for recurring access reviews. Off by default.

    Separate from the review settings on purpose, so a pipeline can drive it from one checkbox and
    the configuration can be merged before it goes live. `access_reviews_configured_not_deployed`
    reports the in-between state.
  EOT
  type        = bool
  default     = false
}

variable "packages" {
  description = "Named access packages, keyed on package name. Empty means one package per scope."
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

    access_reviews = optional(object({
      review_frequency                = optional(string)
      review_type                     = optional(string)
      duration_in_days                = optional(number)
      timeout_behavior                = optional(string)
      approver_justification_required = optional(bool)
    }))

    grant_approver_group = optional(bool)
  }))
  default = {}
}

variable "approver_packages" {
  description = "Peer-approval packages, keyed on scope. One is created per scope with an approver group by default."
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

variable "package_overrides" {
  description = "Per-package deviations from `defaults`, keyed on package name."
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

# In the real thing this is repo 1's input variable and the single place a customer
# describes their access taxonomy. Declared here so the commented-out module call is
# copy-pasteable, and typed loosely because repo 1 owns its schema.
variable "access_scopes" {
  description = <<-EOT
    Repo 1's access taxonomy — the one place a customer describes what access exists.

    Unused while repo 1's module call is commented out. Typed as `any` because repo 1 owns
    this schema and duplicating it here would be a second copy to keep in sync, which is
    the exact duplication the contract exists to avoid.
  EOT
  type        = any
  default     = {}
}
