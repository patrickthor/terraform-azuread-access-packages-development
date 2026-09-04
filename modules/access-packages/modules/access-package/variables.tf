variable "catalog_id" {
  description = "The catalog this package belongs to."
  type        = string
}

variable "display_name" {
  description = "Package name as shown in MyAccess."
  type        = string
}

variable "description" {
  description = "Package description as shown in MyAccess."
  type        = string
}

variable "hidden" {
  description = "Whether to hide the package from the MyAccess catalog."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# Resource roles — the groups this package grants
# ------------------------------------------------------------------------------

variable "resource_roles" {
  description = <<-EOT
    Groups this package grants, keyed by a caller-chosen label.

    catalog_resource_association_id must come from an
    azuread_access_package_resource_catalog_association created by the caller,
    once per (catalog, group). It is not created inside this module because two
    packages in the same catalog may legitimately reference the same group — the
    peer-approval model does exactly that with the approver group.

    A package with more than one entry grants more than one group membership. That
    is how the approver group is bundled alongside the role group to implement
    peer approval, and how a junior tier is expressed by leaving it out.
  EOT

  type = map(object({
    catalog_resource_association_id = string
    access_type                     = optional(string, "Member")
  }))

  validation {
    condition = alltrue([
      for role in values(var.resource_roles) :
      contains(["Member", "Owner"], role.access_type)
    ])
    error_message = <<-EOT
      access_type must be "Member" or "Owner".

      "EligibleMember" is rejected on purpose. The Entra platform supports it for
      PIM-managed groups, but the azuread provider does not — the schema for
      azuread_access_package_resource_package_association accepts only Member and
      Owner. Passing EligibleMember would not fail: Terraform would silently fall
      back to active membership, giving standing access instead of the
      just-in-time access the model promises.

      Roles that need eligible membership (jit_mechanism = "pim_for_groups") are
      excluded from Terraform by the calling module and listed in its
      excluded_resource_roles output instead.
    EOT
  }

  validation {
    condition     = length(var.resource_roles) > 0
    error_message = <<-EOT
      resource_roles cannot be empty. A package with no group attached is
      requestable but grants nothing, which is worse than not existing — it looks
      like working access in MyAccess and silently grants none.

      The most likely cause when called from the access-packages module: every role
      in this scope required "EligibleMember" and was excluded under blocker 2.1,
      and grant_approver_group is false so no approver group was attached either.
      The parent module has a precondition with the available remedies; if you are
      seeing this message instead of that one, the scope has no grantable groups at
      all.
    EOT
  }
}

# ------------------------------------------------------------------------------
# Assignment policy
# ------------------------------------------------------------------------------

variable "policy_display_name" {
  description = "Display name of the assignment policy."
  type        = string
}

variable "policy_description" {
  description = "Description of the assignment policy."
  type        = string
}

variable "duration_in_days" {
  description = <<-EOT
    How long an assignment lasts before it expires automatically. Short durations
    are this POC's substitute for access reviews.
  EOT
  type        = number
  default     = 14

  validation {
    condition     = var.duration_in_days >= 1 && var.duration_in_days <= 3650
    error_message = "duration_in_days must be between 1 and 3650."
  }
}

variable "requestor_scope_type" {
  description = "Who may request the package. See azuread_access_package_assignment_policy."
  type        = string
  default     = "AllExistingDirectoryMemberUsers"

  validation {
    condition = contains([
      "AllExistingConnectedOrganizationSubjects",
      "AllExistingDirectoryMemberUsers",
      "AllExistingDirectorySubjects",
      "AllExternalSubjects",
      "NoSubjects",
      "SpecificConnectedOrganizationSubjects",
      "SpecificDirectorySubjects",
    ], var.requestor_scope_type)
    error_message = <<-EOT
      requestor_scope_type must be one of the values accepted by
      azuread_access_package_assignment_policy. "NoSubjects" makes the package
      unrequestable, which is only useful for direct-assignment-only packages such
      as seeding an approver group.
    EOT
  }
}

variable "requests_accepted" {
  description = "Whether the policy currently accepts new requests."
  type        = bool
  default     = true
}

variable "requestor_justification_required" {
  description = "Whether the requestor must supply a justification."
  type        = bool
  default     = true
}

variable "question_text" {
  description = <<-EOT
    Optional free-text question shown to the requestor. Set to null to omit the
    question block entirely.
  EOT
  type        = string
  default     = null
}

variable "approval_stages" {
  description = <<-EOT
    Sequential approval stages. An empty list disables approval entirely.

    Within one stage, a signature from any single approver is enough. Across
    stages, every stage must be passed in order — so genuine two-step approval
    means two elements here. This is the only place in the system where sequential
    approval is achievable; the PIM policy resources cap approval_stage at one.
  EOT

  type = list(object({
    timeout_days                    = optional(number, 7)
    approver_justification_required = optional(bool, true)
    approvers = list(object({
      object_id    = string
      subject_type = string
    }))
  }))

  default = []

  validation {
    condition     = length(var.approval_stages) <= 2
    error_message = <<-EOT
      Entra supports at most 2 approval stages for an access package assignment
      policy. Model broader coverage as more approvers within one stage rather
      than as more stages.
    EOT
  }

  validation {
    condition = alltrue([
      for stage in var.approval_stages : length(stage.approvers) > 0
    ])
    error_message = <<-EOT
      Every approval stage must contain at least one approver. A stage with no
      approvers cannot be satisfied, so the request would sit until it times out
      and the access would never be granted.
    EOT
  }

  validation {
    condition = alltrue([
      for stage in var.approval_stages : alltrue([
        for approver in stage.approvers : contains([
          "singleUser",
          "groupMembers",
          "connectedOrganizationMembers",
          "requestorManager",
          "internalSponsors",
          "externalSponsors",
        ], approver.subject_type)
      ])
    ])
    error_message = <<-EOT
      subject_type must be one of: singleUser, groupMembers,
      connectedOrganizationMembers, requestorManager, internalSponsors,
      externalSponsors.
    EOT
  }

  validation {
    condition = alltrue([
      for stage in var.approval_stages :
      stage.timeout_days >= 1 && stage.timeout_days <= 60
    ])
    error_message = <<-EOT
      timeout_days must be between 1 and 60. Note that this timeout applies to the
      access package request only. PIM activation requests have a separate,
      non-configurable 24-hour timeout.
    EOT
  }
}
