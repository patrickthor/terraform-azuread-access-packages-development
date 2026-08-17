# ==============================================================================
# group-access-package — én access package som gir tilgang til én Entra-gruppe
#
# Sky-agnostisk. Modulen kjenner bare gruppen, ikke hva gruppen gir tilgang til.
# Samme mønster brukes senere for AWS-, GCP- og GitHub-grupper.
#
# Kjeden av ressurser:
#   access package
#     └─ resource catalog association  (gruppen registreres som ressurs i katalogen)
#          └─ resource package association  (gruppen kobles til pakken med en rolle)
#   access package
#     └─ assignment policy  (hvem kan be om tilgang, hvem godkjenner, hvor lenge)
# ==============================================================================

resource "azuread_access_package" "this" {
  catalog_id   = var.catalog_id
  display_name = var.display_name
  description  = var.description
  hidden       = var.hidden
}

# Registrerer gruppen som en ressurs i katalogen. Må skje før gruppen kan kobles
# til en pakke. Er idempotent per (katalog, gruppe).
resource "azuread_access_package_resource_catalog_association" "this" {
  catalog_id             = var.catalog_id
  resource_origin_id     = var.group_object_id
  resource_origin_system = "AadGroup"
}

# Kobler gruppen til pakken med en gitt rolle. access_type avgjør om brukeren blir
# aktivt eller eligible medlem.
resource "azuread_access_package_resource_package_association" "this" {
  access_package_id               = azuread_access_package.this.id
  catalog_resource_association_id = azuread_access_package_resource_catalog_association.this.id
  access_type                     = var.access_type
}

resource "azuread_access_package_assignment_policy" "this" {
  access_package_id = azuread_access_package.this.id
  display_name      = var.policy_display_name
  description       = var.policy_description

  # Kort varighet er POC-ens substitutt for access reviews. Tildelingen utløper
  # automatisk, og brukeren må be på nytt.
  duration_in_days = var.duration_in_days

  requestor_settings {
    scope_type        = var.requestor_scope_type
    requests_accepted = var.requests_accepted
  }

  approval_settings {
    approval_required                = length(var.approval_stages) > 0
    requestor_justification_required = var.requestor_justification_required

    # Ett eller to steg. Med to steg må begge passeres — det er her "dual"
    # approval faktisk realiseres, siden PIM for Groups bare har ett steg.
    dynamic "approval_stage" {
      for_each = var.approval_stages

      content {
        approval_timeout_in_days = var.approval_timeout_in_days

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

  # assignment_review_settings settes bevisst ikke: access reviews er utenfor
  # POC-scope (ingen Governance-tillegg). Kort duration_in_days erstatter dem.

  depends_on = [
    azuread_access_package_resource_package_association.this
  ]
}
