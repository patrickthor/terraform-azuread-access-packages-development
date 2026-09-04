variable "tenant_id" {
  description = "Entra tenant ID."
  type        = string
}

variable "catalog_display_name" {
  description = "Display name of the catalog."
  type        = string
  default     = "Cloud Access"
}

variable "state_resource_group_name" {
  description = "Resource group holding the storage account with repo 1's state."
  type        = string
}

variable "state_storage_account_name" {
  description = "Storage account holding repo 1's state. Needs Storage Blob Data Reader for this identity."
  type        = string
}

variable "state_container_name" {
  description = "Blob container holding the state files."
  type        = string
  default     = "tfstate"
}

variable "vending_state_key" {
  description = "State key for repo 1 (access-vending). Read, never written."
  type        = string
  default     = "access-vending.tfstate"
}

variable "assignment_duration_days" {
  description = "Default assignment duration. Keep at or below 30 for scopes containing pim_for_groups roles."
  type        = number
  default     = 14
}

variable "scope_overrides" {
  description = "Per-scope deviations from the defaults, keyed on scope key."
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
