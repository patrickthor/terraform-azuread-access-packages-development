# `access-packages`

Creates catalogs, one access package per scope, and one assignment policy per package —
**derived entirely from repo 1's contract**. No group name, scope key or catalog label is
written anywhere in this repo.

This is the field reference for the whole repo. `terraform.tfvars.example` points here
rather than repeating it, so copied tfvars files do not carry a stale reference table.

---

## What it builds

| Resource | Cardinality | Where |
|---|---|---|
| `azuread_access_package_catalog` | 1 per catalog label, unless adopted | `modules/access-package-catalog` |
| `azuread_access_package_catalog_role_assignment` | per delegated systemeier, off by default | `modules/access-package-catalog` |
| `azuread_access_package_resource_catalog_association` | 1 per `(catalog, group)`, **including excluded groups** | this module |
| `azuread_access_package` | 1 per scope | `modules/access-package` |
| `azuread_access_package_resource_package_association` | 1 per granted group | `modules/access-package` |
| `azuread_access_package_assignment_policy` | 1 per package | `modules/access-package` |

The catalog associations live in **this** module rather than in `access-package`. They are
unique per `(catalog, group)`, and under peer approval the same approver group attaches to
several packages in the same catalog — creating the association in the leaf would produce
duplicates and fail.

---

## The contract

One input, `vending`, taking repo 1's single `contract` output. Full definition in
`.kiro/steering/identity-governance-contract.md`; the parts this module reads:

### `roles`, keyed `{scope}--{role}`

| Field | Used for |
|---|---|
| `scope` | which package the role joins |
| `role` | reporting |
| `group_name` | reporting and the manual-step instructions |
| `group_object_id` | `resource_origin_id` on the catalog association |
| `access_type` | `Member` / `EligibleMember`. Drives the exclusion split |
| `jit_mechanism` | which manual steps apply, and whether Terraform governs activation |
| `permanent_access` | distinguishing the scope's baseline from its escalation paths |
| `target` | reporting: what the group actually grants |
| `max_assignment_days` | the expiry ceiling for the package. `null` = none |

### `scopes`, keyed `{scope}`

| Field | Used for |
|---|---|
| `catalog` | which catalog the package lives in |
| `cloud` | reporting, and the SCIM manual step |
| `scope_id` | reporting |
| `systemeier` | **gate 1 approvers**, and the delegation principals |
| `approver_group_name` | whether a scope has an approver group at all |
| `approver_group_object_id` | attaching it as a resource role |
| `role_keys` | **the plan-safe iteration source** for a scope's roles |

### `catalogs`, keyed catalog label

| Field | Used for |
|---|---|
| `scope_keys` | **the plan-safe iteration source** for a catalog's scopes |

### Three validations, not eleven

`contract_version == 1`, composite key shape, and non-empty `roles`. Everything the old
cross-map consistency checks caught is now a type error, which is a better error: the type
system names the missing attribute instead of a hand-written message inferring it.

**No contract field is ever wrapped in `try()`.** `contract_version` handles
compatibility, and it fails loudly. A `try()` around a contract field is how a missing
`access_type` silently becomes standing access.

### Why the module takes an object rather than reading state

In the reference architecture both modules live in one root config and the contract flows
in memory as `module.access_vending.contract`. That makes the apply order a property of
the dependency graph rather than a convention, which matters concretely: for
`pim_for_groups` roles it is the act of writing the PIM policy that onboards the group to
PIM for Groups, and until then the platform does not offer `EligibleMember` at all.

A caller who wants split states can feed `vending` from a remote state read **in their own
root**. That is their choice, not the module's, and it is what this repo's own root does.

### The plan-safe iteration rule

`for_each` keys must be known at plan time. Every iteration source in `locals.tf` is a
contract key or one of the explicit `role_keys` / `scope_keys` lists, never
`distinct([for k in keys(roles) : split("--", k)[0]])`.

