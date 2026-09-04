# `access-packages`

Creates the Entitlement Management catalog, one access package per scope, and one
assignment policy per package — **derived entirely from repo 1's state**. No group
name, scope key or role key is written anywhere in this repo.

This is the field reference for the whole repo. `terraform.tfvars.example` points
here rather than repeating it, so that copied tfvars files do not carry a stale
reference table around.

---

## What it builds

| Resource | Cardinality | Where |
|---|---|---|
| `azuread_access_package_catalog` | 1 | `modules/access-package-catalog` |
| `azuread_access_package_resource_catalog_association` | 1 per group, **including excluded ones** | this module |
| `azuread_access_package` | 1 per scope | `modules/access-package` |
| `azuread_access_package_resource_package_association` | 1 per granted group | `modules/access-package` |
| `azuread_access_package_assignment_policy` | 1 per package | `modules/access-package` |

Applied to the current POC tenant: 1 catalog, 4 packages, 14 catalog associations,
11 package associations, 4 policies.

The catalog associations live in **this** module rather than in `access-package`,
even though everything else about a package does not. They are unique per
`(catalog, group)`, and under the peer-approval model the same approver group is
attached to more than one package — creating the association in the leaf would
produce duplicates and fail.

---

## The two gates

The single most important thing to understand before reading the inputs.

```
request package → [GATE 1: this module] → assigned / eligible
                → activate in PIM       → [GATE 2: repo 1] → active access
```

| | Gate 1 | Gate 2 |
|---|---|---|
| Question | *Should this person have access to this scope?* | *Should they hold contributor right now?* |
| Approver | the scope's `systemeier` | per-role `approval_type` |
| Source | `vending.systemeier_by_scope[scope]` | `vending.approvers_by_role[composite]` |
| Owned by | **this module** | repo 1 |

This module does not re-implement gate 2. It republishes repo 1's rules through the
`gate_2_approvers` output so that one `terraform output` shows a user's whole
journey, and it interprets none of them.

---

## Why the caller passes `vending` in

The module takes the contract as a plain input instead of reading
`data "terraform_remote_state"` itself. That is deliberate: a module with a
hardcoded remote state block could not be exercised by `examples/complete`, which
runs on local state against a literal fixture and no storage account. The root does
the reading; the module does the deriving.

---

## Inputs

### `vending` (required)

Repo 1's outputs. Most maps are keyed on the composite `{scope}--{role}`; the three
`approver_group_*` maps are keyed on `{scope}` alone, because one approver group
serves every role under a scope.

| Attribute | Keyed on | Required | Used for |
|---|---|---|---|
| `group_names` | composite | yes | The primary contract. Its keys define the scope and role set |
| `group_object_ids` | composite | yes | `resource_origin_id` on the catalog association |
| `access_package_access_type` | composite | yes | `Member` / `EligibleMember`. Drives the blocker 2.1 split |
| `jit_mechanism` | composite | yes | Decides whether the trap 6.1 expiry ceiling applies |
| `systemeier_by_scope` | scope | yes | Gate 1 approvers |
| `approver_group_object_ids` | scope | no | The approver group attached under option A |
| `approver_group_names` | scope | no | Reporting only |
| `approver_group_is_managed_here` | scope | no | Reporting only |
| `approvers_by_role` | composite | no | Forwarded to output, never interpreted |
| `access_model` | composite | no | Forwarded |
| `activation_settings` | composite | no | Forwarded |
| `entra_activation_governance_gap` | composite | no | Forwarded. Trap 6.4 |

The required four are validated against each other: every key in `group_names` must
appear in the other three. A key present in one map and missing from another is
rejected rather than defaulted, because the sensible-looking default —
`access_type = "Member"` — is precisely the silent failure in blocker 2.1.

### `catalog_display_name` (required)

Display name of the single catalog. One catalog rather than one per scope: simpler,
and per-scope catalogs only pay off when delegating catalog ownership via
`azuread_access_package_catalog_role_assignment`, which this POC does not do.

### `defaults`

Applied to every package unless a scope overrides it. Defaults fail safe: approval
is always required at gate 1, and assignments always expire.

