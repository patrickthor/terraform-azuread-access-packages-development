# Oppgaver — POC Access Packages på Azure

POC for å bevise tilgangskjeden fra `access-package-architecture.md` på Azure.
To oppgaver i hvert sitt repo. **Begge må være på plass for å teste ende-til-ende.**

---

## Felles ramme

- **Tenant:** POC-tenant med Entra ID P2.
- **Ingen Governance-tillegg:** Access reviews og lifecycle workflows er utenfor
  scope. Substitueres med kort expiry på tildeling + manuell re-request.
- **Azure er native Entra:** Ingen SCIM eller Logic App (det er kun for
  AWS/GCP/GitHub). Grupper er direkte RBAC-principals.
- **Subscription-vending er utenfor scope:** Selve opprettelsen av subscriptions
  gjøres i kundeportal. POC-en bruker 1-2 eksisterende test-subscriptions.
- **Kontrakt mellom repoene:** Gruppenavn følger `azure-{sub}-{rolle}` strengt.
  Vending-repoet oppretter dem, access-package-repoet slår dem opp på navn.
  Endres ikke uten å avklare.
- **Apply-rekkefølge ved test:** `vending` først (grupper må finnes), deretter
  `access-packages`.
- **Multi-cloud-bevisst:** Designen skal kunne videreføres til AWS/GCP/GitHub
  senere. Entra-gruppe + PIM for Groups er felles mekanisme på tvers. Det som
  varierer per sky er rolle-semantikk og hvordan gruppen kobles til skyens
  autorisasjon (Azure RBAC vs. AWS permission sets vs. GitHub team-roller vs.
  GCP IAM). **Ikke hardkode antakelser om "reader/contributor/owner"** — la
  rolle være en konfigurerbar streng.

### Felles tfvars-form (samme struktur i begge repoer)

```hcl
subscriptions = {
  "sub-alpha" = {
    subscription_id = "..."
    systemeier      = "ola@kunde.no"
    # Rolle-keys er prosjekt-/sky-spesifikke navn. På Azure er reader/contributor/owner
    # naturlige eksempler, men strukturen tar imot vilkårlige roller.
    roles = {
      "reader" = {
        azure_role           = "Reader"        # Faktisk Azure RBAC-rolle
        pim_enabled          = false           # Permanent gruppemedlemskap
      }
      "contributor" = {
        azure_role           = "Contributor"
        pim_enabled          = true
        approval_type        = "team"          # "self" | "team" | "owner" | "dual"
        max_activation_hours = 8
      }
      "owner" = {
        azure_role           = "Owner"
        pim_enabled          = true
        approval_type        = "dual"
        max_activation_hours = 2
        require_mfa          = true
      }
    }
  }
}
```

---

## Oppgave 1 — Moduler for tilgangsoppsett per subscription (vending-repo)

**Bakgrunn.** Vi har i dag et LZ-repo som konfigurerer policy m.m., og som på
sikt også skal vende subscriptions. Byggeklossene i denne oppgaven (grupper,
RBAC, PIM) lages som **gjenbrukbare moduler** slik at LZ-repoet holdes tynt — og
slik at de senere kan løftes rett inn i LZ-repoet. I POC-en lever de i et eget
vending-repo.

**Mål.** Gitt 1-2 test-subscriptions i tfvars: opprett Entra-grupper, Azure
RBAC-bindinger og PIM-konfigurasjon via moduler, med minimal kode i kallende rot.

**PIM-modell (viktig):** Vi bruker **PIM for Groups** — ikke PIM for Azure
Resources:

- Gruppen får permanent rolletildeling (Azure RBAC i denne POC-en, men på
  AWS/GCP/GitHub blir det andre mekanismer).
- Brukeren er *eligible member* av gruppen, ikke aktivt medlem.
- Når brukeren PIM-aktiverer, blir hen aktivt medlem av gruppen i et
  tidsbegrenset vindu, med MFA/approval/begrunnelse etter policy.
- Samme mekanisme brukes på AWS/GCP/GitHub via SCIM senere — Entra-gruppen er
  primitivet på tvers.

### Provider-valg

- `azuread ~> 3.7` (HashiCorp, GA) for:
  - Gruppe-opprettelse (`azuread_group`)
  - PIM-for-Groups eligibility (`azuread_privileged_access_group_eligibility_schedule`)
  - PIM-for-Groups policy (`azuread_group_role_management_policy`) — dekker
    activation rules (MFA, approval, varighet, notifications)
  - Access packages og katalog (Oppgave 2)
