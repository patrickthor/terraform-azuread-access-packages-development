# Example: `complete`

Exercises every mechanism on local state, with **no dependency on repo 1**.

The contract that the root module reads from repo 1's remote state is inlined in
`main.tf` as a literal fixture. That is the point of this example: the module takes
the taxonomy as a plain input, so it can be validated and planned without a storage
account, without `Storage Blob Data Reader`, and without repo 1 having been applied.

It doubles as executable documentation of the contract shape. If repo 1 changes an
output, this fixture is the first place the mismatch shows up.

## Running it

```bash
cp terraform.tfvars.example terraform.tfvars   # set your tenant_id
terraform init
terraform validate
terraform plan
```

`validate` works offline. `plan` needs a real tenant, and will fail on the
`data "azuread_user"` lookup because the fixture's systemeier are
`@example.onmicrosoft.com` placeholders. Substitute real UPNs to plan for real —
against a throwaway catalog name, since the group object IDs are placeholders too.

## The fixture

Mirrors the POC tenant: 11 role groups across 4 scopes, spanning all three JIT
mechanisms, plus 3 approver groups.

| Scope | Roles | Mechanism | Approver group |
|---|---|---|---|
| `tommer` | readingbooks, contriband, master | `azure_pim` | yes, 2 systemeier |
| `morkanaught` | reader, blob-leser, nettverksdrift | `azure_pim` | yes, 1 systemeier |
| `jaws` | admin, readonly, billing | `pim_for_groups` | yes, 1 systemeier |
| `tenant` | groupsadmin, directoryreader | `entra_role` | no |

## Expected outcome

```
verification_summary = {
  catalogs_created              = 1
  packages_created              = 4
  role_groups_in_contract       = 11
  role_groups_attached          = 8
  role_groups_excluded          = 3
  approver_groups_attached      = 3
  catalog_resource_associations = 14
  resource_package_associations = 11
  assignment_policies           = 4
  m3_scopes                     = ["jaws"]
}
```

Three things in that output are worth understanding rather than glossing over.

**8 attached out of 11.** The three `aws-jaws-*` roles need `EligibleMember`, which
the `azuread` provider cannot set, so they are excluded and reported in
`excluded_resource_roles` instead of being silently downgraded to standing active
membership. Blocker 2.1, option 1.

**The `jaws` package grants only its approver group.** Every role in that scope was
excluded, so the only resource role left is `aws-jaws-approvers`. Check
`granted_groups_by_package` and you will see it. That is the honest consequence of
option 1 on an all-M3 scope, and `manual_steps_required` tells you exactly which
three resource roles to add in the portal to complete it.

**`tenant` gets 7 days, not 14.** Trap 6.7: that package hands out `Groups
Administrator`, and Terraform can set no activation rules for directory roles at all,
so gate 1 is the only control it enforces. A short duration is the mitigation
available in code.

## Things to try

Each of these should **fail the plan**, which is the behaviour worth verifying:

| Change | Expected failure |
|---|---|
| `grant_approver_group = false` | `jaws` would grant nothing at all — `validate_packages_grant_something` |
| `assignment_duration_days = 60` | `jaws` breaches the 30-day M3 ceiling — `validate_m3_expiry_ceiling` |
| `manage_pim_for_groups_roles = true` alone | Requires `acknowledge_m3_active_membership` — variable validation |
| Rename `"tenant"` in `scope_overrides` to `"tenat"` | Unknown scope — `validate_derivation` |
| Empty a `systemeier_by_scope` list | Gate 1 unsatisfiable — `validate_gate_1_approvers` |

Setting `manage_pim_for_groups_roles = true` **with** the acknowledgement moves
`role_groups_attached` to 11 and `resource_package_associations` to 14 — full IaC
coverage, at the cost of turning `jaws` eligibility into standing access.
