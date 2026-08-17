variable "catalog_id" {
  description = "Katalogen pakken skal ligge i."
  type        = string
}

variable "group_object_id" {
  description = <<-EOT
    Entra-gruppen som pakken gir tilgang til. Gruppen er primitivet — hvilken sky
    den er koblet til er utenfor denne modulens kunnskap.
  EOT
  type        = string
}

variable "display_name" {
  description = "Visningsnavn på access package-en."
  type        = string
}

variable "description" {
  description = "Beskrivelse av access package-en."
  type        = string
}

variable "hidden" {
  description = "Om pakken skal skjules fra MyAccess-katalogen."
  type        = bool
  default     = false
}

variable "access_type" {
  description = <<-EOT
    Rollen brukeren får på gruppen: "Member" (aktivt medlemskap, fungerer på P2)
    eller "EligibleMember" (eligible medlemskap, krever Entra ID
    Governance-lisens).
  EOT
  type        = string
  default     = "Member"
}

# ------------------------------------------------------------------------------
# Tildelingspolicy
# ------------------------------------------------------------------------------

variable "policy_display_name" {
  description = "Visningsnavn på tildelingspolicyen."
  type        = string
}

variable "policy_description" {
  description = "Beskrivelse av tildelingspolicyen."
  type        = string
}

variable "duration_in_days" {
  description = <<-EOT
    Hvor lenge tildelingen varer før den utløper automatisk. Kort varighet er
    POC-ens substitutt for access reviews.
  EOT
  type        = number
  default     = 14
}

variable "requestor_scope_type" {
  description = "Hvem som kan be om tilgang."
  type        = string
  default     = "AllExistingDirectoryMemberUsers"
}

variable "requests_accepted" {
  description = "Om policyen tar imot nye forespørsler."
  type        = bool
  default     = true
}

variable "requestor_justification_required" {
  description = "Om den som ber om tilgang må oppgi begrunnelse."
  type        = bool
  default     = true
}

variable "approval_timeout_in_days" {
  description = "Hvor lenge en forespørsel venter på godkjenning før den forfaller."
  type        = number
  default     = 14
}

variable "approval_stages" {
  description = <<-EOT
    Godkjenningssteg i rekkefølge. Tom liste betyr ingen godkjenning.
    Entra støtter opptil 2 steg for access packages. Innenfor ett steg er det nok
    at én godkjenner signerer; med to steg må begge stegene passeres.

    `subject_type` er f.eks. "singleUser", "groupMembers" eller
    "requestorManager".
  EOT
  type = list(object({
    approvers = list(object({
      object_id    = string
      subject_type = string
    }))
  }))
  default = []

  validation {
    condition     = length(var.approval_stages) <= 2
    error_message = "Entra støtter maks 2 godkjenningssteg for access packages."
  }

  validation {
    condition = alltrue([
      for stage in var.approval_stages : length(stage.approvers) > 0
    ])
    error_message = "Hvert godkjenningssteg må ha minst én godkjenner."
  }
}
