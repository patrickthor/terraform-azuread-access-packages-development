# Module: `access-package-catalog`

Creates **or adopts** one Entitlement Management catalog, and optionally delegates package
management on it. **Cloud-agnostic** — a catalog is a pure Entra concept, identical
regardless of which cloud the packages behind it grant access to.

## Why adoption and delegation live here

A catalog is a **delegation boundary**: it controls who may add resources to it and who may
manage the packages inside it. Two consequences shape this module.

Most real tenants already have a catalog, owned by an identity team that will not hand over
creation rights. `adopt_existing` covers that without changing anything downstream — only
the source of the catalog ID differs.

And because catalog roles decide who can add resources, delegating one is a genuine
security decision rather than a convenience. It is the one standing, non-expiring,
non-activated grant this system can produce, so it is off by default.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `display_name` | `string` | — | Display name. When adopting, this is the lookup key and must match exactly. |
| `description` | `string` | `null` | Rejected when `adopt_existing` is true. |
| `externally_visible` | `bool` | `false` | Visible to users outside the tenant. |
| `published` | `bool` | `true` | Published, therefore requestable. |
| `adopt_existing` | `bool` | `false` | Look the catalog up instead of creating it. |
| `delegated_principals` | `map(string)` | `{}` | label → object ID. Keys are labels from configuration because `for_each` keys must be known at plan time. |
| `delegated_role_name` | `string` | `"Access package manager"` | Catalog role granted to `delegated_principals`. |

## Outputs

| Name | Description |
|---|---|
| `catalog_id` | ID of the catalog, created or adopted. |
| `display_name` | Display name. |
| `was_adopted` | Whether it was adopted. Changes who owns the delegation boundary. |
| `delegated_role_assignments` | Assignment ID per delegated principal. Non-empty means standing package-management rights exist. |

## Example

```hcl
module "catalog" {
  source = "./modules/access-package-catalog"

  display_name = "Cloud Access"
  description  = "Access packages for Terraform-vended cloud access."
}
```

Adopting an existing catalog and delegating to its systemeier:

```hcl
module "catalog" {
  source = "./modules/access-package-catalog"

  display_name   = "Corporate Identity Governance"
  adopt_existing = true

  delegated_principals = {
    "patrick@example.com" = data.azuread_user.patrick.object_id
  }
}
```

## Notes

**Adoption does not rewrite the catalog's own settings.** `description`,
`externally_visible` and `published` belong to whoever owns it, and silently changing
another team's delegation boundary is exactly the kind of invisible change this project
refuses. Setting `description` alongside `adopt_existing` fails validation rather than being
ignored.

**`Access package manager`, not `Catalog owner`.** A catalog owner can add arbitrary
resources to the catalog, which routes around repo 1 entirely and grants access that no PIM
policy governs. Access package manager can manage the packages that already exist there.

**Registering groups as catalog resources is not done here.**
`azuread_access_package_resource_catalog_association` lives in the parent `access-packages`
module. Those associations are unique per `(catalog, group)` while this module is scoped to
one catalog and knows nothing about groups — and under peer approval the same approver group
attaches to several packages in the same catalog.

**One catalog or several?** The label should track *ownership*, not environment. One
identity team owning everything means one catalog is correct, and per-scope catalogs are
pure overhead. Split when a platform team should own its own packages — or to make a
dangerous package visible in a listing rather than buried among ordinary access.
