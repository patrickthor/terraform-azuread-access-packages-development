# Project summary — terraform-azuread-access-packages

**Start here** after a break or when opening a new session. Written to give full context
without reading the code first.

Last updated: 4 September 2026
Status: **restructured onto the two-module contract. Not yet applied against Azure.**

---

## 1. What this repo is

Repo 2 of a two-module pair. It creates catalogs, one access package per **scope**, and one
assignment policy per package — **gate 1**, deciding who may reach a scope at all.

Repo 1 (`terraform-azuread-access-vending`) creates the groups, the Azure RBAC bindings and
the PIM activation policies, and exposes them as a single `contract` output. This repo
consumes it.

The goal is measured on the customer side, not inside either repo: a customer adds a
subscription and three roles to one committed `terraform.tfvars`, runs one apply, and gets
groups, RBAC, PIM policies, a catalog and a requestable access package.

**This repo never creates a group and never writes a group name, scope key or catalog
label.** Everything is derived from the contract. Adding a scope, role or catalog in repo 1
requires no change here.

### Architecture

The reference shape is one root config calling both modules, with the contract flowing in
memory:

```
customer root  →  module "access_vending"  →  output "contract"
                                                     ↓
               →  module "access_packages"  ←  vending = module.access_vending.contract
```

One state, one apply, and apply order becomes a property of the dependency graph rather than
a convention. See `examples/two-module-root`.

This repo's own root is the documented **split-state** variant: it reads repo 1's contract
from remote state, because repo 2 cannot vendor repo 1's module and the POC tenant is
currently two states. The remote state read lives in the root, never in the module.

---

## 2. The POC frame

- POC tenant on **Entra ID P2**, no Governance add-on. Whether that is even enough is the
  first open question; run `scripts/verify-entitlement-management.sh`.
- Access reviews and lifecycle workflows are out of scope. Short assignment expiry plus
  manual re-request is the deliberate substitute.
- Subscription creation is out of scope.
- The design must carry over to AWS/GCP/GitHub. Catalogs and the package/policy pattern are
  cloud-agnostic; only the group's underlying authorization binding is cloud-specific, and
  that lives in repo 1.
- **No hardcoded role names.** Both leaf modules know only about Entra groups, never about
  what those groups grant.

---

## 3. Where things stand

Done:

- Leaf modules `access-package-catalog` (create **or adopt**, plus optional catalog-role
  delegation) and `access-package`
- Wrapper `modules/access-packages/` consuming the single contract object, with multi-catalog
  support and six plan-time preconditions
- Root as the split-state variant; `examples/two-module-root` as the reference architecture;
  `examples/complete` as the offline fixture
- `scripts/grant-graph-permissions.sh` — grants `EntitlementManagement.ReadWrite.All` and
  `User.Read.All`, and prints the Azure RBAC commands. `Group.Read.All` was **removed**:
  repo 2 no longer looks groups up, so it was tenant-wide group read for nothing
- `scripts/verify-entitlement-management.sh` for the licensing probe
- CI asserting no provider blocks, no `terraform_remote_state` in modules, no `try()` around
  contract fields, no hardcoded group names, `>=` constraints in modules, and that the
  backend key is not repo 1's
- All documentation in English. `systemeier` stays as a field **name** — it is a code
  identifier, not prose
- Derivation verified offline against an 11-role, 4-scope, 2-catalog fixture. All six
  preconditions confirmed to fire on their own failure paths, including that the expiry
  ceiling picks the **minimum** across a scope (15 from `jaws--billing`, not the two 30s) and
  names the binding role

Not done, and blocking real verification:

- **Nothing has been applied against the tenant.** Every claim about runtime behaviour is a
  claim about what the provider and Microsoft document, not about what happened
- The licensing question is unanswered: is Entitlement Management usable on P2 alone?
- The platform half of the `EligibleMember` question is unanswered: does the tenant offer
  "Eligible Member" as a resource role at all, or is the provider allowlist masking a
  licensing limit?
- The `Verified in this tenant` table in `README.md` is empty
- No end-to-end test has been run
- Repo 1 must expose a single `contract` output of the agreed shape. This repo is written
  against that shape but has never consumed a real one

---

## 4. What changed in this pass, and why

Worth reading if you remember the earlier shape of this repo.

