# Prosjektsammendrag — terraform-azuread-access-packages

**Start her** hvis du tar opp arbeidet etter en pause, eller åpner en ny
chat-sesjon på dette repoet. Fila er skrevet for å gi full kontekst uten at du
må lese koden først.

Sist oppdatert: 17. august 2026
Status: **førsteutkast, ikke kjørt mot Azure ennå**

---

## 1. Hva dette repoet er

Oppgave 2 av 2 i POC-en for access packages på Azure (full oppgavetekst i
`OPPGAVE.md`). Repoet oppretter:

- Én Entitlement Management-katalog (`Azure Subscriptions`)
- Én access package per (subscription, rolle)
- Tildelingspolicy per pakke med systemeier som godkjenner, begrunnelse påkrevd
  og kort expiry (7-14 dager) som substitutt for access reviews

Gruppene pakkene peker på opprettes **ikke** her. De slås opp på navn fra
**`terraform-azuread-access-vending`**.

### Apply-rekkefølge

```
1. terraform-azuread-access-vending      ← må kjøres først, oppretter gruppene
2. terraform-azuread-access-packages     ← dette repoet, slår opp gruppene
```

Kjører du dette først, feiler `apply` med "no group found".

---

## 2. POC-rammen i korte trekk

- POC-tenant med **Entra ID P2**, ingen Governance-tillegg.
- Access reviews og lifecycle workflows er utenfor scope. Erstattes av kort
  expiry på tildelingen + manuell re-request.
- Azure er native Entra. Ingen SCIM, ingen Logic App.
- Subscription-opprettelse er utenfor scope. POC-en bruker 1-2 eksisterende
  test-subscriptions.
- Designen skal kunne videreføres til AWS/GCP/GitHub. Katalogen og
  pakke-policy-mønsteret er felles på tvers; bare gruppens bakenforliggende
  autorisasjonskobling er sky-spesifikk.
- **Ingen hardkoding av rollenavn.** `reader`/`contributor`/`owner` er bare
  eksempler; rolle er en fri streng.

---

## 3. Beslutninger

Alle beslutninger er dokumentert med begrunnelse og hvor de endres. **Disse er
valgt for POC-fart — endre fritt.** Beslutningsnumrene er de samme i begge
repoer.

### B1 — To separate repoer

**Valgt:** to repoer, som oppgaven spesifiserer.

**Begrunnelse:** oppgaven sier det fire steder, og akseptansekriteriet "kan
løftes inn i LZ-repoet uten omskriving" forutsetter rene modulgrenser.

**Kostnad vi aksepterer:** ingen Terraform-graf på tvers. Gruppene bindes via
navneoppslag, ikke via `depends_on`. Konsekvenser: Graph-propagering må håndteres
med ventetid, apply-rekkefølge er konvensjon og ikke håndhevet, og
`terraform taint` på en gruppe i vending gir ny object-ID som dette repoet ikke
oppdager før neste `apply`.

**Endres i:** repo-struktur. `var.group_lookup_delay` kan settes til `"0s"` hvis
repoene slås sammen.

### B2 — Access packages gir aktivt medlemskap, ikke eligible

**Valgt:** `access_type = "Member"`. Eligibility tildeles statisk i
vending-repoets tfvars.

**Begrunnelse — dette er den viktigste beslutningen i POC-en.** Oppgaven er
tvetydig om hvem som tildeler eligibility, og de to lesningene har ulike
lisenskrav:

| Lesning | Hvordan | Lisens |
|---|---|---|
| **A (valgt)** | Pakken gir aktivt medlemskap. Eligibility statisk i vending-tfvars. | **P2 holder** |
| B | Pakken gir eligible medlemskap. Én forespørselsflate for alt. | Krever **Entra ID Governance / Suite** |

Microsoft dokumenterer at [tildeling av eligible gruppemedlemskap via access
packages](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-eligible)
krever Entra ID Governance- eller Entra Suite-lisens. POC-rammen utelukker
Governance-tillegg.

