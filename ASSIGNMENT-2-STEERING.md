# Assignment 2 — Access Packages Repo: Steering Document

> **How to use this file.** Copy it into the access-package repo as
> `.kiro/steering/access-packages.md` (front matter `inclusion: always`), or paste
> it into the agent as the opening brief. It is written to be self-contained:
> everything the agent needs to know about the contract, the traps, and the
> acceptance criteria is here. Nothing should need to be inferred from repo 1.

---

## 1. What this repo does

This repo (**repo 2**) defines **WHO can get access**. It creates the access
package catalog, the access packages, and the request/approval policies.

Repo 1 (**access-vending**) defines **WHICH access grants exist**. It has already
created the Entra groups, the Azure RBAC bindings, and the PIM activation
policies. It grants no humans access.

```
access-vending  (repo 1, DONE)              access-packages  (repo 2, THIS REPO)
──────────────────────────────              ──────────────────────────────────
WHICH access grants exist                   WHO can receive them
group + role binding + PIM policy           catalog + access package + policy
                        │                            │
                        └────── group name ──────────┘
                                (the contract)
```

**Repo 2 never creates groups.** It looks up existing groups by `display_name`
using `data "azuread_group"` and attaches them to access packages as resource
roles.

---

## 2. Read this first — two confirmed blockers

Both were verified against provider docs and Microsoft Learn on 2026-08-17. Do
not start building until you have decided how to handle them.

### 2.1 BLOCKER — The Terraform provider cannot set `EligibleMember`

Repo 1 outputs `access_package_access_type` telling you which access type to use
per group. For `pim_for_groups` roles (M3 — AWS/GCP/GitHub) it returns
`"EligibleMember"`.

**The provider does not support that value.**

`azuread_access_package_resource_package_association` has:

```
access_type - (Optional) The role of access type to the specified resource.
              Valid values are `Member`, or `Owner`. The default is `Member`.
```

Source: [provider docs, azuread v3.9.0](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/access_package_resource_package_association).
Content was rephrased for compliance with licensing restrictions.

The Entra **platform** does support it — Microsoft Learn confirms that for
PIM-managed groups, "Eligible Member" and "Eligible Owner" appear as selectable
resource roles in the portal. The gap is in the Terraform provider, not the
platform.

**Why this matters:** if you attach an M3 group with `access_type = "Member"`,
the user becomes an **active** member of the group immediately on assignment.
That defeats the entire JIT model — they get standing access to AWS instead of
having to activate through PIM. It will apply cleanly and look correct. Nothing
will fail.

**Options, in order of preference:**

| # | Approach | Trade-off |
|---|---|---|
| 1 | Handle M2 + M4 in Terraform (`Member` is correct there), do M3 resource roles manually in the portal | Honest split. M3 is not IaC, but nothing lies. |
| 2 | `azapi`/`restapi` or `local-exec` with `az rest` against the Graph `accessPackageResourceRoleScope` endpoint | Full IaC, but third-party provider or fire-and-forget |
| 3 | Skip M3 in repo 2 for the POC; test M2/M4 end-to-end only | Smallest scope, defers the problem |

**Do NOT** silently use `Member` for M3 groups and move on. If you take option 1
or 3, add an output that lists which groups were deliberately left out, so the
gap is visible in `terraform output` and not just in a comment.

### 2.2 BLOCKER — Licensing: Entitlement Management may need Governance, not just P2

Microsoft Learn states that using PIM for Groups with access packages
"requires Microsoft Entra ID Governance or Microsoft Entra Suite licenses."
Content was rephrased for compliance with licensing restrictions.

The POC tenant has **P2 only** — no Governance add-on. Verify on day one:

```bash
# Can you create a catalog at all?
az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs"
```

If catalog creation works but eligible-member resource roles are rejected, that
narrows blocker 2.1 to a licensing problem rather than a provider problem.
Report which it is before building further.

---

## 3. The contract from repo 1

### 3.1 How to consume it

Repo 1 writes its state to an Azure Storage backend. Two options:

**Option A — `terraform_remote_state` (tighter coupling, always current):**

```hcl
data "terraform_remote_state" "vending" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.state_resource_group_name
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "access-vending.tfstate"
    use_azuread_auth     = true
  }
}

# then:
data.terraform_remote_state.vending.outputs.group_names
```

**Option B — `data "azuread_group"` on the name (looser coupling, recommended):**

```hcl
data "azuread_group" "role_groups" {
  for_each     = var.access_scopes_flattened
  display_name = each.value.group_name
  # security_enabled = true   # optional guard
}
```

**Recommendation: Option A (remote state).** This is a reversal of an earlier
draft that recommended Option B — here is the reasoning, because it matters.

Option B (name lookup) sounds looser and safer, but it has a hidden cost: to look
a group up by name, repo 2 must independently know every scope key and role key.
That means repo 2 keeps its own copy of the taxonomy — the exact duplication you
want to avoid. Add a role in repo 1, forget it in repo 2, and it silently has no
access package. You get loose coupling **or** no duplication, not both.

Option A makes repo 1's state the single source of truth. Repo 2 iterates over
`group_names` and never re-declares the scope/role list. It also turns the
apply-order rule (trap 6.2) from a documented convention into a hard failure:
repo 2 physically cannot plan until repo 1's state exists.

