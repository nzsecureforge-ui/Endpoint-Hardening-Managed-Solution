<#
.SYNOPSIS
    Deploys the Intune-Baseline/ policy pack to a customer tenant via the Microsoft Graph
    PowerShell SDK — no third-party Terraform provider involved (see ../README.md for why).

.DESCRIPTION
    Reads Intune-Baseline/manifest.json (built by ../scripts/build_baseline.py — never
    hand-edit the manifest or the cleaned policy JSON, regenerate instead) and, for every
    policy in scope, does an idempotent get-by-name / create-or-update against the correct
    Graph beta endpoint for that policy's shape, then assigns it to the target group.

    Uses Invoke-MgGraphRequest (raw REST) rather than the generated Microsoft.Graph.Beta.
    DeviceManagement cmdlets deliberately: that module's beta cmdlet surface changes often
    between versions, while the underlying REST endpoints documented at
    learn.microsoft.com/graph/api/resources/intune-graph-overview are the stable contract.
    This also keeps the module footprint small (just Microsoft.Graph.Authentication).

    Every REST shape below was derived from the actual cleaned source JSON in
    Intune-Baseline/, not from memory of the Graph API. As of 2026-09-08 this script HAS been
    run end-to-end against a live tenant: all 212 in-scope policies across all 5 Graph object
    shapes deployed and verified clean (see RECONCILIATION.md 19). Before changing anything
    here, run ../test/Invoke-OfflineReplay.ps1 — it replays the whole pack against a mocked
    Graph layer and asserts on every request, and exists because five separate deploy failures
    were each found the hard way, one live run at a time, when all five were findable offline.

.PARAMETER CustomerConfigPath
    Path to the customer's copy of ../config/customer.config.psd1. Validated by
    Test-CustomerConfig.ps1 before anything else runs.

.PARAMETER Categories
    Optional list of category folder names (e.g. '01_Defender_for_Endpoint (Windows + Linux)')
    to restrict this run to. Default: all.

.PARAMETER SkipCategories
    Optional list of category folder names to exclude.

.PARAMETER SkipPolicyIds
    Optional list of individual policy ids (exactly as they appear in manifest.json, e.g.
    '13-Google-Chrome-CIS-Benchmark/Baseline-Chrome-Enable-Site-Isolation-for-specified-origins')
    to exclude, without dropping the rest of their category. Useful for a policy whose
    customer-specific value isn't available yet. Throws if an id matches nothing in scope,
    rather than silently skipping nothing.

.PARAMETER AuditModeForFlaggedPolicies
    Default $true. Deploys the 3 manifest entries with audit_first_recommended=true
    (Controlled Folder Access x2, the constructed webshell ASR rule) in audit mode instead
    of their source-recorded block mode, per Production Notes #17/#29/#30. Pass -AuditModeForFlaggedPolicies:$false
    once a customer's pilot ring has been reviewed and you're promoting to block mode.

.PARAMETER RolloutStage
    Which assignment group tier this run targets — see ../README.md "Rollout model" for the
    full narrative. Default 'Pilot'.

      Pilot   (default) — assigns via the category -> platform map to the per-platform PILOT
                ring: Intune-Pilot-WindowsWorkstations / -WindowsServers / -macOS / -Linux.
                Manually-curated membership; this is the first blast radius. (Before
                2026-09-08 this was one mixed-platform Intune-PilotRing group for everything —
                see ../README.md "Rollout model" for why it was split.)
      Static  — assigns via the category -> platform map to the STATIC Intune-Target-<X>
                group (manually-curated membership; expand it by hand during the engagement's
                soak period, recommended 3-4 weeks with no policy-related issues).
      Dynamic — assigns to the DYNAMIC/production Intune-Target-<X>-Dynamic group instead.
                That group only exists once the matching terraform.tfvars flag has been
                flipped true and applied (see ../terraform/terraform.tfvars.example) — this
                script throws a clear error naming the flag if it's missing. Windows Server
                devices have no Dynamic tier at all (Arc enrollment doesn't populate device
                attributes reliably enough) and stay on the Static group with a warning.

    In every stage, Intune-Excl-BreakGlass is added as an exclusion on every single
    assignment, so break-glass devices are protected regardless of rollout stage.

.PARAMETER WhatIf
    Standard PowerShell ShouldProcess support — prints what would be created/updated/assigned
    without calling Graph.

.EXAMPLE
    ./Deploy-IntuneBaseline.ps1 -CustomerConfigPath ./customer.config.psd1 -SkipCategories '16_Defender_for_Endpoint_macOS'

