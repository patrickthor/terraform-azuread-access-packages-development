# terraform-azuread-access-packages

Entra access packages that decide **who can get access**. Repo 2 of a two-module pair.

Repo 1, `terraform-azuread-access-vending`, defines **which access grants exist**: the Entra
groups, the Azure RBAC bindings and the PIM activation policies. It grants no humans anything.
This repo makes those grants requestable.

```
customer repo (one root config, one state, one apply)
│
├── module "access_vending"    repo 1   WHICH access grants exist
│     groups + Azure RBAC bindings + PIM activation policies
│     └── output "contract"
│              │
├── module "access_packages"   repo 2   WHO can receive them   ← THIS REPO
│     catalogs + access packages + assignment policies
│     vending = module.access_vending.contract
```

Success is measured on the customer side: **a customer adds a subscription and three roles to
`terraform.tfvars`, runs one apply, and gets groups, RBAC, PIM policies, a catalog and a
requestable access package.**

**This repo never creates a group and never writes a group name, scope key or catalog label.**
The entire package set is derived from repo 1's contract. Adding a scope, a role or a catalog
in repo 1 needs no change here at all.

---

## The two gates

The thing to understand before anything else. Two separate approval points answering
different questions; neither side implements the other's.

```
request package → [GATE 1: this repo] → assigned / eligible
                → activate in PIM     → [GATE 2: repo 1] → active access
```

| | Gate 1 — request the package | Gate 2 — activate a role |
|---|---|---|
| Question | *Should this person reach this scope at all?* | *Should they hold contributor right now?* |
| Approver | the scope's `systemeier` | per-role `approval_type` |
| Timeout | configurable | fixed 24h, not configurable |
| Owned by | **this repo** | repo 1 |

This repo owns gate 1 only. It republishes what the contract carries about gate 2 through
`gate_2_approvers`, and interprets none of it.

---

## Structure

```
.
├── main.tf                      Split-state root: read repo 1's contract, call the module
├── variables.tf, outputs.tf
├── providers.tf                 azuread provider — roots configure providers, modules never do
├── versions.tf                  >= 1.9, azuread ~> 3.7, backend "azurerm" {}
├── backend.hcl.example
│
├── modules/
│   └── access-packages/         ← THE CONSUMABLE MODULE. All logic lives here.
│       ├── locals.tf            The derivation from the contract
│       ├── main.tf              Catalogs, associations, packages, preconditions
│       ├── README.md            ← THE FIELD REFERENCE for the whole repo
│       └── modules/
│           ├── access-package-catalog/   One catalog: create or adopt, plus delegation
│           └── access-package/           One package + resource roles + policy
│
├── examples/
│   ├── two-module-root/         ← THE REFERENCE ARCHITECTURE. Copy this one.
│   └── complete/                Literal contract fixture, local state, runs offline
│
├── scripts/
│   ├── grant-graph-permissions.sh
│   └── verify-entitlement-management.sh   Licensing probe — run this first
│
└── .kiro/steering/
    ├── identity-governance-contract.md    Shared with repo 1, byte-identical
    └── access-packages-module.md           This repo's brief
```

`modules/access-packages/` and both submodules have **no `provider` blocks**. That is what
lets a caller use `count`, `for_each` and `depends_on` — and `examples/two-module-root` uses
`count` on the module, so the rule is load-bearing rather than stylistic. CI asserts it.

Modules use `>=` provider constraints so they never become a ceiling; roots use `~>` and
commit a lockfile.

### About this repo's root

The reference architecture is `examples/two-module-root`: one root calling both modules, with
the contract flowing in memory. This repo's own root is the documented **split-state** variant,
because repo 2 cannot vendor repo 1's module and the POC tenant is currently deployed as two
states.

The remote state read lives in the root, never in the module — the module takes a plain typed
object precisely so that where the contract comes from stays the caller's decision.

The cost of the split-state variant is worth naming: with two states, nothing forces repo 1 to
be applied first. The plan cannot resolve without repo 1's state, which catches the empty case,
but a *stale* state still plans cleanly.

---

## One package per scope

**Not one per group.** An access package grants everything in it atomically, so its natural
unit is "membership of the team that works on this scope", not "one individual permission".