**Twelve parallel maps → one contract object.** The input was `group_names`,
`group_object_ids`, `access_package_access_type`, `jit_mechanism` and eight more, each keyed
independently. Eight of the eleven variable validations existed purely to check that a key
present in one map was present in the others. With one object, that is a type error — a
better error, since the type system names the missing attribute instead of a hand-written
message inferring it. Three validations remain: `contract_version`, key shape, non-empty.

**`terraform_remote_state` moved out of the module's contract entirely.** It was already in
the root rather than the module, but the root now reads one output instead of assembling
twelve, and the reference architecture drops remote state altogether.

**`try()` removed from the contract passthrough.** The root previously wrapped the gate-2
reference fields in `try()`. Under the contract those fields are required and
`contract_version` handles compatibility. A `try()` around a contract field is how a missing
`access_type` becomes standing access, so CI now rejects the pattern.

**One catalog → one per label, with adopt and delegate.** The catalog is a delegation
boundary and repo 1 treats it as an opaque label on a scope. Repo 2 takes `distinct()` over
the labels. Adoption matters because most real tenants already have a catalog owned by a team
that will not hand over creation rights.

**`m3_max_duration_days` deleted.** Repo 1 emits `max_assignment_days` per role as a number,
so nothing parses ISO-8601 and no human keeps a duplicated ceiling in sync. The precondition
is now per package, uses the minimum non-null value across the scope's roles, and names the
role that set it.

**Iteration sources switched to the contract's own keys.** Previously
`distinct([for k in keys(group_names) : split("--", k)[0]])`. Now `var.vending.scopes`,
`var.vending.catalogs`, `scopes[*].role_keys` and `catalogs[*].scope_keys`. Repo 1 guarantees
those are derivable from its input variables alone, so they are known at plan time. The old
form worked and was one repo-1 refactor away from `The "for_each" value depends on resource
attributes that cannot be determined until apply` — surfacing in this module for a change
made in the other repo.

**Provider constraints split.** Modules use `>=` so they never become a ceiling for a
consumer; roots use `~>` and commit a lockfile.

---

## 5. Decisions

| # | Decision |
|---|---|
| D1 | One access package per **scope**, not per group and not per persona yet |
| D2 | Gate 1 approval is the scope's `systemeier`; gate 2 stays repo 1's and is republished, never interpreted |
| D3 | Catalog resource associations in the wrapper module, not the leaf — unique per `(catalog, group)`, and peer approval attaches one approver group to several packages |
| D4 | `EligibleMember` roles are excluded, registered as catalog resources anyway, and reported |
| D5 | The approver group is attached to its scope's package by default, making peer approval real |
| D6 | The expiry ceiling comes from repo 1 as a number and is enforced per package, over **all** roles in the scope including excluded ones |
| D7 | `terraform_data` preconditions rather than `check` blocks |
| D8 | One catalog per label; adoption supported; delegation off by default and never `Catalog owner` |
| D9 | Fields this repo cannot honour are rejected, not accepted and dropped |
| D10 | The module takes a typed object; where the contract comes from is the root's decision |

### Why the ceiling covers excluded roles

Non-obvious enough to record. A role excluded by the `EligibleMember` gap is expected to be
added by hand in the portal. Once it is, its PIM eligibility expiry constrains the package
just as much as a Terraform-managed one. Computing the ceiling over only the managed roles
would let a too-long duration pass the plan and then start silently dropping access after
the manual step — which is the exact failure the ceiling exists to prevent.

### Why approver-group associations are keyed on scope, with a guard

A catalog resource association is unique per `(catalog, group)`. Role groups are safe keyed
on the composite role key, because one group belongs to one role in one scope and a scope
sits in one catalog — so the role key *is* a `(catalog, group)` key.

Approver groups are not automatically safe: `approver_group_name` may point at a group repo 1
does not manage, and two scopes could share it. Sharing across *different* catalogs is
legitimate and must produce two associations, which is why the key cannot be the group alone.
Sharing inside the *same* catalog is a duplicate the provider only reports at apply, partway
through, with resources already created. `validate_no_duplicate_catalog_resources` turns that
into a plan failure.

---

## 6. Risks

