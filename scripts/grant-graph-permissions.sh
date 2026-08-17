#!/usr/bin/env bash
#
# Granter Microsoft Graph application permissions til service principal-en som
# kjører Terraform i dette repoet.
#
# Krever at du er innlogget som Global Administrator eller Privileged Role
# Administrator: az login
#
# Bruk: ./scripts/grant-graph-permissions.sh <application-client-id>

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Bruk: $0 <application-client-id>" >&2
  exit 1
fi

APP_ID="$1"

# Microsoft Graph resource app ID (konstant på tvers av tenanter).
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"

# Access-package-repoet trenger bare entitlement management. Gruppene leses via
# samme permission (katalogassosiasjonen krever skrivetilgang til pakkene, ikke
# til gruppene).
#
# Kjører du begge repoene med SAMME service principal, bruk vending-repoets
# script i tillegg — det granter Group.ReadWrite.All,
# RoleManagementPolicy.ReadWrite.AzureADGroup og
# PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup.
PERMISSIONS=(
  "EntitlementManagement.ReadWrite.All"
  "Group.Read.All"
)

echo "Slår opp service principal for app ${APP_ID}..."
SP_OBJECT_ID="$(az ad sp show --id "${APP_ID}" --query id --output tsv)"
GRAPH_SP_OBJECT_ID="$(az ad sp show --id "${GRAPH_APP_ID}" --query id --output tsv)"

echo "Service principal object ID: ${SP_OBJECT_ID}"
echo

for PERMISSION in "${PERMISSIONS[@]}"; do
  echo "Behandler ${PERMISSION}..."

  ROLE_ID="$(az ad sp show --id "${GRAPH_APP_ID}" \
    --query "appRoles[?value=='${PERMISSION}'].id | [0]" \
    --output tsv)"

  if [[ -z "${ROLE_ID}" || "${ROLE_ID}" == "None" ]]; then
    echo "  FEIL: fant ikke app role for ${PERMISSION}" >&2
    exit 1
  fi

  # Idempotent: hopp over hvis tildelingen allerede finnes.
  EXISTING="$(az rest \
    --method GET \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
    --query "value[?appRoleId=='${ROLE_ID}'] | [0].id" \
    --output tsv 2>/dev/null || true)"

  if [[ -n "${EXISTING}" && "${EXISTING}" != "None" ]]; then
    echo "  Allerede grantet, hopper over."
    continue
  fi

  az rest \
    --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{
      \"principalId\": \"${SP_OBJECT_ID}\",
      \"resourceId\": \"${GRAPH_SP_OBJECT_ID}\",
      \"appRoleId\": \"${ROLE_ID}\"
    }" \
    --output none

  echo "  Grantet."
done

echo
echo "Ferdig. Verifiser i Entra-portalen under App registrations >"
echo "${APP_ID} > API permissions at alle står som 'Granted'."
