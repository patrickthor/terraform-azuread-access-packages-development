# Project summary — terraform-azuread-access-packages

**Start here** if you are picking the work up after a break or opening a new session on
this repo. Written to give full context without reading the code first.

Last updated: 27 August 2026
Status: **restructured against the revised steering document. Not yet applied against
Azure.**

---

## 1. What this repo is

Assignment 2 of 2 in the Azure access package POC (original text in `OPPGAVE.md`, the
working contract in `ASSIGNMENT-2-STEERING.md`).

It creates one Entitlement Management catalog, one access package per **scope**, and one
assignment policy per package. The groups those packages point at are **not** created
here — they come from `terraform-azuread-access-vending` (repo 1), whose Terraform state
this repo reads.

Everything else about the design follows from one property: **the package set is derived,
not configured.** There is no scope list and no role list anywhere in this repo. Add a
role in repo 1, apply repo 1, apply repo 2, and it appears in the right package with no
edit here.

### Apply order

```
1. terraform-azuread-access-vending    ← must run first
2. terraform-azuread-access-packages   ← this repo, reads repo 1's state
```

This is enforced rather than conventional: the plan cannot resolve without repo 1's state.
That was a deliberate goal of the remote-state decision, because the failure mode of
getting it wrong is silent — for `pim_for_groups` roles, writing the PIM policy is what
onboards the group to PIM, and until then the resource-role picker offers only `Member`.

---

## 2. The POC frame

- POC tenant on **Entra ID P2**, no Governance add-on. Blocker 2.2 is about whether that
  is even enough; run `scripts/verify-entitlement-management.sh`.
- Access reviews and lifecycle workflows are out of scope. Short assignment expiry plus
  manual re-request is the deliberate substitute.
- Azure is native Entra. No SCIM and no Logic App in this repo.
- Subscription creation is out of scope.
- The design must carry over to AWS/GCP/GitHub. The catalog and the package/policy pattern
  are cloud-agnostic; only the group's underlying authorization binding is cloud-specific,
  and that lives in repo 1.
- **No hardcoded role names.** Both leaf modules know only about Entra groups, never about
  what those groups grant.

---

## 3. Where things stand

Done:

- Two leaf modules: `access-package-catalog`, `access-package`
- The wrapper `modules/access-packages/` with the full derivation and five plan-time
  preconditions
- Root rewritten as a thin passthrough reading repo 1's state
- `examples/complete` (literal fixture, local state, runs offline) and
  `examples/github-consumption` (remote state, pinned ref)
- `scripts/grant-graph-permissions.sh` extended with the missing `User.Read.All`
- `scripts/verify-entitlement-management.sh` for blocker 2.2
- CI workflow with the `needs:` ordering note and a no-provider-blocks assertion
- All documentation in English. `systemeier` stays as a field **name** — it is a code
  identifier, not prose
- Derivation verified offline against the 11-group fixture: 4 packages, 8 roles attached,
  3 excluded, 14 catalog associations, 11 package associations. All five preconditions
  confirmed to fire on their respective failure paths

Not done, and blocking real verification:

- **Nothing has been applied against the tenant.** Every claim about runtime behaviour is
  a claim about what the provider documents, not about what happened
- Blocker 2.2 unverified: is Entitlement Management usable on P2 alone?
- Blocker 2.1's platform half unverified: does the tenant offer "Eligible Member" as a
  resource role at all, or is the provider gap masking a licensing gap?
- The `Verified in this tenant` table in `README.md` is empty
- The end-to-end test plan (§9 of the steering document) has not been run

---

## 4. Decisions

Numbered D-series here; the same table with the reasoning is in `README.md`. Repo 1's
B-series decisions are separate and referenced by number where relevant.

| # | Decision |
|---|---|
| D1 | Consume repo 1 via `terraform_remote_state`, not `data "azuread_group"` name lookup |
| D2 | The root reads the state; the module takes a typed `vending` input |
| D3 | One access package per **scope**, not per group and not per persona yet |
| D4 | Gate 1 approval is `systemeier_by_scope` only; gate 2 stays repo 1's |
| D5 | Catalog associations in the wrapper module, not the leaf |
| D6 | Blocker 2.1 → option 1, with catalog associations still created for excluded groups |
| D7 | §5.5 option A: the approver group is a resource role, on by default |
| D8 | Trap 6.1 as a configured ceiling plus a manual confirmation step |
| D9 | `terraform_data` preconditions rather than `check` blocks |
| D10 | One catalog for all packages |
| D11 | Fields repo 2 cannot honour are rejected, not accepted and dropped |

### Reversals from the earlier draft, and why

Worth reading if you remember the previous shape of this repo.

**Name lookup → remote state (D1).** The earlier draft recommended
`data "azuread_group"` on `display_name`, on the grounds that it is more loosely coupled.
It is, but to look a group up by name repo 2 has to know every scope key and role key
independently — its own copy of the taxonomy. Add a role in repo 1, forget it here, and it
silently has no access package. Loose coupling or no duplication, not both. Remote state
also made the apply-order rule a hard failure instead of a convention.

