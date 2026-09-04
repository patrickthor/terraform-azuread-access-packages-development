# ==============================================================================
# access-package-catalog — one Entitlement Management catalog, created or adopted
#
# Cloud-agnostic. A catalog is a pure Entra concept and is identical whether the
# packages behind it grant access to Azure, AWS, GCP or GitHub.
#
# A catalog is a DELEGATION BOUNDARY: it controls who may add resources to it and
# manage the packages inside it. That is why adoption and role delegation live here
# rather than being assumed away — most real tenants already have a catalog owned by
# an identity team that will not hand over creation rights.
#
# Registering groups as catalog resources is NOT done here. The
# azuread_access_package_resource_catalog_association resources live in the parent
# module, because they are unique per (catalog, group) while this module is scoped to
# a single catalog and knows nothing about groups.
# ==============================================================================

# Created only when not adopting. count rather than for_each because a module
# instance is exactly one catalog either way.
resource "azuread_access_package_catalog" "this" {
  count = var.adopt_existing ? 0 : 1

  display_name       = var.display_name
  description        = var.description
  externally_visible = var.externally_visible
  published          = var.published
}

# Adopted by display name. Everything downstream is identical — only the source of
# the catalog ID changes — so the rest of the system cannot tell the difference.
#
# Note that description, externally_visible and published are NOT applied when
# adopting. They belong to whoever owns the catalog, and silently rewriting another
# team's delegation boundary would be exactly the kind of invisible change this
# project refuses. variables.tf rejects setting them alongside adopt_existing.
data "azuread_access_package_catalog" "adopted" {
  count = var.adopt_existing ? 1 : 0

  display_name = var.display_name
}

# ------------------------------------------------------------------------------
# Delegation
#
# Makes the named principals catalog role holders, so package management sits with
# the people who already approve gate 1 rather than with a central team.
#
# This is a STANDING grant with no expiry and no activation step — the one place in
# this system where that is true. It is off by default for that reason, and the
# default role is deliberately not Catalog owner.
# ------------------------------------------------------------------------------

data "azuread_access_package_catalog_role" "delegated" {
  count = length(var.delegated_principals) > 0 ? 1 : 0

  display_name = var.delegated_role_name
}

resource "azuread_access_package_catalog_role_assignment" "delegated" {
  # Keyed on the caller's label (a UPN), which comes from configuration, rather than
  # on the object ID, which is resolved from a data source. for_each keys must be
  # known at plan time.
  for_each = var.delegated_principals

  catalog_id          = local.catalog_id
  principal_object_id = each.value
  role_id             = data.azuread_access_package_catalog_role.delegated[0].object_id
}

locals {
  # Exactly one of the two branches exists, so this resolves unambiguously.
  catalog_id = var.adopt_existing ? data.azuread_access_package_catalog.adopted[0].id : azuread_access_package_catalog.this[0].id

  catalog_display_name = var.adopt_existing ? data.azuread_access_package_catalog.adopted[0].display_name : azuread_access_package_catalog.this[0].display_name
}
