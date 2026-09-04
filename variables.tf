# ==============================================================================
# Root inputs
#
# Note what is absent: there is no scope list and no role list. Those come from
# repo 1's state. Adding a scope or a role in repo 1 needs no change here at all.
#
# The field reference for `defaults` and `scope_overrides` lives in
# modules/access-packages/README.md. It is deliberately not duplicated into tfvars
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
# ------------------------------------------------------------------------------

variable "state_resource_group_name" {
  description = "Resource group holding the storage account with repo 1's state."
  type        = string
}

variable "state_storage_account_name" {
  description = "Storage account holding repo 1's state. The deploy identity needs Storage Blob Data Reader on it."
  type        = string
}

variable "state_container_name" {
  description = "Blob container holding the state files."
  type        = string
  default     = "tfstate"
}

variable "vending_state_key" {
  description = <<-EOT
    State key for repo 1 (access-vending). This is repo 1's key, not repo 2's — repo
    2 reads it. Repo 2 writes its own state to a separate key, configured in
    backend.hcl.
  EOT
  type        = string
  default     = "access-vending.tfstate"
}

variable "state_use_azuread_auth" {
  description = <<-EOT
    Authenticate to the state storage account with Entra identity rather than a
    storage account key. Leave true: an account key would be a second, longer-lived
    credential to manage, and RBAC on the container is auditable.
  EOT
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# Catalog
# ------------------------------------------------------------------------------

variable "catalog_display_name" {
  description = "Display name of the catalog holding every access package."
  type        = string
  default     = "Cloud Access"
}

variable "catalog_description" {
  description = "Description of the catalog."
  type        = string
  default     = "Access packages for Terraform-vended cloud access. Managed by repo 2 (access-packages)."
}

# ------------------------------------------------------------------------------
# Request-side settings — see modules/access-packages/README.md
# ------------------------------------------------------------------------------

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

# ------------------------------------------------------------------------------
# Blocker 2.1
# ------------------------------------------------------------------------------

variable "manage_pim_for_groups_roles" {
  description = <<-EOT
    Attach roles whose required access type is "EligibleMember" anyway, downgraded to
    "Member". Default false. Setting this true converts just-in-time eligibility into
    standing active membership and also requires
    acknowledge_m3_active_membership = true.
  EOT
  type        = bool
  default     = false
}

variable "acknowledge_m3_active_membership" {
  description = "Explicit acknowledgement of the security regression that manage_pim_for_groups_roles causes."
  type        = bool
  default     = false
}

variable "m3_max_duration_days" {
  description = "Ceiling on assignment duration for packages containing pim_for_groups roles. Trap 6.1."
  type        = number
  default     = 30
}
