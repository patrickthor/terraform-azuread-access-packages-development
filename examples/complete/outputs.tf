# The interesting outputs here are the honesty ones. A clean apply does not mean the model
# holds — read what was left out before believing it.

output "catalogs" {
  description = "Two catalogs: platform and privileged. Both created, neither adopted, no standing delegation."
  value       = module.access_packages.catalogs
}

output "packages_by_catalog" {
  description = <<-EOT
    Seven packages, not four. platform holds the jaws, morkanaught and tommer access packages
    plus their three approver packages; privileged holds tenant, which has no approver group.
  EOT
  value       = module.access_packages.packages_by_catalog
}

output "packages" {
  description = <<-EOT
    Every package with its `kind`. Four `access` (one per scope, source = "scope") and three
    `approver` (tommer, morkanaught, jaws — the scopes with an approver group).
  EOT
  value       = module.access_packages.packages
}

output "approver_packages" {
  description = <<-EOT
    Scope → the package granting peer-approval rights over it. Three entries.

    These are the packages that used to be a resource role on the access package. Holding the
    access no longer makes you an approver, and being an approver no longer requires holding
    the access.
  EOT
  value       = module.access_packages.approver_packages
}

output "verification_summary" {
  description = <<-EOT
    Grouped by kind, which is how you confirm the split landed.

    Expected: 4 access packages each granting only role groups with grants_approver_group =
    false, 3 approver packages each granting exactly one group, and totals showing
    roles_excluded = 0 and contract_version = 2.
  EOT
  value       = module.access_packages.verification_summary
}

output "excluded_resource_roles" {
  description = <<-EOT
    Should be EMPTY. Under contract v2 the aws-jaws-* roles attach plain Member on plain
    eligibility-carrier groups, so the EligibleMember gap no longer applies to them and nothing
    is left out. An empty map here is the signal, not an absence of information.
  EOT
  value       = module.access_packages.excluded_resource_roles
}

output "unpackaged_roles" {
  description = "Should be EMPTY on the default path: the generated per-scope packages cover every role."
  value       = module.access_packages.unpackaged_roles
}

output "manual_steps_required" {
  description = <<-EOT
    Shorter than it used to be: the EligibleMember portal step is gone. What remains is the
    entra_role PIM rules for the tenant scope, and SCIM on the AWS side for jaws.
  EOT
  value       = module.access_packages.manual_steps_required
}

output "peer_approval_status" {
  description = <<-EOT
    viable = true for tommer, morkanaught and jaws, each naming its approver package. false for
    tenant, which has no approver group. deadlock_risk should be false everywhere, because every
    scope with an approver group got an approver package.
  EOT
  value       = module.access_packages.peer_approval_status
}

output "gate_1_approvers" {
  description = <<-EOT
    Per package, both kinds. Note that the approver packages route to the same systemeier as
    their scope's access package — never to the approver group itself.
  EOT
  value       = module.access_packages.gate_1_approvers
}

output "gate_2_approvers" {
  description = <<-EOT
    Republished per role. `attached_group` is what the package grants; `activation_group` is the
    PIM-managed group behind it for pim_for_groups roles. Both tenant roles show
    terraform_governs_activation = false.
  EOT
  value       = module.access_packages.gate_2_approvers
}

output "granted_groups_by_package" {
  description = <<-EOT
    What each package actually grants. For the jaws roles, `group_name` is the plain carrier
    group and `confers_eligibility_on` is the PIM-managed group — without both, the listing
    would imply the carrier group is the access.
  EOT
  value       = module.access_packages.granted_groups_by_package
}
