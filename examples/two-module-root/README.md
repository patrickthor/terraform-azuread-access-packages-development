# Example: `two-module-root` — the reference architecture

**One root config, one state, one apply, one committed `terraform.tfvars`.** A customer adds
a subscription and three roles to `access_scopes`, runs one apply, and gets groups, RBAC, PIM
policies, a catalog, and a requestable access package.

This is the shape to copy. `examples/complete` exists to exercise the module offline; this one
shows how the two repos are meant to fit together.

```
customer repo
│
├── module "access_vending"    repo 1   WHICH access grants exist
│     groups + Azure RBAC bindings + PIM activation policies
│     └── output "contract"
│              │
├── module "access_packages"   repo 2   WHO can receive them
│     catalogs + access packages + assignment policies
│     vending = module.access_vending.contract
```

## What this shape buys

**The contract flows in memory.** Nothing is written to a state file for the other side to
read back, so there is no state-layout coupling between the repos and no
`Storage Blob Data Reader` grant to manage.

**Apply order becomes a property of the dependency graph.** Repo 2's resources reference repo
1's outputs, so a single apply physically cannot get the order wrong. That matters concretely:
for `pim_for_groups` roles it is the act of writing the PIM policy that onboards the group to
PIM for Groups, and until that has happened the platform does not offer `EligibleMember` as a
resource role at all. Apply them out of order and you get standing access where eligibility
was intended, with nothing failing.

**One committed tfvars is the governance record.** For an access system the configuration
*is* the reviewable answer to "who may reach what". It holds no secrets — object IDs and UPNs
are not credentials — so it belongs in git, unlike the gitignored `terraform.tfvars` in this
repo's own root.

## What is stubbed, and why

Repo 1's module call is commented out and a `locals.access_vending_contract` fixture stands in
for its output. Repo 2 cannot vendor repo 1's module, and CI validates this example without
network access.

To make it real: uncomment the `module "access_vending"` block, delete the fixture, and change
`vending = local.access_vending_contract` to `vending = module.access_vending.contract`. Then
fill in `access_scopes` in your tfvars — the commented block at the bottom of
`terraform.tfvars.example` shows the shape.

The fixture here is deliberately minimal — two roles, one scope, one catalog — because this
example is about the wiring. `examples/complete` has the full-fidelity fixture.

## Pin tags, never branches

```hcl
source = "git::https://github.com/patrickthor/terraform-azuread-access-vending-development.git//modules/access-vending?ref=v1.0.0"
```

Repo 2 derives its entire package set from repo 1's contract. With a floating ref, a module
change and a taxonomy change can land in the same plan with nothing to tell them apart — you
would see four packages become five and not know whether repo 1 gained a scope or the module
changed how it derives them. A branch pin in a customer root is a review finding.

## `count` on the access-packages module

```hcl
module "access_packages" {
  source = "..."
  count  = var.enable_access_packages ? 1 : 0
  ...
}
```

This is legal **only** because neither module nor any submodule declares a `provider` block.
It is why that rule is load-bearing rather than stylistic, and it is asserted in CI.

It also buys something practical: stage the rollout. Vend the groups, RBAC bindings and PIM
policies first, then add the request layer once the licensing question is settled — eligible
group membership in access packages needs Entra ID Governance or Entra Suite, not P2 alone.
Run `scripts/verify-entitlement-management.sh` before flipping it on.

Outputs use `one(module.access_packages[*].x)` to unwrap the count, yielding `null` when the
request layer is off. Not `try()`, which would hide real errors along with absent ones.

## Permissions

One identity runs both modules. Not a convenience: repo 1's identity owns every group it
creates, and `azuread_access_package_resource_catalog_association` fails with
`CallerNotResourceOwner` when the caller does not own the group being linked.

| Permission | Needed by | Type |
|---|---|---|
| `Group.ReadWrite.All` | repo 1 | Graph application |
| `User.Read.All` | both | Graph application |
| `RoleManagementPolicy.ReadWrite.AzureADGroup` | repo 1 | Graph application |
| `PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup` | repo 1 | Graph application |
| `EntitlementManagement.ReadWrite.All` | repo 2 | Graph application |
| `User Access Administrator` on each vended subscription | repo 1, `azure_pim` only | Azure RBAC |
| `Storage Blob Data Contributor` on the state account | this root | Azure RBAC |

`RoleManagement.ReadWrite.Directory` and `RoleEligibilitySchedule.ReadWrite.Directory` are
needed **only** for `entra_role`. The first lets the holder assign directory roles anywhere in
the tenant, including to itself — keep `entra_role` disabled while this identity also holds
`User Access Administrator`.

All Graph application permissions need admin consent. That cannot be automated and should not
be: a pipeline able to grant itself tenant-wide group write is a privilege-escalation path.
