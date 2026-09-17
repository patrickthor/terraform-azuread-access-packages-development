# ==============================================================================
# examples/complete — every mechanism, on local state, with no dependency on repo 1
#
# Repo 1's contract is inlined here as a literal fixture. That is the point of this
# example: the module takes the contract as a plain typed object, so it can be validated
# and planned without repo 1 having been applied, without a storage account, and without
# Storage Blob Data Reader.
#
# It doubles as executable documentation of the contract. If repo 1 changes an output,
# this fixture is the first place the mismatch shows up.
#
# The fixture mirrors the POC tenant: 11 role groups across 4 scopes, spanning all three
# JIT mechanisms, in two catalogs. Object IDs are placeholders, so a plan against a real
# tenant fails on the systemeier user lookup — that is expected.
# ==============================================================================

locals {
  contract = {
    contract_version = 2

    roles = {
      # ---- azure_pim. Membership is active; the user activates the ROLE in PIM for
      # Azure Resources. max_assignment_days is null: the ceiling does not apply.
      "tommer--readingbooks" = {
        scope            = "tommer", role = "readingbooks"
        group_name       = "azure-tommer-readingbooks", group_object_id = "00000000-0000-0000-0000-000000000001"
        access_type      = "Member", jit_mechanism = "azure_pim"
        permanent_access = true, target = "Reader", max_assignment_days = null
      }
      "tommer--contriband" = {
        scope            = "tommer", role = "contriband"
        group_name       = "azure-tommer-contriband", group_object_id = "00000000-0000-0000-0000-000000000002"
        access_type      = "Member", jit_mechanism = "azure_pim"
        permanent_access = false, target = "Contributor", max_assignment_days = null
      }
      "tommer--master" = {
        scope            = "tommer", role = "master"
        group_name       = "azure-tommer-master", group_object_id = "00000000-0000-0000-0000-000000000003"
        access_type      = "Member", jit_mechanism = "azure_pim"
        permanent_access = false, target = "Owner", max_assignment_days = null
      }
      "morkanaught--reader" = {
        scope            = "morkanaught", role = "reader"
        group_name       = "azure-morkanaught-reader", group_object_id = "00000000-0000-0000-0000-000000000004"
        access_type      = "Member", jit_mechanism = "azure_pim"
        permanent_access = true, target = "Reader", max_assignment_days = null
      }
      "morkanaught--blob-leser" = {
        scope            = "morkanaught", role = "blob-leser"
        group_name       = "azure-morkanaught-blob-leser", group_object_id = "00000000-0000-0000-0000-000000000005"
        access_type      = "Member", jit_mechanism = "azure_pim"
        permanent_access = false, target = "Storage Blob Data Reader", max_assignment_days = null
      }
      "morkanaught--nettverksdrift" = {
        scope            = "morkanaught", role = "nettverksdrift"
        group_name       = "azure-morkanaught-nettverksdrift", group_object_id = "00000000-0000-0000-0000-000000000006"
        access_type      = "Member", jit_mechanism = "azure_pim"
        permanent_access = false, target = "Network Contributor", max_assignment_days = null
      }

      # ---- pim_for_groups. CONTRACT V2: two groups per role.
      #
      # group_object_id is a PLAIN, non-PIM-managed group that repo 1 has made an eligible
      # member of the PIM-managed group named in pim_group_name. The access package attaches
      # plain Member on the plain group — which the provider fully supports — and the user
      # still activates through PIM to reach the real access.
      #
      # That is what removed the EligibleMember gap: under v1 these roles required an access
      # type the azuread provider cannot set, so they were excluded and left to the portal.
      #
      # max_assignment_days still comes from the PIM-MANAGED group's
      # active_assignment_expire_after, not from the plain group. The package assignment
      # governs membership of the plain group; if that outlives the PIM eligibility the user
      # keeps the membership and silently loses the ability to activate.
      "jaws--admin" = {
        scope            = "jaws", role = "admin"
        group_name       = "aws-jaws-admin-eligible", group_object_id = "00000000-0000-0000-0000-000000000007"
        access_type      = "Member", jit_mechanism = "pim_for_groups"
        permanent_access = false, target = "AdministratorAccess", max_assignment_days = 30
        pim_group_name   = "aws-jaws-admin", pim_group_object_id = "00000000-0000-0000-0000-0000000000a7"
      }
      "jaws--readonly" = {
        scope            = "jaws", role = "readonly"
        group_name       = "aws-jaws-readonly-eligible", group_object_id = "00000000-0000-0000-0000-000000000008"
        access_type      = "Member", jit_mechanism = "pim_for_groups"
        permanent_access = false, target = "ReadOnlyAccess", max_assignment_days = 30
        pim_group_name   = "aws-jaws-readonly", pim_group_object_id = "00000000-0000-0000-0000-0000000000a8"
      }
      "jaws--billing" = {
        scope            = "jaws", role = "billing"
        group_name       = "aws-jaws-billing-eligible", group_object_id = "00000000-0000-0000-0000-000000000009"
        access_type      = "Member", jit_mechanism = "pim_for_groups"
        permanent_access = false, target = "Billing", max_assignment_days = 15
        pim_group_name   = "aws-jaws-billing", pim_group_object_id = "00000000-0000-0000-0000-0000000000a9"
      }

      # ---- entra_role. Membership is active; the DIRECTORY ROLE is activated in PIM,
      # under rules Terraform cannot set at all.
      "tenant--groupsadmin" = {
        scope            = "tenant", role = "groupsadmin"
        group_name       = "entra-tenant-groupsadmin", group_object_id = "00000000-0000-0000-0000-00000000000a"
        access_type      = "Member", jit_mechanism = "entra_role"
        permanent_access = false, target = "Groups Administrator", max_assignment_days = null
      }
      "tenant--directoryreader" = {
        scope            = "tenant", role = "directoryreader"
        group_name       = "entra-tenant-directoryreader", group_object_id = "00000000-0000-0000-0000-00000000000b"
        access_type      = "Member", jit_mechanism = "entra_role"
        permanent_access = true, target = "Directory Readers", max_assignment_days = null
      }
    }

    scopes = {
      # tommer has two systemeier, so peer approval works there already.
      "tommer" = {
        catalog                  = "platform", cloud = "azure"
        scope_id                 = "/subscriptions/11111111-1111-1111-1111-111111111111"
        systemeier               = ["patrick@example.onmicrosoft.com", "edgar@example.onmicrosoft.com"]
        approver_group_name      = "azure-tommer-approvers"
        approver_group_object_id = "00000000-0000-0000-0000-0000000000c1"
        role_keys                = ["tommer--contriband", "tommer--master", "tommer--readingbooks"]
      }
      # One systemeier. Its approver package is what lets a second person be given approval
      # rights without also being given the access.
      "morkanaught" = {
        catalog                  = "platform", cloud = "azure"
        scope_id                 = "/subscriptions/22222222-2222-2222-2222-222222222222"
        systemeier               = ["patrick@example.onmicrosoft.com"]
        approver_group_name      = "azure-morkanaught-approvers"
        approver_group_object_id = "00000000-0000-0000-0000-0000000000c2"
        role_keys                = ["morkanaught--blob-leser", "morkanaught--nettverksdrift", "morkanaught--reader"]
      }
      "jaws" = {
        catalog                  = "platform", cloud = "aws"
        scope_id                 = "123456789012"
        systemeier               = ["patrick@example.onmicrosoft.com"]
        approver_group_name      = "aws-jaws-approvers"
        approver_group_object_id = "00000000-0000-0000-0000-0000000000c3"
        role_keys                = ["jaws--admin", "jaws--billing", "jaws--readonly"]
      }
      # No approver group: entra_role has no Terraform-managed approval at all, so repo 1
      # created none. Its own catalog because it hands out Groups Administrator.
      "tenant" = {
        catalog                  = "privileged", cloud = "entra"
        scope_id                 = null
        systemeier               = ["patrick@example.onmicrosoft.com"]
        approver_group_name      = null
        approver_group_object_id = null
        role_keys                = ["tenant--directoryreader", "tenant--groupsadmin"]
      }
    }

    catalogs = {
      "platform"   = { scope_keys = ["jaws", "morkanaught", "tommer"] }
      "privileged" = { scope_keys = ["tenant"] }
    }
  }
}