That works because repo 1's groups are PIM-managed: membership is not privilege, activation is.
A package can say "you belong here, here is your baseline plus your escalation paths", and PIM
still gates each escalation with its own approval, MFA and time limit.

---

## Getting started

```bash
# 0. Repo 1 must have applied first.

# 1. Is Entitlement Management usable in this tenant at all? Run this before anything else.
./scripts/verify-entitlement-management.sh

# 2. Grant the deploy identity what it needs (and run repo 1's script on the same app)
./scripts/grant-graph-permissions.sh <app-client-id>

# 3. Configure
cp backend.hcl.example backend.hcl                # repo 2's own state key
cp terraform.tfvars.example terraform.tfvars      # tenant + repo 1's state location

# 4. Apply
terraform init -backend-config=backend.hcl
terraform plan
terraform apply

# 5. Idempotency check — must report "No changes"
terraform plan

# 6. Read what Terraform could NOT do. This is a step, not a footnote.
terraform output manual_steps_required
terraform output excluded_resource_roles
```

Step 6 matters more than step 4 succeeding. Parts of this model cannot be expressed in
Terraform today, and a green apply says nothing about them.

```bash
# Check the derivation against what repo 1 vended
terraform output verification_summary
terraform output packages_by_catalog
```

---

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
| `Storage Blob Data Contributor` on the state account | the root config | Azure RBAC |

`Group.Read.All` is deliberately **not** needed by repo 2 any more: every group object ID
arrives in the contract, so there is nothing to look up.

`RoleManagement.ReadWrite.Directory` and `RoleEligibilitySchedule.ReadWrite.Directory` are
needed **only** for `entra_role`. The first lets the holder assign directory roles anywhere in
the tenant, including to itself — keep `entra_role` disabled while this identity also holds
`User Access Administrator`.

Admin consent cannot be automated, and should not be: a pipeline able to grant itself
tenant-wide group write is a privilege-escalation path.

State keys must differ in the split-state setup:

```
access-vending.tfstate    ← repo 1 writes, this root reads   (vending_state_key)
access-packages.tfstate   ← this root writes                 (backend.hcl key)
```

---

## Catalogs

A catalog is a **delegation boundary** — it controls who may add resources to it and manage the
packages inside it. So the label should track **ownership**, not environment. One identity team
owning everything means one catalog is correct; per-scope catalogs are pure overhead.

Repo 1 treats the catalog as an opaque label on a scope and creates nothing. Repo 2 takes
`distinct()` over the labels and decides whether to create or adopt. Adding a catalog costs one
word in `terraform.tfvars` and no code change on either side.

Two options worth knowing:

- **`adopt_existing`** — most real tenants already have a catalog owned by a team that will not
  hand over creation rights. Adoption creates nothing and changes nothing downstream. The
  catalog's own settings stay with its owner, which is why setting `description` alongside it is
  rejected rather than ignored.
- **`delegate_to_systemeier`** — makes the scope's systemeier catalog role holders, so package
  management sits with the people who already approve gate 1. Off by default: it is the one
  standing, non-expiring, non-activated grant this system can produce. The default role is
  `Access package manager`, not `Catalog owner` — a catalog owner can add arbitrary resources,
  routing around repo 1 entirely.

---

## Known gaps

Real limitations, deliberately visible rather than papered over.

### `EligibleMember` is not in the `azuread` provider

`azuread_access_package_resource_package_association.access_type` is validated client-side to
`Member` and `Owner` only. The Entra platform offers "Eligible Member" in the portal for
PIM-managed groups; the sole barrier is a `StringInSlice` allowlist on the provider's schema
field.

For `pim_for_groups` roles that matters enormously. Attaching one as `Member` makes the user an
**active** member the moment the assignment lands — standing access to AWS instead of activating
through PIM. It applies cleanly, looks correct, and nothing fails.

**Default behaviour: exclude, register, report.** Those roles get their *catalog* association
created but not their *package* association, and appear in `excluded_resource_roles` and
`manual_steps_required` with the portal path. The manual step is one click on a resource that is
already registered.

In order of what to pursue:

1. **Verify licensing first** — see below. If the platform rejects eligible roles, every
   workaround is a dead end including the portal step.
2. Exclude, register, report. This is what the code does.
3. **A PR to `hashicorp/terraform-provider-azuread`** adding `"EligibleMember"` to the allowlist
   is small and well-motivated. Worth opening regardless.
