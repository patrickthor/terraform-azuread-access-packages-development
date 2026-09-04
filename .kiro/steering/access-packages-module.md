---
inclusion: always
---

# Repo 2 — access-packages

Read `identity-governance-contract.md` first. This file covers only what is local to this
repo.

## What this repo owns

Catalogs, access packages, their resource roles, and their assignment policies —
**gate 1**. It makes repo 1's grants requestable and decides *who* can receive them.

## What this repo must never do

- Create a group, or write a group name or a scope key anywhere in its source. Every name
  and every key comes from `var.vending`.
- Reimplement gate 2. Repo 1's `approval_type`, MFA and activation-duration rules are
  republished in an output and interpreted nowhere.
- Default a missing `access_type` to `Member`. That is the one silent failure that turns
  just-in-time eligibility into standing cloud access. A missing key is fatal.
- Read a remote state. The module takes a typed object; the root decides where it comes
  from.
- Parse ISO-8601. Repo 1 emits `max_assignment_days` as a number.

## Changes to land for the two-module contract

The draft is structurally right — one catalog, one package per scope, derivation from repo
1, `terraform_data` preconditions, two flags on the `EligibleMember` downgrade. What
changes is the input surface and catalog support.

### 1. Replace the twelve-map `vending` input with the contract object

Take `contract_version`, `roles`, `scopes`, `catalogs` as defined in the shared file.

**Delete all eight cross-map key-consistency validations.** They exist only because the
contract was scattered across separate outputs — a key cannot be present in one map and
absent from another when there is one map. Keep exactly three:

```hcl
validation {   # version compatibility, named both ways round
  condition     = var.vending.contract_version == 1
  error_message = "..."
}
validation {   # composite key shape, since scope is derived by splitting
  condition     = alltrue([for k in keys(var.vending.roles) : length(split("--", k)) == 2])
  error_message = "..."
}
validation {   # non-empty, with the "repo 1 has not applied" hint
  condition     = length(var.vending.roles) > 0
  error_message = "..."
}
```

Everything else the old validations checked is now a type error, which is a better error.

**Never wrap a contract field in `try()`.** The draft's root does this for the gate-2
passthrough fields. Under the contract those fields are required and `contract_version`
is what handles compatibility. A `try()` around a contract field is how a missing
`access_type` becomes standing access.

### 2. `for_each` on the plan-safe iteration sources

Use `var.vending.catalogs`, `var.vending.scopes`, `scopes[*].role_keys` and
`catalogs[*].scope_keys`. They exist specifically so key sets provably come from
configuration rather than from repo 1's resource attributes. Do not replace them with
`distinct([for k in keys(...) : split("--", k)[0]])` — that works today and is one repo-1
refactor away from breaking the plan.

### 3. Catalogs

One catalog per distinct label in `var.vending.catalogs`. The label is the key; the
display name is configurable per label and defaults to the label.

```hcl
variable "catalogs" {
  description = <<-EOT
    Per-catalog settings, keyed on the catalog LABEL from repo 1's contract.

    Every key is optional — a label with no entry here gets the defaults, so the simple
    case needs no configuration at all. A key that does not appear in the contract is
    rejected, because an override with no effect is the accepted-and-ignored pattern this
    project refuses.
  EOT

  type = map(object({
    display_name         = optional(string)
    description          = optional(string)
    externally_visible   = optional(bool, false)
    published            = optional(bool, true)

    # Adopt an existing catalog instead of creating one. Real customers usually have a
    # catalog already, owned by an identity team that will not hand over creation rights.
    adopt_existing       = optional(bool, false)

    # Make each contained scope's systemeier a catalog role holder, so package management
    # is delegated to the people who already approve gate 1. Off by default: it is a
    # standing grant, and standing grants are this project's default no.
    delegate_to_systemeier = optional(bool, false)
    systemeier_catalog_role = optional(string, "Access package manager")
  }))

  default = {}
}
```

- `adopt_existing = true` uses `data.azuread_access_package_catalog` and creates nothing.
  Everything downstream is identical; only the catalog ID source changes.
- `delegate_to_systemeier` uses `azuread_access_package_catalog_role_assignment` with
  `data.azuread_access_package_catalog_role`. `Access package manager` is the right
  default over `Catalog owner`: a catalog owner can add arbitrary resources, which routes
  around repo 1 entirely.
- Reject unknown keys in a `terraform_data` precondition, naming the known labels.
- `externally_visible` stays `false` by default. Every scope in this system grants cloud
  access and none of it is meant for guests.

### 4. Packages stay one-per-scope

An access package grants everything in it atomically, so its natural unit is "membership
of the team that works on this scope", not "one individual permission". That works because
repo 1's groups are PIM-managed: membership is not privilege, activation is. A package can
say "you belong here, here is your baseline plus your escalation paths" and PIM still
gates each escalation.

