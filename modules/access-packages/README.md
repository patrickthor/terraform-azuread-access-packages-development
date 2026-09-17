# `access-packages`

Creates catalogs, access packages and their assignment policies — **derived from repo 1's
contract**. No group name, scope key or catalog label is written anywhere in this repo.

By default there is **one package per scope**, containing every role in that scope. Set
`var.packages` to build several named packages over the same groups instead — the
"engineers get reader+contributor, admins also get owner" case, which a scope-wide package
cannot express because a package grants everything in it atomically.

This is the field reference for the whole repo. `terraform.tfvars.example` points here
rather than repeating it, so copied tfvars files do not carry a stale reference table.

---

## What it builds

| Resource | Cardinality | Where |
|---|---|---|
| `azuread_access_package_catalog` | 1 per catalog label, unless adopted | `modules/access-package-catalog` |
| `azuread_access_package_catalog_role_assignment` | per delegated systemeier, off by default | `modules/access-package-catalog` |
| `azuread_access_package_resource_catalog_association` | 1 per `(catalog, group)`, **including excluded groups** | this module |
| `azuread_access_package` | 1 per access package (default: 1 per scope) **+ 1 approver package per scope with an approver group** | `modules/access-package` |
| `azuread_access_package_resource_package_association` | 1 per granted group | `modules/access-package` |
| `azuread_access_package_assignment_policy` | 1 per package | `modules/access-package` |

The catalog associations live in **this** module rather than in `access-package`. They are
unique per `(catalog, group)`, and several packages in one catalog legitimately share a
group — creating the association in the leaf would produce duplicates and fail.

`scope` is no longer the unit of anything except gate 1 approval. Everything else keys on
**package name**, and the per-scope default is one way of generating package definitions
rather than a separate code path. That is what keeps named packages non-breaking: with
`var.packages` empty, the generated definitions reproduce the previous behaviour exactly.

---

## The contract

One input, `vending`, taking repo 1's single `contract` output. Full definition in
`.kiro/steering/identity-governance-contract.md`; the parts this module reads:

### `roles`, keyed `{scope}--{role}`

| Field | Used for |
|---|---|
| `scope` | the package's single scope, and therefore its gate 1 approvers |
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

### Contract v2: the eligibility carrier group

For `pim_for_groups` roles the contract now describes **two** groups:

| Field | What it is |
|---|---|
| `group_object_id` | a **plain**, non-PIM-managed group. This is what the package attaches |
| `pim_group_object_id` / `pim_group_name` | the **PIM-managed** group the plain group is an eligible member of |

Repo 1 creates the plain group and makes it an eligible member of the PIM-managed one. So the
access package attaches plain `Member` on a plain group — which the provider fully supports —
and the user still activates through PIM to reach the real access.

That removed the `EligibleMember` gap entirely. Under v1 these roles needed an access type the
`azuread` provider cannot set, so this module excluded them and reported the gap for portal
work. `access_type` is now `Member` for every mechanism, and the module rejects anything else
rather than downgrading it.

**v1 is not accepted with a branch.** Supporting both shapes would mean carrying the dead
exclusion path plus a silent behaviour difference between two callers running the same module
version. Pin both repos to matching tags.

The expiry ceiling still comes from the **PIM-managed** group's `active_assignment_expire_after`
(`max_assignment_days`), not from the plain group. The package assignment governs membership of
the plain group; if that outlives the PIM eligibility the user keeps the membership and silently
loses the ability to activate.

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

### Gate 1 and cross-scope packages

A package's gate 1 approvers are the systemeier of its **single scope**. Packages spanning
scopes are **rejected at plan time**, not resolved. The decision is explicit because both
alternatives are wrong today:

| Option | Why not |
|---|---|
| Union of every touched scope's systemeier | An owner of scope A could approve entry to scope B — a quiet privilege expansion |
| Approval from each scope's systemeier in turn | Not expressible: the provider allows one approval stage per assignment policy |
| **Reject until there is a real need** | **Chosen.** Every case in front of us is single-scope |

Split the package by scope. When a genuine cross-scope persona appears, the gate 1 note in
`locals.tf` is where to reopen it, and the union with an explicit acknowledgement flag is the
likely answer.

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
| `description` | generated from the label | Required by the provider when creating, so it is defaulted rather than left null. Must be unset when adopting |
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