Recomputing them would work today and would break the plan the moment repo 1 populated a
list from a resource attribute — surfacing as
`The "for_each" value depends on resource attributes that cannot be determined until apply`
in **this** module, for a change made in the other repo. Values inside the maps may be
unknown until apply; `group_object_id` always is. That is fine, because unknown values are
only a problem in `for_each` and `count`.

---

## The two gates

| | Gate 1 | Gate 2 |
|---|---|---|
| Question | *Should this person reach this scope at all?* | *Should they hold contributor right now?* |
| Approver | the scope's `systemeier` | per-role `approval_type` |
| Timeout | `approval_timeout_days` | fixed 24h, not configurable |
| Owned by | **this module** | repo 1 |

This module does not implement or interpret gate 2. It republishes what the contract
carries through `gate_2_approvers` so one `terraform output` shows the whole journey.

**What that output can and cannot say.** The contract carries `jit_mechanism`,
`permanent_access`, `target` and `max_assignment_days` — enough to show where activation
applies and where Terraform governs it. It does **not** carry repo 1's per-role
`approval_type`, so `gate_2_approvers` cannot name the approver for an individual role. It
lists the scope's systemeier and approver group because those are the two pools repo 1
draws from, not because this module worked out which applies.

---

## Inputs

### `vending` (required)

Repo 1's `contract`. See above.

### `catalogs`

Keyed on the catalog **label** from the contract. Every key optional — a label with no
entry gets the defaults, so the simple case needs no configuration. A key not in the
contract **fails the plan**.

| Field | Default | Notes |
|---|---|---|
| `display_name` | the label | |
| `description` | `null` | Rejected together with `adopt_existing` |
| `externally_visible` | `false` | Every scope here grants cloud access; none is for guests |
| `published` | `true` | |
| `adopt_existing` | `false` | Look the catalog up instead of creating it |
| `delegate_to_systemeier` | `false` | Standing catalog role for the scope's systemeier |
| `systemeier_catalog_role` | `Access package manager` | |

A catalog in Entra is a **delegation boundary** — it controls who may add resources to it
and manage the packages inside it. So the label should track ownership, not environment.
One identity team owning everything means one catalog is correct; split when a platform
team should own its own packages.

**`adopt_existing`** creates nothing and uses `data.azuread_access_package_catalog`.
Everything downstream is identical; only the source of the catalog ID changes. The
catalog's own settings stay with whoever owns it, which is why setting `description`
alongside it is rejected rather than ignored.

**`delegate_to_systemeier`** is the one standing, non-expiring, non-activated grant this
system can produce, which is why it is off by default. `Access package manager` rather
than `Catalog owner`: a catalog owner can add arbitrary resources to the catalog, routing
around repo 1 entirely and granting access no PIM policy governs.

### `defaults`

| Field | Default | Notes |
|---|---|---|
| `assignment_duration_days` | `14` | Short expiry substitutes for access reviews |
| `requestor_scope_type` | `AllExistingDirectoryMemberUsers` | |
| `require_justification` | `true` | |
| `approval_timeout_days` | `7` | Gate 1 only |
| `grant_approver_group` | `true` | Peer approval — see below |

### `scope_overrides`

Keyed on scope key; omitted fields fall back to `defaults`. Fields: `display_name`,
`description`, `assignment_duration_days`, `requestor_scope_type`,
`require_justification`, `approval_timeout_days`, `question_text`, `hidden`,
`requests_accepted`. A key matching no scope **fails the plan** — an override that
silently has no effect is worse than a typo caught at plan time.

### `manage_pim_for_groups_roles` / `acknowledge_m3_active_membership`