Grunnleggende access packages fungerer derimot fint på P2 — Microsoft lister
[P2, Entra ID Governance eller EMS E5](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-first)
som gyldige lisenser for entitlement management. Oppgavenotatets bekymring om at
Entitlement Management skulle være flyttet helt under Governance stemmer altså
ikke for kjernefunksjonaliteten.

**Konsekvens:** for PIM-roller gir pakken aktivt medlemskap, som umiddelbart
aktiverer den permanente RBAC-bindingen. Det omgår PIM-aktiveringssteget.
I POC-en fungerer PIM-testene ved at eligibility er forhåndstildelt i
vending-tfvars, uavhengig av pakken. Det er en reell forskjell fra måldesignet og
bør meldes videre.

**Endres i:** `var.default_access_type` eller `roles[*].access_type`. Sett til
`"EligibleMember"` for lesning B. Verifiser at provideren tar imot verdien —
det er ikke bekreftet.

### B3 — `dual` gir to godkjenningssteg her, ett i PIM

**Valgt:** `approval_type = "dual"` gir **to reelle godkjenningssteg** på
access package-forespørselen: først team-gruppa, deretter systemeier. I
vending-repoets PIM-policy degraderer den til ett steg med begge godkjennerne.

**Begrunnelse:** de to lagene har ulike muligheter.

| Lag | Antall steg | Kilde |
|---|---|---|
| Access package-policy (dette repoet) | opptil 2 | Microsoft dokumenterer [flerstegs godkjenning](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-approval-policy) |
| PIM for Groups-aktivering (vending) | 1 | `azuread_group_role_management_policy.activation_rules.approval_stage` finnes i entall |

Alternativene var å droppe `dual` helt (skjuler et krav) eller å gå til
`msgraph`/`azapi` mot beta-endepunkter for én verdis skyld (bryter
provider-linjen i oppgaven). Å implementere `dual` der plattformen støtter det,
og degradere eksplisitt der den ikke gjør det, gir mest verdi per innsats.

**Konsekvens:** oppgavens testpunkt "PIM-aktiver høyere rolle (owner) → dual
approval" må presiseres til å gjelde access-package-forespørselen.

**Mapping i dette repoet:**

| `approval_type` | Steg | Godkjennere |
|---|---|---|
| `self` | 0 | ingen |
| `team` | 1 | `approver_group_name` som `groupMembers` |
| `owner` | 1 | `systemeier` som `singleUser` |
| `dual` | 2 | steg 1 team, steg 2 systemeier |

**Endres i:** `main.tf`, `local.approval_stages_by_instance`.

### B4 — `azurerm` for RBAC, med deterministisk `name`

Gjelder vending-repoet. Dette repoet oppretter ingen Azure-ressurser og har
ikke `azurerm` i `required_providers`.

### B5 — Samme tfvars-skjema, egen fil per repo

**Valgt:** hvert repo har sin egen `terraform.tfvars` med identisk
`subscriptions`-struktur. Ikke delt fil.

**Begrunnelse:** oppgaven sier "samme struktur i begge repoer" — det er skjemaet
som er kontrakten, ikke fila.

Skjemaet her tar imot alle feltene vending-repoet bruker, også de dette repoet
ignorerer (`max_activation_hours`, `require_mfa`,
`eligible_user_principal_names`, `assignable_to_role`). Det gjør at samme blokk
kan kopieres uendret mellom repoene uten valideringsfeil.

**Risiko:** divergens over tid. En rolle lagt til her men ikke der gir en pakke
som leter etter en gruppe som ikke finnes.

**Endres i:** `terraform.tfvars` i begge repoer. Ved behov: CI-jobb som differ
`subscriptions`-nøklene på tvers.

### B6 — Oppslag på `display_name`

**Valgt:** `data "azuread_group" { display_name = ... }`, som oppgaven
spesifiserer.

**Begrunnelse:** `display_name` er ikke unikt i Entra, men vending-repoet setter
`mail_nickname` til samme streng (som *er* unik i tenant) og har
`prevent_duplicate_names = true`. Kombinasjonen gjør oppslaget entydig i praksis,
uten at vi endrer navnekontrakten oppgaven kaller ufravikelig.

**Endres i:** `main.tf`, `data "azuread_group" "role_groups"`.

