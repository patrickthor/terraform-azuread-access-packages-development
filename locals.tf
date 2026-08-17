# ==============================================================================
# Navnederivering — MÅ være identisk med vending-repoet
#
# Denne blokka er duplisert fra terraform-azuread-access-vending
# (modules/azure-subscription-access/main.tf, local.group_names). Divergens her
# gir kryptiske "no group found"-feil.
#
# Kontrakten: {cloud_prefix}-{subscription_key}-{rolle_key}
# ==============================================================================

locals {
  # Flat map over alle (subscription, rolle)-par.
  # Composite-key bruker "--" fordi enkelt bindestrek finnes i navnene selv.
  role_instances = merge([
    for sub_key, sub in var.subscriptions : {
      for role_key, role in sub.roles :
      "${sub_key}--${role_key}" => {
        subscription_key = sub_key
        subscription_id  = sub.subscription_id
        systemeier       = sub.systemeier
        role_key         = role_key
        azure_role       = role.azure_role
        pim_enabled      = role.pim_enabled

        # Kontrakten mot vending-repoet.
        group_name = "${var.cloud_prefix}-${sub_key}-${role_key}"

        approval_type       = role.approval_type
        approver_group_name = role.approver_group_name

        assignment_duration_days = coalesce(
          role.assignment_duration_days,
          var.default_assignment_duration_days
        )
        access_type = coalesce(role.access_type, var.default_access_type)
        requestor_scope_type = coalesce(
          role.requestor_scope_type,
          var.default_requestor_scope_type
        )
        hidden = role.hidden

        display_name = replace(
          replace(
            replace(var.package_display_name_template, "{sub}", sub_key),
            "{role}", role_key
          ),
          "{azure_role}", role.azure_role
        )

        description = replace(
          replace(
            replace(
              replace(var.package_description_template, "{sub}", sub_key),
              "{role}", role_key
            ),
            "{azure_role}", role.azure_role
          ),
          "{subscription_id}", sub.subscription_id
        )
      }
    }
  ]...)

  # Unike systemeier-UPN-er som må slås opp.
  systemeier_upns = toset([
    for inst in values(local.role_instances) : inst.systemeier
    if contains(["owner", "dual"], inst.approval_type)
  ])

  # Unike team-godkjennergrupper som må slås opp.
  approver_group_names = toset([
    for inst in values(local.role_instances) : inst.approver_group_name
    if contains(["team", "dual"], inst.approval_type) && inst.approver_group_name != null
  ])
}