.EXAMPLE
    # Promote Windows workstations to production after a clean pilot + static soak period
    # (run terraform apply with windows_workstations_dynamic = true first):
    ./Deploy-IntuneBaseline.ps1 -CustomerConfigPath ./customer.config.psd1 -RolloutStage Dynamic -Categories '02_Windows_CIS_Benchmark_Hardening'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$CustomerConfigPath,
    [string[]]$Categories,
    [string[]]$SkipCategories,
    [string[]]$SkipPolicyIds,
    [bool]$AuditModeForFlaggedPolicies = $true,
    [ValidateSet('Pilot', 'Static', 'Dynamic')] [string]$RolloutStage = 'Pilot',
    [string]$ManifestRoot = (Join-Path $PSScriptRoot "..\Intune-Baseline")
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\config\Test-CustomerConfig.ps1")

$macOSInScope = (-not $Categories -or $Categories -contains "16_Defender_for_Endpoint_macOS") -and
                (-not $SkipCategories -or $SkipCategories -notcontains "16_Defender_for_Endpoint_macOS")
$cfg = Test-CustomerConfig -ConfigPath $CustomerConfigPath -RequireMacOS:$macOSInScope

if (-not (Get-MgContext)) {
    throw "Not connected to Microsoft Graph. Run Connect-MgGraph (app-only, via the credentials from bootstrap/New-AppRegistration.ps1) before this script. This script never manages the connection itself, so the caller is always explicit about which tenant it's touching."
}
Write-Host "Deploying to tenant: $((Get-MgContext).TenantId)" -ForegroundColor Cyan
Write-Host "Rollout stage: $RolloutStage" -ForegroundColor Cyan
Write-Host "  -> assigning via category -> platform map, $RolloutStage tier. Intune-Excl-BreakGlass is excluded on every assignment." -ForegroundColor DarkGray

$manifestPath = Join-Path $ManifestRoot "manifest.json"
$manifest = (Get-Content $manifestPath -Raw | ConvertFrom-Json).policies

if ($Categories)     { $manifest = $manifest | Where-Object { $_.category -in $Categories } }
if ($SkipCategories) { $manifest = $manifest | Where-Object { $_.category -notin $SkipCategories } }
if ($SkipPolicyIds) {
    # Skip individual policies without having to drop their whole category — used when one
    # policy needs a customer value that isn't available yet (see the ChromeIsolatedOrigins
    # and QuickMachineRecovery warnings) but the rest of its category should still deploy.
    $unknown = $SkipPolicyIds | Where-Object { $_ -notin $manifest.id }
    if ($unknown) {
        throw "-SkipPolicyIds contains $($unknown.Count) id(s) that match no policy in scope: $($unknown -join ', '). Ids must match manifest.json exactly (hyphenated category segment, e.g. '13-Google-Chrome-CIS-Benchmark/Baseline-Chrome-Enable-Site-Isolation-for-specified-origins'). Failing here rather than silently skipping nothing."
    }
    $manifest = $manifest | Where-Object { $_.id -notin $SkipPolicyIds }
}

Write-Host "$($manifest.Count) polic$(if ($manifest.Count -eq 1) {'y'} else {'ies'}) in scope." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Assignment group resolution
# ---------------------------------------------------------------------------

$script:GroupIdCache = @{}

function Resolve-AssignmentGroupId {
    param([string]$Key, [hashtable]$ConfiguredIds)
    if ($script:GroupIdCache.ContainsKey($Key)) { return $script:GroupIdCache[$Key] }
    if ($ConfiguredIds[$Key]) { $script:GroupIdCache[$Key] = $ConfiguredIds[$Key]; return $ConfiguredIds[$Key] }
    $displayNameMap = @{
        PilotWindowsWorkstations    = "Intune-Pilot-WindowsWorkstations"
        PilotWindowsServers         = "Intune-Pilot-WindowsServers"
        PilotMacOS                  = "Intune-Pilot-macOS"
        PilotLinux                  = "Intune-Pilot-Linux"
        WindowsWorkstations         = "Intune-Target-WindowsWorkstations"
        WindowsWorkstationsDynamic  = "Intune-Target-WindowsWorkstations-Dynamic"
        WindowsServers              = "Intune-Target-WindowsServers"
        MacOS                       = "Intune-Target-macOS"
        MacOSDynamic                = "Intune-Target-macOS-Dynamic"
        Linux                       = "Intune-Target-Linux"
        LinuxDynamic                = "Intune-Target-Linux-Dynamic"
        ExclusionBreakGlass         = "Intune-Excl-BreakGlass"
    }
    $displayName = $displayNameMap[$Key]
    $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$displayName'"
    if ($resp.value.Count -eq 0) {
        $hint = if ($Key -like 'Pilot*') {
            "This is a rollout-stage-1 pilot ring. Run 'terraform apply' in ../terraform/ first — as of 2026-09-08 the single 'Intune-PilotRing' group was replaced by four per-platform pilot rings, so a tenant built before that change needs a re-apply to create them (and its old Intune-PilotRing membership moved across by hand). See README.md 'Rollout model'."
        } elseif ($Key -like '*Dynamic') {
            "This is the promotion-to-production tier — it's only provisioned once the matching terraform.tfvars flag (see ../terraform/terraform.tfvars.example) is flipped true and 'terraform apply' re-run. Don't flip it until the static tier has run clean through the agreed soak period."
        } else {
            "Run 'terraform apply' in ../terraform/ first (see README.md), or populate AssignmentGroupIds.$Key in the customer config directly."
        }
        throw "Assignment group '$displayName' not found. $hint"
    }
    $script:GroupIdCache[$Key] = $resp.value[0].id
    return $resp.value[0].id
}

