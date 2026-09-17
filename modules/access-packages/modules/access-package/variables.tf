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

      azuread_access_package_resource_package_association validates this field
      client-side to those two values. "EligibleMember" exists in the Entra platform
      for PIM-managed groups but not in the provider's schema, and passing it would
      not fail cleanly: Terraform would fall back to active membership, giving
      standing access instead of the just-in-time access the model promises.

      Under the current design nothing should ever ask for it. Just-in-time access
      comes from attaching plain Member on a plain group that the vending module has
      made an eligible member of the PIM-managed group — so the access package needs
      no eligible access type at all, and the user still activates through PIM.

      Seeing this means the caller passed an access type from an older contract
      shape.
    EOT
  }

  validation {
    condition     = length(var.resource_roles) > 0
    error_message = <<-EOT
      resource_roles cannot be empty. A package with no group attached is
      requestable but grants nothing, which is worse than not existing — it looks
      like working access in MyAccess and silently grants none.

      The parent access-packages module has a precondition covering this with the
      available remedies, so seeing this message instead means the leaf was called
      directly with an empty map.
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
    How long an assignment lasts before it expires automatically. A short duration is a control
    in its own right: access lapses with nobody in the loop.

    When var.access_review is also set, this must be LONGER than the review interval, or the
    assignment expires before the first campaign opens and the review has an empty subject list.
    The calling module enforces that.
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

variable "access_review" {
  description = <<-EOT
    Recurring access review on this package's assignment policy. Null means no review block is
    emitted at all.

    The caller resolves and layers this; the leaf just writes it. `reviewers` must be non-empty
    when review_type is "Reviewers" — a review with no reviewer cannot be answered and falls
    through to the timeout behaviour, which looks like governance while enforcing nothing.

    NOT exposed: `starting_on`, because Graph rejects changes to a review's start date after
    creation and this resource declares ForceNew on nothing, so a changed value fails at apply
    rather than replacing cleanly. It defaults to now.

    NOT exposed: `access_recommendation_enabled`. The recommendation helpers are the
    ID-Governance-licensed area, and this system targets P2.

    REMOVING this block is an in-place update — the resource implements UpdateContext and marks
    nothing ForceNew, so no assignment is dropped and nobody loses access. What IS lost is the
    review campaign and its history, which is the audit trail.
  EOT

  type = object({
    review_frequency                = string
    review_type                     = string
    duration_in_days                = number
    timeout_behavior                = string
    approver_justification_required = optional(bool, true)

    reviewers = optional(list(object({
      object_id    = string
      subject_type = string
    })), [])
  })

  default = null

  # NOTE ON SHAPE. Each condition below iterates a list that is empty when the variable is null,
  # so the attribute access happens inside the `for` body and only runs when there is an object to
  # read. `var.access_review == null ? true : var.access_review.<attr>` would be the obvious
  # spelling and is NOT safe: Terraform may evaluate both branches of a conditional, and this
  # project has already had two bugs of exactly that shape reach a consumer's plan.
  #
  # The `null ? [] : [obj]` ternary itself is fine, because neither branch can error — building a
  # one-element list around a null is legal, it is only reading an attribute off it that is not.

  validation {
    condition = alltrue([
      for r in(var.access_review == null ? [] : [var.access_review]) :
      contains(["weekly", "monthly", "quarterly", "halfyearly", "annual"], r.review_frequency)
    ])
    error_message = "access_review.review_frequency must be one of: weekly, monthly, quarterly, halfyearly, annual."
  }

  validation {
    condition = alltrue([
      for r in(var.access_review == null ? [] : [var.access_review]) :
      contains(["Reviewers", "Self"], r.review_type)
    ])
    error_message = <<-EOT
      access_review.review_type must be "Reviewers" or "Self".

      "Manager" is rejected. It reviews against the requestor's manager attribute, which B2B
      guest users almost never have populated — with no manager there is no reviewer, and the
      campaign falls silently through to the timeout behaviour.
    EOT
  }

  validation {
    condition = alltrue([
      for r in(var.access_review == null ? [] : [var.access_review]) :
      contains(["keepAccess", "removeAccess"], r.timeout_behavior)
    ])
    error_message = <<-EOT
      access_review.timeout_behavior must be "keepAccess" or "removeAccess".

      "acceptAccessRecommendation" is rejected because it depends on the access recommendation
      helper, which this module does not enable — recommendations are ID Governance licensed and
      this system targets P2. Selecting it while recommendations are off leaves the timeout
      behaviour undefined.
    EOT
  }

  validation {
    condition = alltrue([
      for r in(var.access_review == null ? [] : [var.access_review]) :
      r.duration_in_days >= 1 && r.duration_in_days <= 365
    ])
    error_message = "access_review.duration_in_days must be between 1 and 365. It is how long each review campaign stays open, not how often it recurs."
  }

  validation {
    # Only the "Reviewers" case needs a reviewer list, so filter to those in the `for` clause
    # rather than testing the type alongside the length.
    condition = alltrue([
      for r in(var.access_review == null ? [] : [var.access_review]) :
      length(r.reviewers) > 0
      if r.review_type == "Reviewers"
    ])
    error_message = <<-EOT
      access_review.reviewers cannot be empty when review_type is "Reviewers".

      A review with no reviewer cannot be answered by anyone, so every campaign runs to its
      timeout and the configured timeout_behavior silently becomes the only outcome. That is a
      config that looks like governance and enforces nothing.
    EOT
  }
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
