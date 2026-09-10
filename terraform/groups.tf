# Device assignment groups for the Intune baseline. These are the only Terraform-managed
# objects in this project — see ../README.md "Why Terraform only manages groups" for why
# the 222 Intune policies themselves are deployed by deploy/Deploy-IntuneBaseline.ps1
# (Microsoft's own Graph PowerShell SDK) instead of a Terraform resource.
#
# Uses the same official hashicorp/azuread provider as the CA-Baseline project — see
# ../terraform/providers.tf. Naming mirrors that project's persona-group convention
# (CA-Perm-*, CA-Pers-*) adapted for device targeting.
#
# ---------------------------------------------------------------------------------------
# Rollout model — see ../README.md "Rollout model" for the full narrative. Short version:
#
#   1. Pilot   — Intune-Pilot-<Platform> (below). Every policy's first assignment, always.
#                Small, manually-curated device set, one ring per platform so each can run
#                its own soak clock. Deploy script default.
#   2. Static  — Intune-Target-<Platform> (below). Manually expanded membership over the
#                engagement's agreed soak period (recommended 3-4 weeks clean). Still no
#                auto-membership — a human decides who's in scope, same governance pattern
#                Pilot Ring already used.
#   3. Dynamic — Intune-Target-<Platform>-Dynamic. Auto-populated by an OS-type rule; this
#                is "production." Provisioned only when the matching var.*_dynamic flag is
#                flipped true and `terraform apply` re-run.
#
# Stage 3 is a SEPARATE group resource from stage 2, not the same group promoted in place.
# That's deliberate, not an oversight: the azuread_group resource's `types` argument (what
# turns DynamicMembership on) is ForceNew in the hashicorp/azuread provider — confirmed by
# reading internal/services/groups/group_resource.go in the provider source — so flipping it
# on an EXISTING group would make Terraform destroy and recreate that group. Every policy
# assignment that referenced the old group's object ID would silently point at a deleted
# group. Provisioning a second, purpose-built group instead means promoting a platform to
# production is an additive Terraform apply (new object, new ID) followed by a normal
# re-run of the deploy script at -RolloutStage Dynamic — which POSTs a fresh /assign call
# pointing at the new group. The static group is left in place (harmless, and useful as an
# audit trail of who was in the pilot/expansion set) rather than torn down automatically.

resource "azuread_group" "target_windows_workstations" {
  display_name     = "Intune-Target-WindowsWorkstations"
  description      = "Entra-joined / hybrid-joined Windows 10/11 workstations — STATIC tier. Manually add devices here during pilot expansion (recommended 3-4 week soak, see README.md 'Rollout model'). Primary assignment target for categories 01-14 at -RolloutStage Static. Promote to production by flipping var.windows_workstations_dynamic and using -RolloutStage Dynamic instead."
  security_enabled = true
  mail_enabled     = false
  # Deliberately static/manual — see the file-level comment above on why this is never
  # converted to DynamicMembership in place.
}

resource "azuread_group" "target_windows_workstations_dynamic" {
  count = var.windows_workstations_dynamic ? 1 : 0

  display_name     = "Intune-Target-WindowsWorkstations-Dynamic"
  description      = "Entra-joined / hybrid-joined Windows 10/11 workstations — DYNAMIC/production tier. Auto-populated; only exists once var.windows_workstations_dynamic = true, which should only happen after Intune-Target-WindowsWorkstations has run clean through the agreed soak period. Assignment target for categories 01-14 at -RolloutStage Dynamic."
  security_enabled = true
  mail_enabled     = false
  types            = ["DynamicMembership"]

  dynamic_membership {
    enabled = true
    # Excludes anything already caught by the Server rule below, even if it reports as
    # deviceOSType windows (e.g. a Windows Server enrolled without the /Server profile).
    rule = "(device.deviceOSType -eq \"Windows\") and not (device.displayName -startsWith \"SRV-\")"
  }
}

