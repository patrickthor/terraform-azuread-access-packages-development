# ==============================================================================
# access-package-catalog — the Entitlement Management catalog holding the packages
#
# Cloud-agnostic. A catalog is a pure Entra concept and is identical whether the
# packages behind it grant access to Azure, AWS, GCP or GitHub.
# ==============================================================================

resource "azuread_access_package_catalog" "this" {
  display_name       = var.display_name
  description        = var.description
  externally_visible = var.externally_visible
  published          = var.published
}