The cost is real but acceptable: repo 2 needs `Storage Blob Data Reader` on repo
1's state storage account, and the two repos are coupled through the state file
layout. For a POC where both repos share one deploy identity anyway (see 6.5),
that coupling is already there.

Everything in the rest of this document — including the systemeier approver
wiring in 3.4 and the tfvars split in 5.3 — assumes Option A.

### 3.2 The composite key

Repo 1 keys most of its map outputs on `{scope_key}--{role_key}`. The `--`
separator is reserved and validated out of both scope keys and role keys, so it
is safe to split on.

```
"tommer--contriband"  →  scope "tommer", role "contriband"
```

**Approver group outputs are keyed on `scope_key` alone**, not the composite —
because one approver group serves all roles under a scope.

### 3.3 Full output reference

| Output | Keyed on | What it gives you | Use in repo 2? |
|---|---|---|---|
| `group_names` | composite | Group `display_name`. **The primary contract.** | **YES** — lookup key |
| `group_object_ids` | composite | Entra object IDs | YES — `resource_origin_id` |
| `access_package_access_type` | composite | `Member` or `EligibleMember` | **YES** — see 2.1 |
| `access_model` | composite | `permanent` / `eligible` / `eligible_member` | Useful for policy duration |
| `jit_mechanism` | composite | `azure_pim` / `pim_for_groups` / `entra_role` | YES — branch logic |
| `approver_group_names` | **scope** | Approver group per scope | **YES** — approval + peer model |
| `approver_group_object_ids` | **scope** | Object ID per approver group | **YES** — `primary_approver` |
| `approver_group_is_managed_here` | **scope** | `false` = group lives outside vending | Sanity check |
| `approvers_by_role` | composite | Who approves what, derived (`approval_type`, `systemeier_approves`, `approver_group`) | **YES** — approval branching |
| `systemeier_by_scope` | **scope** | System owner UPN list per scope | **YES** — named request approvers, see 3.6 |
| `permanent_roles` | list | Roles with permanent binding | Reference |
| `jit_roles` | list | Roles requiring activation | Reference |
| `activation_settings` | composite | **Requested** activation rules, not effective | Reference only |
| `azure_role_assignment_scopes` | composite | ARM scope. M2 only | Reference |
| `azure_activation_policy_ids` | scope | Policy ID per `{scope}\|{role}` | Not needed |
| `pim_group_policy_ids` | composite | M3 policy IDs | Not needed |
| `target_cloud_bindings` | composite | SCIM work list. M3 only | Reference |
| `entra_role_template_ids` | composite | `roleDefinitionId`. M4 only | Not needed |
| `entra_role_object_ids` | composite | Activated role object ID. M4 only | Not needed |
| `entra_activation_governance_gap` | composite | What repo 1 cannot manage for M4 | **READ IT** |
| `demo_eligibility_schedules` | composite | Should be empty | Sanity check |
| `access_summary` | list | One line per role, human-readable | Debugging |

### 3.4 `access_package_access_type` — the mapping repo 1 applies

| `jit_mechanism` | Value returned | Why |
|---|---|---|
| `azure_pim` (M2) | `Member` | Membership is **active**; the user activates the *role* in PIM for Azure Resources |
| `pim_for_groups` (M3) | `EligibleMember` | The access package makes them **eligible**; they activate the *membership* |
| `entra_role` (M4) | `Member` | Membership is **active**; the directory *role* is what gets activated in PIM |

Only M3 needs `EligibleMember`. M2 and M4 both want `Member`, which the provider
supports. That is why option 1 in section 2.1 is viable.

### 3.5 Wiring approvers — and the two-gate distinction

Repo 1 tells you **who** approves, so repo 2 does not re-declare it. Three
outputs combine:

- `approvers_by_role[key].approval_type` — `self` / `owner` / `dual` (or
  `"not managed by Terraform"` for M4). If `self`, emit no `approval_settings`.
- `approvers_by_role[key].systemeier_approves` — `true` when `owner` or `dual`.
- `systemeier_by_scope[scope]` — the actual UPNs to resolve with
  `data "azuread_user"` and add as `singleUser` primary approvers.
- `approver_group_object_ids[scope]` — the approver group, added as
  `groupMembers` when `approval_type == "dual"`.

```hcl
locals {
  v = data.terraform_remote_state.vending.outputs

  # Resolve systemeier UPNs to object IDs, per scope
  systemeier_upns = toset(flatten([for s in values(local.v.systemeier_by_scope) : s]))
}

data "azuread_user" "systemeier" {
  for_each            = local.systemeier_upns
  user_principal_name = each.value
}
```

Then in the assignment policy, exactly as sketched in 5.4, add the systemeier as
`singleUser` approvers when `systemeier_approves` is true, and the approver group
as `groupMembers` when `approver_group` is non-null.

**THE TWO GATES.** There are two separate approval points in a user's journey, and
they answer different questions:

```
request package → [GATE 1: repo 2 assignment policy] → assigned/eligible
                → activate in PIM → [GATE 2: repo 1 PIM policy] → active access
```