resource "azuread_group" "target_windows_servers" {
  display_name     = "Intune-Target-WindowsServers"
  description      = "Azure Arc-enrolled / co-managed Windows Server devices. Assignment target for category 15 (Defender for Endpoint - Windows Server). Do NOT assign client ASR/CIS workstation policies (01-02) to this group — server and workstation ASR rule sets differ (see Production Notes #29-31). No dynamic tier for this group at all (not just 'not yet promoted') — Arc-enrolled servers don't reliably populate the same device attributes as Entra-joined workstations across every customer environment, so membership stays manual regardless of rollout stage."
  security_enabled = true
  mail_enabled     = false
  # Membership intentionally static/manual, not dynamic: Arc-enrolled servers don't
  # reliably populate the same device attributes as Entra-joined workstations across every
  # customer environment. Add server device objects to this group explicitly per tenant.
}

resource "azuread_group" "target_macos" {
  display_name     = "Intune-Target-macOS"
  description      = "Entra-joined macOS devices — STATIC tier. Manually add pilot/expansion devices here (see README.md 'Rollout model'). Assignment target for category 16 at -RolloutStage Static. Deploy the 10 profiles in the order documented in Intune-Baseline/manifest.json (deploy_order field) / README_Onboarding_Package.md — NOT alphabetically."
  security_enabled = true
  mail_enabled     = false
}

resource "azuread_group" "target_macos_dynamic" {
  count = var.macos_dynamic ? 1 : 0

  display_name     = "Intune-Target-macOS-Dynamic"
  description      = "Entra-joined macOS devices — DYNAMIC/production tier. Only exists once var.macos_dynamic = true. Assignment target for category 16 at -RolloutStage Dynamic."
  security_enabled = true
  mail_enabled     = false
  types            = ["DynamicMembership"]

  dynamic_membership {
    enabled = true
    rule    = "(device.deviceOSType -eq \"MacMDM\")"
  }
}

resource "azuread_group" "target_linux" {
  display_name     = "Intune-Target-Linux"
  description      = "Linux (Ubuntu/RHEL-family) devices enrolled via the Intune Linux MDM agent — STATIC tier. Manually add pilot/expansion devices here. Assignment target for the Linux Defender baseline and the Linux Device Encryption COMPLIANCE policy (reporting only — see Production Notes #24, it does not enforce encryption) at -RolloutStage Static."
  security_enabled = true
  mail_enabled     = false
}

resource "azuread_group" "target_linux_dynamic" {
  count = var.linux_dynamic ? 1 : 0

  display_name     = "Intune-Target-Linux-Dynamic"
  description      = "Linux devices — DYNAMIC/production tier. Only exists once var.linux_dynamic = true. Assignment target for the same two Linux-specific policies at -RolloutStage Dynamic."
  security_enabled = true
  mail_enabled     = false
  types            = ["DynamicMembership"]

  dynamic_membership {
    enabled = true
    rule    = "(device.deviceOSType -eq \"Linux\")"
  }
}

# --- Rollout stage 1: per-platform pilot rings -------------------------------------------
# Replaced the single mixed-platform "Intune-PilotRing" on 2026-09-08. That group was safe
# (Intune only applies a policy to a matching-platform device, so a Windows policy assigned to
# a pilot Mac was a no-op) but it made Pilot the odd tier out: Static and Dynamic were already
# per-platform, so Pilot was the only stage where every platform shared one blast radius and
# one soak clock. Splitting it means each platform moves Pilot -> Static -> Dynamic on its own
# timeline, and pilot assignment reporting stops showing 202 Windows policies targeted at Macs.
# All four are static/manual membership by design — a customer decides deliberately who is in
# the first blast radius; there is no dynamic pilot tier and there should not be one.

