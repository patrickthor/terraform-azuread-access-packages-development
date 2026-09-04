# ==============================================================================
# examples/complete — every mechanism, on local state, with no dependency on repo 1
#
# The contract that the root module reads from repo 1's remote state is inlined here
# as a literal fixture. That is the whole point of this example: the module takes the
# taxonomy as a plain input, so it can be exercised without a live storage account,
# without Storage Blob Data Reader, and without repo 1 having been applied.
#
# It also serves as executable documentation of the contract shape. If repo 1 changes
# an output, this fixture is where the mismatch shows up first.
#
# The fixture mirrors the POC tenant: 11 role groups across 4 scopes, spanning all
# three JIT mechanisms, plus 3 approver groups. Object IDs are placeholders — a plan
# against a real tenant would fail on the systemeier user lookup, which is expected.
# ==============================================================================

locals {
  vending = {
    group_names = {
      # M2 — azure_pim. Membership is active; the user activates the Azure role in PIM.
      "tommer--readingbooks"        = "azure-tommer-readingbooks"
      "tommer--contriband"          = "azure-tommer-contriband"
      "tommer--master"              = "azure-tommer-master"
      "morkanaught--reader"         = "azure-morkanaught-reader"
      "morkanaught--blob-leser"     = "azure-morkanaught-blob-leser"
      "morkanaught--nettverksdrift" = "azure-morkanaught-nettverksdrift"

      # M3 — pim_for_groups. Needs EligibleMember, which the provider cannot set.
      "jaws--admin"    = "aws-jaws-admin"
      "jaws--readonly" = "aws-jaws-readonly"
      "jaws--billing"  = "aws-jaws-billing"

      # M4 — entra_role. Membership is active; the directory role is activated in PIM,
      # under rules Terraform cannot manage at all.
      "tenant--groupsadmin"     = "entra-tenant-groupsadmin"
      "tenant--directoryreader" = "entra-tenant-directoryreader"
    }

    group_object_ids = {
      "tommer--readingbooks"        = "00000000-0000-0000-0000-000000000001"
      "tommer--contriband"          = "00000000-0000-0000-0000-000000000002"
      "tommer--master"              = "00000000-0000-0000-0000-000000000003"
      "morkanaught--reader"         = "00000000-0000-0000-0000-000000000004"
      "morkanaught--blob-leser"     = "00000000-0000-0000-0000-000000000005"
      "morkanaught--nettverksdrift" = "00000000-0000-0000-0000-000000000006"
      "jaws--admin"                 = "00000000-0000-0000-0000-000000000007"
      "jaws--readonly"              = "00000000-0000-0000-0000-000000000008"
      "jaws--billing"               = "00000000-0000-0000-0000-000000000009"
      "tenant--groupsadmin"         = "00000000-0000-0000-0000-00000000000a"
      "tenant--directoryreader"     = "00000000-0000-0000-0000-00000000000b"
    }

    # The blocker 2.1 surface. Only pim_for_groups returns EligibleMember.
    access_package_access_type = {
      "tommer--readingbooks"        = "Member"
      "tommer--contriband"          = "Member"
      "tommer--master"              = "Member"
      "morkanaught--reader"         = "Member"
      "morkanaught--blob-leser"     = "Member"
      "morkanaught--nettverksdrift" = "Member"
      "jaws--admin"                 = "EligibleMember"
      "jaws--readonly"              = "EligibleMember"
      "jaws--billing"               = "EligibleMember"
      "tenant--groupsadmin"         = "Member"
      "tenant--directoryreader"     = "Member"
    }

    jit_mechanism = {
      "tommer--readingbooks"        = "azure_pim"
      "tommer--contriband"          = "azure_pim"
      "tommer--master"              = "azure_pim"
      "morkanaught--reader"         = "azure_pim"
      "morkanaught--blob-leser"     = "azure_pim"
      "morkanaught--nettverksdrift" = "azure_pim"
      "jaws--admin"                 = "pim_for_groups"
      "jaws--readonly"              = "pim_for_groups"
      "jaws--billing"               = "pim_for_groups"
      "tenant--groupsadmin"         = "entra_role"
      "tenant--directoryreader"     = "entra_role"
    }

    # Keyed on scope, not on the composite key. Gate 1 approvers.
    # tommer has two, so peer approval works there already. morkanaught and jaws have
    # one each — the deadlock in section 4.5 that option A resolves.
    systemeier_by_scope = {
      "tommer"      = ["patrick@example.onmicrosoft.com", "edgar@example.onmicrosoft.com"]
      "morkanaught" = ["patrick@example.onmicrosoft.com"]
      "jaws"        = ["patrick@example.onmicrosoft.com"]
      "tenant"      = ["patrick@example.onmicrosoft.com"]
    }

    # Only scopes with at least one dual-approval role get an approver group. `tenant`
    # has none because entra_role has no Terraform-managed approval at all.
    approver_group_object_ids = {
      "tommer"      = "00000000-0000-0000-0000-0000000000c1"
      "morkanaught" = "00000000-0000-0000-0000-0000000000c2"
      "jaws"        = "00000000-0000-0000-0000-0000000000c3"
    }

    approver_group_names = {
      "tommer"      = "azure-tommer-approvers"
      "morkanaught" = "azure-morkanaught-approvers"
      "jaws"        = "aws-jaws-approvers"
    }

    approver_group_is_managed_here = {
      "tommer"      = true
      "morkanaught" = true
      "jaws"        = true
    }

    # Gate 2. Forwarded to outputs, never interpreted by this module.
    approvers_by_role = {
      "tommer--readingbooks"        = { approval_type = "owner", systemeier_approves = true, approver_group = null }
      "tommer--contriband"          = { approval_type = "dual", systemeier_approves = true, approver_group = "azure-tommer-approvers" }
      "tommer--master"              = { approval_type = "dual", systemeier_approves = true, approver_group = "azure-tommer-approvers" }
      "morkanaught--reader"         = { approval_type = "owner", systemeier_approves = true, approver_group = null }
      "morkanaught--blob-leser"     = { approval_type = "self", systemeier_approves = false, approver_group = null }
      "morkanaught--nettverksdrift" = { approval_type = "owner", systemeier_approves = true, approver_group = null }
      "jaws--admin"                 = { approval_type = "owner", systemeier_approves = true, approver_group = null }
      "jaws--readonly"              = { approval_type = "self", systemeier_approves = false, approver_group = null }
      "jaws--billing"               = { approval_type = "dual", systemeier_approves = true, approver_group = "aws-jaws-approvers" }
      "tenant--groupsadmin"         = { approval_type = "not managed by Terraform", systemeier_approves = false, approver_group = null }
      "tenant--directoryreader"     = { approval_type = "not managed by Terraform", systemeier_approves = false, approver_group = null }
    }

    entra_activation_governance_gap = {
      "tenant--groupsadmin" = {
        role                 = "Groups Administrator"
        unmanaged_attributes = ["require_mfa", "approval_required", "max_activation_duration"]
        why                  = "The azuread provider has no resource for directory role management policies. Set these in the PIM portal by hand."
      }
      "tenant--directoryreader" = {
        role                 = "Directory Readers"
        unmanaged_attributes = []
        why                  = "Permanent access, so there is no activation step to govern."
      }
    }
  }
}

module "access_packages" {
  source = "../../modules/access-packages"

  vending = local.vending

  catalog_display_name = var.catalog_display_name

  defaults = {
    assignment_duration_days = 14
    approval_timeout_days    = 7
    require_justification    = true

    # Option A from section 5.5. Attaches each scope's approver group to its package,
    # which is what makes peer approval real and fixes the single-systemeier deadlock
    # on morkanaught and jaws.
    grant_approver_group = true
  }

  scope_overrides = {
    # Trap 6.7. This package hands out Groups Administrator, and Terraform can set no
    # activation rules for directory roles, so gate 1 is the only control it enforces.
    # A short duration is the mitigation available here.
    "tenant" = { assignment_duration_days = 7 }
  }

  # Blocker 2.1, option 1. The three aws-jaws-* roles need EligibleMember, which the
  # provider cannot set, so they are left out and reported in excluded_resource_roles
  # instead of being silently downgraded to active membership.
  manage_pim_for_groups_roles = false
}
