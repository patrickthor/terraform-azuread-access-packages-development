# Module: `access-package-catalog`

Creates an Entitlement Management catalog. **Cloud-agnostic** — a catalog is a
pure Entra concept and is identical regardless of which cloud the packages behind
it grant access to.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `display_name` | `string` | — | Display name. |
| `description` | `string` | — | Description. |
| `externally_visible` | `bool` | `false` | Visible to external users. |
| `published` | `bool` | `true` | Published and available for requests. |

## Outputs

| Name | Description |
|---|---|
| `catalog_id` | ID of the catalog. |
| `display_name` | Display name. |

## Example

```hcl
module "catalog" {
  source = "./modules/access-package-catalog"

  display_name = "Cloud Access"
  description  = "Access packages for Terraform-vended cloud access."
}
```

## Notes

One catalog or one per scope? This POC uses **one** catalog, which is simpler.
Per-scope catalogs would allow cleaner delegation through
`azuread_access_package_catalog_role_assignment`, at the cost of more moving
parts. See open question 4 in `ASSIGNMENT-2-STEERING.md`.

Registering groups as catalog resources is **not** done here.
`azuread_access_package_resource_catalog_association` lives in the parent
`access-packages` module, because it is unique per `(catalog, group)` while the
peer-approval model attaches one approver group to several packages. Creating it
here would have coupled a per-group resource to a per-catalog module.