module "access_packages" {
  source = "../../modules/access-packages"

  vending = local.contract

  catalogs = {
    "platform" = {
      display_name = "Cloud Access"
      description  = "Access packages for Terraform-vended cloud access."
    }

    # Separate catalog so the most dangerous package in the system is visible in a
    # listing rather than buried among ordinary cloud access. A catalog is a delegation
    # boundary, so this also means nobody delegated the platform catalog can touch it.
    "privileged" = {
      display_name = "Privileged Directory Access"
      description  = "Entra directory roles. Terraform enforces gate 1 only — activation rules are set in the PIM portal by hand."
    }
  }

  defaults = {
    assignment_duration_days = 14
    approval_timeout_days    = 7
    require_justification    = true
  }

  # var.approver_packages is deliberately NOT set: one approver package is created for every
  # scope that has an approver group, using the defaults above. That is tommer, morkanaught and
  # jaws — three extra packages granting only the approver group, on top of the four access
  # packages.
  #
  # The approver group is no longer a resource role on any access package. Requesting access to
  # a scope no longer makes you an approver for it, and being an approver no longer requires
  # holding the access.

  # var.packages is deliberately NOT set here: this example verifies the DEFAULT path —
  # one package per scope, every role in it. See examples/named-packages for the
  # several-audiences-per-scope shape.
  #
  # package_overrides is keyed on package name, and package names are scope names on the
  # default path, so this reads exactly as scope_overrides did.
  package_overrides = {
    # Terraform can set no activation rules for directory roles, so gate 1 is the only
    # control it enforces here. Short duration is the mitigation available in code.
    "tenant" = { assignment_duration_days = 7 }
  }

  # manage_pim_for_groups_roles / acknowledge_m3_active_membership are gone. Under contract v2
  # the aws-jaws-* roles attach plain Member on a plain eligibility-carrier group, so there is
  # no EligibleMember downgrade left to opt into. Setting either flag now fails the plan with an
  # explanation rather than being quietly ignored.
}
