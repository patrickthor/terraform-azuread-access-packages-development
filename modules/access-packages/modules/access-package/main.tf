# ==============================================================================
# access-package — one requestable package, its resource roles and its policy
#
# Cloud-agnostic. The module knows only about Entra groups, never about what those
# groups grant. The same pattern is reused for AWS, GCP and GitHub groups.
#
# Resource chain:
#   access package
#     └─ resource package association  (one per group, links group → package)
#   access package
#     └─ assignment policy             (who may request, who approves, how long)
#
# The catalog association (registering a group as a catalog resource) is NOT
# created here. It is created once per (catalog, group) by the calling module and
# passed in as catalog_resource_association_id. Creating it here would produce
# duplicate associations whenever two packages in the same catalog reference the
# same group — which is exactly what the peer-approval model does with the
# approver group.
# ==============================================================================

resource "azuread_access_package" "this" {
  catalog_id   = var.catalog_id
  display_name = var.display_name
  description  = var.description
  hidden       = var.hidden
}

# One association per group the package grants. A package that grants both a role
# group and the scope's approver group therefore has two.
resource "azuread_access_package_resource_package_association" "this" {
  for_each = var.resource_roles

  access_package_id               = azuread_access_package.this.id
  catalog_resource_association_id = each.value.catalog_resource_association_id
  access_type                     = each.value.access_type
}

resource "azuread_access_package_assignment_policy" "this" {
  access_package_id = azuread_access_package.this.id
  display_name      = var.policy_display_name
  description       = var.policy_description

  # Short duration is the baseline control, with a recurring review as the optional
  # complement below rather than a replacement. The assignment
  # expires on its own and the user has to request again.
  duration_in_days = var.duration_in_days

  requestor_settings {
    scope_type        = var.requestor_scope_type
    requests_accepted = var.requests_accepted
  }

  approval_settings {
    approval_required                = length(var.approval_stages) > 0
    requestor_justification_required = var.requestor_justification_required

    # Each element is one sequential stage. Multiple stages are only achievable
    # here, on the access package — the PIM policy resources cap approval_stage
    # at max_items = 1, so sequential approval is only achievable here.
    dynamic "approval_stage" {
      for_each = var.approval_stages

      content {
        approval_timeout_in_days        = approval_stage.value.timeout_days
        approver_justification_required = approval_stage.value.approver_justification_required

        # Within a single stage, one signature from any approver is enough.
        dynamic "primary_approver" {
          for_each = approval_stage.value.approvers

          content {
            object_id    = primary_approver.value.object_id
            subject_type = primary_approver.value.subject_type
          }
        }
      }
    }
  }

  dynamic "question" {
    # This null-test ternary is safe, unlike the `x != null && <compare x>` pattern the
    # parent module's locals.tf warns about. Terraform may evaluate both branches, but
    # neither errors: `[]` and `[null]` are both valid lists. The danger is only when the
    # unevaluated branch would pass a null to something that rejects it, such as a
    # comparison operator.
    for_each = var.question_text == null ? [] : [var.question_text]

    content {
      required = true

      text {
        default_text = question.value
      }
    }
  }

  # Recurring access review. Emitted only when the caller passes one — the caller owns both the
  # master switch and the per-package layering, so a null here means "no review block", full stop.
  #
  # Short duration_in_days on the assignment remains the baseline control. A review is the
  # recurring complement to it, not a replacement: the assignment still expires on its own.
  #
  # The provider's CustomizeDiff requires duration_in_days, review_frequency and
  # access_review_timeout_behavior to all be set once the block is enabled. The type constraint on
  # var.access_review makes all three non-optional so a partial block cannot be constructed, and
  # the parent module validates the same thing earlier with a message naming the missing field.
  #
  # NO ForceNew anywhere on this resource: it implements UpdateContext and marks nothing for
  # replacement, so adding, changing or removing this block is an in-place update of the
  # assignment policy. No assignment is dropped and nobody loses access. What IS lost on removal
  # is the review campaign and its history, which is the audit trail.
  dynamic "assignment_review_settings" {
    for_each = var.access_review == null ? [] : [var.access_review]

    content {
      enabled          = true
      review_frequency = assignment_review_settings.value.review_frequency
      review_type      = assignment_review_settings.value.review_type
      duration_in_days = assignment_review_settings.value.duration_in_days

      access_review_timeout_behavior  = assignment_review_settings.value.timeout_behavior
      approver_justification_required = assignment_review_settings.value.approver_justification_required

      # starting_on is deliberately unset: Graph rejects changes to a review's start date after
      # creation, and with no ForceNew a changed value fails at apply rather than replacing
      # cleanly. Unset means "now".
      #
      # access_recommendation_enabled is deliberately unset, leaving it false. The recommendation
      # helpers are ID Governance licensed, and guest add-on enforcement from January 2026
      # specifically blocks guest-scoped reviews that use the affiliation recommendation helper.
      # Staying off keeps this inside P2.

      dynamic "reviewer" {
        for_each = assignment_review_settings.value.reviewers

        content {
          object_id    = reviewer.value.object_id
          subject_type = reviewer.value.subject_type
        }
      }
    }
  }

  depends_on = [
    azuread_access_package_resource_package_association.this
  ]
}