# Category -> platform key. Used at EVERY rollout stage now — Get-EffectiveGroupKey below
# turns the platform key into the tier's group ("Pilot" prefix / "Dynamic" suffix / bare for
# Static), so Pilot is no longer a special case that ignores the policy's platform.
$categoryGroupKey = @{
    "01_Defender_for_Endpoint (Windows + Linux)" = "WindowsWorkstations"
    "02_Windows_CIS_Benchmark_Hardening"          = "WindowsWorkstations"
    "03_Audit_and_Logging"                        = "WindowsWorkstations"
    "04_Identity_and_Authentication"              = "WindowsWorkstations"
    "05_Tenant_and_Account_Access_Control"        = "WindowsWorkstations"
    "06_Data_Encryption"                          = "WindowsWorkstations"   # overridden per-policy below for the one Linux-specific policy — see $LinuxSpecificPolicyIds
    "07_Firewall_and_Network_Security"            = "WindowsWorkstations"
    "08_Removable_Media_and_Device_Control"       = "WindowsWorkstations"
    "09_Patch_Management"                         = "WindowsWorkstations"
    "10_Privacy_and_AI_Data_Governance"           = "WindowsWorkstations"
    "11_Microsoft_Edge_CIS_Benchmark"             = "WindowsWorkstations"
    "12_Passwordless_Authentication"              = "WindowsWorkstations"
    "13_Google_Chrome_CIS_Benchmark"              = "WindowsWorkstations"
    "14_Modern_Workplace_and_Resilience"          = "WindowsWorkstations"
    "15_Defender_for_Endpoint_Windows_Server"     = "WindowsServers"
    "16_Defender_for_Endpoint_macOS"              = "MacOS"
}

# The only two policies in the manifest that are Linux-specific despite living in a
# Windows-titled category (01's category label is literally "...(Windows + Linux)"; 06 mixes
# a Windows BitLocker intent with one Linux compliance policy). manifest.json has no explicit
# per-policy platform field to key off, so this is a hand-verified exception list rather than
# a schema-driven filter — re-check it if build_baseline.py's source pack is ever regenerated
# with renamed/added Linux policies (see RECONCILIATION.md).
$LinuxSpecificPolicyIds = @(
    "01-Defender-for-Endpoint-Windows-Linux/Baseline-Defender-for-Endpoint-Linux"
    "06-Data-Encryption/Baseline-Linux-Device-Encryption"
)

$script:WarnedServerNoDynamic = $false

function Get-EffectiveGroupKey {
    # Every stage now resolves the policy's platform the same way and then applies a tier
    # affix: Pilot prefixes "Pilot", Dynamic suffixes "Dynamic", Static uses the bare key.
    # Before 2026-09-08 Pilot short-circuited to a single mixed-platform 'PilotRing' group for
    # every policy regardless of platform — that special case is gone, so the three tiers are
    # now structurally identical and a platform can move through them on its own timeline.
    param($Policy, [string]$Stage)

    $baseKey = if ($Policy.shape -eq 'macos_custom_configuration') { 'MacOS' } else { $categoryGroupKey[$Policy.category] }
    if ($Policy.id -in $LinuxSpecificPolicyIds) { $baseKey = 'Linux' }

    if ($Stage -eq 'Pilot') { return "Pilot$baseKey" }

    if ($Stage -eq 'Dynamic') {
        if ($baseKey -eq 'WindowsServers') {
            if (-not $script:WarnedServerNoDynamic) {
                Write-Warning "Windows Server has no Dynamic tier (Arc-enrolled devices don't populate device attributes reliably enough for a membership rule) — staying on the Static Intune-Target-WindowsServers group."
                $script:WarnedServerNoDynamic = $true
            }
            return 'WindowsServers'
        }
        return "$($baseKey)Dynamic"
    }

    return $baseKey
}

# ---------------------------------------------------------------------------
# Customer-value patching (Production Notes #1, #14, #21, #23 — see
# config/customer.config.psd1.example for what each of these protects against)
# ---------------------------------------------------------------------------

function Set-JsonLeafValue {
    # Walks $Body looking for a settingInstance/settingValue whose settingDefinitionId
    # matches $DefinitionIdSuffix and replaces its scalar or collection value. Used only
    # for the 4 known customer-specific policies below — not a general-purpose patcher.
    param($Body, [string]$DefinitionIdSuffix, $NewValue, [switch]$AsCollection)
    function Walk($node) {
        if ($node -is [System.Collections.IDictionary]) {
            if ($node.ContainsKey('settingDefinitionId') -and $node.settingDefinitionId -like "*$DefinitionIdSuffix") {
                if ($AsCollection -and $node.ContainsKey('simpleSettingCollectionValue')) {
                    $node.simpleSettingCollectionValue = @($NewValue | ForEach-Object {
                        @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'; settingValueTemplateReference = $null; value = $_ }
                    })
                } elseif ($node.ContainsKey('simpleSettingValue')) {
                    $node.simpleSettingValue.value = $NewValue
                }
            }
            foreach ($k in @($node.Keys)) { Walk $node[$k] }
        } elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
            foreach ($item in $node) { Walk $item }
        }
    }
    Walk $Body
    return $Body
}

