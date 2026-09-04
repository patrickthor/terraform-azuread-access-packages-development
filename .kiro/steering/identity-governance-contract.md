---
inclusion: always
---

# Identity Governance Contract — shared by both module repos

> **This file must be byte-identical in `terraform-azuread-access-vending-development`
> and `terraform-azuread-access-packages-development`.** It is the interface between
> them. Change it in both repos in the same PR pair, and bump `contract_version`.

## The common goal

One lightweight module pair that a customer repo can consume to get working Entra
identity governance from a single committed `terraform.tfvars`.

```
customer repo (one root config, one state, one apply)
│
├── module "access_vending"    repo 1   WHICH access grants exist
│     groups + Azure RBAC bindings + PIM activation policies
│     └── output "contract"
│              │
├── module "access_packages"   repo 2   WHO can receive them
│     catalogs + access packages + assignment policies
│     consumes module.access_vending.contract
```

Success is measured on the customer side, not inside either repo: **a customer adds a
subscription and three roles to `terraform.tfvars`, runs one `apply`, and gets groups,
RBAC, PIM policies, a catalog, and a requestable access package.** Every design choice
in either repo is judged against that sentence.

## Architecture decisions that are settled

Do not relitigate these without changing this file.

| # | Decision |
|---|---|
| **A1** | **One root config, one state, two modules.** Values flow `module.access_vending.contract → module.access_packages.vending` in memory. |
| **A2** | **No `terraform_remote_state` anywhere in either module.** Repo 2 takes a plain typed object. A customer who wants split states can still feed it from a remote state read in their own root — that is their choice, not the module's. |
| **A3** | **No `provider` blocks in any module or submodule.** A module with provider blocks cannot be used with `count`, `for_each` or `depends_on`. Repo 2's module is used with `count` in the reference customer config, so this is load-bearing, not stylistic. CI in both repos asserts it. |
| **A4** | **Repo 2 never creates a group and never writes a group name.** Repo 1 never creates a catalog or an access package. Neither side reimplements the other's gate. |
| **A5** | **One shared `terraform.tfvars`, committed.** For an access system the configuration *is* the governance record. Both modules read from the same variable set in the customer root. |
| **A6** | **Apply order is enforced by the dependency graph, not by convention.** Repo 2's resources depend on repo 1's outputs, so a single apply cannot get the order wrong. This matters concretely: for `pim_for_groups` roles it is the act of writing the PIM policy that onboards the group to PIM for Groups, and until that has happened the platform does not offer `EligibleMember` as a resource role at all. |
| **A7** | **Reject, never ignore.** A field that the chosen code path does not read must fail validation, not pass silently. A configuration that looks like it controls something it does not is worse than a configuration that refuses to load. |
| **A8** | **`--` is the reserved composite separator.** Repo 1 validates it out of scope keys and role keys, so repo 2 may split on it safely. |

## The contract

Repo 1 exposes exactly one machine-readable output. Repo 2 accepts exactly one
machine-readable input. Both are this object.

```hcl
object({
  contract_version = number   # 1

  # ---- keyed "{scope}--{role}" ------------------------------------------------
  roles = map(object({
    scope               = string
    role                = string
    group_name          = string
    group_object_id     = string
    access_type         = string           # "Member" | "EligibleMember"
    jit_mechanism       = string           # "azure_pim" | "pim_for_groups" | "entra_role"
    permanent_access    = bool
    target              = string           # the RBAC role / target-cloud role / directory role
    max_assignment_days = optional(number) # ceiling for the package assignment; null = none
  }))

  # ---- keyed "{scope}" --------------------------------------------------------
  scopes = map(object({
    catalog                  = string           # catalog LABEL, never a GUID
    cloud                    = string
    scope_id                 = optional(string)
    systemeier               = list(string)     # UPNs
    approver_group_name      = optional(string)
    approver_group_object_id = optional(string)
    role_keys                = list(string)     # sorted composite keys in this scope
  }))

  # ---- keyed catalog LABEL ----------------------------------------------------
  catalogs = map(object({
    scope_keys = list(string)                   # sorted scope keys in this catalog
  }))
})
```

### The one rule that makes this work

> **Every map key and every list element in `contract` must be derivable from
> `var.access_scopes` alone. Never key a contract map or populate a contract list from a
> resource attribute.**

