# ==============================================================================
# Rot-modul — POC access packages
#
# Slår opp gruppene vending-repoet har opprettet, og lager én access package per
# (subscription, rolle) med systemeier som godkjenner.
#
# FORUTSETNING: terraform-azuread-access-vending må ha kjørt først. Gruppene
# slås opp på navn og må finnes.
# ==============================================================================

# ------------------------------------------------------------------------------
# Gruppeoppslag — kontrakten mot vending-repoet
# ------------------------------------------------------------------------------

# Nyopprettede grupper er ikke umiddelbart søkbare i Graph. Denne sover kun ved
# første opprettelse, så kostnaden er engangs.
resource "time_sleep" "group_propagation" {
  create_duration = var.group_lookup_delay
}

# Oppslag på display_name, som oppgaven spesifiserer. Vending-repoet setter både
# display_name og mail_nickname til samme streng, og har
# prevent_duplicate_names = true, så oppslaget er entydig.
#
# depends_on gjør at Terraform utsetter lesingen til apply-tid.
data "azuread_group" "role_groups" {
  for_each = local.role_instances

  display_name = each.value.group_name

  depends_on = [time_sleep.group_propagation]
}

# ------------------------------------------------------------------------------
# Godkjennere
# ------------------------------------------------------------------------------

data "azuread_user" "systemeier" {
  for_each            = local.systemeier_upns
  user_principal_name = each.value
}

data "azuread_group" "approvers" {
  for_each     = local.approver_group_names
  display_name = each.value
}

locals {
  # Godkjenningssteg per rolle-instans.
  #
  # Her realiseres "dual" som to reelle steg — noe PIM for Groups ikke støtter.
  # Se beslutning B3 i PROSJEKT-SAMMENDRAG.md.
  #
  #   self  → ingen godkjenning
  #   team  → 1 steg: team-gruppa
  #   owner → 1 steg: systemeier
  #   dual  → 2 steg: team-gruppa, deretter systemeier
  approval_stages_by_instance = {
    for key, inst in local.role_instances : key => (
      inst.approval_type == "self" ? [] :
      inst.approval_type == "team" ? [
        {
          approvers = [{
            object_id    = data.azuread_group.approvers[inst.approver_group_name].object_id
            subject_type = "groupMembers"
          }]
        }
      ] :
      inst.approval_type == "owner" ? [
        {
          approvers = [{
            object_id    = data.azuread_user.systemeier[inst.systemeier].object_id
            subject_type = "singleUser"
          }]
        }
      ] :
      # dual
      [
        {
          approvers = [{
            object_id    = data.azuread_group.approvers[inst.approver_group_name].object_id
            subject_type = "groupMembers"
          }]
        },
        {
          approvers = [{
            object_id    = data.azuread_user.systemeier[inst.systemeier].object_id
            subject_type = "singleUser"
          }]
        },
      ]
    )
  }
}

# ------------------------------------------------------------------------------
# Katalog
# ------------------------------------------------------------------------------

module "catalog" {
  source = "./modules/access-package-catalog"

  display_name       = var.catalog_display_name
  description        = var.catalog_description
  externally_visible = var.catalog_externally_visible
}

# ------------------------------------------------------------------------------
# Én access package per (subscription, rolle)
# ------------------------------------------------------------------------------

module "access_package" {
  source   = "./modules/group-access-package"
  for_each = local.role_instances

  catalog_id      = module.catalog.catalog_id
  group_object_id = data.azuread_group.role_groups[each.key].object_id

  display_name = each.value.display_name
  description  = each.value.description
  hidden       = each.value.hidden
  access_type  = each.value.access_type

  policy_display_name = "${each.value.display_name} - standard"
  policy_description = join(" ", [
    "Forespørsel om ${each.value.azure_role}-tilgang til ${each.value.subscription_key}.",
    length(local.approval_stages_by_instance[each.key]) > 0
    ? "Godkjenning i ${length(local.approval_stages_by_instance[each.key])} steg."
    : "Ingen godkjenning påkrevd.",
    "Tildelingen utløper etter ${each.value.assignment_duration_days} dager.",
  ])

  duration_in_days     = each.value.assignment_duration_days
  requestor_scope_type = each.value.requestor_scope_type

  requestor_justification_required = var.require_requestor_justification
  approval_timeout_in_days         = var.approval_timeout_in_days
  approval_stages                  = local.approval_stages_by_instance[each.key]
}
