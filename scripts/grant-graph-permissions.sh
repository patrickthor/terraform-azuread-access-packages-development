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
# ONE IDENTITY RUNS BOTH MODULES. That is not a convenience: repo 1's identity owns
# every group it creates, and azuread_access_package_resource_catalog_association fails
# with CallerNotResourceOwner when the caller does not own the group being linked. A
# separate identity for repo 2 would need group ownership or Catalog owner on top.
#
# So in practice you run this script AND repo 1's, against the same app. Repo 1 needs
# Group.ReadWrite.All, RoleManagementPolicy.ReadWrite.AzureADGroup and
# PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup, which repo 2 does not.
PERMISSIONS=(
  # Catalogs, access packages, assignment policies, resource roles.
  "EntitlementManagement.ReadWrite.All"

  # data "azuread_user" for the systemeier who approve at gate 1. Without it the plan
  # fails on the user lookup before creating anything, which at least fails loudly.
  #
  # Also needed by repo 1, for the same systemeier.
  "User.Read.All"

  # Group.Read.All is deliberately NOT here. Repo 2 no longer looks groups up by name —
  # every group object ID arrives in repo 1's contract, so there is nothing to read.
  # Granting it anyway would be tenant-wide group read for no reason.
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
echo "Admin consent cannot be automated, and should not be: a pipeline able to grant"
echo "itself tenant-wide group write is a privilege-escalation path."
echo
echo "Azure RBAC is separate and not granted by this script. The root config needs"
echo "Storage Blob Data Contributor on the account holding its own state:"
echo
echo "  az role assignment create \\"
echo "    --assignee ${APP_ID} \\"
echo "    --role 'Storage Blob Data Contributor' \\"
echo "    --scope \"\$(az storage account show -n <state-account> -g <state-rg> --query id -o tsv)\""
echo
echo "The split-state root in this repo additionally reads repo 1's state. If that lives"
echo "in a different account, Storage Blob Data Reader on it is enough. The reference"
echo "two-module root needs neither, because the contract never touches a state file."
