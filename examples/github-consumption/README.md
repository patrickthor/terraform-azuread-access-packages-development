# Example: `github-consumption`

How another team consumes the module: sourced from a pinned git ref, with the
contract read from repo 1's live remote state.

Two things differ from `examples/complete`, and they are why both exist:

| | `complete` | `github-consumption` |
|---|---|---|
| Module source | relative path | pinned git ref |
| Contract | literal fixture | live remote state |
| State | local | the consumer's own backend |
| Runs offline | yes | no |

## The source line

`main.tf` currently uses a relative path so that `terraform validate` passes in CI
without network access and without the repo having been tagged. A real consumer swaps
it for:

```hcl
source = "git::https://github.com/patrickthor/terraform-azuread-access-packages-development.git//modules/access-packages?ref=v1.0.0"
```

**Pin to a tag or a commit, never a branch.** The module derives its entire package
set from repo 1's state, so with a floating ref a module change and a taxonomy change
can land in the same plan with nothing to tell them apart. You would see four
packages become five and not know whether repo 1 gained a scope or the module changed
how it derives them.

## Running it

```bash
cp terraform.tfvars.example terraform.tfvars   # tenant + repo 1's state location
terraform init
terraform plan
```

The `backend "azurerm" {}` block is commented out in `versions.tf` so the example can
be validated without a storage account. Uncomment it and pass
`-backend-config=backend.hcl` for a real deployment.

## What the consuming identity needs

| Permission | Type | Why |
|---|---|---|
| `EntitlementManagement.ReadWrite.All` | Graph application | Catalogs, packages, policies, resource roles |
| `Group.Read.All` | Graph application | Group lookups |
| `User.Read.All` | Graph application | `data "azuread_user"` for the gate 1 approvers |
| `Storage Blob Data Reader` | Azure RBAC | Reading repo 1's state |

`scripts/grant-graph-permissions.sh` grants the three Graph permissions and prints
the command for the RBAC role.

Reusing **repo 1's** service principal is recommended. Repo 1's identity owns all 14
groups, and `azuread_access_package_resource_catalog_association` fails with
`CallerNotResourceOwner` when the calling identity does not own the group being
linked. A different identity needs group ownership or `Catalog owner` in Identity
Governance on top of the permissions above. Trap 6.5.

## State keys

Repo 2 **reads** repo 1's state and **writes** its own. They must be different keys.

```
access-vending.tfstate    ← repo 1 writes, repo 2 reads  (vending_state_key)
access-packages.tfstate   ← repo 2 writes               (backend key)
```

Pointing repo 2's backend at `access-vending.tfstate` would overwrite the contract it
depends on.

## Apply order

Repo 1 first, always. Under this design that is enforced rather than documented: the
plan cannot resolve without repo 1's state, so getting the order wrong fails instead
of silently producing active membership where eligibility was intended.

For `pim_for_groups` roles the ordering matters beyond group existence. Writing the
PIM policy is what onboards a group to PIM for Groups, and until that has happened the
resource-role picker offers only `Member` — never `Eligible Member`. In one pipeline,
use `needs:` between the jobs. See `.github/workflows/deploy.yml`.