4. **Microsoft's `msgraph` provider** (public preview) can POST the role scope directly. Treat
   as a spike — nobody here has tested that specific POST. If adopted, it goes behind an explicit
   opt-in and never becomes a required provider.

Full IaC coverage by downgrading to `Member` stays available behind **two** flags,
`manage_pim_for_groups_roles` and `acknowledge_m3_active_membership`, because the failure mode
shows up in neither plan nor portal.

### Licensing — verify before building further

Eligible group membership in access packages requires **Entra ID Governance or Entra Suite**, not
P2 alone. `scripts/verify-entitlement-management.sh` is the probe, and the answer changes what is
worth building:

- Catalogs work but eligible resource roles are rejected at the platform level → the provider
  allowlist is not the blocker, and neither the `msgraph` spike nor the portal workaround helps.
- Eligible roles do work in the portal → the allowlist is the only barrier, and the `msgraph`
  path is worth the spike.

### `entra_role` activation is outside Terraform entirely

The `azuread` provider has no resource for directory role management policies —
`azuread_group_role_management_policy` applies to groups, not directory roles. So MFA, approval
and maximum activation duration for `entra_role` cannot be set by Terraform at all. Repo 1
rejects those fields rather than ignoring them, and both repos surface the gap.

"No approval from Terraform" here means **governed by tenant admins outside Terraform** — active
Privileged Role Administrator and Global Administrator do act as default approvers. It does not
mean the role is open.

### `pim_for_groups` stops at the tenant boundary

Terraform does not connect the group to AWS, GCP or GitHub. That is SCIM on the cloud side.
`manual_steps_required` lists it per scope.

### The riskiest package

A scope handing out `entra_role` — `Groups Administrator` in particular — is the most dangerous
thing this system can produce. That role can manage membership in every non-role-assignable group
in the tenant, which is **all** the `azure_pim` and `pim_for_groups` groups repo 1 creates, and
rewrite their PIM policies. Terraform can set no activation rules for it, so gate 1 is the only
gate it enforces and one systemeier approval is the entire control.

Mitigations in place: the shortest `assignment_duration_days` of any package, its own catalog so
it is visible in a listing, and `manual_steps_required` naming the portal rules to set by hand.
Splitting a harmless `Directory Readers` out of the same package as `Groups Administrator` is a
defensible further step.

### The self-approval deadlock

Repo 1 seeds each approver group with its scope's `systemeier`, so dual-approval roles work on
the first apply. But PIM blocks self-approval, so a group with exactly one member cannot approve
that member's own request — the request times out after 24 hours, a timeout nobody can configure.

Fixed by `grant_approver_group = true` (the default): the package grants the approver group too,
so everyone in the scope is a peer approver. `peer_approval_status` reports where that is viable
and where it is not.

---

## Verified in this tenant

Blank rows are honest unverified claims. A filled-in row that nobody tested is not.

| Question | Result | Date |
|---|---|---|
| Can a catalog be created on P2 alone? | | |
| Does the platform offer "Eligible Member" as a resource role? | | |
| Does `terraform plan` report no changes after the first apply? | | |
| Does a `pim_for_groups` assignment produce eligible or active membership? | | |
| Can two members of one scope approve each other? | | |
| Does a lone systemeier fail to activate their own dual-approval role? | | |
| How long does gate 2 propagation take? | | |

---

## Diagrams

- `generated-diagrams/1-terraform-architecture.png` — module layout and what creates what
- `generated-diagrams/2-runtime-flow-two-gates.png` — a user's journey through both gates

Editable `.drawio` counterparts alongside; the `.dot` intermediates are gitignored.

---

## Further reading

- `modules/access-packages/README.md` — **the field reference** and the design notes
- `.kiro/steering/identity-governance-contract.md` — the contract, shared byte-identically with repo 1
- `.kiro/steering/access-packages-module.md` — this repo's brief
- `examples/two-module-root/README.md` — the architecture to copy
- `examples/complete/README.md` — what to expect from the derivation, and how to make it fail
- `PROSJEKT-SAMMENDRAG.md` — status, decisions and risks. Start here after a break
- `OPPGAVE.md` — the original assignment text