That interacts with a provider detail worth knowing:
`azuread_access_package_catalog.description` is a **required** argument. Leaving it null
fails the apply after a clean plan. So the module defaults it from the catalog label when
creating, and forces it to null when adopting — the two cases genuinely need opposite
handling, and neither can be left to the caller if a bare catalog label is to work with no
configuration.

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

Applies to approver packages too.


### `packages`

**Optional.** Leave it empty and the module behaves exactly as before: one package per
scope, containing every role in that scope. The zero-config promise is not traded away for
the feature.

Set it when one scope needs more than one audience:

```hcl
packages = {
  "prod-engineers" = {
    display_name = "Prod Engineer Access"
    role_keys    = ["prod--reader", "prod--contributor"]
  }
  "prod-admins" = {
    display_name             = "Prod Admin Access"
    role_keys                = ["prod--reader", "prod--contributor", "prod--owner"]
    assignment_duration_days = 7
  }
}
```

| Field | Default | Notes |
|---|---|---|
| `role_keys` | — | **Required.** Composite `{scope}--{role}` keys from the contract |
| `display_name` | the package name | |
| `description` | generated from the scope | |
| `catalog` | the scope's catalog | Must be a label the contract defines |
| `assignment_duration_days` | from `defaults` | Capped by the package's own expiry ceiling |
| `requestor_scope_type`, `require_justification`, `approval_timeout_days`, `question_text`, `hidden`, `requests_accepted` | from `defaults` | |

These packages grant ROLE GROUPS ONLY. Peer-approval rights are a separate package — see
`approver_packages`.

Rules, all enforced at plan time:

- Every `role_keys` entry must exist in the contract. Unknown keys **fail the plan** with
  the known set listed — never skipped, because a package silently missing a role grants
  less than it claims and nothing in the portal says so.