| | Gate 1 — request the package | Gate 2 — activate a role |
|---|---|---|
| Question | *Should this person have access to this scope?* | *Should they hold contributor right now?* |
| Approver | the scope's **`systemeier`** | per-role `approval_type`: systemeier and/or approver group |
| Source | `systemeier_by_scope[scope]` | `approvers_by_role[composite]` — already built |
| Owned by | **repo 2** | repo 1 ✓ |

**This is the settled design:** `systemeier` scopes who may enter a package;
`approval_type` on individual roles governs privilege elevation within it. Because
a package maps to exactly one scope, gate 1 is a direct lookup — no merging across
scopes needed.

That changes if you later move to personas spanning several scopes (see 5.2). Then
a package inherits several `systemeier` lists and you must decide between a union,
a nominated owning scope, or `requestorManager`. Not a problem today.

### 3.6 Current groups in the POC tenant (14)

Verified against the tenant. Use these exact names.

| Group | Scope | Mechanism | `access_type` | Notes |
|---|---|---|---|---|
| `azure-tommer-readingbooks` | tommer | azure_pim | `Member` | Permanent Reader |
| `azure-tommer-contriband` | tommer | azure_pim | `Member` | Contributor, eligible, `dual` |
| `azure-tommer-master` | tommer | azure_pim | `Member` | Owner, eligible, `dual`, MFA |
| `azure-morkanaught-reader` | morkanaught | azure_pim | `Member` | Permanent Reader |
| `azure-morkanaught-blob-leser` | morkanaught | azure_pim | `Member` | Storage Blob Data Reader, `self` |
| `azure-morkanaught-nettverksdrift` | morkanaught | azure_pim | `Member` | Network Contributor, `owner`, MFA |
| `aws-jaws-admin` | jaws | pim_for_groups | `EligibleMember` ⚠ | AdministratorAccess |
| `aws-jaws-readonly` | jaws | pim_for_groups | `EligibleMember` ⚠ | ReadOnlyAccess, `self` |
| `aws-jaws-billing` | jaws | pim_for_groups | `EligibleMember` ⚠ | Billing, `dual` |
| `entra-tenant-groupsadmin` | tenant | entra_role | `Member` | Groups Administrator, eligible |
| `entra-tenant-directoryreader` | tenant | entra_role | `Member` | Directory Readers, permanent |
| `azure-tommer-approvers` | tommer | — | n/a | **Approver group**, seeded with systemeier |
| `azure-morkanaught-approvers` | morkanaught | — | n/a | **Approver group**, seeded with systemeier |
| `aws-jaws-approvers` | jaws | — | n/a | **Approver group**, seeded with systemeier |

⚠ = affected by blocker 2.1.

`morkanaught` has **no** approver group because none of its roles use
`approval_type = "dual"`. `tenant` has none because `entra_role` has no
Terraform-managed approval at all.

---

## 4. The approval model

### 4.1 `approval_type` in repo 1 — three values

Repo 1 originally had four. `team` was removed. Current state:

| `approval_type` | Approvers in the PIM policy | Approver group created? |
|---|---|---|
| `self` | none — approval disabled | no |
| `owner` (**default**) | the `systemeier` list, as named users | no |
| `dual` | `systemeier` list **+** the scope's approver group | **yes** |

**Important:** the default is `owner`, **not** `self`. Omitting `approval_type`
means approval **is** required. Nobody gets unapproved access by accident.

**Naming trap:** `approval_type = "owner"` has nothing to do with Entra group
ownership. It means "the system owner approves". The systemeier are added as
explicit `primary_approver` entries — their group-ownership status is irrelevant.
The deploy service principal is the actual Entra owner of every group (see 6.3).

### 4.2 `dual` is one stage, not two

Both provider schemas cap `approval_stage` at `max_items = 1`. So with `dual`,
the systemeier **and** the approver group land in the **same** stage, and **one
signature from either pool is enough**. It is broader coverage, not stricter
control.

**If you need genuine two-stage sequential approval, it must live here in repo 2**
on `azuread_access_package_assignment_policy`. That resource supports
`approval_stage` blocks and — unlike the PIM policy resources — you can define
more than one. This is the one place two-step approval is actually achievable.

### 4.3 Peer approval — the intended model

The approver groups are **seeded with the `systemeier`** by repo 1, so `dual`
roles are activatable from the first apply. Beyond that seed, membership in an
approver group *is* the approval authority, and additional peers should be vended
through an access package like everything else.

The chosen model is **peer approval**: people who hold access to a scope can
approve each other's activation requests.

To implement it, one access package grants **two** memberships:

```
Access package "tommer team member":
  → azure-tommer-contriband     (the access)
  → azure-tommer-approvers      (the right to approve peers)
```

Alice activates `contriband` → Bob approves. Bob activates → Alice approves. PIM
blocks self-approval, so **at least two members are required** or everyone
deadlocks.

### 4.4 Excluding junior staff from approval

Same scope, two packages, different group combinations:

```
Access package "tommer senior":
  → azure-tommer-contriband     (access)
  → azure-tommer-approvers      (can approve)

Access package "tommer junior":
  → azure-tommer-contriband     (access)
  (no approver group)            (cannot approve anyone)
```

