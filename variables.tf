variable "tenant_id" {
  description = "Entra tenant ID for POC-tenanten."
  type        = string
}

# ------------------------------------------------------------------------------
# Katalog
# ------------------------------------------------------------------------------

variable "catalog_display_name" {
  description = "Visningsnavn på katalogen som rommer pakkene."
  type        = string
  default     = "Azure Subscriptions"
}

variable "catalog_description" {
  description = "Beskrivelse av katalogen."
  type        = string
  default     = "Access packages for tilgang til Azure-subscriptions. Forvaltet av Terraform."
}

variable "catalog_externally_visible" {
  description = "Om katalogen skal være synlig for eksterne brukere."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# Kontrakten mot vending-repoet
# ------------------------------------------------------------------------------

variable "cloud_prefix" {
  description = <<-EOT
    Prefiks på gruppenavn. MÅ være identisk med cloud_prefix i
    terraform-azuread-access-vending, ellers finner ikke oppslaget gruppene.
  EOT
  type        = string
  default     = "azure"

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.cloud_prefix))
    error_message = "cloud_prefix må være små bokstaver og tall, uten bindestrek."
  }
}

variable "group_lookup_delay" {
  description = <<-EOT
    Ventetid før gruppene slås opp, for å la vending-repoets grupper propagere i
    Graph. Sett høyere hvis dette repoet kjøres rett etter vending i CI.
  EOT
  type        = string
  default     = "30s"
}

# ------------------------------------------------------------------------------
# Subscriptions — samme struktur som i vending-repoet
# ------------------------------------------------------------------------------

variable "subscriptions" {
  description = <<-EOT
    Subscriptions og roller. Skal ha IDENTISK struktur som i
    terraform-azuread-access-vending. Feltene subscription_id og azure_role
    brukes bare til beskrivelser her — dette repoet oppretter ingen
    Azure-ressurser.
  EOT

  type = map(object({
    subscription_id = string
    systemeier      = string

    roles = map(object({
      azure_role  = string
      pim_enabled = optional(bool, false)

      approval_type       = optional(string, "owner")
      approver_group_name = optional(string)

      # Felter vending-repoet bruker, men som ignoreres her. Tatt med slik at
      # samme tfvars-fil kan kopieres uendret mellom repoene.
      max_activation_hours          = optional(number)
      require_mfa                   = optional(bool)
      require_justification         = optional(bool)
      eligible_user_principal_names = optional(list(string))
      assignable_to_role            = optional(bool)

      # Overstyringer som bare gjelder access package-en.
      assignment_duration_days = optional(number)
      access_type              = optional(string)
      requestor_scope_type     = optional(string)
      hidden                   = optional(bool, false)
    }))
  }))

  default = {}

  validation {
    condition = alltrue([
      for sub_key in keys(var.subscriptions) : !can(regex("--", sub_key))
    ])
    error_message = "Subscription-keys kan ikke inneholde '--' (reservert som composite-separator)."
  }

  validation {
    condition = alltrue(flatten([
      for sub in values(var.subscriptions) : [
        for role_key in keys(sub.roles) : !can(regex("--", role_key))
      ]
    ]))
    error_message = "Rolle-keys kan ikke inneholde '--' (reservert som composite-separator)."
  }

  validation {
    condition = alltrue(flatten([
      for sub in values(var.subscriptions) : [
        for role in values(sub.roles) :
        contains(["self", "team", "owner", "dual"], role.approval_type)
      ]
    ]))
    error_message = "approval_type må være en av: self, team, owner, dual."
  }

  validation {
    condition = alltrue(flatten([
      for sub in values(var.subscriptions) : [
        for role in values(sub.roles) :
        contains(["team", "dual"], role.approval_type) ? role.approver_group_name != null : true
      ]
    ]))
    error_message = "approver_group_name må settes når approval_type er 'team' eller 'dual'."
  }
}

# ------------------------------------------------------------------------------
# Defaults for tildelingspolicy
# ------------------------------------------------------------------------------

variable "default_assignment_duration_days" {
  description = <<-EOT
    Hvor lenge en tildeling varer før den utløper. Kort expiry er POC-ens
    substitutt for access reviews — 7-14 dager per oppgaven. Kan overstyres per
    rolle med assignment_duration_days.
  EOT
  type        = number
  default     = 14

  validation {
    condition     = var.default_assignment_duration_days >= 1 && var.default_assignment_duration_days <= 3650
    error_message = "default_assignment_duration_days må være mellom 1 og 3650."
  }
}

variable "default_access_type" {
  description = <<-EOT
    Hvilken rolle brukeren får på gruppen når tildelingen innvilges.

    "Member" gir aktivt medlemskap og fungerer på ren P2.
    "EligibleMember" gir eligible-medlemskap som brukeren så PIM-aktiverer, men
    krever Entra ID Governance-lisens og er derfor utenfor POC-rammen.

    Se beslutning B2 i PROSJEKT-SAMMENDRAG.md.
  EOT
  type        = string
  default     = "Member"
}

variable "default_requestor_scope_type" {
  description = "Hvem som kan be om tilgang. Se azuread_access_package_assignment_policy."
  type        = string
  default     = "AllExistingDirectoryMemberUsers"
}

variable "approval_timeout_in_days" {
  description = "Hvor lenge en forespørsel venter på godkjenning før den forfaller."
  type        = number
  default     = 14
}

variable "require_requestor_justification" {
  description = "Om den som ber om tilgang må oppgi begrunnelse. Oppgaven krever dette."
  type        = bool
  default     = true
}

variable "package_display_name_template" {
  description = "Mal for pakkenavn. Plassholdere: {sub}, {role}, {azure_role}."
  type        = string
  default     = "Azure {sub} - {role}"
}

variable "package_description_template" {
  description = "Mal for pakkebeskrivelse. Plassholdere: {sub}, {role}, {azure_role}, {subscription_id}."
  type        = string
  default     = "Gir {azure_role}-tilgang til Azure-subscription {sub} via gruppen. Tildelingen utløper automatisk."
}
