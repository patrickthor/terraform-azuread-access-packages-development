# terraform-azuread-access-packages

Entra access packages that decide **who can get access**. Half 2 of 2 in the access
package POC (see `OPPGAVE.md`).

The other half, `terraform-azuread-access-vending` (repo 1), defines **which access
grants exist**: the Entra groups, the Azure RBAC bindings and the PIM activation
policies. It grants no humans anything. This repo makes those grants requestable.

```
access-vending  (repo 1)                    access-packages  (repo 2, THIS REPO)
──────────────────────────                  ──────────────────────────────────
WHICH access grants exist                   WHO can receive them
group + role binding + PIM policy           catalog + access package + policy
                        │                            │
                        └──── terraform state ───────┘
                                (the contract)
```

**Repo 2 never creates groups, and never names one.** The entire package set is
derived from repo 1's state. Adding a scope or a role in repo 1 and re-applying repo 2
picks it up with no configuration change here at all.

---

## The two gates

The thing to understand before reading anything else. There are two separate approval
points in a user's journey, and they answer different questions.

```
request package → [GATE 1: this repo] → assigned / eligible
                → activate in PIM     → [GATE 2: repo 1] → active access
```

| | Gate 1 — request the package | Gate 2 — activate a role |
|---|---|---|
| Question | *Should this person have access to this scope?* | *Should they hold contributor right now?* |
| Approver | the scope's `systemeier` | per-role `approval_type` |
| Source | `systemeier_by_scope[scope]` | `approvers_by_role[composite]` |
| Owned by | **this repo** | repo 1 |

This repo owns gate 1 only. It republishes repo 1's gate 2 rules through the
`gate_2_approvers` output so one `terraform output` shows the whole journey, and it
interprets none of them. Requiring approval here does not gate activation, and
approval at activation does not gate entry.

---

## Structure

```
.
├── main.tf                      Thin passthrough: read repo 1's state, call the module
├── variables.tf, outputs.tf
├── providers.tf                 azuread provider
├── versions.tf                  required_version >= 1.9, backend "azurerm" {}
├── backend.hcl.example
│
├── modules/
│   └── access-packages/         ← THE CONSUMABLE MODULE. All logic lives here.
│       ├── locals.tf            The derivation from repo 1's contract
│       ├── main.tf              Catalog, catalog associations, preconditions
│       ├── README.md            ← THE FIELD REFERENCE for the whole repo
│       └── modules/
│           ├── access-package-catalog/
│           └── access-package/  One package + its resource roles + its policy
│
├── examples/
│   ├── complete/                Literal fixture, local state, runs offline
│   └── github-consumption/      Pinned git ref, remote state
│
├── scripts/
│   ├── grant-graph-permissions.sh
│   └── verify-entitlement-management.sh   Blocker 2.2 licensing probe
│
└── .github/workflows/deploy.yml
```

`modules/access-packages/` has **no `provider` blocks**, which is what lets a consumer
use `count`, `for_each` and `depends_on` on it. Provider config belongs to the root and
to `examples/*/providers.tf`. CI asserts this.

`azurerm` is not needed at all — this repo touches no ARM resources. The `azurerm`
*backend* used for state is built into Terraform.

---

## One package per scope

**Not one per group.** An access package grants everything in it atomically, so its
natural meaning is "membership of the team that works on this scope", not "one
individual permission".

That works here because repo 1's groups are PIM-managed: membership is not privilege,
activation is. A package can therefore say "you belong to this scope, here is your
permanent baseline plus your escalation paths", and PIM still gates each escalation
with its own approval, MFA and time limit.

In this tenant that yields four packages:

| Package | Resource roles | Gate 1 | Gate 2 |
|---|---|---|---|
| `tommer` | readingbooks, contriband, master, + approver group | patrick, edgar | `dual` → systemeier or approver group |
| `morkanaught` | reader, blob-leser, nettverksdrift, + approver group | patrick | `self` / `owner` |
| `jaws` | approver group only ⚠ | patrick | `owner` / `self` / `dual` |
| `tenant` | groupsadmin, directoryreader | patrick | **none Terraform can set** |

