#!/usr/bin/env bash
#
# Does this tenant allow Entitlement Management on P2 alone?
#
# Microsoft Learn states that using PIM for Groups together with access packages
# requires Microsoft Entra ID Governance or Entra Suite licensing. The POC tenant has
# P2 only. If Entitlement Management is unavailable, nothing in this repo can be
# applied, so this is the first thing to check.
#
# The probe also narrows the EligibleMember question. If a catalog can be created but an
# eligible-member resource role is rejected at the platform level, that gap is a licensing
# limit rather than only the azuread provider's schema allowlist — and neither the msgraph
# spike nor the manual portal step would rescue it.
#
# Read-only apart from step 3, which creates a catalog and then deletes it again.
# Pass --no-write to skip that step.
#
# Usage: ./scripts/verify-entitlement-management.sh [--no-write]

set -euo pipefail

WRITE_TEST=true
if [[ "${1:-}" == "--no-write" ]]; then
  WRITE_TEST=false
fi

GRAPH="https://graph.microsoft.com/v1.0"
PROBE_CATALOG_NAME="tf-probe-delete-me-$$"

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; }
info() { printf '  ..    %s\n' "$1"; }

echo "=============================================================="
echo "Entitlement Management availability probe"
echo "=============================================================="
echo

# --------------------------------------------------------------------------------
echo "1. Signed-in context"
# --------------------------------------------------------------------------------
if ! az account show --output none 2>/dev/null; then
  fail "not signed in. Run: az login"
  exit 1
fi
TENANT_ID="$(az account show --query tenantId --output tsv)"
UPN="$(az account show --query user.name --output tsv)"
pass "tenant ${TENANT_ID} as ${UPN}"
echo

# --------------------------------------------------------------------------------
echo "2. Licensing — is Governance or Entra Suite present?"
# --------------------------------------------------------------------------------
# Service plan names to look for. AAD_PREMIUM_P2 alone is the case in question; the
# Governance plans are what Microsoft says eligible group membership actually requires.
if SKUS="$(az rest --method GET --uri "${GRAPH}/subscribedSkus" \
  --query "value[].{sku:skuPartNumber,plans:servicePlans[].servicePlanName}" \
  --output json 2>/dev/null)"; then

  if grep -qi 'IDENTITY_GOVERNANCE\|Entra_Identity_Governance' <<<"${SKUS}"; then
    pass "an Identity Governance service plan is present"
  else
    info "no Identity Governance service plan found"
  fi

  if grep -qi 'AAD_PREMIUM_P2' <<<"${SKUS}"; then
    info "AAD_PREMIUM_P2 is present"
  fi

  echo "  SKUs in this tenant:"
  az rest --method GET --uri "${GRAPH}/subscribedSkus" \
    --query "value[].skuPartNumber" --output tsv 2>/dev/null | sed 's/^/    /'
else
  info "could not read subscribedSkus. Needs Organization.Read.All or Directory.Read.All."
  info "Not fatal for this probe — steps 3 and 4 are the ones that matter."
fi
echo

# --------------------------------------------------------------------------------
echo "3. Can catalogs be read and written?"
# --------------------------------------------------------------------------------
if CATALOGS="$(az rest --method GET \
  --uri "${GRAPH}/identityGovernance/entitlementManagement/catalogs" \
  --output json 2>&1)"; then
  COUNT="$(jq -r '.value | length' <<<"${CATALOGS}" 2>/dev/null || echo "?")"
  pass "catalogs are readable (${COUNT} existing)"
else
  fail "cannot read catalogs. Entitlement Management looks unavailable or unlicensed."
  echo "${CATALOGS}" | sed 's/^/    /'
  echo
  echo "  This blocks the entire repo. Record the result and stop here."
  exit 1
fi

if [[ "${WRITE_TEST}" == "true" ]]; then
  info "creating probe catalog '${PROBE_CATALOG_NAME}'"
  if CREATED="$(az rest --method POST \
    --uri "${GRAPH}/identityGovernance/entitlementManagement/catalogs" \
    --headers "Content-Type=application/json" \
    --body "{\"displayName\":\"${PROBE_CATALOG_NAME}\",\"description\":\"Temporary probe, safe to delete\",\"isExternallyVisible\":false}" \
    --output json 2>&1)"; then

    PROBE_ID="$(jq -r '.id' <<<"${CREATED}")"
    pass "catalog creation works (id ${PROBE_ID})"

    info "deleting probe catalog"
    if az rest --method DELETE \
      --uri "${GRAPH}/identityGovernance/entitlementManagement/catalogs/${PROBE_ID}" \
      --output none 2>/dev/null; then
      pass "probe catalog deleted"
    else
      fail "could not delete probe catalog ${PROBE_ID}. Remove it by hand."
    fi
  else
    fail "catalog creation was rejected"
    echo "${CREATED}" | sed 's/^/    /'
    echo
    echo "  Read is allowed but write is not. That is usually a missing"
    echo "  EntitlementManagement.ReadWrite.All permission rather than licensing —"
    echo "  check scripts/grant-graph-permissions.sh before concluding it is a"
    echo "  license problem."
  fi
else
  info "skipping the write test (--no-write)"
fi
echo

# --------------------------------------------------------------------------------
echo "4. Which resource role types does the tenant offer for a PIM-managed group?"
# --------------------------------------------------------------------------------
# This is the EligibleMember question. The Entra platform is documented to offer
# "Eligible Member" for groups onboarded to PIM for Groups, while the azuread
# provider accepts only Member and Owner. If the platform does not offer it either,
# the cause is licensing rather than the provider and option 2 would not help.
echo "  Manual check, because it needs a group already registered as a catalog"
echo "  resource. After the first apply of this repo:"
echo
echo "    az rest --method GET --uri \\"
echo "      \"${GRAPH}/identityGovernance/entitlementManagement/catalogs/<catalog-id>/resourceRoles?\\\$filter=(originSystem+eq+'AadGroup')&\\\$expand=resource\""
echo
echo "  Look at the displayName values in the response:"
echo "    'Member' and 'Owner' only     → the platform agrees with the provider;"
echo "                                     the limit is licensing, not the provider"
echo "    'Eligible Member' also present → the platform supports it and the gap is"
echo "                                     purely the Terraform provider, so the"
echo "                                     portal workaround in option 1 will work"
echo

echo "=============================================================="
echo "Record the outcome in README.md under 'Verified in this tenant', and leave the"
echo "row blank until it is actually verified. A blank row is an honest unverified"
echo "claim; a filled-in row nobody tested is not."
echo "=============================================================="
