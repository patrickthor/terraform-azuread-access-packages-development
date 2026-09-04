# Module: `access-package`

Creates one requestable access package, its resource roles and its assignment
policy. **Cloud-agnostic** — the module knows only about Entra groups, never about
what those groups grant.

## Where this sits

The assignment policy this module creates is **gate 1**: it decides who may enter a
scope at all. The parent module wires its approvers from repo 1's
`systemeier_by_scope`.

**Gate 2** — whether a person may hold a given privilege *right now* — is the PIM
policy on the group, built in repo 1. This module knows nothing about it, and must
not try to reimplement it. Requiring approval here does not gate activation, and
approval at activation does not gate entry.

The parent module (`modules/access-packages`) decides *which* groups go in *which*
package. This module just builds whatever it is handed, which is what makes the
junior/senior split (§5.5 option B) a matter of passing a different
`resource_roles` map rather than a code change.

## Resource chain

```
azuread_access_package
  └─ azuread_access_package_resource_package_association   (one per granted group)

azuread_access_package
  └─ azuread_access_package_assignment_policy              (who requests, who approves, how long)
```

The catalog association is **not** created here. See the note below.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `catalog_id` | `string` | — | Catalog the package belongs to. |
| `display_name` | `string` | — | Package name in MyAccess. |
| `description` | `string` | — | Package description. |
| `hidden` | `bool` | `false` | Hide from the MyAccess catalog. |
| `resource_roles` | `map(object)` | — | Groups the package grants. See below. |
| `policy_display_name` | `string` | — | Name of the assignment policy. |
| `policy_description` | `string` | — | Description of the assignment policy. |
| `duration_in_days` | `number` | `14` | Assignment lifetime before automatic expiry. |
| `requestor_scope_type` | `string` | `"AllExistingDirectoryMemberUsers"` | Who may request. |
| `requests_accepted` | `bool` | `true` | Whether the policy accepts new requests. |
| `requestor_justification_required` | `bool` | `true` | Requestor must justify. |
| `question_text` | `string` | `null` | Optional question shown to the requestor. |
| `approval_stages` | `list(object)` | `[]` | Sequential stages. Empty disables approval. Max 2. |

### `resource_roles`

```hcl
resource_roles = {
  "role" = {
    catalog_resource_association_id = module.parent.catalog_association_ids["azure-tommer-contriband"]
    access_type                     = "Member"
  }
  "approver" = {
    catalog_resource_association_id = module.parent.catalog_association_ids["azure-tommer-approvers"]
    access_type                     = "Member"
  }
}
```

### `approval_stages`

```hcl
approval_stages = [
  {
    timeout_days = 7
    approvers = [
      { object_id = data.azuread_user.systemeier.object_id, subject_type = "singleUser" },
    ]
  },
  {
    timeout_days = 7
    approvers = [
      { object_id = data.azuread_group.approvers.object_id, subject_type = "groupMembers" },
    ]
  },
]
```

Within one stage, a signature from any single approver is enough. Across stages,
every stage must be passed in order.

## Outputs

| Name | Description |
|---|---|
| `access_package_id` | ID of the package. |
| `access_package_display_name` | Display name as shown in MyAccess. |
| `assignment_policy_id` | ID of the assignment policy. |
| `resource_package_association_ids` | Association ID per granted group. |
| `effective_policy` | Summary of what was actually configured. |

## Design notes worth knowing

**The catalog association lives in the caller, not here.**
`azuread_access_package_resource_catalog_association` registers a group as a
resource in a catalog, and is unique per `(catalog, group)`. Two packages in the
same catalog can legitimately grant the same group — the peer-approval model does
exactly that with the approver group. Creating the association inside this module
would therefore attempt to register the same group twice and fail. The caller
creates one association per group and passes the ID in.

**Multiple groups per package is the point.** Repo 1 holds the invariant *one
group = one role = one scope*. Bundling several grants into a single requestable
item is this layer's job. That is how peer approval works:

```
Package "tommer senior":  role group + approver group   → can approve peers
Package "tommer junior":  role group only               → cannot approve anyone
```

**Two approval stages are only possible here.** Both PIM policy schemas cap
`approval_stage` at `max_items = 1`, so repo 1's `dual` puts the system owner and
the approver group in the *same* stage — one signature from either pool is enough.
Genuine sequential approval has to live on the access package request. See section
4.2 of `ASSIGNMENT-2-STEERING.md`.

**`EligibleMember` is rejected, not accepted-and-ignored.** The Entra platform
supports it for PIM-managed groups; the `azuread` provider does not. Passing it
would silently degrade just-in-time access into standing access without failing.
Validation rejects it and explains why. See blocker 2.1.

**`assignment_review_settings` is deliberately unset.** Access reviews are out of
scope (no Governance add-on assumed) and a short `duration_in_days` is the
substitute: the assignment expires and the user has to request again.
