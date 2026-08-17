# Modul: `access-package-catalog`

Oppretter en Entitlement Management-katalog. **Sky-agnostisk** — katalogen er et
rent Entra-begrep og er identisk uansett hvilken sky pakkene gir tilgang til.

Modulen er liten nok at variabler, ressurs og outputs ligger i `main.tf`.

## Input

| Navn | Type | Default | Beskrivelse |
|---|---|---|---|
| `display_name` | `string` | — | Visningsnavn. |
| `description` | `string` | — | Beskrivelse. |
| `externally_visible` | `bool` | `false` | Synlig for eksterne brukere. |
| `published` | `bool` | `true` | Publisert og tilgjengelig for forespørsler. |

## Output

| Navn | Beskrivelse |
|---|---|
| `catalog_id` | ID på katalogen. |
| `display_name` | Visningsnavn. |

## Kall-eksempel

```hcl
module "catalog" {
  source = "./modules/access-package-catalog"

  display_name = "Azure Subscriptions"
  description  = "Access packages for tilgang til Azure-subscriptions."
}
```