⚠ See [Blocker 2.1](#blocker-21-eligiblemember) for why `jaws` looks like that.

---

## Getting started

```bash
# 0. Repo 1 must have applied first. This is enforced, not just documented —
#    the plan reads repo 1's state and cannot resolve without it.

# 1. Verify Entitlement Management is available in this tenant at all
./scripts/verify-entitlement-management.sh

# 2. Grant the deploy identity what it needs
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

# 6. Read what Terraform could NOT do. This is not optional.
terraform output manual_steps_required
terraform output excluded_resource_roles
```

Step 6 matters more than step 4 succeeding. Parts of this model cannot be expressed in
Terraform today, and a green apply says nothing about them.

Check the derivation matched what repo 1 vended:

```bash
terraform output verification_summary
terraform output roles_by_scope
```

---

## Permissions

| Permission | Type | Why |
|---|---|---|
| `EntitlementManagement.ReadWrite.All` | Graph application | Catalogs, packages, policies, resource roles |
| `Group.Read.All` | Graph application | Group lookups |
| `User.Read.All` | Graph application | `data "azuread_user"` for the gate 1 approvers |
| `Storage Blob Data Reader` | Azure RBAC | Reading repo 1's state |

`./scripts/grant-graph-permissions.sh <app-id>` grants the Graph permissions and prints
the command for the RBAC role. Missing permissions surface as a `403` on first apply and
are the most common blocker on this repo.

**Use repo 1's service principal.** Repo 1's identity owns all 14 groups, and
`azuread_access_package_resource_catalog_association` fails with `CallerNotResourceOwner`
when the caller does not own the group being linked. A separate identity needs group
ownership or `Catalog owner` in Identity Governance on top of the table above.

State keys must differ:

```
access-vending.tfstate    ← repo 1 writes, repo 2 reads   (vending_state_key)
access-packages.tfstate   ← repo 2 writes                 (backend.hcl key)
```

---

## The contract

Consumed via `terraform_remote_state` against repo 1, not by looking groups up on
`display_name`.

A name lookup sounds more loosely coupled, and it was the earlier recommendation. But to
look a group up by name, repo 2 must independently know every scope key and role key —
its own copy of the taxonomy, which is exactly the duplication worth avoiding. Add a role
in repo 1, forget it here, and it silently has no access package. You get loose coupling
**or** no duplication, not both.

Remote state makes repo 1's state the single source of truth, and turns the apply-order
rule from a convention into a hard failure. The cost is real: repo 2 needs
`Storage Blob Data Reader` on repo 1's state account, and the repos are coupled through
the state layout. Acceptable when both already share a deploy identity.

Keys are composite: `{scope}--{role}`, with `--` reserved and validated out of both halves
by repo 1, so splitting on it is safe. The `approver_group_*` outputs are keyed on
`{scope}` alone, because one approver group serves every role under a scope.

Full field reference: **`modules/access-packages/README.md`**.

---

## Known gaps

Everything below is a real limitation, deliberately visible rather than papered over.

### Blocker 2.1: `EligibleMember`

`azuread_access_package_resource_package_association.access_type` accepts only `Member`
and `Owner`. There is no `EligibleMember` — even though the Entra platform offers that
role in the portal for PIM-managed groups. The gap is in the provider, not the platform.

For `pim_for_groups` roles (the `aws-jaws-*` groups) that matters enormously. Attaching
one as `Member` makes the user an **active** member the moment the assignment lands: they
get standing access to AWS instead of having to activate through PIM. It applies cleanly,
looks correct, and nothing fails.

**Resolution: option 1.** Those roles are left out of Terraform and reported in
`excluded_resource_roles` and `manual_steps_required`, with the portal path to finish
them. Their *catalog* associations are still created, so the manual step is picking
"Eligible Member" on an already-registered resource.

The consequence, visible in the table above: `jaws` is entirely `pim_for_groups`, so its
package currently grants only its approver group. That is the honest outcome, and it is
in `granted_groups_by_package` for anyone to see.

Full IaC coverage is available via `manage_pim_for_groups_roles = true`, which
additionally requires `acknowledge_m3_active_membership = true` because it trades the JIT
model for standing access. Two flags because the failure is invisible.

### Blocker 2.2: licensing

Microsoft documents that PIM for Groups together with access packages requires Entra ID
Governance or Entra Suite. This tenant has P2 only. Run
`./scripts/verify-entitlement-management.sh` and record the result below before building
further — if catalogs work but eligible-member resource roles are rejected at the
platform level, blocker 2.1 is a licensing limit rather than a provider gap, and the
portal workaround will not help either.

### Trap 6.7: the `tenant` package is the riskiest

It hands out `Groups Administrator` — a role that can manage membership in every
non-role-assignable group in the tenant and rewrite their PIM policies. The `azuread`
provider has no resource for directory role management policies, so **gate 1 is the only
gate Terraform enforces** on that package. One systemeier approval is the entire control.

Mitigations in place: the shortest duration of the four packages (7 days, via
`scope_overrides`), and `manual_steps_required` naming the portal rules to set by hand.
Splitting `groupsadmin` from `directoryreader` into separate packages is a defensible
further step — `Directory Readers` is harmless and `Groups Administrator` is not.

Worth knowing: for Entra directory roles, active *Privileged Role Administrator* and
*Global Administrator* **do** act as default approvers if approval is required and none
are set. Unlike M2/M3, "no approval from Terraform" here means "governed outside
Terraform, by tenant admins", not "open".

### Section 4.5: the self-approval deadlock

Repo 1 seeds each approver group with its scope's `systemeier`, so `dual` roles work on
the first apply. But PIM blocks self-approval, so a group with exactly one member cannot
approve that member's own request — and `morkanaught` and `jaws` have one systemeier
each. The request sits until it times out after 24 hours, which is not configurable.

Fixed by `grant_approver_group = true` (the default): the package grants the approver
group too, so everyone in the scope is a peer approver. `peer_approval_status` reports
where this is viable and where it is not.

---

## Verified in this tenant

Fill in after running against the real tenant. Blank rows are unverified claims, and
this table is where the honesty requirement in §8 of the steering document lands.

| Question | Result | Date |
|---|---|---|
| Can a catalog be created on P2 alone? (blocker 2.2) | | |
| Does the platform offer "Eligible Member" as a resource role? (blocker 2.1) | | |
| Does `terraform plan` report no changes after the first apply? | | |
| Does a `jaws` assignment produce eligible or active membership? (test 10) | | |
| Can two `tommer` members approve each other? (test 6) | | |
| Does a lone systemeier fail to activate their own `dual` role? (test 7) | | |
| How long does gate 2 propagation take? (test 4) | | |

---

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Consume repo 1 via `terraform_remote_state`, not name lookup | Name lookup forces repo 2 to keep its own copy of the taxonomy |
| D2 | Root reads the state; the module takes a typed `vending` input | A module with a hardcoded remote state block could not be tested on local state by `examples/complete` |
| D3 | One package per scope | A package grants atomically, so its unit is a job function. Membership is not privilege here — activation is |
| D4 | Gate 1 = `systemeier_by_scope` only | Gate 2 already exists in repo 1. Reimplementing `approval_type` would duplicate it and drift |
| D5 | Catalog associations in the wrapper, not the leaf | Unique per `(catalog, group)`, and peer approval attaches one approver group to several packages |
| D6 | Blocker 2.1 → option 1, catalog associations still created | Honest split, minimal manual step. Nothing lies |
| D7 | §5.5 option A: approver group as a resource role, default on | Makes peer approval real and fixes the single-systemeier deadlock |
| D8 | Trap 6.1 as a configured ceiling, not parsed from repo 1's ISO-8601 | Parsing `P30D` in HCL is fragile; the ceiling plus a manual confirmation step is honest |
| D9 | `terraform_data` preconditions, not `check` blocks | A `check` warns and lets the apply proceed. These failures are all invisible-by-default |
| D10 | One catalog, not one per scope | Simpler. Per-scope catalogs only pay off when delegating catalog ownership |
| D11 | Repo 1 fields that repo 2 cannot honour are not accepted at all | §11: reject, never ignore |

---

## Diagrams

- `generated-diagrams/1-terraform-architecture.png` — module layout and what creates what
- `generated-diagrams/2-runtime-flow-two-gates.png` — a user's journey through both gates

Both have editable `.drawio` counterparts. The `.dot` intermediates are gitignored.

---

## Further reading

- `modules/access-packages/README.md` — **the field reference**, and the design notes
- `ASSIGNMENT-2-STEERING.md` — the contract, the traps, the acceptance criteria
- `OPPGAVE.md` — the original assignment text for both halves
- `PROSJEKT-SAMMENDRAG.md` — status, decisions and risks. Start here after a break
- `examples/complete/README.md` — what to expect from the derivation, and how to make it fail