| # | Risk | Status |
|---|---|---|
| R1 | `EligibleMember` is not in the provider's allowlist, so `pim_for_groups` roles are excluded from IaC | Mitigated by exclude-register-report and visible in `excluded_resource_roles`. **Not eliminated** |
| R2 | Eligible group membership may need Governance licensing, not just P2 | **Unverified.** Gates everything, including whether the portal workaround helps |
| R3 | An `entra_role` scope hands out `Groups Administrator`, which can rewrite the PIM policies of every group repo 1 creates. Gate 1 is the only gate Terraform enforces | Mitigated by the shortest duration, its own catalog, and a named manual step |
| R4 | A scope whose roles are all excluded grants only its approver group | Visible in `granted_groups_by_package`; the portal steps are listed |
| R5 | Renaming a scope or role key in repo 1 is destructive and invalidates every object ID in the contract | Treat the key set as append-only across both repos |
| R6 | `CallerNotResourceOwner` if repo 2 runs as a different identity from repo 1 | Mitigated by using one identity for both modules |
| R7 | Assignment expiry outliving the PIM eligibility expiry causes silent access loss | Precondition per package, from repo 1's `max_assignment_days` |
| R8 | `entra_role` activation rules are unmanageable in Terraform | Surfaced in `gate_2_approvers` as `terraform_governs_activation = false` and in `manual_steps_required` |
| R9 | `delegate_to_systemeier` creates a standing, non-expiring grant — the only one in the system | Off by default; reported in `catalogs` and `manual_steps_required` when on |
| R10 | Contract drift between the repos | `contract_version`, a CI reminder, and the byte-identical steering file |
| R11 | The split-state root can plan cleanly against a **stale** repo 1 state | Not mitigated in that variant. The reference two-module root removes the failure mode entirely |

---

## 7. Next steps

In order.

1. Confirm repo 1 exposes a single `contract` output matching
   `.kiro/steering/identity-governance-contract.md`. Everything here is written against that
   shape and has never seen a real one.
2. Run `scripts/verify-entitlement-management.sh`. Record the licensing answer in the
   `Verified in this tenant` table. If Entitlement Management is unavailable, stop.
3. Run `scripts/grant-graph-permissions.sh` on the same app repo 1 uses, plus the Azure RBAC
   role it prints.
4. `terraform apply`, then `terraform plan` again to confirm idempotency.
5. Read `terraform output manual_steps_required` and do the portal work it lists.
6. Answer the platform half of the `EligibleMember` question — step 4 of the verify script.
7. Run an end-to-end test. The ones that can falsify the design rather than merely exercise
   it: whether a `pim_for_groups` assignment produces eligible or active membership; whether
   two members of one scope can approve each other; whether a lone systemeier is genuinely
   blocked from self-approval.
8. Fill in the `Verified in this tenant` table.

---

## 8. Open questions

| # | Question | Position |
|---|---|---|
| 1 | Entitlement Management on P2 alone? | Unverified. Blocks everything |
| 2 | `EligibleMember` — provider allowlist or licensing limit? | Unverified. Decides whether the `msgraph` spike or a provider PR is worth it |
| 3 | Approver group as a resource role? | Yes, on by default. A junior/senior split is the next refinement |
| 4 | One catalog or several? | Per label, tracking ownership. The `entra_role` scope gets its own so it is visible in a listing |
| 5 | Same identity as repo 1? | Yes, and effectively required by `CallerNotResourceOwner` |
| 6 | Does a mixed `entra_role` scope stay one package? | For now. Splitting `Directory Readers` from `Groups Administrator` is defensible |
| 7 | Any package needing genuine two-stage approval? | None today. Gate 1 is the only place it is possible, and the leaf module supports two stages |
| 8 | Open a provider PR for the `EligibleMember` allowlist? | Worth doing regardless of the answer to 2 |

---

## 9. Notes on the steering documents

- The two files in `.kiro/steering/` were added at the repo root and moved there, which is
  where `inclusion: always` front matter takes effect. Contents unchanged, so the
  byte-identical requirement on `identity-governance-contract.md` still holds.
- The contract carries no per-role `approval_type`, so `gate_2_approvers` cannot name the
  gate-2 approver for an individual role. It publishes what the contract does carry —
  mechanism, permanence, target, ceiling, and the scope's two approver pools — and says so in
  its own description. If naming the per-role approver matters, `approval_type` is an
  additive contract field and would not need a version bump.
- `OPPGAVE.md` still documents the original assignment's `subscriptions` / `subscription_id`
  tfvars shape, superseded twice over. Left unedited and in Norwegian because it is the
  original assignment text, not a design document.
