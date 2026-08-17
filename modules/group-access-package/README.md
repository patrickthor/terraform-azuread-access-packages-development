# Modul: `group-access-package`

Oppretter én access package som gir tilgang til én Entra-gruppe, med
tildelingspolicy. **Sky-agnostisk** — modulen kjenner bare gruppen, ikke hva
gruppen gir tilgang til.

## Ressurskjeden

```
azuread_access_package
  └─ azuread_access_package_resource_catalog_association
       (gruppen registreres som ressurs i katalogen)
       └─ azuread_access_package_resource_package_association
            (gruppen kobles til pakken med en rolle)

azuread_access_package
  └─ azuread_access_package_assignment_policy
       (hvem kan be, hvem godkjenner, hvor lenge)
```

## Input

| Navn | Type | Default | Beskrivelse |
|---|---|---|---|
| `catalog_id` | `string` | — | Katalogen pakken ligger i. |
| `group_object_id` | `string` | — | Entra-gruppen pakken gir tilgang til. |
| `display_name` | `string` | — | Pakkenavn i MyAccess. |
| `description` | `string` | — | Pakkebeskrivelse. |
| `hidden` | `bool` | `false` | Skjul fra MyAccess-katalogen. |
| `access_type` | `string` | `"Member"` | `"Member"` eller `"EligibleMember"`. |
| `policy_display_name` | `string` | — | Navn på tildelingspolicyen. |
| `policy_description` | `string` | — | Beskrivelse av policyen. |
| `duration_in_days` | `number` | `14` | Hvor lenge tildelingen varer. |
| `requestor_scope_type` | `string` | `"AllExistingDirectoryMemberUsers"` | Hvem kan be om tilgang. |
| `requests_accepted` | `bool` | `true` | Om policyen tar imot forespørsler. |
| `requestor_justification_required` | `bool` | `true` | Begrunnelse påkrevd. |
| `approval_timeout_in_days` | `number` | `14` | Forfall på ubesvart forespørsel. |
| `approval_stages` | `list(object)` | `[]` | Godkjenningssteg i rekkefølge. Maks 2. |

`approval_stages`-elementet:

```hcl
{
  approvers = [
    { object_id = "...", subject_type = "singleUser" },
  ]
}
```

`subject_type` er f.eks. `singleUser`, `groupMembers` eller `requestorManager`.

## Output

| Navn | Beskrivelse |
|---|---|
| `access_package_id` | ID på pakken. |
| `access_package_display_name` | Visningsnavn som i MyAccess. |
| `assignment_policy_id` | ID på tildelingspolicyen. |
| `catalog_association_id` | ID på katalog-til-gruppe-koblingen. |
| `effective_policy` | Oppsummering for verifisering. |

## Kall-eksempel

```hcl
module "package" {
  source = "./modules/group-access-package"

  catalog_id      = module.catalog.catalog_id
  group_object_id = data.azuread_group.reader.object_id

  display_name = "Azure sub-alpha - reader"
  description  = "Gir Reader-tilgang til sub-alpha."

  policy_display_name = "Azure sub-alpha - reader - standard"
  policy_description  = "Systemeier godkjenner. Tildelingen utløper etter 14 dager."

  duration_in_days = 14

  approval_stages = [
    {
      approvers = [
        { object_id = data.azuread_user.systemeier.object_id, subject_type = "singleUser" },
      ]
    },
  ]
}
```

## Designvalg verdt å kjenne

**To godkjenningssteg er der `dual` faktisk realiseres.** Entra støtter opptil 2
steg for access packages, men bare 1 for PIM for Groups-aktivering. Reell
to-stegs godkjenning må derfor ligge på forespørselen, ikke på aktiveringen. Se
beslutning B3 i `PROSJEKT-SAMMENDRAG.md`.

**`assignment_review_settings` settes ikke.** Access reviews er utenfor
POC-scope, siden POC-tenanten ikke har Governance-tillegg. Kort
`duration_in_days` er substituttet: tildelingen utløper og brukeren må be på
nytt.

**`access_type` avgjør lisensbehov.** `"Member"` gir aktivt medlemskap og
fungerer på ren P2. `"EligibleMember"` gir eligible medlemskap som brukeren så
PIM-aktiverer, men krever Entra ID Governance-lisens. POC-en bruker `"Member"`.
Se beslutning B2.
