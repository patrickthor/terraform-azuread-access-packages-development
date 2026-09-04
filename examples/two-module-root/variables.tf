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
  description = "Request-side settings applied to every package unless overridden per scope."
  type = object({
    assignment_duration_days = optional(number, 14)
    requestor_scope_type     = optional(string, "AllExistingDirectoryMemberUsers")
    require_justification    = optional(bool, true)
    approval_timeout_days    = optional(number, 7)
    grant_approver_group     = optional(bool, true)
  })
  default = {}
}

variable "scope_overrides" {
  description = "Per-scope deviations from `defaults`, keyed on scope key."
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