- `role_keys` must be non-empty and free of duplicates.
- A package must stay within **one scope**. See [gate 1](#gate-1-and-cross-scope-packages).
- `catalog` must be a label the contract defines. Repo 1 owns the label set.
- Setting `packages` **replaces** the per-scope default; it is not merged with it. Any role
  no package names is reported in `unpackaged_roles`, not silently dropped.

### `package_overrides`

Keyed on **package name**; omitted fields fall back to the package definition, then to
`defaults`. Same fields as a package minus `role_keys`, `catalog` and
`grant_approver_group`.

When `packages` is empty, package names are scope names — so this behaves exactly as its
previous name, `scope_overrides`, did. A key matching no package **fails the plan**: an
override that silently has no effect is worse than a typo caught at plan time.

### `approver_packages`

Keyed on **scope key**. Peer-approval rights as their own package, granting only the scope's
approver group and nothing else.

| Field | Default | Notes |
|---|---|---|
| `enabled` | `true` | Set `false` to opt a scope out |
| `display_name` | `"{scope} approver rights"` | |
| `description` | generated | |
| `assignment_duration_days` | from `defaults` | Often longer than the access packages — approval authority is an ongoing responsibility, not a task |
| `requestor_scope_type`, `require_justification`, `approval_timeout_days`, `question_text`, `hidden`, `requests_accepted` | from `defaults` | |

**One is created by default** for every scope whose contract entry has a non-null
`approver_group_name`, so this variable is only needed to deviate. That preserves the previous
default-on behaviour.

**One per scope, not per package.** Repo 1 creates one approver group per scope, so a second
approver package for a second audience in the same scope would grant the identical group twice.

**The package name is generated as `"{scope}-approvers"` and is reserved.** A `packages` key
that collides with it fails the plan. Neither is silently renamed, because the name is how every
output identifies a package.

The package lives in the same catalog as its scope, and that is not configurable: approval rights
over a scope belong to whoever owns that scope's delegation boundary. Making it configurable
would let approval be delegated somewhere the access itself is not.

### `enable_access_reviews` and `access_reviews`

Recurring access reviews on the assignment policy. Two separate things:

**`enable_access_reviews`** — a single boolean master switch, `false` by default. When false, no
review block is written to any assignment policy regardless of configuration. Deliberately not
inferred from whether settings are present, so a pipeline can drive it from one checkbox and the
configuration can be written, reviewed and merged before it goes live.

**`access_reviews`** — an object available on `defaults`, on each `packages` entry, and on each
`approver_packages` entry. Same layering as `assignment_duration_days`: defaults apply,
per-package wins field by field.

| Field | Default | Values |
|---|---|---|
| `review_frequency` | `quarterly` | `weekly`, `monthly`, `quarterly`, `halfyearly`, `annual` |
| `review_type` | `Reviewers` | `Reviewers`, `Self`. **`Manager` is rejected** |
| `duration_in_days` | `14` | How long each campaign stays open |
| `timeout_behavior` | `removeAccess` | `keepAccess`, `removeAccess` |
| `approver_justification_required` | `true` | |

**Presence means on.** There is no `enabled` field inside `access_reviews`: that plus the master
switch would be two switches at the same granularity with no obvious precedence. A package gets a
review when a block exists for it, and none when it does not.

The consequence worth knowing: setting `defaults.access_reviews` turns reviews on for **every**
package, and there is no per-package opt-out. If you want reviews on some packages only, leave the
default unset and set the block on the packages that need it.

**Reviewers are the scope's systemeier** — the same people who approve at gate 1, resolved from the
same `data.azuread_user` lookup rather than a second one. `Self` reviews take no reviewer list.

`timeout_behavior` defaults to `removeAccess`, which is the opposite of the provider's default. An
unanswered review that keeps access is not much of a control.

**Not exposed, deliberately:**

- **`starting_on`** — Graph rejects changes to a review's start date after creation, and this
  resource declares ForceNew on nothing, so a changed value fails at apply rather than replacing
  cleanly. Left unset, which means now.
- **`access_recommendation_enabled`** — the recommendation helpers are ID Governance licensed, and
  guest add-on enforcement from January 2026 specifically blocks guest-scoped reviews that use the
  affiliation recommendation helper. Staying off keeps this inside P2. `acceptAccessRecommendation`
  as a `timeout_behavior` is rejected for the same reason: it would depend on a feature that is off.

**`Manager` is rejected** because it reviews against the requestor's manager attribute, which B2B
guests almost never have populated. With no manager there is no reviewer, so every campaign runs to
its timeout and `timeout_behavior` becomes the only outcome — governance on paper, nothing enforced.

**Adding, changing or removing a review is an in-place update.** The resource implements
UpdateContext and marks nothing ForceNew, so no assignment is dropped and nobody loses access. What
*is* lost on removal is the review campaign and its history, which is the audit trail.

### The review-must-be-shorter-than-the-assignment rule

The most important validation in this feature. A review that recurs less often than the assignment
lasts never runs against a live assignment: the assignment expires first, the campaign opens with an
empty subject list, and the configuration reads like recurring governance while enforcing nothing.

Enforced per package: `assignment_duration_days` must be **greater than** the review interval.
Approximate intervals — weekly 7, monthly 30, quarterly 90, halfyearly 180, annual 365. Exactness
does not matter; the failure mode does.

There are two failures here with the same cause and different fixes, so they get separate messages.
The second is the interesting one:

**The cross-repo case.** For `pim_for_groups` roles the assignment duration is already capped by
`max_assignment_days`, derived from `active_assignment_expire_after` in the vending configuration. So
a scope whose PIM policy says `P15D` **cannot** carry a quarterly review — the two constraints are
unsatisfiable together, and no amount of editing this repo fixes it. The error says so and names the
role:

> Package X has a quarterly review but its assignment duration is capped at 15 days by role Y's PIM
> policy. Either review more frequently, or raise `active_assignment_expire_after` for that role in
> the access-vending configuration — which lengthens standing eligibility in exchange for the review
> becoming the recurring control.

That second option is a real trade, not a formality: you are choosing between a short automatic
expiry and a longer window with a periodic human affirmation. And the fix is in the *other* repo's
tfvars, which an operator hitting this has no reason to guess.

### Removed inputs

`manage_pim_for_groups_roles`, `acknowledge_m3_active_membership`, and `grant_approver_group`
(on both `defaults` and a package) are gone. All three are still declared, so setting one fails
with an explanation of what replaced it rather than a bare "unsupported argument".

| Removed | Why | Replacement |
|---|---|---|
| `manage_pim_for_groups_roles` | There is no EligibleMember downgrade left to opt into | none needed |
| `acknowledge_m3_active_membership` | The security regression it guarded no longer exists | none needed |
| `grant_approver_group` | Meaning changed from per-package to per-scope | `approver_packages` |

---

## Outputs

| Output | Purpose |
|---|---|
| `manual_steps_required` | What Terraform could not do, with the portal path. **Read this before believing an apply.** |
| `excluded_resource_roles` | Per-group detail behind the above |
| `catalogs` | Label → ID, display name, created-or-adopted, standing delegation |
| `packages_by_catalog` | Which packages landed in which catalog. Security-relevant: a catalog is a delegation boundary |
| `granted_groups_by_package` | What each package grants. For `pim_for_groups`, both the plain group and the PIM-managed group it confers eligibility on |
| `packages` | Per package: `kind` (`access` / `approver`), source, scope, catalog, declared vs attached vs excluded roles |
| `approver_packages` | **Scope → the package granting peer-approval rights over it** |
| `unpackaged_roles` | **Roles the contract vended that no package grants** — access nobody can request |
| `gate_1_approvers` | Per package, both kinds, the systemeier as named approvers |
| `gate_2_approvers` | Repo 1's activation facts, republished, with `attached_group` and `activation_group` per role |
| `peer_approval_status` | Per scope: the approver package, and where the deadlock remains |
| `access_reviews` | Per package: effective review settings, resolved reviewer UPNs, and `deployed` |
| `access_reviews_configured_not_deployed` | **Packages with review settings while the master switch is off** |
| `verification_summary` | Grouped by kind, plus totals. **The output that confirms the split landed**. Includes review frequency per package |
| `scopes`, `access_package_ids`, `assignment_policy_ids`, `effective_policies`, `contract_version` | |

`packages`, `access_package_ids`, `assignment_policy_ids`, `effective_policies` and
`gate_1_approvers` cover **both kinds**. Use the `kind` field rather than matching on the
`-approvers` name suffix.

`unpackaged_roles` is always empty on the default path, since the generated per-scope
packages cover every role. Non-empty means repo 1 created a group, an RBAC binding and a
PIM policy for access that cannot be requested — either a deliberate omission or a
forgotten `role_keys` entry. Reported rather than assumed either way.

---

## The approver package split

Approval rights are a **separate package** from the access. Previously the approver group was a
resource role on the access package, added when `grant_approver_group` was true, which welded
two unrelated rights together:

- everyone who requested the access automatically became a peer approver
- nobody could hold approval rights without also holding the access

Now:

```
request access package    → systemeier approve → hold / activate the access
request approver package  → systemeier approve → can approve other people
```

Two independent grants, two independent expiries, and the approver population is no longer
forced to equal the requester population. In practice the approver package usually gets a much
longer duration than the access it governs — approval authority is an ongoing responsibility
rather than a task.

**Gate 1 on an approver package is always the systemeier, never the approver group.** This is
load-bearing, not a convenience: if the group approved requests for its own membership, the
approver population would be self-perpetuating with no authority outside it. The chain has to
terminate somewhere, and the systemeier are the right place because they are named in the
contract and are not themselves vended by this system.

Both kinds share all the resource wiring — one `module "access_package"` call over a merged map
keyed on package name, with a `kind` of `"access"` or `"approver"`. They differ only in which
resource roles go in. `verification_summary` reports them separately, because it is the output
people read to confirm the split actually landed.

The catalog association for the approver group is keyed `"{catalog}|{scope}--approvers"`,
unchanged from when it was a resource role on the access package, so it is reused rather than
recreated.

---

## The EligibleMember gap (historical)

**No longer applies under contract v2.** Kept here because the mechanism explains why
`excluded_resource_roles` still exists and why it should now be empty.

`azuread_access_package_resource_package_association.access_type` is validated client-side to
`Member` and `Owner` only. The Entra platform offers "Eligible Member" in the portal for
PIM-managed groups; the sole barrier is a `StringInSlice` allowlist on the provider's schema
field.

Under contract v1 that mattered enormously for `pim_for_groups` roles. Attaching one as `Member`
would make the user an **active** member the moment the assignment landed — standing access to
AWS instead of activating through PIM. It applied cleanly, looked correct, and nothing failed. So
this module excluded those roles, registered their catalog resource anyway, and reported the
portal step.

**Contract v2 sidesteps it.** Repo 1 creates a plain group per `pim_for_groups` role and makes it
an eligible member of the PIM-managed group, so the package attaches plain `Member` on a plain
group and the user still activates through PIM. No provider limitation is involved any more.

The exclusion machinery is still here, and still keyed off the *value* of `access_type` rather
than `jit_mechanism`. It is now a guard rather than a workflow: if a contract ever asks for an
access type the provider cannot set, it is caught and reported instead of applied wrongly.
`excluded_resource_roles` should be empty, and an empty map is the useful signal — it is what you
read to confirm nothing is being left out.

**Licensing is worth re-testing.** Eligible group membership *in access packages* is the feature
documented as requiring Entra ID Governance or Entra Suite. This design no longer uses it: it uses
plain `Member` plus PIM for Groups. That **may** make it work on a P2-only tenant where the
previous design could not. Treat that as a hypothesis to test with
`scripts/verify-entitlement-management.sh`, not as a claim — nobody here has confirmed it.

---

## The expiry ceiling

If a package assignment outlives the PIM-managed group's eligible-assignment expiry, PIM expires
the eligibility while Entitlement Management still lists the user as assigned. Under contract v2
the user keeps membership of the plain carrier group and silently loses the ability to activate.
Nothing errors, and their own MyAccess page contradicts what they can do.

Repo 1 emits the ceiling as `max_assignment_days`, a number, so **nothing here parses ISO-8601**.
It comes from the **PIM-managed** group's `active_assignment_expire_after`, not from the plain
group the package attaches — the plain group has no PIM policy of its own.

Enforced per package as a plan-time precondition: `assignment_duration_days` must be at or below
the minimum non-null `max_assignment_days` across **the roles that package grants**. The error
names the role that set the binding ceiling, because the ceiling comes from one role's PIM policy
and the operator needs to know which.

Per package, not per scope, and that is a concrete benefit of named packages: an engineers
package holding only reader and contributor is not constrained by an owner role it does not
grant. On the per-scope path every package in a scope inherited the shortest ceiling in it.

Approver packages have no ceiling. The approver group is a plain group with no PIM policy, so
there is no eligibility expiry for the assignment to drift against.

---

## Preconditions

Every guard is a `terraform_data` `precondition`. A `check` block reports and lets the apply
proceed, which is wrong for every failure mode here: they all end with a successful apply and
something subtly wrong in the portal.

| Precondition | Catches |
|---|---|
| `validate_configuration` | Unknown catalog label, unknown `package_overrides` key, `approver_packages` naming a scope with no approver group, a scope naming a catalog missing from `contract.catalogs`, a catalog label containing `\|` |
| `validate_packages` | Unknown role key; a `packages` name colliding with a generated approver package name; a package spanning scopes; an unknown catalog on a package; a package granting nothing |
| `validate_gate_1_approvers` | A scope with no systemeier, whose requests time out forever |
| `validate_assignment_expiry_ceiling` | The expiry drift above |
| `validate_no_duplicate_catalog_resources` | Two scopes sharing an approver group inside one catalog |
| `validate_peer_approval_viability` | An approver package disabled on a scope with a lone systemeier |
| `validate_access_reviews` | Invalid frequency / type / timeout; `Manager` reviews; `acceptAccessRecommendation`; an incomplete review block; `Reviewers` with no systemeier; **a review interval that the assignment cannot outlive**, split into the local case and the cross-repo case |

`validate_packages_grant_something` is folded into `validate_packages` and stays **strict**.
Under contract v2 nothing is excluded for provider reasons, so an all-`pim_for_groups` scope's
package grants real memberships rather than nothing — relaxing the check would only hide a
genuinely empty package.

### Why the association keys are what they are

A catalog resource association is unique per `(catalog, group)`, and they are keyed on
`"{catalog}|{role_key}"`.

Before named packages, keying on the role key alone was *already* keying on
`(catalog, group)`: a role belongs to one scope, a scope sits in one catalog, so
role → catalog was 1:1. A per-package `catalog` breaks that. Two packages in **different**
catalogs can now share a role, and that legitimately needs **two** associations, one per
catalog — which a role-keyed map cannot represent. It would create one, and the second
package's resource association would fail at **apply**, not at plan.

Two packages in the **same** catalog sharing a role is the other direction: one catalog
association, two package associations. The composite key is identical for both, so they
collapse to a single entry, which is exactly right — and is already how the approver group
attaches to several packages.

A catalog label containing a literal `|` would make two different `(catalog, role)` pairs
collide on one key, so that is rejected in `validate_configuration` rather than silently
mis-keyed.

Approver groups need one more guard. `approver_group_name` may point at a group repo 1 does
not manage, and two scopes could share it. Sharing across *different* catalogs is legitimate
and must produce two associations. Sharing inside the *same* catalog is a duplicate, and the
provider reports it at apply, partway through, with resources already created.
`validate_no_duplicate_catalog_resources` turns that into a plan failure.

---

## Peer approval and the self-approval deadlock

Repo 1 seeds each approver group with its `systemeier`, so dual-approval roles work on the first
apply. But PIM blocks self-approval, so a group with exactly one member cannot approve that
member's own request — the request times out after 24 hours, a timeout nobody can configure.

The **approver package** is what resolves that: it lets additional people be granted approval
rights without also being granted the access. So the viability test is whether the scope has an
approver package, not whether some access package happens to attach the group.

`peer_approval_status` reports it per scope:

| Field | Meaning |
|---|---|
| `has_approver_group` | the contract gave this scope an approver group |
| `approver_package` | the single package that grants it, or `null` if opted out |
| `viable` | an approver package exists, so peers can be added |
| `deadlock_risk` | fewer than two systemeier **and** no approver package |

An approver package is created for every scope with an approver group by default, so
`deadlock_risk` can only become true if one was explicitly disabled with
`approver_packages = { "<scope>" = { enabled = false } }`. That combination fails the plan rather
than shipping a scope whose dual-approval roles nobody can activate.

Note what the split changed here. Previously the fix was "attach the group to an access package",
which meant granting the access to get the approval right. Now the two are independent, so the
junior/senior distinction is purely about **access tiers**, and whether someone can approve is a
separate grant that either tier's holders may or may not have.

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
  }

  # Optional. Omit for one package per scope with every role in it.
  packages = {
    "prod-engineers" = {
      display_name = "Prod Engineer Access"
      role_keys    = ["prod--reader", "prod--contributor"]
    }
    "prod-admins" = {
      display_name             = "Prod Admin Access"
      role_keys                = ["prod--reader", "prod--contributor", "prod--owner"]
      assignment_duration_days = 7
    }
  }

  # Optional. One approver package per scope with an approver group is created anyway; this
  # only deviates from the defaults. Longer than the access it governs, because approval
  # authority is an ongoing responsibility rather than a task.
  approver_packages = {
    "prod" = {
      display_name             = "Prod Approver Rights"
      assignment_duration_days = 90
    }
  }

  package_overrides = {
    "tenant" = { assignment_duration_days = 7 }
  }

  # Recurring reviews. Off by default; drive this from a pipeline checkbox. Presence of an
  # access_reviews block on a package is what selects it — there is no per-package enabled flag.
  enable_access_reviews = true
}
```

A package that carries a review needs an assignment duration **longer** than the review interval,
which usually means longer than a package without one:

```hcl
packages = {
  "prod-admins" = {
    role_keys = ["prod--reader", "prod--contributor", "prod--owner"]

    # 120 > 90, so the quarterly campaign runs against a live assignment.
    assignment_duration_days = 120

    access_reviews = {
      review_frequency = "quarterly"
      review_type      = "Reviewers"
      duration_in_days = 14
      timeout_behavior = "removeAccess"
    }
  }
}
```

Pin tags, never branches. This module derives its whole package set from the contract, so with
a floating ref a module change and a taxonomy change land in the same plan with nothing to
tell them apart.

Runnable variants: `examples/two-module-root` (the shape above), `examples/complete` (literal
contract fixture, local state, the default one-package-per-scope path) and
`examples/named-packages` (the same fixture with several tiers per scope).

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

Provider constraints here are `>=` so the module never becomes a version ceiling. Only roots
pin, to patch level, and no lock file is committed. `azurerm` is absent entirely: this module
touches no ARM resources.

---

## Future direction: cross-scope personas

Named packages already deliver job-function packaging *within* a scope — junior, senior,
read-only, admin — driven entirely by this repo's variables, touching repo 1 not at all.

What remains is personas that span **several** scopes: one package granting prod-reader and
staging-contributor together. That is blocked on the gate 1 question above, not on the
resource wiring, which already keys on package name and would need no change. When it lands,
`package_scope` in `locals.tf` stops being single-valued and gate 1 needs the union plus an
explicit acknowledgement that a scope owner can then approve entry to another scope.

Repo 1 stays out of it either way. Azure keys `azurerm_role_management_policy` on
(ARM scope, role definition), so there is one activation policy per role per subscription:
two groups eligible for Contributor on the same subscription would share it, and duplicating
the role buys no extra governance. Only the packaging layer can differentiate audiences.