Both `false`. See [the EligibleMember gap](#the-eligiblemember-gap). Setting the first
without the second fails validation.

---

## Outputs

| Output | Purpose |
|---|---|
| `manual_steps_required` | What Terraform could not do, with the portal path. **Read this before believing an apply.** |
| `excluded_resource_roles` | Per-group detail behind the above |
| `catalogs` | Label → ID, display name, created-or-adopted, standing delegation |
| `packages_by_catalog` | Which packages landed in which catalog. Security-relevant: a catalog is a delegation boundary |
| `granted_groups_by_package` | What each package grants, after exclusions |
| `gate_1_approvers` | Per package, the systemeier as named approvers |
| `gate_2_approvers` | Repo 1's activation facts, republished |
| `peer_approval_status` | Where the single-systemeier deadlock is resolved and where it is not |
| `verification_summary` | One line per package |
| `access_package_ids`, `assignment_policy_ids`, `effective_policies`, `contract_version` | |

---

## The EligibleMember gap

`azuread_access_package_resource_package_association.access_type` is validated client-side
to `Member` and `Owner` only. The Entra platform offers "Eligible Member" in the portal for
PIM-managed groups; the sole barrier is a `StringInSlice` allowlist on the provider's
schema field.

For `pim_for_groups` roles that matters enormously. Attaching one as `Member` makes the
user an **active** member the moment the assignment lands — standing access to AWS instead
of activating through PIM. It applies cleanly, looks correct, and nothing fails.

**Default behaviour: exclude, register, report.** Those roles get their *catalog*
association created but not their *package* association, and appear in
`excluded_resource_roles` and `manual_steps_required` with the portal path. Registration is
access-type agnostic, so the manual step is one click on a resource that is already there.

The split is driven by the *value* of `access_type`, not by `jit_mechanism`. Repo 1 only
returns `EligibleMember` for `pim_for_groups` today, but keying off the value means a future
mechanism that also needs eligibility is caught automatically instead of slipping through as
standing membership.

If a scope's roles are *all* excluded, its package ends up granting only its approver group.
That is visible in `granted_groups_by_package`. With `grant_approver_group = false` it would
grant nothing, and the plan fails rather than shipping a package that looks like working
access.

**Verify licensing first.** Eligible group membership in access packages requires Entra ID
Governance or Entra Suite, not P2 alone. If the platform rejects it, every workaround is a
dead end including the manual portal step. `scripts/verify-entitlement-management.sh` is the
probe.

---

## The expiry ceiling

If a package assignment outlives the group's eligible-assignment expiry, PIM expires the
eligibility while Entitlement Management still lists the user as assigned. They lose access
without losing the assignment, nothing errors, and their own MyAccess page contradicts what
they can do.

Repo 1 emits the ceiling as `max_assignment_days`, a number, so **nothing here parses
ISO-8601**. Enforced per package as a plan-time precondition: `assignment_duration_days`
must be at or below the minimum non-null `max_assignment_days` across the scope's roles. The
error names the role that set the binding ceiling, because the ceiling comes from one role's
PIM policy and the operator needs to know which.

The ceiling is computed across **every** role in the scope, including those excluded by the
EligibleMember gap. Those are expected to be added by hand in the portal, and once they are,
their expiry constrains the package too. Using only the managed roles would let a too-long
duration pass the plan and then start silently dropping access after the manual step.

---

## Preconditions

Every guard is a `terraform_data` `precondition`. A `check` block reports and lets the apply
proceed, which is wrong for every failure mode here: they all end with a successful apply and
something subtly wrong in the portal.

| Precondition | Catches |
|---|---|
| `validate_configuration` | Unknown catalog label or scope key in the inputs; a scope naming a catalog missing from `contract.catalogs` |
| `validate_gate_1_approvers` | A scope with no systemeier, whose requests time out forever |
| `validate_packages_grant_something` | A package with no resource roles — looks like access, grants none |
| `validate_assignment_expiry_ceiling` | The expiry drift above |
| `validate_no_duplicate_catalog_resources` | Two scopes sharing an approver group inside one catalog |
| `validate_peer_approval_viability` | Peer approval switched off while a lone systemeier deadlocks |

### Why the association keys are what they are

A catalog resource association is unique per `(catalog, group)`. Role groups are safe keyed
on the composite role key: one group belongs to one role in one scope, and a scope sits in
exactly one catalog, so the role key *is* a `(catalog, group)` key.

Approver groups are not automatically safe. `approver_group_name` may point at a group repo 1
does not manage, and two scopes could share it. Sharing across *different* catalogs is
legitimate and must produce two associations — which is exactly why the key cannot be the
group alone. Sharing inside the *same* catalog is a duplicate, and the provider reports it at
apply, partway through, with resources already created.
`validate_no_duplicate_catalog_resources` turns that into a plan failure.

---

## Peer approval

`grant_approver_group` defaults to `true`, attaching each scope's approver group to that
scope's package as an extra resource role.

Repo 1 seeds each approver group with its `systemeier`, so dual-approval roles work on the
first apply. But PIM blocks self-approval, so a group with exactly one member cannot approve
that member's own request — the request times out after 24 hours, a timeout nobody can
configure. Attaching the approver group makes everyone in the scope a peer approver.

The cost is that any member can approve an `Owner` elevation, which a future junior/senior
split fixes by giving juniors a package **without** the approver group. The leaf module
already supports that: a package is just a different set of `resource_roles`.

Setting this `false` while a scope still has fewer than two systemeier fails the plan, because
that leaves the deadlock in place with nothing to resolve it.

---

## Call example

The reference architecture — one root, both modules, contract in memory:

```hcl
module "access_vending" {
  source = "git::https://github.com/patrickthor/terraform-azuread-access-vending-development.git//modules/access-vending?ref=v1.0.0"

  access_scopes   = var.access_scopes
  default_catalog = "platform"
  tenant_id       = var.tenant_id
}

module "access_packages" {
  source = "git::https://github.com/patrickthor/terraform-azuread-access-packages-development.git//modules/access-packages?ref=v1.0.0"

  vending = module.access_vending.contract

  catalogs = {
    "platform" = { display_name = "Cloud Access" }
  }

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

Pin tags, never branches. This module derives its whole package set from the contract, so with
a floating ref a module change and a taxonomy change land in the same plan with nothing to
tell them apart.

Runnable variants: `examples/two-module-root` (the shape above) and `examples/complete`
(literal contract fixture, local state, all three mechanisms and two catalogs).

---

## Adding a scope, a role or a catalog

Nothing to do here. Add it in repo 1 and apply — the new role joins its scope's package, a new
scope gets a new package with its own policy, and a new catalog label gets a catalog named
after itself. Adding a catalog costs one word in `terraform.tfvars` and no code change on
either side.

Renaming a scope or role key is destructive in repo 1: the key is both a `for_each` key and
part of the group name, so a rename deletes and recreates the group and invalidates every
object ID in the contract. Treat the key set as append-only across both repos.

---

## No provider blocks

Neither this module nor its children declares a `provider` block. That is what lets a caller
use `count`, `for_each` and `depends_on` — and `examples/two-module-root` uses `count` on this
module, so it is load-bearing rather than stylistic. CI asserts it.

Provider constraints here are `>=` so the module never becomes a version ceiling. Roots pin
with `~>` and commit a lockfile. `azurerm` is absent entirely: this module touches no ARM
resources.

---

## Future direction: personas

Today a package means "membership of the team that works on this scope". Eventually packages
will represent job functions spanning several scopes — junior, senior, developer, security,
non-technical stakeholder — referencing composite keys across scopes.

At that point gate 1 stops being a direct lookup: a package would inherit several `systemeier`
lists and you would choose between a union, a nominated owning scope, or `requestorManager`.
Persona packages are driven by *this* repo's variables and touch repo 1 not at all. The
scope→package mapping in `locals.tf` is what gets replaced; the resource wiring in `main.tf`
and both leaf modules survive unchanged.