- `azurerm ~> 4.0` for permanent RBAC-tildeling på gruppen
  (`azurerm_role_assignment` med `principal_type = "Group"`). Dette er
  **Azure-spesifikk** og bytter ut per sky.
- `msgraph` **er ikke nødvendig** for POC-en. `azuread`-provideren dekker både
  PIM for Groups og access packages med typed, GA-ressurser. Reserver `msgraph`
  til eventuelle beta-endepunkter eller dokumentert fallback hvis `azuread` har
  en konkret bug.

> **Merk:** Hovedarkitekturens "Terraform Provider-valg"-seksjon anbefaler
> `msgraph` for PIM for Groups og access packages. Den anbefalingen er foreldet —
> `azuread`-provideren har siden fått full støtte for begge. Bruk `azuread`.
> Se interne notater for oppdatering av hovedarkitekturen.

### Graph API-permissions (vanligste felle)

Service principal-en som kjører Terraform må ha disse Microsoft
Graph-permissions (application type), grantet med admin consent:

- `Group.ReadWrite.All` — opprette og oppdatere grupper
- `RoleManagementPolicy.ReadWrite.AzureADGroup` — konfigurere PIM-policy
- `PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup` — tildele
  eligible-medlemskap
- `EntitlementManagement.ReadWrite.All` — access packages (Oppgave 2)

Mangler disse, får man 403-feil ved første `apply`. Sjekk dem tidlig.

### Det som skal bygges

**Sky-agnostiske moduler (gjenbrukes på alle skyer senere):**

- Modul `entra-groups` — cloud-only sikkerhetsgrupper basert på en input-map med
  navn og beskrivelse. Sky-prefiks (`azure-`, senere `aws-` osv.) settes av
  kalleren. Output: gruppe-IDer + navn.
- Modul `pim-for-groups` — PIM-policy + eligible-tildeling på en eksisterende
  gruppe. Input: gruppe-ID, activation rules (godkjenning, MFA, varighet,
  begrunnelse), eligible-medlemmer. Ren Entra-modul, ingen Azure-spesifikt.

**Azure-spesifikk modul:**

- Modul `azure-rbac-on-group` — knytter gruppe → Azure-rolle →
  subscription-scope (`azurerm_role_assignment` med `principal_type = "Group"`,
  permanent). Senere får dere parallellmoduler for AWS (permission set
  assignment via SCIM), GCP (IAM binding) osv.

**Composite per sky:**

- Modul `azure-subscription-access` — wrapper de tre over for én subscription,
  slik at LZ-kallet blir én blokk per subscription. Senere blir det
  `aws-account-access`, `gcp-project-access`, osv.

**Rot-modul i POC-repoet:**

- Itererer over `subscriptions`-mappet og kaller `azure-subscription-access` per
  oppføring.

Navnekonvensjon for grupper: `azure-{sub}-{rolle}` (jf. felles ramme). På andre
skyer blir det `aws-{konto}-{rolle}` osv. — samme prinsipp, annet prefiks.

### Inspirasjon — `bouvettl/terraform-azurerm-rbac-groups`

Vi har allerede en modul som gjør noe lignende på Azure, men på **PIM for Azure
Resources** (annen ressurs-type). Den kan ikke gjenbrukes direkte, men det er
flere ting å hente derfra:

**Verdt å stjele:**

- Navnekonvensjon og prefiks-mønster for grupper
- `azuread_group`-oppsettet (security_enabled, beskrivelse, lifecycle)
- `azurerm_role_assignment` med `principal_type = "Group"` — eksakt det vi
  trenger til `azure-rbac-on-group`
- Lifecycle/idempotency-triksene i `main.tf` og `pim-policies.tf` — særlig
  `ignore_changes` for å unngå drift, og håndtering av null-/manglende verdier
  (se `module-improvements-for-idempotency.md` og changelog v1.0.6-v1.1.0)
- Variabelvalidering-mønstre

**Skal *ikke* gjenbrukes:**

- `azurerm_pim_eligible_role_assignment` og `azurerm_role_management_policy` —
  dette er PIM for Resources; vi bruker PIM for Groups via `azuread`-provideren
  i stedet
- Variabel-skjemaet (groups → role_assignments → pim_config) — designet rundt
  feil PIM-modell og er Azure-låst. Vi trenger en enklere struktur som matcher
  tfvars-formen over og som kan utvides per sky

**Utenfor scope:** access packages (Oppgave 2), subscription-opprettelse, access
reviews, SCIM/Logic App for andre skyer, faktisk multi-cloud-implementasjon (vi
designer for det, bygger Azure).