### B7 — Team-godkjennere angis eksplisitt per rolle

**Valgt:** feltet `approver_group_name` per rolle. Kreves når `approval_type` er
`team` eller `dual`. `owner` bruker `systemeier` fra subscription-nivå.

**Begrunnelse:** oppgaven nevner `"team"` som approval-type uten å definere hvem
team er. Gruppen må finnes fra før — POC-en oppretter den ikke.

**Endres i:** `variables.tf` (validering) og `main.tf` (oppslag).

### B8 — `msgraph`-provideren brukes ikke

**Valgt:** kun `azuread` og `time`.

**Begrunnelse:** oppgaven sier `azuread` dekker access packages med typede
GA-ressurser.

Merk at det eksisterende `terraform-azuread-identity-governance`-repoet bruker
`msgraph` for access reviews. Access reviews er utenfor POC-scope, så behovet
faller bort.

### B11 — Access reviews settes ikke

**Valgt:** `assignment_review_settings` utelates helt fra
tildelingspolicyen.

**Begrunnelse:** POC-tenanten har ikke Governance-tillegg, og oppgaven setter
access reviews utenfor scope. Kort `duration_in_days` (default 14) er
substituttet — tildelingen utløper og brukeren må be på nytt.

**Endres i:** `modules/group-access-package/main.tf`.

---

## 4. Risikoer og ting å verifisere tidlig

### R2 — Argumentnavn: verifisert med `terraform validate` (i hovedsak løst)

`terraform init && terraform validate` er kjørt og gir **Success**. Følgende er
dermed bekreftet mot providerens skjema:

- `approval_settings.requestor_justification_required` — riktig plassering og navn
- `approval_settings.approval_stage.primary_approver.subject_type` — riktig navn
- `requestor_settings.requests_accepted` — riktig navn
- `azuread_access_package_resource_catalog_association` og
  `..._resource_package_association` med de feltene vi bruker

**Gjenstår:** `validate` sjekker navn, ikke verdier. Fortsatt uverifisert:

- Om `access_type` godtar `"EligibleMember"` (kun `"Member"` er testet i praksis
  gjennom POC-designet — se B2)
- Om `subject_type = "groupMembers"` fungerer som forventet for team-godkjennere
- Om `requestor_scope_type = "AllExistingDirectoryMemberUsers"` er riktig
  enum-verdi for vår tenant-konfigurasjon

### R4 — Graph-propagering ved gruppeoppslag

Grupper vending-repoet nettopp opprettet er ikke umiddelbart søkbare i Graph.

**Mitigert med:** `time_sleep.group_propagation` (default 30s) som
`data "azuread_group"` avhenger av. Den sover kun ved første opprettelse, så
kostnaden er engangs.

**Hvis `apply` feiler med "no group found":** sjekk først at vending-repoet
faktisk har kjørt og at gruppenavnene stemmer:

```bash
terraform output resolved_group_names
(cd ../terraform-azuread-access-vending && terraform output group_names)
```

Er navnene identiske og gruppene finnes i portalen, øk `group_lookup_delay`.

### R9 — Navnederiveringen er duplisert

`locals.tf` her og `modules/azure-subscription-access/main.tf` i vending-repoet
inneholder samme navnelogikk. Endres den ett sted, må den endres i begge.
Divergens gir kryptiske "no group found"-feil, ikke en tydelig feilmelding.

**Mitigasjon på sikt:** en delt modul, eller en CI-test som verifiserer at kjent
input gir samme output i begge repoer.

### R10 — Lisensverifisering bør gjøres først av alt

Oppgaven ber eksplisitt om å verifisere at access packages lar seg opprette på
ren P2. Etter dokumentasjonen skal det gå, men bekreft i POC-tenanten før du
bygger videre.

**Rask test:** opprett en katalog manuelt i portalen under ID Governance >
Entitlement management. Får du "Access denied", mangler lisensen.

### R11 — Access reviews-modulen i det gamle repoet gjenbrukes ikke

Det eksisterende `terraform-azuread-identity-governance` har en
`access-review-definition`-modul basert på `msgraph`. Den er bevisst ikke tatt
med. Skal access reviews inn senere, hent den derfra.