function Patch-CustomerSpecificValues {
    param([string]$Id, $Body)
    # NOTE: these keys must match $Policy.id EXACTLY as build_baseline.py's slugify()
    # generates it — every non-alphanumeric run (including "_" in a category folder
    # name like "05_Tenant_and_Account_Access_Control") collapses to a SINGLE HYPHEN,
    # so the id's category segment is hyphenated ("05-Tenant-and-Account-Access-..."),
    # never underscored. Confirmed live, 2026-09-08: the four cases below were
    # originally written with underscored category segments and SILENTLY NEVER
    # MATCHED for the entire first deploy run — every OneDrive/Teams/Edge/Chrome
    # policy that reached the tenant went out with its unpatched placeholder value
    # (tenant ID 00000000-..., "*" blocked with zero approved extensions) instead of
    # this customer's real values, with no error or warning of any kind, because
    # Patch-CustomerSpecificValues degrades silently to "no patch, return Body
    # unchanged" for any id it doesn't recognize — see RECONCILIATION.md §14 for the
    # full account and why every earlier live run needs re-checking, not just re-run.
    switch ($Id) {
        "05-Tenant-and-Account-Access-Control/Baseline-One-Drive-management-settings" {
            return Set-JsonLeafValue -Body $Body -DefinitionIdSuffix "_allowtenantlistbox" -NewValue @($cfg.EntraTenantId) -AsCollection
        }
        "05-Tenant-and-Account-Access-Control/Baseline-Teams-Restrict-sign-in-to-Teams-to-accounts-in-specific-tenants" {
            return Set-JsonLeafValue -Body $Body -DefinitionIdSuffix "_restrictteamssignintoaccountsfromtenantlist" -NewValue $cfg.EntraTenantId
        }
        "13-Google-Chrome-CIS-Benchmark/Baseline-Chrome-Configure-extension-installation-allow-list" {
            return Set-JsonLeafValue -Body $Body -DefinitionIdSuffix "_extensioninstallallowlistdesc" -NewValue $cfg.ChromeApprovedExtensionIds -AsCollection
        }
        "11-Microsoft-Edge-CIS-Benchmark/CISv3-EDGE-L2-Configure-extension-management-settings" {
            # UNVERIFIED AGAINST A LIVE TENANT — see README.md "Known gaps". The source
            # value is the bare string "*" (wildcard-blocks-everything per Production Note
            # #14). Microsoft's documented ExtensionSettings schema (shared with Chrome's
            # equivalent policy) is a JSON-encoded map of extension-id -> {installation_mode}.
            # This builds that map: "*" stays blocked as a default-deny, each customer-approved
            # ID is explicitly allowed. Confirm this renders correctly in the Intune UI (Devices
            # > Configuration > this policy > review the decoded JSON) before trusting it in
            # production — do not skip this check given Production Note #14's HIGH risk rating.
            $map = @{ "*" = @{ installation_mode = "blocked" } }
            foreach ($extId in $cfg.EdgeApprovedExtensionIds) { $map[$extId] = @{ installation_mode = "allowed" } }
            $json = $map | ConvertTo-Json -Compress -Depth 5
            return Set-JsonLeafValue -Body $Body -DefinitionIdSuffix "_extensionsettings_extensionsettings" -NewValue $json
        }
        "13-Google-Chrome-CIS-Benchmark/Baseline-Chrome-Enable-Site-Isolation-for-specified-origins" {
            # Found during the 2026-09-08 pre-flight audit, not by hitting an error: this policy
            # ships with the literal placeholder "<YOURSITE>" as its isolated-origins list and
            # had no patch case at all, so it would have deployed that string verbatim. Not a
            # Graph error (Chrome just tries to isolate a non-existent origin and no real site
            # gets the protection), which is exactly why it would have gone unnoticed.
            if ($cfg.ChromeIsolatedOrigins) {
                return Set-JsonLeafValue -Body $Body -DefinitionIdSuffix "_isolateorigins_isolateorigins" -NewValue ($cfg.ChromeIsolatedOrigins -join ',')
            }
            Write-Warning "Baseline - Chrome - Enable Site Isolation for specified origins: ChromeIsolatedOrigins not set in customer.config.psd1 — this policy would deploy the literal placeholder '<YOURSITE>' and protect nothing. Set the customer's real origins (e.g. @('https://intranet.customer.com')), or pass -SkipPolicyIds '13-Google-Chrome-CIS-Benchmark/Baseline-Chrome-Enable-Site-Isolation-for-specified-origins' to leave it out of this run."
            return $Body
        }
        "14-Modern-Workplace-and-Resilience/Baseline-Cloud-Remediation-quick-machine-recovery" {
            # Windows Quick Machine Recovery's offline recovery network. Optional — not
            # every customer wants a WiFi-reachable recovery network configured — so
            # unlike the four cases above this is NOT hard-enforced by Test-CustomerConfig.
            # Source ships with placeholder SSID/password text; deploying that literally
            # is harmless (it just won't connect to any real network) but non-functional.
            if ($cfg.QuickMachineRecoverySsid -and $cfg.QuickMachineRecoveryPassword) {
                $Body = Set-JsonLeafValue -Body $Body -DefinitionIdSuffix "_networkssid" -NewValue $cfg.QuickMachineRecoverySsid
                $Body = Set-JsonLeafValue -Body $Body -DefinitionIdSuffix "_networkcredentials_networkpassword" -NewValue $cfg.QuickMachineRecoveryPassword
            } else {
                Write-Warning "Baseline - Cloud Remediation / quick machine recovery: QuickMachineRecoverySsid/QuickMachineRecoveryPassword not set in customer.config.psd1 — deploying with placeholder network credentials (non-functional recovery network, not a Graph error). Set both once this customer has a real recovery network, or ignore if Quick Machine Recovery over WiFi isn't wanted for this tenant."
            }
            return $Body
        }
    }
    return $Body
}