Repo 2 uses `contract.roles`, `contract.scopes`, `contract.catalogs`, `role_keys` and
`scope_keys` as `for_each` sources. `for_each` needs keys known at *plan* time. Values
inside those maps may be unknown until apply — `group_object_id` always is — and that is
fine, because unknown values are only a problem in `for_each` and `count`.

This is why `role_keys` and `scope_keys` exist as explicit sorted lists even though
repo 2 could compute them with a `for` expression. They are the plan-time-safe iteration
sources, and having them named makes the guarantee reviewable rather than accidental.

Run `terraform plan` against an **empty tenant** whenever either side changes how the
contract is assembled. A regression here surfaces as
`The "for_each" value depends on resource attributes that cannot be determined until
apply`, in repo 2, for a change made in repo 1.

### `access_type` is repo 1's answer, not repo 2's guess

| `jit_mechanism` | `access_type` | What the user activates |
|---|---|---|
| `azure_pim` | `Member` | the **role**, in PIM for Azure Resources |
| `pim_for_groups` | `EligibleMember` | the **membership**, in PIM for Groups |
| `entra_role` | `Member` | the **directory role**, in PIM for Entra roles |

Repo 2 must never default a missing `access_type`. Defaulting it to `Member` turns
just-in-time eligibility into standing membership: the apply succeeds, the portal looks
right, and the user silently holds access they should have had to activate for. A
missing key is a hard failure.

### `max_assignment_days` closes the expiry-drift trap

If an access package assignment outlives the group's *eligible assignment expiry*, PIM
expires the eligibility while Entitlement Management still lists the user as assigned.
They lose access without losing the assignment, nothing errors, and the user's own
MyAccess page contradicts what they can do. Microsoft documents this explicitly under
[eligible group membership in access packages](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-eligible).

Repo 1 owns `active_assignment_expire_after`, so repo 1 emits the ceiling as a number:

| `active_assignment_expire_after` | `max_assignment_days` |
|---|---|
| `P15D` / `P30D` / `P90D` / `P180D` / `P365D` | `15` / `30` / `90` / `180` / `365` |
| `"permanent"` | `null` |
| not applicable (`azure_pim`, `entra_role`) | `null` |

Repo 2 enforces it as a plan-time precondition per package. Neither side parses
ISO-8601, and no human keeps a duplicated ceiling in sync.

### Catalogs

The catalog is a **label** on a scope, not an object repo 1 knows anything about.

- Repo 1: one optional `catalog` field per scope, defaulting to the module's
  `default_catalog`. Repo 1 validates the string and passes it through. It creates
  nothing.
- Repo 2: `distinct()` over the labels, one catalog per distinct label, and it decides
  whether to create or adopt.

A catalog in Entra is a **delegation boundary** — who may add resources to it and manage
packages inside it. So the label should track ownership, not environment. One identity
team owning everything means one catalog is correct, and per-scope catalogs are pure
overhead. Split when a platform team should own its own packages.

Because the label is opaque to repo 1, adding a catalog costs one word in
`terraform.tfvars` and no code change on either side.

## The two gates

Two separate approval points answering different questions. Neither side may implement
the other's.

```
request package → [GATE 1: repo 2] → assigned / eligible
                → activate in PIM  → [GATE 2: repo 1] → active access
```

| | Gate 1 — request the package | Gate 2 — activate |
|---|---|---|
| Question | *Should this person have access to this scope at all?* | *Should they hold contributor right now?* |
| Approver | the scope's `systemeier` | per-role `approval_type` |
| Timeout | configurable (`approval_timeout_days`) | fixed 24h, not configurable |
| Owned by | repo 2 | repo 1 |

Repo 2 may **republish** repo 1's gate-2 rules in its own outputs so one
`terraform output` shows the whole journey. It must not interpret them.

## Known platform and provider limits

Both repos must describe these the same way. They are real, and they are surfaced rather
than papered over.

### `EligibleMember` is not in the `azuread` provider

`azuread_access_package_resource_package_association.access_type` is validated
client-side to `Member` and `Owner` only. Verified in the provider source: the resource
builds the Graph role scope as `OriginId = "{access_type}_{group_object_id}"` with
`DisplayName = access_type`, and the sole barrier is a `StringInSlice` allowlist on the
schema field. There is no missing API path and no missing resource — it is one line.

Consequences, in the order worth pursuing them:

1. **Verify licensing first.** Eligible group membership in access packages requires
   Entra ID Governance or Entra Suite, **not P2 alone**. If the platform rejects it,
   every workaround below is a dead end including the manual portal step. Run repo 2's
   `scripts/verify-entitlement-management.sh` and record the result.