---

## 5. Status

### Gjort

- Katalogmodul og pakkemodul, begge sky-agnostiske
- Rot-modul som slår opp grupper og itererer over (subscription, rolle)
- Ett- og to-stegs godkjenning implementert etter `approval_type`
- Variabelskjema som tar imot samme tfvars-blokk som vending-repoet, med
  validering
- README per modul med input/output og kall-eksempel
- Script for Graph-permissions
- Outputs for å krysse gruppenavn mot vending-repoet

### Verifisert

- `terraform fmt -recursive` — formatering normalisert
- `terraform init -backend=false` + `terraform validate` → **Success**. Alle
  ressurstyper og attributtnavn er sjekket mot provider-skjemaet.
- Provider-versjoner som ble resolvet: `azuread` 3.9.0, `time` 0.14.1
  (constraintene `~> 3.7` og `~> 0.12` tillater dette).
- Repoet trekker ikke inn `azurerm` eller `msgraph` — kun `azuread` og `time`.

### Ikke gjort

- **Ingen `plan` eller `apply` mot POC-tenanten.** Krever autentisering og
  Graph-permissions.
- Lisens ikke verifisert i POC-tenanten (se R10).
- Ingen CI-workflow.
- Ingen backend-konfigurasjon (kjører med lokal state så langt).
- Idempotency ikke verifisert.
- MyAccess-flyten ikke testet ende-til-ende.

### Neste steg, i rekkefølge

1. Verifiser lisens i POC-tenanten (se R10). **Gjør dette først** — feiler det,
   stopper POC-en.
2. Grant Graph-permissions.
3. Kjør vending-repoet ferdig og verifiser at gruppene finnes.
4. `apply` med **én** subscription og **én** rolle først.
5. Kryss gruppenavn mot vending-repoet med `terraform output`.
6. `plan` på nytt for å bekrefte idempotency.
7. Test MyAccess-flyten manuelt: be om tilgang, godkjenn, verifiser tilgang.
8. Utvid til full tfvars.

---

## 6. Åpne spørsmål til avklaring

- [ ] **Lesning A vs B for eligibility** (se B2). Avgjør om POC-en trenger
      Governance-lisens. Bør meldes til den som skrev oppgaven.
- [ ] **Testchecklisten** må justeres for at PIM-aktivering ikke støtter
      to-stegs godkjenning (se B3).
- [ ] **Hvilken gruppe er team-godkjennere?** `approver_group_name` er lagt til
      som felt, men POC-en definerer ikke en konkret gruppe (se B7).
- [ ] **Én katalog eller én per subscription?** Utkastet bruker én felles
      katalog, som oppgaven antyder. Én per subscription ville gi bedre delegering
      av katalogeierskap til systemeier.
- [ ] **Backend:** skal state ligge i samme storage account som vending-repoet,
      med ulik key?
- [ ] **Skal `requestor_scope_type` være `AllExistingDirectoryMemberUsers`?**
      Det åpner for at alle interne kan be om tilgang til alt. Snevrere scope
      krever at vi definerer hvem som er kvalifisert per subscription.

---

## 7. For en ny chat-sesjon

Nyttig kontekst å gi opp front:

> Dette er access-package-repoet (Oppgave 2) i en to-repo POC for access packages
> på Azure. Les `PROSJEKT-SAMMENDRAG.md` og `OPPGAVE.md` først. Koden er et
> uverifisert førsteutkast — ingen `terraform validate` er kjørt. Det andre repoet
> er `terraform-azuread-access-vending` og ligger som søskenmappe; det må
> `apply`-es før dette.

Filer som gir mest kontekst raskt:

| Fil | Hva den gir |
|---|---|
| `PROSJEKT-SAMMENDRAG.md` | denne fila — beslutninger, risikoer, status |
| `OPPGAVE.md` | full oppgavetekst for begge halvdeler |
| `locals.tf` | navnederiveringen, altså kontrakten mot vending-repoet |
| `main.tf` | gruppeoppslag, godkjennerlogikk, iterasjon |
| `variables.tf` | tfvars-kontrakten med validering |