# ---------------------------------------------------------------------------
# Audit-mode override (Production Notes #17, #29, #30)
# ---------------------------------------------------------------------------

function Set-AuditModeIfFlagged {
    <#
        Flips the manifest's audit_first_recommended policies between audit and block mode.
        Rewritten 2026-09-08 after an offline replay of the whole pack showed the previous
        version silently did nothing for 2 of the 3 flagged policies. See RECONCILIATION.md §18.

        Two real encodings exist in this pack — verified by scanning every choice value in all
        212 policies, not inferred from documentation:

          1. ASR rule actions use WORD suffixes: "..._block" <-> "..._audit". (18 values in the
             pack are already "_audit", 14 are "_block".) The earlier numeric "_actiontype_1"/
             "_actionmode_1" substitution this function used to perform matched NOTHING — that
             encoding does not appear anywhere in this source pack. It has been removed rather
             than left in as dead code that implies coverage this function doesn't have.
          2. Controlled Folder Access is NOT an ASR-suffix setting at all. It's
             Defender/EnableControlledFolderAccess, whose documented enum is
             0=Disabled, 1=Enabled(block), 2=Audit Mode, 3=Block disk modification only,
             4=Audit disk modification only. So block is "..._1" and audit is "..._2" — both of
             this pack's Controlled Folder Access policies already ship as "_2" (audit).

        This is deliberately BIDIRECTIONAL. The old version only ever flipped block->audit, so
        -AuditModeForFlaggedPolicies:$false (documented as the way to promote a reviewed pilot
        to block mode) had no effect on a policy already recorded as audit — which is every
        Controlled Folder Access policy here. Promotion to block now actually works.
    #>
    param($Policy, $Body)
    if (-not $Policy.audit_first_recommended) { return $Body }

    $json = $Body | ConvertTo-Json -Depth 40 -Compress

    if ($AuditModeForFlaggedPolicies) {
        $flipped = $json -replace '(attacksurfacereductionrules_[a-z0-9]+)_block"', '$1_audit"' `
                          -replace '(defender_enablecontrolledfolderaccess)_1"', '$1_2"'
        $mode = 'audit'
    } else {
        $flipped = $json -replace '(attacksurfacereductionrules_[a-z0-9]+)_audit"', '$1_block"' `
                          -replace '(defender_enablecontrolledfolderaccess)_2"', '$1_1"'
        $mode = 'block'
    }

    if ($flipped -eq $json) {
        # Not necessarily a problem: a policy already recorded in the requested mode needs no
        # change. Only say something when the policy is in neither recognizable state, which
        # would mean this function genuinely can't govern it.
        if ($json -notmatch "attacksurfacereductionrules_[a-z0-9]+_(block|audit)`"" -and
            $json -notmatch "defender_enablecontrolledfolderaccess_[12]`"") {
            Write-Warning "Set-AuditModeIfFlagged: '$($Policy.display_name)' is flagged audit_first_recommended but has no ASR action value or EnableControlledFolderAccess value this function recognises — deploying exactly as recorded in source. Check its mode manually in the portal."
        } else {
            Write-Host "    already in $mode mode" -ForegroundColor DarkGray
        }
        return $Body
    }
    Write-Host "    -> forced to $mode mode" -ForegroundColor DarkGray
    return $flipped | ConvertFrom-Json -AsHashtable
}

# ---------------------------------------------------------------------------
# Per-shape deploy functions — GET-by-name, then create-or-update, then assign
# ---------------------------------------------------------------------------