Juniors can request and activate; they never appear as an approver. Seniors
approve both each other and the juniors.

### 4.5 Guard against the self-approval deadlock

Repo 1 seeds each approver group with the scope's `systemeier`, so the group is
never empty and `dual` roles are activatable immediately. But **one member is not
enough**: an approver cannot approve their own request, so a lone systemeier
cannot activate their own `dual` role. The request sits until it times out.

PIM has **no default approvers** for `azure_pim` or `pim_for_groups`, and an
unapproved request times out after **24 hours** (not configurable).

In this tenant, `morkanaught` and `jaws` each have exactly one systemeier — so
their `dual` roles are currently un-activatable by that person alone. `tommer` has
two, so it works. Repo 2's packages should add peers to fix the other two.

**Exception worth knowing:** for `entra_role` (M4), active *Privileged Role
Administrator* and *Global Administrator* **do** become default approvers if
approval is required and none are set. That is the opposite of M2/M3. So "no
approval configured" does not mean "open role" for M4 — it means "approved by
tenant admins".

Recommended: seed the approver groups with at least two members via a direct
assignment policy before testing, or document it as a manual first step.

---

## 5. What to build

### 5.1 Repo structure

Mirror repo 1's shape so the two repos feel like siblings.

```
.
├── main.tf                    Thin passthrough → modules/access-packages
├── variables.tf               tenant_id + passthrough vars
├── outputs.tf                 Forwarded module outputs
├── providers.tf               azuread provider block
├── versions.tf                required_version >= 1.9, backend "azurerm" {}
├── backend.hcl.example
├── terraform.tfvars           Real values (gitignored)
│
├── modules/
│   └── access-packages/       ← THE CONSUMABLE MODULE
│       ├── main.tf            Catalog + per-package dispatch
│       ├── variables.tf       Type + validations
│       ├── outputs.tf
│       ├── versions.tf        NO provider blocks
│       ├── README.md
│       └── modules/
│           ├── access-package-catalog/
│           └── access-package/          One package + policy + resource roles
│
├── examples/
│   ├── complete/              Local state, all mechanisms
│   └── github-consumption/    Pinned git ref + CI
│
└── .github/workflows/deploy.yml
```

**Critical:** `modules/access-packages/` must have **no `provider` blocks**. That
is what allows callers to use `count`, `for_each`, and `depends_on` on it. Provider
config belongs in the root and in `examples/*/providers.tf`.

Unlike repo 1, you do **not** need `azurerm` at all — no `features {}` problem, so
the root can be genuinely thin.

### 5.2 The unit of a package: one per SCOPE

**One access package per scope. Not one per group.**

An access package grants **everything in it, atomically** — there is no menu. So a
package's natural meaning is "membership of the team that works on this scope",
not "one individual permission". Microsoft's own guidance maps packages to job
functions, not to single resources.

This works especially well here because repo 1's groups are PIM-managed.
Membership is not privilege — activation is. A package can therefore say "you
belong to this scope, here is your permanent baseline plus your escalation paths",
and PIM still gates each escalation with its own approval, MFA, and time limit.

The two gates divide cleanly:

| Gate | Decides | Approver | Owned by |
|---|---|---|---|
| 1 — request the package | *who belongs to this scope* | the scope's `systemeier` | repo 2 |
| 2 — activate a role | *what they may do right now* | per-role `approval_type` (repo 1) | repo 1 ✓ built |

**Consequence: repo 2 is fully derivable from repo 1's state.** There is no
persona map, no second list of scopes and roles to maintain. The package set is
`distinct(scope)` over `group_names`.

> **Future direction — personas.** Eventually packages will represent job
> functions that span *several* scopes: junior, senior, developer, security,
> non-technical stakeholder. At that point a package is no longer one-per-scope,
> it references composite keys across scopes, and repo 2 gains a persona map that
> genuinely cannot be derived from repo 1. Build one-per-scope now; the derivation
> code is the part that would be replaced, not the resource wiring.

### 5.3 Resources to create

| Resource | Cardinality (this tenant) | Purpose |
|---|---|---|
| `azuread_access_package_catalog` | 1 | Container for all packages |
| `azuread_access_package_resource_catalog_association` | **1 per group** (14) | Registers each group as a catalog resource. `resource_origin_system = "AadGroup"`, `resource_origin_id` = group object ID |
| `azuread_access_package` | **1 per scope** (4) | The requestable item |
| `azuread_access_package_resource_package_association` | **1 per group** (11–14) | Attaches groups to their scope's package. **`access_type` — see 2.1** |
| `azuread_access_package_assignment_policy` | 1 per package (4) | Who can request, who approves, how long |

Dependency chain: catalog → catalog_resource_association → access_package →
resource_package_association. The `resource_package_association` needs
`catalog_resource_association_id`, so the catalog association must exist first.
Terraform infers this if you reference the attributes directly.

The 11-vs-14 range on `resource_package_association` is the approver-group
question in 5.5.

### 5.4 The derivation