2. **Default behaviour: exclude, register, report.** Roles whose `access_type` is
   `EligibleMember` get their *catalog* association created but not their *package*
   association, and appear in repo 2's `excluded_resource_roles` and
   `manual_steps_required` outputs. The manual portal step is then one click on an
   already-registered resource.
3. **A PR to `hashicorp/terraform-provider-azuread`** adding `"EligibleMember"` to the
   allowlist is small and well-motivated. Worth opening regardless.
4. **Microsoft's `msgraph` provider** (public preview) can POST the role scope directly
   and is the IaC-native path until 3 lands. Treat as a spike: nobody here has tested
   that specific POST. If it is adopted, it goes in repo 2 behind an explicit opt-in and
   never becomes a required provider for the vending-only path.

Full IaC coverage by downgrading `EligibleMember` to `Member` stays available behind
**two** flags (`manage_pim_for_groups_roles` + `acknowledge_m3_active_membership`),
because the failure mode is invisible in both plan and portal.

### `entra_role` has no policy resource

The `azuread` provider has no resource for directory role management policies.
`azuread_group_role_management_policy` applies to groups, not directory roles. So MFA,
approval and maximum activation duration for `entra_role` cannot be set by Terraform at
all. Repo 1 therefore **rejects** those fields on `entra_role` instead of ignoring them,
and both repos surface the gap in an output.

For `entra_role`, "no approval from Terraform" means "governed by tenant admins outside
Terraform" — active Privileged Role Administrator and Global Administrator do act as
default approvers — not "open". Say it that way.

### `pim_for_groups` stops at the tenant boundary

Terraform does not connect the group to AWS, GCP or GitHub. That is SCIM on the cloud
side. `target_role` is documentation, and repo 1's `target_cloud_bindings` output is the
work list.

## Permissions

One identity runs both modules. This is not a convenience: repo 1's identity owns every
group it creates, and `azuread_access_package_resource_catalog_association` fails with
`CallerNotResourceOwner` when the caller does not own the group being linked. A separate
identity for repo 2 would need group ownership or Catalog owner on top.

| Permission | Needed by | Type |
|---|---|---|
| `Group.ReadWrite.All` | repo 1 | Graph application |
| `User.Read.All` | both | Graph application |
| `RoleManagementPolicy.ReadWrite.AzureADGroup` | repo 1 | Graph application |
| `PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup` | repo 1 | Graph application |
| `EntitlementManagement.ReadWrite.All` | repo 2 | Graph application |
| `User Access Administrator` on each vended subscription | repo 1, `azure_pim` only | Azure RBAC |
| `Storage Blob Data Contributor` on the state account | the root config | Azure RBAC |

`RoleManagement.ReadWrite.Directory` and
`RoleEligibilitySchedule.ReadWrite.Directory` are needed **only** for `entra_role`. The
first lets the holder assign directory roles anywhere in the tenant including to itself.
Keep `entra_role` disabled while this identity also holds `User Access Administrator`.

All Graph application permissions need admin consent. That cannot be automated, and
should not be: a pipeline able to grant itself tenant-wide group write is a
privilege-escalation path.

## Versioning

- `contract_version` is an integer in the contract object. It starts at `1`.
- Repo 2 validates it and fails with a message naming the version it supports and the
  version it received. Never `try()` around a contract field to paper over a mismatch —
  that is how a missing `access_type` becomes standing access.
- Additive fields do not bump the version. Removing, renaming or changing the meaning of
  a field does.
- Both repos ship semver tags. Customer configs pin tags, never branches. A branch pin
  in a customer root is a review finding.

## Style, shared

- `required_version >= 1.9`. Cross-variable references in validation blocks are a 1.9
  feature and both modules use them.
- Modules use `>=` provider constraints so they never become a ceiling. Roots use `~>`
  and commit a lockfile.
- Every non-obvious decision gets a comment saying *why*, not *what*. Both repos already
  read this way; keep it.
- Guard nullable values in validations by **filtering nulls in the `for` clause**, not
  with `x == null || contains(...)`. Terraform's `||` does not reliably short-circuit,
  so the function still receives the null and fails with
  `argument must not be null`. A ternary is not a dependable fix either.
- Use `terraform_data` + `precondition` for things that must fail the plan. A `check`
  block reports and lets the apply proceed, which is wrong for every failure mode in
  this system, because they are all invisible by default.