function Get-ExistingByName {
    param([string]$CollectionUrl, [string]$NameField, [string]$Name)
    $items = @()
    $uri = $CollectionUrl
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri
        $items += $resp.value
        $uri = $resp.'@odata.nextLink'
    } while ($uri)
    return $items | Where-Object { $_.$NameField -eq $Name } | Select-Object -First 1
}

function Assign-ToGroup {
    param([string]$AssignUrl, [string]$GroupId, [string]$ExcludeGroupId)
    $desc = if ($ExcludeGroupId) { "Assign to group $GroupId (excluding break-glass $ExcludeGroupId)" } else { "Assign to group $GroupId" }
    if ($PSCmdlet.ShouldProcess($AssignUrl, $desc)) {
        $assignments = @(@{ target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $GroupId } })
        if ($ExcludeGroupId) {
            # Mixed include + exclude in one assignments array is Microsoft's documented
            # pattern, but this hasn't been exercised end-to-end against a live tenant for
            # every one of the 5 object shapes here — see RECONCILIATION.md.
            $assignments += @{ target = @{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = $ExcludeGroupId } }
        }
        $body = @{ assignments = $assignments }
        Invoke-MgGraphRequest -Method POST -Uri $AssignUrl -Body ($body | ConvertTo-Json -Depth 10)
    }
}

function Deploy-SettingsCatalogLike {
    param($Policy, $Body, [string]$CollectionPath, [string]$GroupId, [string]$ExcludeGroupId)
    $base = "https://graph.microsoft.com/beta/deviceManagement/$CollectionPath"
    $existing = Get-ExistingByName -CollectionUrl $base -NameField 'name' -Name $Body.name
    if ($existing) {
        # Graph does NOT support updating a configurationPolicies/compliancePolicies policy's
        # settings via PATCH — 'settings' is a navigation property, and PATCHing it fails with
        # "Cannot apply PATCH to navigation property 'settings'". Confirmed live, 2026-09-08 —
        # see RECONCILIATION.md. There is no documented in-place settings-replace action for
        # this resource type (unlike endpoint security intents' /updateSettings action below),
        # and this is a known, still-open Graph limitation (see e.g.
        # microsoftgraph/powershell-intune-samples#286) — not something specific to this script.
        #
        # So an "update" here is create-new, assign it, THEN delete the old one — in that
        # order, so a failed create never leaves the tenant with the policy missing entirely.
        # Known edge case: if the script is interrupted between create and delete (e.g. the
        # assign call throws), the old and new copies both exist under the same name until the
        # next run, which will delete whichever one Get-ExistingByName happens to return first
        # and can leave a true duplicate/orphan behind. Acceptable given $ErrorActionPreference
        # = Stop halts the whole run on any failure, but worth knowing before re-running after
        # a partial failure — check the portal for duplicate names on that one policy.
        Write-Host "  UPDATE (recreate)  $($Policy.display_name)" -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess($Policy.display_name, "Recreate (settings replaced)")) {
            $created = Invoke-MgGraphRequest -Method POST -Uri $base -Body ($Body | ConvertTo-Json -Depth 40)
            $id = $created.id
            Set-ComplianceScheduledActions -CollectionPath $CollectionPath -Base $base -Id $id -Policy $Policy
            Assign-ToGroup -AssignUrl "$base('$id')/assign" -GroupId $GroupId -ExcludeGroupId $ExcludeGroupId
            Invoke-MgGraphRequest -Method DELETE -Uri "$base('$($existing.id)')"
        }
        return
    } else {
        Write-Host "  CREATE  $($Policy.display_name)" -ForegroundColor Green
        if ($PSCmdlet.ShouldProcess($Policy.display_name, "Create")) {
            $created = Invoke-MgGraphRequest -Method POST -Uri $base -Body ($Body | ConvertTo-Json -Depth 40)
            $id = $created.id
            Set-ComplianceScheduledActions -CollectionPath $CollectionPath -Base $base -Id $id -Policy $Policy
        }
    }
    if ($id) { Assign-ToGroup -AssignUrl "$base('$id')/assign" -GroupId $GroupId -ExcludeGroupId $ExcludeGroupId }
}