```hcl
locals {
  v = data.terraform_remote_state.vending.outputs

  # All 14 group names, keyed on composite "{scope}--{role}".
  # Approver groups are NOT in here — they are keyed on scope in a separate output.
  role_keys = keys(local.v.group_names)

  # One package per scope
  scopes = distinct([for k in local.role_keys : split("--", k)[0]])

  # Which composite keys belong to which scope
  roles_by_scope = {
    for s in local.scopes :
    s => [for k in local.role_keys : k if split("--", k)[0] == s]
  }
}

resource "azuread_access_package" "this" {
  for_each = toset(local.scopes)

  catalog_id   = azuread_access_package_catalog.this.id
  display_name = each.value
  description  = "Access to the ${each.value} scope"
}

# Register every group in the catalog
resource "azuread_access_package_resource_catalog_association" "this" {
  for_each = local.v.group_object_ids

  catalog_id             = azuread_access_package_catalog.this.id
  resource_origin_id     = each.value
  resource_origin_system = "AadGroup"
}

# Attach each group to its scope's package
resource "azuread_access_package_resource_package_association" "this" {
  for_each = local.v.group_names

  access_package_id               = azuread_access_package.this[split("--", each.key)[0]].id
  catalog_resource_association_id = azuread_access_package_resource_catalog_association.this[each.key].id
  access_type                     = local.v.access_package_access_type[each.key] # ⚠ blocker 2.1
}
```

Applied to the current tenant that yields:

| Package | Resource roles | Gate 1 approver | Gate 2 |
|---|---|---|---|
| `tommer` | readingbooks, contriband, master | patrick + edgar | `dual` → systemeier + `azure-tommer-approvers` |
| `morkanaught` | reader, blob-leser, nettverksdrift | patrick | `self` / `dual` → `azure-morkanaught-approvers` |
| `jaws` | admin, readonly, billing | patrick | `owner` / `self` / `dual` → `aws-jaws-approvers` |
| `tenant` | groupsadmin, directoryreader | patrick | **none** — see trap 6.7 |

**Validate rather than trust.** Every key you use must exist in `group_names`, so
a removed or renamed role fails the plan instead of silently producing a package
with a missing resource role:

```hcl
resource "terraform_data" "validate_keys" {
  lifecycle {
    precondition {
      condition     = length(local.role_keys) > 0
      error_message = "No groups found in repo 1's state. Has repo 1 been applied?"
    }
  }
}
```

### 5.5 Does the package also grant approver-group membership?

The one thing **not** derivable, because it is a policy choice rather than a fact
about repo 1.

Three scopes have `dual` roles and therefore approver groups:
`azure-tommer-approvers`, `azure-morkanaught-approvers`, `aws-jaws-approvers`.
Repo 1 seeds each with its `systemeier`, so `dual` works on first apply — but a
lone systemeier cannot approve their own request (see 4.5). `morkanaught` and
`jaws` have exactly one systemeier each, so their `dual` roles are currently
un-activatable by that person alone.

| Option | Effect | Trade-off |
|---|---|---|
| **A** — include the approver group as a resource role in its scope's package | Everyone in the scope becomes a peer approver | Gives peer approval automatically and fixes the one-approver problem. But with `dual`, one signature suffices — so any member could approve an `Owner` elevation |
| **B** — separate small package per scope for approver membership | Your future junior/senior split, available now | More packages; needs its own request policy |
| **C** — seed manually beyond the systemeier | Nothing to build | Undocumented state, drifts |

**Recommended: A for the POC, with B noted as the next step.** It makes the peer
model real, resolves the deadlock on `morkanaught` and `jaws`, and the
over-approval risk is exactly what the junior/senior split later fixes.

Under option A the `resource_package_association` count goes from 11 to 14, and
the extra three come from `approver_group_object_ids` (keyed on **scope**, not
composite):

```hcl
resource "azuread_access_package_resource_package_association" "approvers" {
  for_each = local.v.approver_group_object_ids # 3 entries: tommer, morkanaught, jaws

  access_package_id               = azuread_access_package.this[each.key].id
  catalog_resource_association_id = azuread_access_package_resource_catalog_association.approvers[each.key].id
  access_type                     = "Member"
}
```

### 5.6 Assignment policy fields worth setting

Gate 1 approval comes from `systemeier_by_scope[scope]`. Because a package maps to
exactly one scope, this is a direct lookup — no union or merging needed:

```hcl
locals {
  # Every systemeier UPN across all scopes, for the data lookup
  all_systemeier = toset(flatten(values(local.v.systemeier_by_scope)))
}

data "azuread_user" "systemeier" {
  for_each            = local.all_systemeier
  user_principal_name = each.value
}

resource "azuread_access_package_assignment_policy" "this" {
  for_each = toset(local.scopes)

  access_package_id = azuread_access_package.this[each.value].id
  display_name      = "Request access to ${each.value}"
  description       = "Approved by the systemeier for ${each.value}"

  duration_in_days = try(
    var.scope_overrides[each.value].assignment_duration_days,
    var.defaults.assignment_duration_days
  )

  requestor_settings {
    scope_type        = var.defaults.requestor_scope_type
    requests_accepted = true
  }

  approval_settings {
    approval_required                = true
    requestor_justification_required = var.defaults.require_justification

    approval_stage {
      approval_timeout_in_days        = var.defaults.approval_timeout_days
      approver_justification_required = true

      # The scope's systemeier, as named approvers
      dynamic "primary_approver" {
        for_each = local.v.systemeier_by_scope[each.value]
        content {
          object_id    = data.azuread_user.systemeier[primary_approver.value].object_id
          subject_type = "singleUser"
        }
      }
    }
  }

  question {
    required = true
    text {
      default_text = "Why do you need access to ${each.value}?"
    }
  }
}
```