### Akseptansekriterier

- `terraform apply` oppretter grupper, RBAC og PIM for subscriptions i tfvars.
- Permanent-rollen (f.eks. reader) har permanent gruppemedlemskap; PIM-rollene
  har eligible-medlemskap med riktig approval (team/dual), MFA der spesifisert,
  og angitt maks varighet.
- `terraform plan` etter første `apply` viser "No changes" (idempotency).
- `entra-groups` og `pim-for-groups` er sky-agnostiske og kan brukes uten
  `azurerm`-provideren installert.
- `azure-rbac-on-group` er den eneste Azure-spesifikke modulen.
- Rolnavn er konfigurerbare via tfvars — ingen hardkodede strenger som "reader"
  i modul-koden.
- Kan løftes inn i LZ-repoet uten omskriving.
- README per modul med input/output og kall-eksempel.

### Notater

- P2 dekker PIM for Groups og Azure RBAC.
- Verifiser Graph API-permissions før `apply` — det er den vanligste blokkeren.

---

## Oppgave 2 — Access packages-oppsett (access-package-repo)

**Bakgrunn.** Vi har allerede en Terraform-modul som setter opp selve access
packages. Denne oppgaven instansierer den for test-subscriptionsene og kobler
pakkene til gruppene fra Oppgave 1.

**Mål.** Gitt samme `subscriptions`-tfvars: opprett katalog og access packages
som gir tilgang til gruppene, med systemeier som godkjenner.

### Provider-valg

- `azuread ~> 3.7` for både access packages og oppslag av gruppene fra Oppgave 1:
  - `azuread_access_package_catalog` — katalog
  - `azuread_access_package` — pakke per (subscription, rolle)
  - `azuread_access_package_resource_catalog_association` — kobler katalogen til
    gruppene
  - `azuread_access_package_resource_package_association` — kobler gruppe til
    pakke
  - `azuread_access_package_assignment_policy` — request-/godkjennings-policy
  - `data "azuread_group"` — slår opp gruppene Oppgave 1 har laget på navn

**Graph API-permission:** `EntitlementManagement.ReadWrite.All` (jf. Oppgave 1).

### Det som skal bygges

- Én katalog (f.eks. `Azure Subscriptions`) som rommer pakkene.
- Per (subscription, rolle): access package med gruppa (`azure-{sub}-{rolle}`)
  som resource role — slått opp via `data "azuread_group"` på navn.
- Request-policy per pakke: hvem kan be om tilgang, systemeier som godkjenner,
  begrunnelse påkrevd, og **kort expiry på tildelingen** (f.eks. 7-14 dager) som
  substitutt for access reviews.
- Hold modul-strukturen sky-agnostisk der det er mulig — det er katalogen og
  pakke-policy-mønsteret som er felles på tvers; bare resource role-koblingen er
  Azure-spesifikk (peker på en Entra-gruppe som tilfeldigvis er knyttet til
  Azure RBAC).

**Utenfor scope:** grupper/RBAC/PIM (Oppgave 1), access reviews/lifecycle
workflows (ingen Governance), subscription-opprettelse.

### Akseptansekriterier

- `terraform apply` (etter at Oppgave 1 er kjørt) oppretter katalog og access
  packages koblet til riktige grupper.
- Bruker kan be om tilgang i MyAccess; systemeier godkjenner; tilgang gis.
- Tildeling har expiry og utløper automatisk.
- Pakker og policy er parametrisert fra samme tfvars-struktur som Oppgave 1.

### Notater

Verifiser tidlig at access packages (Entitlement Management) lar seg opprette på
ren P2 uten Governance-tillegg i POC-tenanten — Microsoft har flyttet
Entitlement Management under Entra ID Governance i nyere lisensiering. Hvis
modulen feiler på lisens, meld fra før videre bygg.

---

## Felles test (når begge er deployet)

- [ ] Be om permanent rolle (reader-eksempelet) via MyAccess → systemeier
      godkjenner → tilgang virker
- [ ] PIM-aktiver en eligible rolle (contributor) → approval → **mål tid fra
      aktivering til tilgang er synlig i Azure Portal/CLI, inkludert om brukeren
      må logge ut/inn eller refreshe sesjonen** (kritisk for PIM for Groups,
      fordi gruppe-claim må propageres til ny token)
- [ ] PIM-aktiver høyere rolle (owner) → dual approval → utløper automatisk
- [ ] Avslag → ingen tilgang
- [ ] Tildeling utløper (kort expiry) → tilgang borte
- [ ] Offboarding: fjern bruker fra tenant → all tilgang borte
