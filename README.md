# terraform-azuread-access-packages

Terraform-oppsett for Entra access packages som gir tilgang til Azure-subscriptions
via grupper. Bygget for **Oppgave 2** i POC-en for access packages (se
`OPPGAVE.md`).

## Rollen i POC-en

Dette repoet er **halvdel 2 av 2**. Det andre er
`terraform-azuread-access-vending`, som oppretter gruppene dette repoet slår opp.

```
terraform-azuread-access-vending          terraform-azuread-access-packages
  (det andre repoet)                        (dette repoet)
  ─────────────────────────                 ─────────────────────────────
  1. Oppretter Entra-gruppe          ──►    3. Slår opp gruppen på navn
     azure-{sub}-{rolle}                       data "azuread_group"
  2. Permanent Azure RBAC                   4. Access package + request-policy
     på gruppen                                med systemeier som godkjenner
  2b. PIM-policy + eligibility
      (kun pim_enabled = true)
```

**Apply-rekkefølge: vending-repoet først.** Gruppene må finnes før dette repoet
kan slå dem opp. Kjører du dette først, feiler `apply` med "no group found".

## Modulstruktur

| Modul | Sky-agnostisk | Ansvar |
|---|---|---|
| `access-package-catalog` | ja | Katalogen som rommer pakkene |
| `group-access-package` | ja | Pakke + grupperessurskobling + tildelingspolicy |

Begge er sky-agnostiske: katalogen og pakke-policy-mønsteret er identisk uansett
om gruppen bak gir tilgang til Azure, AWS, GCP eller GitHub. Rot-modulen er der
den Azure-spesifikke kunnskapen ligger (gruppenavn og RBAC-semantikk).

## Kom i gang

```bash
cp terraform.tfvars.example terraform.tfvars
# fyll inn tenant_id og samme subscriptions-blokk som i vending-repoet

terraform init
terraform plan
terraform apply

# idempotency-sjekk — skal vise "No changes"
terraform plan
```

Verifiser at gruppeoppslaget traff riktig:

```bash
# Disse to skal gi identiske gruppenavn
terraform output resolved_group_names
(cd ../terraform-azuread-access-vending && terraform output group_names)
```

## Graph API-permissions

| Permission | Trengs for |
|---|---|
| `EntitlementManagement.ReadWrite.All` | kataloger, pakker, policyer |
| `Group.Read.All` | slå opp gruppene fra vending-repoet |

Kjør `./scripts/grant-graph-permissions.sh <app-id>` for å grante dem.

Bruker du **samme** service principal for begge repoene, kjør i tillegg
vending-repoets script.

## Kontrakten mot vending-repoet

Gruppene slås opp på `display_name` med strengen
`{cloud_prefix}-{subscription_key}-{rolle_key}`. Med default prefiks gir det
`azure-{sub}-{rolle}`.

Tre ting må stemme mellom repoene:

1. `cloud_prefix` — samme verdi.
2. `subscriptions`-nøklene — samme subscriptions og samme rolle-nøkler.
3. Navnederiveringen i `locals.tf` — duplisert fra vending-repoet. Endres den
   ett sted, må den endres i begge.

## Lisens

Grunnleggende entitlement management fungerer på **Entra ID P2**. Microsoft
dokumenterer at access packages krever
[P2, Entra ID Governance eller EMS E5](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-first).

Men `access_type = "EligibleMember"` krever Entra ID Governance. POC-en bruker
`"Member"`. Se beslutning B2 i `PROSJEKT-SAMMENDRAG.md`.

## Videre lesning

- `OPPGAVE.md` — full oppgavetekst for begge halvdeler
- `PROSJEKT-SAMMENDRAG.md` — beslutninger, risikoer og status. **Start her** hvis
  du tar opp arbeidet etter en pause.
- README per modul under `modules/`