function Set-ComplianceScheduledActions {
    # Compliance policies need a scheduled-action rule saying what happens to a device that
    # comes back non-compliant. The source pack's exported JSON carries only Graph navigation
    # LINKS for this (`scheduledActionsForRule@odata.navigationLink`) — the export was never
    # $expand'ed, so the actual rule content was never in the source data to begin with and
    # `clean()` had nothing to keep. The exported policy does advertise the documented
    # `setScheduledActions` action, which is the supported way to attach the rule after create:
    # POST /deviceManagement/compliancePolicies/{id}/setScheduledActions.
    #
    # Default here is "block" (i.e. mark the device non-compliant) after a grace period, which
    # matches what the Intune portal creates for a hand-made compliance policy. The grace
    # period is deliberately NOT zero by default: this tenant has a separate Conditional
    # Access baseline, and a device flipping to non-compliant with no grace can cut off access
    # before anyone can remediate — exactly the "security doesn't automatically trump
    # productivity" call this pack is supposed to make consciously. Override per customer with
    # ComplianceNoncompliantGracePeriodHours in customer.config.psd1.
    param([string]$CollectionPath, [string]$Base, [string]$Id, $Policy)
    if ($CollectionPath -ne 'compliancePolicies' -or -not $Id) { return }

    $graceHours = if ($null -ne $cfg.ComplianceNoncompliantGracePeriodHours) {
        [int]$cfg.ComplianceNoncompliantGracePeriodHours
    } else { 24 }

    $body = @{
        scheduledActions = @(
            @{
                '@odata.type'                 = '#microsoft.graph.deviceManagementComplianceScheduledActionForRule'
                ruleName                      = 'PasswordRequired'
                scheduledActionConfigurations = @(
                    @{
                        '@odata.type'             = '#microsoft.graph.deviceManagementComplianceActionItem'
                        actionType                = 'block'
                        gracePeriodHours          = $graceHours
                        notificationTemplateId    = ''
                        notificationMessageCCList = @()
                    }
                )
            }
        )
    }
    if ($PSCmdlet.ShouldProcess($Policy.display_name, "Set compliance scheduled actions (block after ${graceHours}h)")) {
        Write-Host "    scheduled action: block after ${graceHours}h grace" -ForegroundColor DarkGray
        Invoke-MgGraphRequest -Method POST -Uri "$Base('$Id')/setScheduledActions" -Body ($body | ConvertTo-Json -Depth 10)
    }
}

function Deploy-LegacyDeviceConfiguration {
    param($Policy, $Body, [string]$GroupId, [string]$ExcludeGroupId)
    $base = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations"
    $existing = Get-ExistingByName -CollectionUrl $base -NameField 'displayName' -Name $Body.displayName
    if ($existing) {
        Write-Host "  UPDATE  $($Policy.display_name)" -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess($Policy.display_name, "Update")) {
            Invoke-MgGraphRequest -Method PATCH -Uri "$base/$($existing.id)" -Body ($Body | ConvertTo-Json -Depth 40)
        }
        $id = $existing.id
    } else {
        Write-Host "  CREATE  $($Policy.display_name)" -ForegroundColor Green
        if ($PSCmdlet.ShouldProcess($Policy.display_name, "Create")) {
            $created = Invoke-MgGraphRequest -Method POST -Uri $base -Body ($Body | ConvertTo-Json -Depth 40)
            $id = $created.id
        }
    }
    if ($id) { Assign-ToGroup -AssignUrl "$base('$id')/assign" -GroupId $GroupId -ExcludeGroupId $ExcludeGroupId }
}

function Deploy-EndpointSecurityIntent {
    param($Policy, $Body, [string]$GroupId, [string]$ExcludeGroupId)
    $base = "https://graph.microsoft.com/beta/deviceManagement/intents"
    $existing = Get-ExistingByName -CollectionUrl $base -NameField 'displayName' -Name $Body.displayName
    $settings = $Body.settings
    if ($existing) {
        # Updating an existing intent: PATCH carries only the intent's own scalar properties
        # (displayName/description/roleScopeTagIds — NOT templateId, which is fixed at creation
        # and not updatable), then settings go through the documented updateSettings action.
        Write-Host "  UPDATE  $($Policy.display_name)" -ForegroundColor Yellow
        $id = $existing.id
        $patchBody = @{ displayName = $Body.displayName; description = $Body.description; roleScopeTagIds = $Body.roleScopeTagIds }
        if ($PSCmdlet.ShouldProcess($Policy.display_name, "Update")) {
            Invoke-MgGraphRequest -Method PATCH -Uri "$base('$id')" -Body ($patchBody | ConvertTo-Json -Depth 10)
        }
        if ($id -and $PSCmdlet.ShouldProcess($Policy.display_name, "Push settings")) {
            # updateSettings replaces the intent's full settings set. NOTE the parameter name:
            # this action takes "settings", while templates/{id}/createInstance on the create
            # branch above takes "settingsDelta" for the same shape of data. Conflating the two
            # is exactly the bug this line had until 2026-09-08 — Graph answered the
            # settingsDelta version with 400 "settings is a required field". Both names are now
            # asserted by test/Invoke-OfflineReplay.ps1 so they can't drift back.
            Invoke-MgGraphRequest -Method POST -Uri "$base('$id')/updateSettings" -Body (@{ settings = $settings } | ConvertTo-Json -Depth 20)
        }
    } else {
        # CREATING an intent does NOT go through POST /deviceManagement/intents — that is not a
        # documented create path and there is no way to attach a templateId that way. The
        # supported call is createInstance on the TEMPLATE the intent is derived from:
        #   POST /deviceManagement/templates/{templateId}/createInstance
        # with displayName/description/settingsDelta/roleScopeTagIds in one body — settings are
        # supplied at creation, so no follow-up updateSettings call is needed on this branch.
        # Corrected 2026-09-08 during the pre-flight audit of paths this pack had never
        # executed; the previous POST-to-/intents form would have failed on both of this
        # pack's two intents (BitLocker, Account Protection). See RECONCILIATION.md §17.
        Write-Host "  CREATE  $($Policy.display_name)" -ForegroundColor Green
        $templateId = $Body.templateId
        if (-not $templateId) {
            throw "Endpoint security intent '$($Policy.display_name)' has no templateId in its cleaned JSON — cannot create it via templates/{id}/createInstance. Check Intune-Baseline/$($Policy.clean_file)."
        }
        $createBody = @{
            displayName     = $Body.displayName
            description     = $Body.description
            settingsDelta   = $settings
            roleScopeTagIds = $Body.roleScopeTagIds
        }
        if ($PSCmdlet.ShouldProcess($Policy.display_name, "Create from template $templateId")) {
            $createUri = "https://graph.microsoft.com/beta/deviceManagement/templates('$templateId')/createInstance"
            $created = Invoke-MgGraphRequest -Method POST -Uri $createUri -Body ($createBody | ConvertTo-Json -Depth 20)
            $id = $created.id
        }
    }
    if ($id) { Assign-ToGroup -AssignUrl "$base('$id')/assign" -GroupId $GroupId -ExcludeGroupId $ExcludeGroupId }
}