A package belongs to the catalog of its scope's label. Packages in different catalogs never
share resource associations, because a catalog resource association is unique per
`(catalog, group)` — so the associations must be keyed on `(catalog, group)`, not on group
alone. **This is the one place catalog support changes existing code**, and getting it
wrong produces a duplicate-association failure at apply, not at plan.

Keep the associations in the wrapper module rather than the leaf. They are unique per
`(catalog, group)`, and under peer approval the same approver group attaches to several
packages in the same catalog.

Persona packages spanning several scopes are a later extension. When they land, they are
driven by *this* repo's variables and touch repo 1 not at all. The resource wiring
survives; only the scope→package mapping changes.

### 5. Delete `m3_max_duration_days`

Read `var.vending.roles[*].max_assignment_days` instead. The precondition becomes: for
each package, `assignment_duration_days` must be `<=` the minimum non-null
`max_assignment_days` across the roles it grants. Name the offending role in the error, not
just the scope — the ceiling comes from one role's PIM policy and the operator needs to
know which.

## Keep these from the draft

- **`terraform_data` + `precondition`, not `check`.** Every failure mode here is invisible
  by default, so warn-and-continue is wrong.
- **The two-flag `EligibleMember` downgrade.** `manage_pim_for_groups_roles` plus
  `acknowledge_m3_active_membership`. Two flags because the failure shows up in neither
  plan nor portal.
- **Register excluded groups as catalog resources anyway.** Registration is access-type
  agnostic, so it costs nothing and reduces the manual portal step to picking
  "Eligible Member" on an already-registered resource.
- **The empty-package precondition.** A package with no resource roles is still
  requestable and still approvable, so it shows up in MyAccess as working access while
  granting nothing. That is worse than the package not existing.
- **The peer-approval precondition.** Repo 1 seeds each approver group with its
  `systemeier`, PIM blocks self-approval, so a scope with exactly one systemeier cannot
  activate its own `dual` role and the request times out after 24 hours — a timeout nobody
  can configure. `grant_approver_group = true` (default on) attaches the approver group to
  the package, making everyone in the scope a peer approver.
- **`excluded_resource_roles` and `manual_steps_required` as outputs.** A green apply says
  nothing about the parts Terraform cannot express. Reading them is a step in the runbook,
  not a footnote.

## Outputs

Repo 2's outputs are the verification surface for the whole system, since it is the last
module to run.

| Output | Purpose |
|---|---|
| `manual_steps_required` | What Terraform could not do, with the portal path. Read this before believing an apply. |
| `excluded_resource_roles` | Per-group detail behind the above. |
| `catalogs` | Label → catalog ID, display name, created-or-adopted. |
| `packages_by_catalog` | Which packages landed in which catalog. The catalog is a delegation boundary, so this is a security-relevant listing. |
| `granted_groups_by_package` | What each package actually grants, after exclusions. |
| `gate_1_approvers` | Per package, the systemeier acting as named approvers. |
| `gate_2_approvers` | Repo 1's activation rules, republished verbatim. |
| `peer_approval_status` | Where the single-systemeier deadlock is resolved and where it is not. |
| `verification_summary` | One line per package for reading a plan quickly. |

## Licensing — verify before building further

Eligible group membership in access packages requires **Entra ID Governance or Entra
Suite**, not P2 alone. `scripts/verify-entitlement-management.sh` is the probe. Record the
answer in the README table, because it changes what is worth building:

- If catalogs work but eligible resource roles are rejected at the platform level, the
  provider allowlist is not the blocker and neither the `msgraph` spike nor the portal
  workaround helps.
- If eligible roles do work in the portal, the provider allowlist is the only barrier and
  the `msgraph` path is worth the spike.

Leave the "Verified in this tenant" table in the README, and leave the rows blank until
they are actually verified. A blank row is an honest unverified claim; a filled-in row that
nobody tested is not.

## The riskiest package

A scope handing out `entra_role` — `Groups Administrator` in particular — is the most
dangerous thing this system can produce. That role can manage membership in every
non-role-assignable group in the tenant, which is *all* the `azure_pim` and
`pim_for_groups` groups repo 1 creates, and rewrite their PIM policies. Terraform can set
no activation rules for it, so **gate 1 is the only gate Terraform enforces** and one
systemeier approval is the entire control.

Mitigations that belong here: the shortest `assignment_duration_days` of any package, its
own catalog so it is visible in a listing, and `manual_steps_required` naming the portal
rules to set by hand. Splitting a harmless `Directory Readers` role out of the same package
as `Groups Administrator` is a defensible further step.