`subject_type` values: `singleUser`, `groupMembers`, `connectedOrganizationMembers`,
`requestorManager`, `internalSponsors`, `externalSponsors`.

`requestorManager` is worth knowing about — manager approval needs no
configuration data at all. Not the default here, since you decided gate 1 belongs
to the systemeier, but useful if a package ever needs a second stage.

Gate 1 is also **the only place genuine two-stage sequential approval is
possible** — `approval_stage` is repeatable on this resource, unlike the PIM policy
resources repo 1 uses, which cap at one stage (repo 1's B3).

**Do not set `assignment_review_settings`.** Access reviews are out of scope (no
Governance add-on assumed) and short `duration_in_days` is the deliberate
substitute.

### 5.7 tfvars — defaults plus a short override list

There is no scope or role list here. That comes from repo 1's state. Repo 2's
tfvars holds only request-side settings:

```hcl
tenant_id    = "8aacb043-2429-460e-b9d1-d81459e9330e"
catalog_name = "Azure Subscriptions"

# Repo 1's state location, so the taxonomy can be read
state_resource_group_name  = "rg-tfstate-poc"
state_storage_account_name = "sttfstatepocbvt"
vending_state_key          = "access-vending.tfstate"

defaults = {
  assignment_duration_days = 14   # ≤ 30, see trap 6.1
  requestor_scope_type     = "AllExistingDirectoryMemberUsers"
  require_justification    = true
  approval_timeout_days    = 7
  grant_approver_group     = true # option A in 5.5
}

# Only where you deviate
scope_overrides = {
  "tenant" = { assignment_duration_days = 7 }  # Groups Administrator — see trap 6.7
}
```

Roughly 20 lines, and adding a scope or role in repo 1 needs **no change here at
all**.

---

## 6. Traps — read before building

### 6.1 Expiry mismatch between the access package and the PIM policy

Microsoft Learn warns that if the access package expiration exceeds the group's
"Expire eligible assignments after" setting, Entitlement Management and PIM can
drift apart — users lose access while EM still shows them assigned.
Content was rephrased for compliance with licensing restrictions.

Repo 1 sets `active_assignment_expire_after` with a **default of `P30D`** for M3
roles.

**Rule: keep `duration_in_days` ≤ 30 for any M3 package**, or read repo 1's
`activation_settings` output and validate it in code. A validation block that
fails the plan is better than a silent access loss.

In this tenant that means the `jaws` package, which is the only one containing
`pim_for_groups` roles.

### 6.2 Apply order is not enforced by Terraform

Repo 1 **must** apply first. Not only because the groups must exist, but because
for M3 the **PIM policy must be written** — writing it is what onboards the group
to PIM for Groups. Until then, the access package resource-role picker will offer
only `Member`, never `Eligible Member`.

If you apply repo 2 first, you get active membership instead of JIT, and nothing
fails. Same failure mode as blocker 2.1, different cause.

If both repos run in one pipeline, use `needs:` between the jobs.

### 6.3 The service principal owns every group

Repo 1's deploy identity is the Entra owner of all 14 groups, and that ownership
cannot be removed (Graph assigns it to the calling principal and a group cannot
exist ownerless). `set_systemeier_as_group_owner` is `false` on purpose so that no
*human* has standing ownership — a group owner can add members directly and bypass
the whole access package flow, unseen in any plan.

The approver groups have no owners at all for the same reason: an owner could grant
themselves approval authority. Their systemeier are **members**, which carries no
such power.

Consequence for repo 2: do **not** rely on group-owner-based approval flows. Use
explicit `primary_approver` entries.

### 6.4 M4 activation rules are outside Terraform entirely

`entra_role` groups (`entra-tenant-*`) are bound to Entra directory roles. Repo 1
cannot set MFA, approval, or max duration for those — the `azuread` provider has
no `azuread_directory_role_management_policy`. See R6 in repo 1's module README.

Repo 2 **can** still put approval on the access package request, which is the only
Terraform-managed gate on that path. Worth doing, and worth documenting as such —
it is approval on *getting eligible*, not on *activating*.

Read `terraform output entra_activation_governance_gap` from repo 1 and surface it
in repo 2's README so the gap does not get lost between repos.

### 6.5 `CallerNotResourceOwner` on catalog association

A known failure when the identity creating the catalog association is not an owner
of the group being linked. Since repo 1's SP owns all the groups, the cleanest fix
is to run repo 2 with the **same** service principal. If you use a different
identity, it needs `EntitlementManagement.ReadWrite.All` **and** either group
ownership or `Catalog owner` in Identity Governance.

### 6.6 Renaming a scope key or role key is destructive

They are `for_each` keys **and** part of the group name in repo 1. Renaming
deletes and recreates the group, which invalidates every object ID repo 2 holds.
Treat the key set as an append-only contract across both repos.

### 6.7 The `tenant` package is the riskiest one — gate 1 is the ONLY control

The `tenant` scope holds `entra_role` roles, and repo 1 cannot manage their
activation rules at all. Repo 1's `approvers_by_role` returns
`"not managed by Terraform"` for both, and `directoryreader` is `permanent_access`
so it has no activation step whatsoever.

Consequence: for the `tenant` package, **gate 1 is the only gate Terraform
enforces** — and the package hands out `Groups Administrator`, a role that can
manage membership in every non-role-assignable group in the tenant and rewrite
their PIM policies. One systemeier approval is the entire control.

Three mitigations:

1. Give `tenant` the shortest `duration_in_days` of the four packages.
2. Set the PIM portal activation rules for `Groups Administrator` manually — MFA,
   approval, max duration. Repo 1's R6 explains why Terraform cannot.
3. Consider whether `groupsadmin` and `directoryreader` belong in the same package
   at all. `Directory Readers` is harmless; `Groups Administrator` is not. Splitting
   them is a deliberate deviation from one-package-per-scope, and defensible.

Note for M4: unlike M2/M3, active *Privileged Role Administrator* and *Global
Administrator* **do** act as default approvers on Entra role activation if approval
is required and none are set. So "no approval from Terraform" does not mean "no
approval" here — it means "governed outside Terraform, by tenant admins".

---

## 7. Providers and permissions

### 7.1 Providers

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.7"
    }
  }
}
```

`azurerm` is **not needed**. If you end up taking option 2 in section 2.1, add
`azapi` or `restapi` and document why.

### 7.2 Graph permissions

The deploy identity needs, as **application** permissions with admin consent:

| Permission | Why |
|---|---|
| `EntitlementManagement.ReadWrite.All` | Catalog, packages, policies, resource roles |
| `Group.Read.All` | `data "azuread_group"` lookups |
| `User.Read.All` | `data "azuread_user"` for named approvers |

Repo 1's `bootstrap/grant-graph-permissions.sh` already grants
`Group.ReadWrite.All` and `User.Read.All`. You need to **add**
`EntitlementManagement.ReadWrite.All`. Extend that script rather than writing a
new one — it is idempotent and skips already-granted roles.

Missing permissions surface as `403` on first apply and are the single most common
blocker.

### 7.3 Reuse repo 1's deploy identity

Recommended, for the reason in 6.5. Same managed identity, same federated
credential pattern, separate state key:

```
key = "access-packages.tfstate"     # NOT access-vending.tfstate
```

---

## 8. Acceptance criteria

Functional:

- [ ] `terraform apply` creates one catalog and **one access package per scope** — 4 in this tenant
- [ ] Every role group is attached to its scope's package as a resource role (11 groups)
- [ ] The package set is **derived** from repo 1's state, not listed in repo 2's tfvars
- [ ] Adding a role in repo 1 and re-applying repo 2 picks it up with **no config change**
- [ ] `terraform plan` after the first apply reports **no changes** (idempotent)
- [ ] Gate 1 approval routes to the scope's `systemeier` from `systemeier_by_scope`
- [ ] Assignment policies have `duration_in_days` set and expiry actually fires
- [ ] Under option A (5.5), the three approver groups are attached to their packages
- [ ] Peer approval works: two members of the same scope can approve each other

Structural:

- [ ] `modules/access-packages/` has **no** `provider` blocks
- [ ] No group name is hardcoded — all come from repo 1's `group_names`
- [ ] A precondition fails the plan if repo 1's state is empty or unreachable
- [ ] `README.md` per module: inputs, outputs, call example
- [ ] `terraform fmt -check -recursive` passes
- [ ] `terraform validate` passes at root, module, and every example

Honesty:

- [ ] Blocker 2.1 is resolved or explicitly documented, with an output listing any group left out of IaC
- [ ] Blocker 2.2 is verified against the actual tenant and the result recorded
- [ ] A validation or documented rule prevents the 6.1 expiry mismatch
- [ ] No field is accepted-and-ignored. If a mechanism cannot honour a setting, **reject it in validation** — the same principle repo 1 follows

---

## 9. End-to-end test plan

Run only after both repos are applied, repo 1 first.

| # | Test | Expected |
|---|---|---|
| 1 | Request the `tommer` package in MyAccess | Systemeier (patrick or edgar) approves → assigned |
| 2 | After assignment, check what you hold | Immediate `Reader` via `readingbooks` (permanent); **eligible only** for contriband and master |
| 3 | Activate `contriband` in PIM | Gate 2 fires: `dual` → systemeier or approver-group member approves |
| 4 | **Measure gate 2 propagation** | Time from activation until access is visible in portal/CLI, and whether re-login is needed. Repo 1's R5 |
| 5 | Activate `master` (Owner, MFA, 2h) | MFA prompt, approval, expires automatically |
| 6 | Peer approval | Alice approves Bob's activation; Bob approves Alice's; **neither can approve their own** |
| 7 | Single-systemeier scope (`morkanaught` or `jaws`) | Confirm the lone systemeier **cannot** activate their own `dual` role until a peer is added (4.5) |
| 8 | Deny a request at gate 1 | No package assignment, no group membership |
| 9 | Wait out `duration_in_days` | Assignment expires, all groups in the package are removed |
| 10 | **M3 — `jaws` package** | Confirm whether the user is **eligible** or **active** on `aws-jaws-*`. This is the test for blocker 2.1 |
| 11 | `tenant` package | Confirm gate 1 approval is the only Terraform-managed control (trap 6.7), and that PIM portal rules are set manually |
| 12 | Offboard: remove user from tenant | All access disappears |

Test 4 matters most for PIM for Groups: the group claim only lands in a **new**
token, so expect 5–10 minutes or a sign-out/sign-in. Test 10 tells you whether
blocker 2.1 bit you — if the user is an *active* member of `aws-jaws-readonly`
immediately on assignment, the JIT model is not working.

Test 3 matters most for PIM for Groups: the group claim only lands in a **new**
token, so expect 5–10 minutes or a sign-out/sign-in. Repo 1's R5 documents this.
Test 9 is the one that will tell you whether blocker 2.1 bit you.

---

## 10. Explicitly out of scope

- Creating groups, RBAC bindings, or PIM policies — that is repo 1
- Access reviews and lifecycle workflows — no Governance add-on assumed; short expiry is the substitute
- Subscription vending — done in the customer portal
- SCIM provisioning to AWS/GCP/GitHub — cloud-side work, tracked by repo 1's `target_cloud_bindings`
- Setting M4 activation rules — impossible in Terraform today, see 6.4 and repo 1's R6

---

## 11. Conventions to follow

Inherited from repo 1. Keeping them makes the two repos reviewable as one system.

**Reject, never ignore.** If a field does not apply to a mechanism, fail
validation with a message that explains *why*. Accepting a field and dropping it
silently is how a config ends up lying about what it enforces.

**Defaults that fail safe.** Repo 1 defaults `approval_type` to `owner`, not
`self`, so forgetting the field means *more* control rather than less. Apply the
same instinct here: default to approval required and a short duration.

**Error messages explain the reason.** Compare:
`"approval_type must be one of: self, owner, dual"` versus explaining that
`approver_group_object_id` is required for `dual` because otherwise the role would
demand group approval with no group to approve it. Write the second kind.

**Comments explain *why*, not *what*.** The HCL already says what. Comment the
provider limitation, the ordering constraint, the trap.

**Documentation lives in one place.** Repo 1 keeps the field reference in
`modules/*/README.md` and points to it from tfvars. Do not duplicate reference
tables into tfvars comments — they get copied into user files and never updated.

**All documentation in English.** Repo 1 was converted to English. Note that
`systemeier` stays as a field **name** — it is a code identifier, not prose.

---

## 12. Open questions to resolve early

Already settled — do not relitigate:

- **Package unit:** one per **scope**, not per group and not per persona yet (5.2)
- **Gate 1 approver:** the scope's `systemeier` (3.6)
- **Gate 2 approver:** per-role `approval_type`, already built in repo 1 (3.6)
- **Contract consumption:** `terraform_remote_state` against repo 1, not name lookup (3.1)
- **Approver group seeding:** repo 1 seeds the systemeier as members; repo 2 layers peers on top (4.3, 5.5)

Still open — answer in the first session and record the answers:

1. **Does the tenant allow Entitlement Management on P2 alone?** (blocker 2.2) — try creating one catalog. This gates everything else.
2. **How is `EligibleMember` handled?** (blocker 2.1) — pick option 1, 2, or 3 and write it down. Affects the `jaws` package only.
3. **Approver-group membership: option A, B, or C?** (5.5) — recommended A for the POC
4. **One catalog or one per scope?** One is simpler; per-scope gives cleaner delegation via `azuread_access_package_catalog_role_assignment`
5. **Same service principal as repo 1?** Recommended (6.5) — confirm and extend `bootstrap/grant-graph-permissions.sh` with `EntitlementManagement.ReadWrite.All`
6. **Does `tenant` stay one package?** Bundling `Groups Administrator` with `Directory Readers` may be too coarse (trap 6.7)
7. **Any package needing genuine two-stage approval?** Gate 1 is the only place it is possible (5.6)

---

## 13. Reference — repo 1 facts worth carrying over

- Naming formula: `{cloud}-{scope_key}-{role_key}`, prefix comes from `cloud` (not the scope key — `aws-prod` + `cloud = "aws"` would produce `aws-aws-prod-admin`)
- Approver group name: `{cloud}-{scope_key}-approvers`, **seeded with the `systemeier`** as members (never empty)
- Composite key: `{scope}--{role}`, `--` reserved and validated out
- Role key `"approvers"` is reserved (would collide with the approver group name)
- One group = one role = one scope. Bundling multiple roles happens in the **access package layer** — that is repo 2's job
- Terraform `>= 1.9` required (cross-variable references in validations)
- Repo 1 risks: R1 PIM onboarding irreversible · R2 unmanaged policy attributes · R3 `assignable_to_role` force-replace · R4 directory role activation irreversible · R5 token propagation delay · R6 M4 activation rules unmanaged
- Repo 1 decisions: B1 dispatch on role · B2 nullable defaults · B3 one approval stage · B4 approver group in module root · B5 SP as group owner

Full detail: `modules/access-vending/README.md` in repo 1.
