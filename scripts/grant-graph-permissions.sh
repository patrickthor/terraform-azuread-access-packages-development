#!/usr/bin/env bash
#
# Grant the Microsoft Graph application permissions that the service principal
# running Terraform in this repo needs.
#
# Requires you to be signed in as Global Administrator or Privileged Role
# Administrator: az login
#
# Usage: ./scripts/grant-graph-permissions.sh <application-client-id>

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <application-client-id>" >&2
  exit 1
fi

APP_ID="$1"

# Microsoft Graph resource app ID. Constant across all tenants.
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"

# Missing permissions surface as a 403 on the first apply and are the single most
# common blocker on this repo.
#
# If you run both repos with the SAME service principal — which is recommended, see
# trap 6.5 — also run repo 1's bootstrap/grant-graph-permissions.sh. It grants
# Group.ReadWrite.All, RoleManagementPolicy.ReadWrite.AzureADGroup and
# PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup, which repo 2 does not need.
PERMISSIONS=(
  # Catalogs, access packages, assignment policies, resource roles.
  "EntitlementManagement.ReadWrite.All"

  # Group lookups. The catalog resource association needs write access to the
  # package, not to the group, so read is enough here.
  "Group.Read.All"

  # data "azuread_user" for the systemeier who approve at gate 1. Without this the
  # plan fails on the user lookup before it creates anything, which at least fails
  # loudly rather than silently.
  "User.Read.All"
)

echo "Looking up the service principal for app ${APP_ID}..."
SP_OBJECT_ID="$(az ad sp show --id "${APP_ID}" --query id --output tsv)"
GRAPH_SP_OBJECT_ID="$(az ad sp show --id "${GRAPH_APP_ID}" --query id --output tsv)"

echo "Service principal object ID: ${SP_OBJECT_ID}"
echo

for PERMISSION in "${PERMISSIONS[@]}"; do
  echo "Processing ${PERMISSION}..."

  ROLE_ID="$(az ad sp show --id "${GRAPH_APP_ID}" \
    --query "appRoles[?value=='${PERMISSION}'].id | [0]" \
    --output tsv)"

  if [[ -z "${ROLE_ID}" || "${ROLE_ID}" == "None" ]]; then
    echo "  ERROR: no app role found for ${PERMISSION}" >&2
    exit 1
  fi

  # Idempotent: skip if the assignment already exists.
  EXISTING="$(az rest \
    --method GET \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
    --query "value[?appRoleId=='${ROLE_ID}'] | [0].id" \
    --output tsv 2>/dev/null || true)"

  if [[ -n "${EXISTING}" && "${EXISTING}" != "None" ]]; then
    echo "  Already granted, skipping."
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

  echo "  Granted."
done

echo
echo "Done. Verify in the Entra portal under App registrations >"
echo "${APP_ID} > API permissions that everything shows as 'Granted'."
echo
echo "This repo also needs Storage Blob Data Reader on repo 1's state storage"
echo "account, which is an Azure RBAC role rather than a Graph permission and is"
echo "not granted by this script:"
echo
echo "  az role assignment create \\"
echo "    --assignee ${APP_ID} \\"
echo "    --role 'Storage Blob Data Reader' \\"
echo "    --scope \"\$(az storage account show -n <state-account> -g <state-rg> --query id -o tsv)\""