resource "azuread_group" "pilot_windows_workstations" {
  display_name     = "Intune-Pilot-WindowsWorkstations"
  description      = "Rollout-stage-1 pilot ring for Windows workstation policies (categories 01-14). Named WindowsWorkstations rather than Windows11 deliberately: this pack's CIS Windows policies target Windows 10 and 11 both, so a Win11-specific name would understate what actually lands here. Add pilot devices manually; promote to Intune-Target-WindowsWorkstations (-RolloutStage Static) after an agreed clean soak."
  security_enabled = true
  mail_enabled     = false
}

resource "azuread_group" "pilot_windows_servers" {
  display_name     = "Intune-Pilot-WindowsServers"
  description      = "Rollout-stage-1 pilot ring for Windows Server policies (category 15). Kept separate from the workstation pilot ring because server change windows, owners and risk tolerance are almost never the same as a workstation fleet's — this is the tier where that difference matters most."
  security_enabled = true
  mail_enabled     = false
}

resource "azuread_group" "pilot_macos" {
  display_name     = "Intune-Pilot-macOS"
  description      = "Rollout-stage-1 pilot ring for macOS policies (category 16). Promote to Intune-Target-macOS (-RolloutStage Static) after an agreed clean soak."
  security_enabled = true
  mail_enabled     = false
}

resource "azuread_group" "pilot_linux" {
  display_name     = "Intune-Pilot-Linux"
  description      = "Rollout-stage-1 pilot ring for the Linux-scoped policies (Linux Defender for Endpoint, Linux Device Encryption compliance). Promote to Intune-Target-Linux (-RolloutStage Static) after an agreed clean soak."
  security_enabled = true
  mail_enabled     = false
}

resource "azuread_group" "exclusion_break_glass" {
  display_name     = "Intune-Excl-BreakGlass"
  description      = "Break-glass / emergency-access devices, excluded from every assignment in this baseline at every rollout stage — Deploy-IntuneBaseline.ps1 adds this group as an exclusionGroupAssignmentTarget alongside the inclusion target on every single Assign-ToGroup call, whether that target is a pilot ring, a Static group, or a Dynamic group. DELIBERATELY ONE GROUP, not split per platform like the pilot/target tiers (considered and rejected 2026-09-08): break-glass gets used mid-incident by whoever is on call, and a single group has the property that matters under pressure — a device in it is excluded, full stop. Four platform-specific exclusion groups would create a way to put a device in the wrong one, believe it is protected, and be wrong. Nothing is lost by keeping it single: one group can hold a Windows admin box, a Mac and a Linux jump host at once, since Intune only applies a policy to a matching-platform device anyway. Same governance pattern as CA-BG-EmergencyAccess in the Conditional Access project — members are the break-glass devices themselves, never a human's day-to-day device."
  security_enabled = true
  mail_enabled     = false
}

output "assignment_group_ids" {
  description = "Object IDs of the groups above, consumed by deploy/Deploy-IntuneBaseline.ps1 via -AssignmentGroupIds (or resolved independently by display name if you run the script without this output — see deploy/README.md). The *_dynamic keys are null until the matching var.*_dynamic flag is flipped true and applied."
  value = {
    windows_workstations         = azuread_group.target_windows_workstations.object_id
    windows_workstations_dynamic = try(azuread_group.target_windows_workstations_dynamic[0].object_id, null)
    windows_servers               = azuread_group.target_windows_servers.object_id
    macos                         = azuread_group.target_macos.object_id
    macos_dynamic                 = try(azuread_group.target_macos_dynamic[0].object_id, null)
    linux                         = azuread_group.target_linux.object_id
    linux_dynamic                 = try(azuread_group.target_linux_dynamic[0].object_id, null)
    pilot_windows_workstations    = azuread_group.pilot_windows_workstations.object_id
    pilot_windows_servers         = azuread_group.pilot_windows_servers.object_id
    pilot_macos                   = azuread_group.pilot_macos.object_id
    pilot_linux                   = azuread_group.pilot_linux.object_id
    exclusion_break_glass         = azuread_group.exclusion_break_glass.object_id
  }
}