**One package per (subscription, role) → one per scope (D3).** A package grants everything
in it atomically; there is no menu. So its natural unit is a job function, not an
individual permission. This works here specifically because repo 1's groups are
PIM-managed: membership is not privilege, activation is. A package can hand someone their
whole scope and PIM still gates each escalation.

**Reimplementing `approval_type` → gate 1 only (D4).** The earlier root translated repo 1's
`self`/`owner`/`dual` into approval stages on the access package. That conflated the two
gates: `approval_type` governs privilege elevation, which repo 1 already built on the PIM
policies. Repo 2 answers a different question — who may enter the scope — and that is the
`systemeier`.

**Accepted-and-ignored fields dropped (D11).** The earlier variables accepted `pim_enabled`,
`max_activation_hours`, `require_mfa`, `eligible_user_principal_names` and
`assignable_to_role` and did nothing with them. That is the exact pattern §11 forbids.
Moot now anyway, since repo 2's tfvars carries no role list at all.

---

## 5. Risks

| # | Risk | Status |
|---|---|---|
| R1 | Blocker 2.1: `EligibleMember` is unsupported by the provider, so `pim_for_groups` roles are excluded from IaC | Mitigated by option 1 and made visible in `excluded_resource_roles`. **Not eliminated** |
| R2 | Blocker 2.2: Entitlement Management may need Governance licensing, not just P2 | **Unverified.** Gates everything |
| R3 | Trap 6.7: the `tenant` package hands out `Groups Administrator` with gate 1 as its only Terraform-enforced control | Mitigated by a 7-day duration; the PIM portal rules must be set by hand |
| R4 | `jaws` currently grants only its approver group, because every role in it is excluded by R1 | Visible in `granted_groups_by_package`; three portal steps to complete |
| R5 | Renaming a scope or role key in repo 1 is destructive and invalidates every object ID here | Treat the key set as append-only across both repos |
| R6 | Trap 6.5: `CallerNotResourceOwner` if repo 2 runs as a different identity from repo 1 | Mitigated by reusing repo 1's service principal |
| R7 | Trap 6.1: assignment expiry outliving the PIM eligibility expiry causes silent access loss | Precondition enforces a 30-day ceiling on M3 packages. The ceiling is configured, not read from repo 1 |
| R8 | Repo 1's M4 activation rules are unmanageable in Terraform | Surfaced via the forwarded `entra_activation_governance_gap` output |

---

## 6. Next steps

In order.

1. Run `scripts/verify-entitlement-management.sh`. Record the answer to blocker 2.2 in the
   `Verified in this tenant` table. If Entitlement Management is unavailable, stop.
2. Run `scripts/grant-graph-permissions.sh` and grant `Storage Blob Data Reader` on repo
   1's state account.
3. `terraform apply`, then `terraform plan` again to confirm idempotency.
4. Read `terraform output manual_steps_required` and do the portal work it lists.
5. Answer the blocker 2.1 platform question: does the tenant offer "Eligible Member" as a
   resource role? The command is in step 4 of the verify script.
6. Work through the §9 test plan. Tests 6, 7 and 10 are the ones that can falsify the
   design rather than merely exercise it.
7. Fill in the `Verified in this tenant` table.

---

## 7. Open questions

| # | Question | Position |
|---|---|---|
| 1 | Entitlement Management on P2 alone? | Unverified. Blocks everything |
| 2 | `EligibleMember` handling | Option 1 chosen. Revisit if the platform turns out not to offer it either |
| 3 | Approver group membership | Option A, on by default. Option B (junior/senior split) is the next step |
| 4 | One catalog or one per scope? | One. Per-scope only pays off when delegating catalog ownership |
| 5 | Same service principal as repo 1? | Yes, per trap 6.5 |
| 6 | Does `tenant` stay one package? | For now. Splitting `groupsadmin` from `directoryreader` is defensible and would deviate from one-package-per-scope deliberately |
| 7 | Any package needing genuine two-stage approval? | None today. Gate 1 is the only place it is possible, and the leaf module supports up to 2 stages |

---

## 8. Known documentation inconsistencies

Found while implementing against the revised steering document. Recorded rather than
silently worked around.

- **§3.6 vs the note beneath it.** The table lists `azure-morkanaught-approvers` as one of
  14 groups, but the note below still says morkanaught has *no* approver group. §5.5 agrees
  with the table (three approver groups: tommer, morkanaught, jaws). The code derives from
  `approver_group_object_ids` at runtime and is unaffected either way.
- **§5.4 code comment.** Says "All 14 group names" for `group_names`, but the same comment
  then notes approver groups are not in that output. It holds 11 role groups; 14 is the
  total including the 3 approver groups. The counts in §5.3 are consistent with 11.
- **§9 has two contradictory trailing paragraphs.** One says test 4 matters most and test 10
  reveals blocker 2.1; the other says test 3 and test 9. By the numbered table, test 4 is
  propagation and test 10 is the M3 eligible-vs-active check, so the first paragraph matches
  the table.
- **`OPPGAVE.md` documents the old tfvars shape** — a `subscriptions` block with
  `subscription_id`, from when packages were one-per-(subscription, role). Superseded by the
  derived model. Left unedited because it is the original assignment text, not a design
  document.
