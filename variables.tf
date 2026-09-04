# ==============================================================================
# Root inputs
#
# Note what is absent: no scope list, no role list, no group name, no catalog label.
# All of it comes from repo 1's contract. Adding a scope, a role or a catalog in repo 1
# needs no change here.
#
# The field reference for `catalogs`, `defaults` and `scope_overrides` lives in
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

variable "manage_pim_for_groups_roles" {
  description = <<-EOT
    Attach roles whose contract access_type is "EligibleMember" anyway, downgraded to
    "Member". Default false. Setting this true converts just-in-time eligibility into
    standing active membership and also requires acknowledge_m3_active_membership = true.
  EOT
  type        = bool
  default     = false
}

variable "acknowledge_m3_active_membership" {
  description = "Explicit acknowledgement of the security regression that manage_pim_for_groups_roles causes."
  type        = bool
  default     = false
}