function Deploy-MacOSCustomConfiguration {
    param($Policy, [string]$GroupId, [string]$ExcludeGroupId)
    $payloadPath = Join-Path $ManifestRoot $Policy.clean_file
    $payloadB64 = Get-Content $payloadPath -Raw
    $displayName = "Baseline - macOS - $($Policy.display_name)"
    $body = @{
        '@odata.type'  = '#microsoft.graph.macOSCustomConfiguration'
        displayName    = $displayName
        description    = $Policy.notes
        payload        = $payloadB64
        payloadFileName = $Policy.payload_file_name
        payloadName    = $Policy.payload_file_name
    }
    if ($Policy.display_name -eq 'com.microsoft.wdav.atp' -or $Policy.id -match 'wdav-atp') {
        # Never reached by the manifest as generated (onboarding isn't in the source pack —
        # see README_Onboarding_Package.md); kept as a documented extension point for the
        # per-tenant onboarding step described in that file.
    }
    Deploy-LegacyDeviceConfiguration -Policy $Policy -Body $body -GroupId $GroupId -ExcludeGroupId $ExcludeGroupId
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

$exclusionGroupId = Resolve-AssignmentGroupId -Key 'ExclusionBreakGlass' -ConfiguredIds $cfg.AssignmentGroupIds

$manifest | Sort-Object { $_.deploy_order ?? 0 } | ForEach-Object {
    $policy = $_
    Write-Host "[$($policy.category)] $($policy.display_name)" -ForegroundColor White
    $groupKey = Get-EffectiveGroupKey -Policy $policy -Stage $RolloutStage
    $groupId = Resolve-AssignmentGroupId -Key $groupKey -ConfiguredIds $cfg.AssignmentGroupIds
    Write-Host "  -> $groupKey" -ForegroundColor DarkGray

    if ($policy.shape -eq 'macos_custom_configuration') {
        Deploy-MacOSCustomConfiguration -Policy $policy -GroupId $groupId -ExcludeGroupId $exclusionGroupId
        return
    }

    $bodyPath = Join-Path $ManifestRoot $policy.clean_file
    $body = Get-Content $bodyPath -Raw | ConvertFrom-Json -AsHashtable
    $body = Patch-CustomerSpecificValues -Id $policy.id -Body $body
    $body = Set-AuditModeIfFlagged -Policy $policy -Body $body

    switch ($policy.shape) {
        'settings_catalog_policy' { Deploy-SettingsCatalogLike -Policy $policy -Body $body -CollectionPath 'configurationPolicies' -GroupId $groupId -ExcludeGroupId $exclusionGroupId }
        'compliance_policy'       { Deploy-SettingsCatalogLike -Policy $policy -Body $body -CollectionPath 'compliancePolicies' -GroupId $groupId -ExcludeGroupId $exclusionGroupId }
        'legacy_device_configuration' { Deploy-LegacyDeviceConfiguration -Policy $policy -Body $body -GroupId $groupId -ExcludeGroupId $exclusionGroupId }
        'endpoint_security_intent'    { Deploy-EndpointSecurityIntent -Policy $policy -Body $body -GroupId $groupId -ExcludeGroupId $exclusionGroupId }
        default { Write-Warning "Unhandled shape '$($policy.shape)' for $($policy.display_name) — skipped." }
    }
}

Write-Host "`nDone. Run ../verify/Verify-Deployment.ps1 to diff the live tenant against Intune-Baseline/manifest.json." -ForegroundColor Cyan
