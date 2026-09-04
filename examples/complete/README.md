# Example: `complete`

Exercises every mechanism and two catalogs on local state, with **no dependency on repo 1**.

Repo 1's contract is inlined in `main.tf` as a literal fixture. That is the point: the module
takes the contract as a plain typed object, so it can be validated and planned without repo 1
having been applied, without a storage account, and without any state-reading permission.

It doubles as executable documentation of the contract. If repo 1 changes an output, this
fixture is the first place the mismatch shows up.

For the architecture a customer should actually copy — one root, both modules, contract in
memory — see `examples/two-module-root`.

## Running it

```bash
cp terraform.tfvars.example terraform.tfvars   # set your tenant_id
terraform init
terraform validate
terraform plan
```

`validate` works offline. `plan` needs a real tenant and will fail on the
`data "azuread_user"` lookup, because the fixture's systemeier are
`@example.onmicrosoft.com` placeholders. Substitute real UPNs to plan for real — against
throwaway catalog names, since the group object IDs are placeholders too.

## The fixture

11 role groups across 4 scopes, all three JIT mechanisms, two catalogs.

| Scope | Catalog | Roles | Mechanism | Approver group | Systemeier |
|---|---|---|---|---|---|
| `tommer` | platform | readingbooks, contriband, master | `azure_pim` | yes | 2 |
| `morkanaught` | platform | reader, blob-leser, nettverksdrift | `azure_pim` | yes | 1 |
| `jaws` | platform | admin, readonly, billing | `pim_for_groups` | yes | 1 |
| `tenant` | **privileged** | groupsadmin, directoryreader | `entra_role` | no | 1 |

## Expected outcome

Four things in the output are worth understanding rather than glossing over.

**`jaws` attaches 0 of its 3 roles.** They need `EligibleMember`, which the provider
validates away, so they are excluded and reported in `excluded_resource_roles` instead of
being silently downgraded to standing membership. Its package therefore grants **only its
approver group** — check `granted_groups_by_package`. That is the honest consequence on an
all-`pim_for_groups` scope, and `manual_steps_required` names the three portal steps that
complete it.

**`tenant` sits in its own catalog.** It hands out `Groups Administrator`, which can manage
membership in every non-role-assignable group in the tenant — *including* all the groups
repo 1 creates — and rewrite their PIM policies. Terraform can set no activation rules for
directory roles, so gate 1 is the only gate it enforces. A separate catalog keeps it visible
in a listing, and a 7-day duration is the other mitigation available in code.

**`jaws`'s ceiling is 15 days, not 30.** `jaws--billing` carries
`max_assignment_days = 15` while the other two carry 30, and the ceiling is the minimum
across the scope. `verification_summary.jaws.expiry_ceiling_days` shows it.

**`gate_2_approvers` shows `terraform_governs_activation = false`** for both `tenant` roles.
That does not mean those roles are open: active Privileged Role Administrator and Global
Administrator act as default approvers on Entra role activation. It means governed outside
Terraform, by tenant admins.

## Things to try

Each should **fail the plan**, which is the behaviour worth verifying:

| Change | Expected failure |
|---|---|
| `grant_approver_group = false` | `jaws` would grant nothing — `validate_packages_grant_something` |
| `assignment_duration_days = 20` | `jaws` breaches its 15-day ceiling, error names `jaws--billing` — `validate_assignment_expiry_ceiling` |
| `manage_pim_for_groups_roles = true` alone | Requires the acknowledgement — variable validation |
| Add `"platfrom" = {}` to `catalogs` | Unknown catalog label — `validate_configuration` |
| Rename `"tenant"` in `scope_overrides` to `"tenat"` | Unknown scope — `validate_configuration` |
| Empty a scope's `systemeier` list | Gate 1 unsatisfiable — `validate_gate_1_approvers` |
| Point `morkanaught` and `jaws` at the same `approver_group_name` | Duplicate `(catalog, group)` — `validate_no_duplicate_catalog_resources` |
| Set `contract_version = 2` | Version mismatch — variable validation |

Setting `manage_pim_for_groups_roles = true` **with** the acknowledgement moves `jaws` to 3
roles attached and 0 excluded — full IaC coverage, at the cost of turning its eligibility
into standing AWS access.