| Field | Default | Notes |
|---|---|---|
| `assignment_duration_days` | `14` | Short expiry is this POC's substitute for access reviews |
| `requestor_scope_type` | `AllExistingDirectoryMemberUsers` | Who may request |
| `require_justification` | `true` | |
| `approval_timeout_days` | `7` | Gate 1 only. Gate 2 has a fixed, non-configurable 24-hour timeout |
| `grant_approver_group` | `true` | Option A from §5.5 — see below |

### `scope_overrides`

Keyed on scope key. Omitted fields fall back to `defaults`. Available fields:
`display_name`, `description`, `assignment_duration_days`, `requestor_scope_type`,
`require_justification`, `approval_timeout_days`, `question_text`, `hidden`,
`requests_accepted`.

A key that matches no scope in repo 1's state **fails the plan**. An override that
silently has no effect is worse than a typo caught at plan time: the package quietly
keeps the default and only the portal would tell you.

### `manage_pim_for_groups_roles` / `acknowledge_m3_active_membership`

Both `false` by default. See [Blocker 2.1](#blocker-21) below. Setting the first
without the second fails validation, on purpose.

### `m3_max_duration_days`

Default `30`. Ceiling on `assignment_duration_days` for any package containing a
`pim_for_groups` role. See [Trap 6.1](#trap-61).

---

## Outputs

| Output | What it tells you |
|---|---|
| `catalog_id`, `catalog_display_name` | The catalog |
| `scopes` | Derived scope list. Not configured anywhere — if it looks wrong, the state is wrong |
| `access_package_ids`, `assignment_policy_ids` | Per scope |
| `roles_by_scope` | Composite keys per package, including excluded ones |
| `granted_groups_by_package` | What each package actually grants, with the access type set |
| `effective_policies` | What each package enforces after defaults and overrides were layered |
| `gate_1_approvers` | The systemeier per scope, resolved to object IDs |
| `gate_2_approvers` | Repo 1's `approvers_by_role`, forwarded verbatim |
| `entra_activation_governance_gap` | Repo 1's report of what it cannot manage for M4 |
| `excluded_resource_roles` | **Groups left out of IaC by blocker 2.1** |
| `manual_steps_required` | **Everything still to be done by hand** |
| `peer_approval_status` | Whether peer approval is viable per scope, and where a lone systemeier deadlocks |
| `verification_summary` | Counts to check against the acceptance criteria |
| `catalog_resource_association_ids` | Association ID per group |

Read `manual_steps_required` before believing a clean apply. Parts of this model
cannot be expressed in Terraform today, and that output is where they are listed.

---

## Blocker 2.1

`azuread_access_package_resource_package_association.access_type` accepts only
`Member` and `Owner`. It has no `EligibleMember`, even though the Entra platform
offers that role in the portal for PIM-managed groups.

For `pim_for_groups` roles that matters enormously. Attaching such a group as
`Member` makes the user an **active** member the moment the assignment lands — they
get standing access to AWS instead of having to activate through PIM. It applies
cleanly, it looks correct in the portal, and nothing fails.

**This module takes option 1: those roles are left out and reported.** They appear
in `excluded_resource_roles` and in `manual_steps_required` with the exact portal
path. Their *catalog* associations are still created, so the manual step is picking
`Eligible Member` on an already-registered resource rather than registering it from
scratch.

The split is driven by the *value* of `access_package_access_type`, not by
`jit_mechanism`. Repo 1 only returns `EligibleMember` for `pim_for_groups` today,
but keying off the value means a future mechanism that also needs eligibility is
caught automatically instead of slipping through as active membership.

If a scope's roles are *all* excluded — `jaws` in this tenant — the package ends up
granting only its approver group. That is visible in `granted_groups_by_package` and
is the honest outcome. With `grant_approver_group = false` it would grant nothing at
all, and the plan fails rather than shipping a package that looks like working
access and grants none.

---

## Trap 6.1

Repo 1 sets `active_assignment_expire_after` on `pim_for_groups` groups, defaulting
to `P30D`. If the package assignment outlives that, Entitlement Management and PIM
drift apart: PIM expires the eligibility, the user loses access, and the package
still lists them as assigned.

Enforced as a plan-time precondition: `assignment_duration_days` must be
`<= m3_max_duration_days` for any package containing a `pim_for_groups` role. The
rule is a configured ceiling rather than a value parsed out of repo 1's ISO-8601
`activation_settings`, which is why `manual_steps_required` asks you to confirm the
two agree.

---

## Why preconditions instead of `check` blocks

Every guard in `main.tf` is a `terraform_data` `precondition`. A `check` block
reports and continues, so the apply would still go through and produce the broken
configuration. These failures all share a shape — the apply succeeds and something
is subtly wrong in the portal — so warning is not enough.

| Precondition | Catches |
|---|---|
| `validate_derivation` | Empty scope set; `scope_overrides` naming a scope that does not exist |
| `validate_gate_1_approvers` | A scope with no systemeier, whose requests would time out forever |
| `validate_packages_grant_something` | A package with no resource roles — looks like access, grants none |
| `validate_m3_expiry_ceiling` | Trap 6.1 |
| `validate_peer_approval_viability` | Option A switched off while a lone systemeier deadlocks |

---

## Section 5.5, option A

`grant_approver_group` defaults to `true`, which attaches each scope's approver group
to that scope's package as a second resource role.

Repo 1 seeds each approver group with its `systemeier`, so `dual` roles work on the
first apply. But PIM blocks self-approval, so a group with exactly one member cannot
approve that member's own request — and `morkanaught` and `jaws` have one systemeier
each. Their `dual` roles are un-activatable by that person alone, and the request
times out after 24 hours.

Attaching the approver group makes everyone in the scope a peer approver, which
resolves it. The cost is that any member can approve an `Owner` elevation, which is
what the future junior/senior split (option B, §5.5) fixes by giving juniors a
package **without** the approver group. The leaf module already supports that: a
package is just a different set of `resource_roles`.

Setting this to `false` while a scope still has fewer than two systemeier fails the
plan, because that leaves the deadlock in place with nothing to resolve it.

---

## Call example

```hcl
data "terraform_remote_state" "vending" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-poc"
    storage_account_name = "sttfstatepocbvt"
    container_name       = "tfstate"
    key                  = "access-vending.tfstate"
    use_azuread_auth     = true
  }
}

locals {
  v = data.terraform_remote_state.vending.outputs
}

module "access_packages" {
  source = "./modules/access-packages"

  vending = {
    group_names                = local.v.group_names
    group_object_ids           = local.v.group_object_ids
    access_package_access_type = local.v.access_package_access_type
    jit_mechanism              = local.v.jit_mechanism

    systemeier_by_scope            = local.v.systemeier_by_scope
    approver_group_object_ids      = local.v.approver_group_object_ids
    approver_group_names           = local.v.approver_group_names
    approver_group_is_managed_here = local.v.approver_group_is_managed_here

    approvers_by_role               = local.v.approvers_by_role
    entra_activation_governance_gap = local.v.entra_activation_governance_gap
  }

  catalog_display_name = "Cloud Access"

  defaults = {
    assignment_duration_days = 14
    approval_timeout_days    = 7
    grant_approver_group     = true
  }

  scope_overrides = {
    "tenant" = { assignment_duration_days = 7 }
  }
}
```

Runnable variants: `examples/complete` (literal fixture, local state) and
`examples/github-consumption` (remote state, pinned git ref).

---

## Adding a scope or a role

Nothing to do here. Add it in repo 1, apply repo 1, then apply repo 2 — the new role
joins its scope's package, or a new scope gets a new package with its own policy.

Removing one works the same way. Note that *renaming* a scope or role key is
destructive in repo 1: the key is both a `for_each` key and part of the group name,
so a rename deletes and recreates the group and invalidates every object ID this
module holds. Treat the key set as append-only across both repos (trap 6.6).

---

## No provider blocks

Neither this module nor its children declare a `provider` block. That is what allows
a caller to use `count`, `for_each` and `depends_on` on it. Provider configuration
belongs to the root and to `examples/*/providers.tf`.

`azurerm` is not needed at all — this repo touches no ARM resources. The `azurerm`
*backend* used for state is built into Terraform and needs no provider.

---

## Future direction: personas

Today a package means "membership of the team that works on this scope". Eventually
packages will represent job functions spanning several scopes — junior, senior,
developer, security, non-technical stakeholder — and a package will reference
composite keys across scopes. At that point repo 2 gains a persona map that genuinely
cannot be derived from repo 1, and gate 1 stops being a direct lookup: a package
would inherit several `systemeier` lists and you would have to choose between a
union, a nominated owning scope, or `requestorManager`.

`locals.tf` is the file that gets replaced when that happens. The resource wiring in
`main.tf` and both leaf modules survive it unchanged.
