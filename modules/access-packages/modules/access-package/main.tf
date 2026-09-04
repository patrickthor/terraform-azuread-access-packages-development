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

  # Short duration is this POC's substitute for access reviews. The assignment
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
    for_each = var.question_text == null ? [] : [var.question_text]

    content {
      required = true

      text {
        default_text = question.value
      }
    }
  }

  # assignment_review_settings is deliberately not set. Access reviews are out of
  # scope for this POC (no Governance add-on assumed) and a short
  # duration_in_days is the deliberate substitute. See section 5.4.

  depends_on = [
    azuread_access_package_resource_package_association.this
  ]
}
