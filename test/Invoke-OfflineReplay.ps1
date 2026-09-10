<#
.SYNOPSIS
    Replays the entire baseline through Deploy-IntuneBaseline.ps1 against a MOCKED Graph API
    and asserts on every request it would send. No tenant, no credentials, no side effects.

.DESCRIPTION
    Built 2026-09-08 after a run of deploy failures that each surfaced one at a time, hours
    apart, in a live tenant (see RECONCILIATION.md sections 9, 13, 14, 15, 16). Every one of
    them was findable offline. Run this before any live deploy, and after ANY change to the
    deploy script, the source pack, or the generated Intune-Baseline output.

    What it proves: the requests this toolkit SENDS are structurally correct and complete.
    What it cannot prove: that Graph ACCEPTS them, or that a policy is semantically right for
    a given customer. See RECONCILIATION.md section 18 for that distinction.

.EXAMPLE
    pwsh ./test/Invoke-OfflineReplay.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
$deploy   = Join-Path $RepoRoot 'deploy/Deploy-IntuneBaseline.ps1'
$manifest = Join-Path $RepoRoot 'Intune-Baseline/manifest.json'

# ---- a throwaway customer config with obviously-fake but well-formed values ----------------
$cfgPath = Join-Path ([System.IO.Path]::GetTempPath()) 'offline-replay-config.psd1'
@'
@{
    EntraTenantId = "11111111-2222-3333-4444-555555555555"
    EdgeApprovedExtensionIds   = @("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    ChromeApprovedExtensionIds = @("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    MacOSOnboardingXmlPath = $null
    FeatureUpdatePeriodDays = 180
    AssignmentGroupIds = @{
        PilotWindowsWorkstations = "10000000-0000-0000-0000-00000000000a"
        PilotWindowsServers      = "10000000-0000-0000-0000-00000000000b"
        PilotMacOS               = "10000000-0000-0000-0000-00000000000c"
        PilotLinux               = "10000000-0000-0000-0000-00000000000d"
        WindowsWorkstations = "10000000-0000-0000-0000-000000000001"
        WindowsServers      = "10000000-0000-0000-0000-000000000002"
        MacOS               = "10000000-0000-0000-0000-000000000003"
        Linux               = "10000000-0000-0000-0000-000000000004"
        ExclusionBreakGlass = "10000000-0000-0000-0000-000000000006"
    }
    AsrPsExecWmiExclusions = @()
    QuickMachineRecoverySsid = $null
    QuickMachineRecoveryPassword = $null
    ChromeIsolatedOrigins = @()
    ComplianceNoncompliantGracePeriodHours = 24
}
'@ | Set-Content $cfgPath

$PILOT_WKS   = '10000000-0000-0000-0000-00000000000a'
$PILOT_SRV   = '10000000-0000-0000-0000-00000000000b'
$PILOT_MAC   = '10000000-0000-0000-0000-00000000000c'
$PILOT_LNX   = '10000000-0000-0000-0000-00000000000d'
$ALL_PILOT   = @($PILOT_WKS, $PILOT_SRV, $PILOT_MAC, $PILOT_LNX)
$BREAKGLASS  = '10000000-0000-0000-0000-000000000006'
$TENANT      = '11111111-2222-3333-4444-555555555555'
$EXT         = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

$global:Captured = [System.Collections.Generic.List[object]]::new()
$global:PretendPoliciesExist = $false

function Get-MgContext { [pscustomobject]@{ TenantId = 'offline-replay' } }
function Get-MgGroup { param([string]$Filter, [switch]$All) return @() }
function Invoke-MgGraphRequest {
    param([string]$Method, [string]$Uri, $Body)
    $global:Captured.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })
    if ($Uri -like '*v1.0/groups*') {
        # every named assignment group resolves, so group lookup isn't what's under test here
        return @{ value = @(@{ id = '10000000-0000-0000-0000-00000000000f'; displayName = 'resolved' }) }
    }
    if ($Method -eq 'GET') {
        if (-not $global:PretendPoliciesExist) { return @{ value = @() } }
        $items = foreach ($p in (Get-Content $script:ManifestPath -Raw | ConvertFrom-Json).policies) {
            $n = if ($p.shape -eq 'macos_custom_configuration') { "Baseline - macOS - $($p.display_name)" } else { $p.display_name }
            @{ id = [guid]::NewGuid().ToString(); name = $n; displayName = $n }
        }
        return @{ value = $items }
    }
    return @{ id = [guid]::NewGuid().ToString() }
}
$script:ManifestPath = $manifest

$failures = [System.Collections.Generic.List[string]]::new()
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $failures.Add($Name) }
}

function Invoke-Replay {
    param([string]$Stage, [bool]$Existing, [hashtable]$Extra = @{})
    $global:Captured.Clear()
    $global:PretendPoliciesExist = $Existing
    & $deploy -CustomerConfigPath $cfgPath -SkipCategories '16_Defender_for_Endpoint_macOS' `
              -RolloutStage $Stage -WarningAction SilentlyContinue @Extra *>$null
    return @($global:Captured)
}

Write-Host "`n=== 1. Every policy, every stage, create + update ===" -ForegroundColor Cyan
foreach ($stage in 'Pilot', 'Static', 'Dynamic') {
    foreach ($existing in $false, $true) {
        $label = "$stage / $(if ($existing) {'update'} else {'create'})"
        try {
            $calls = Invoke-Replay -Stage $stage -Existing $existing
            Assert-That "$label completes ($($calls.Count) calls)" $true
        } catch {
            Assert-That "$label completes" $false "-> $($_.Exception.Message)"
        }
    }
}

Write-Host "`n=== 2. Assignments name the tier group AND exclude break-glass ===" -ForegroundColor Cyan
$calls   = Invoke-Replay -Stage 'Pilot' -Existing $false
$assigns = @($calls | Where-Object { $_.Uri -like '*/assign' })
$badIncl = @($assigns | Where-Object { $b = $_.Body; -not ($ALL_PILOT | Where-Object { $b -like "*$_*" }) })
$badExcl = @($assigns | Where-Object { $_.Body -notlike "*$BREAKGLASS*" -or $_.Body -notlike '*exclusionGroupAssignmentTarget*' })
Assert-That "every policy is assigned (got $($assigns.Count))" ($assigns.Count -gt 0)
Assert-That "all assignments name a per-platform pilot ring" ($badIncl.Count -eq 0) "($($badIncl.Count) missing)"
Assert-That "all assignments exclude break-glass"     ($badExcl.Count -eq 0) "($($badExcl.Count) missing)"

# Pilot must now be per-platform, not one bucket: server policies must NOT land in the
# workstation ring, and every ring must actually be used by something.
$srvAssigns = @($assigns | Where-Object { $_.Body -like "*$PILOT_SRV*" })
$wksAssigns = @($assigns | Where-Object { $_.Body -like "*$PILOT_WKS*" })
$lnxAssigns = @($assigns | Where-Object { $_.Body -like "*$PILOT_LNX*" })
Assert-That "Windows Server policies use their own pilot ring" ($srvAssigns.Count -gt 0) "(got $($srvAssigns.Count))"
Assert-That "Windows workstation policies use their own pilot ring" ($wksAssigns.Count -gt 0) "(got $($wksAssigns.Count))"
Assert-That "Linux policies use their own pilot ring" ($lnxAssigns.Count -eq 2) "(expected 2, got $($lnxAssigns.Count))"
Assert-That "no assignment names two different pilot rings" (-not ($assigns | Where-Object { $b=$_.Body; (@($ALL_PILOT | Where-Object { $b -like "*$_*" })).Count -gt 1 }))

Write-Host "`n=== 3. Customer-specific values actually reach the wire ===" -ForegroundColor Cyan
$withTenant = @($calls | Where-Object { $_.Body -like "*$TENANT*" })
$withExt    = @($calls | Where-Object { $_.Body -like "*$EXT*" })
Assert-That "real tenant ID substituted (OneDrive + Teams)"        ($withTenant.Count -ge 2) "(found $($withTenant.Count))"
Assert-That "real extension IDs substituted (Edge + Chrome)"       ($withExt.Count -ge 2)    "(found $($withExt.Count))"

Write-Host "`n=== 4. No unhandled placeholders, no over-length descriptions ===" -ForegroundColor Cyan
# The 3 values below are expected to remain: each raises an explicit deploy-time warning.
$expected = 'YOUR WIFI', 'YOUR SSID', 'YOURSITE'
$leftover = foreach ($c in $calls) {
    foreach ($m in [regex]::Matches([string]$c.Body, '(YourOwnTenantID|<YOUR[^>]*>|<REPLACE[^>]*>)')) {
        if (-not ($expected | Where-Object { $m.Value -like "*$_*" })) { $m.Value }
    }
}
Assert-That "no unexpected placeholder on the wire" (@($leftover).Count -eq 0) "($(@($leftover) -join ', '))"
$tooLong = foreach ($c in $calls) {
    if ($c.Body) { try { $o = $c.Body | ConvertFrom-Json; if ($o.description -and $o.description.Length -gt 1000) { $c.Uri } } catch {} }
}
Assert-That "no description exceeds Graph's 1000-char limit" (@($tooLong).Count -eq 0)

Write-Host "`n=== 5. Documented Graph endpoints are the ones actually called ===" -ForegroundColor Cyan
$uris = ($calls | ForEach-Object { $_.Uri }) -join "`n"
$upd  = Invoke-Replay -Stage 'Pilot' -Existing $true
$uUris = ($upd | ForEach-Object { $_.Uri }) -join "`n"
Assert-That "intents created via templates/{id}/createInstance" ($uris -like '*templates(*)/createInstance*')
Assert-That "intents never created via POST /intents"           (-not ($calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/intents$' }))
Assert-That "compliance scheduled actions set"                  ($uris -like '*setScheduledActions*')
Assert-That "settings-catalog update recreates (DELETE issued)" (@($upd | Where-Object { $_.Method -eq 'DELETE' }).Count -gt 0)
Assert-That "settings are never PATCHed onto a policy"          (-not ($upd | Where-Object { $_.Method -eq 'PATCH' -and $_.Body -like '*"settings"*' }))

# Action endpoints take DIFFERENT body parameter names for the same data. Getting one wrong
# is a 400 that only shows up on the branch that calls it, which is how the updateSettings
# bug survived to a second live run. Assert each by name.
$createInstance = @($calls | Where-Object { $_.Uri -like '*createInstance*' })
$updateSettings = @($upd    | Where-Object { $_.Uri -like '*updateSettings*' })
$assignCalls    = @($calls  | Where-Object { $_.Uri -like '*/assign' })
$schedCalls     = @($calls  | Where-Object { $_.Uri -like '*setScheduledActions*' })
Assert-That "createInstance body uses 'settingsDelta'" (@($createInstance | Where-Object { $_.Body -like '*"settingsDelta"*' }).Count -eq $createInstance.Count) "($($createInstance.Count) call(s))"
Assert-That "updateSettings body uses 'settings', NOT 'settingsDelta'" (@($updateSettings | Where-Object { $_.Body -like '*"settings"*' -and $_.Body -notlike '*"settingsDelta"*' }).Count -eq $updateSettings.Count) "($($updateSettings.Count) call(s))"
Assert-That "assign body uses 'assignments'" (@($assignCalls | Where-Object { $_.Body -like '*"assignments"*' }).Count -eq $assignCalls.Count)
Assert-That "setScheduledActions body uses 'scheduledActions'" (@($schedCalls | Where-Object { $_.Body -like '*"scheduledActions"*' }).Count -eq $schedCalls.Count)

Write-Host "`n=== 6. Guard rails fail loudly ===" -ForegroundColor Cyan
$threw = $false
try { & $deploy -CustomerConfigPath $cfgPath -SkipPolicyIds 'no/such-policy' -WarningAction SilentlyContinue *>$null }
catch { $threw = $true }
Assert-That "-SkipPolicyIds throws on an id matching nothing" $threw

Remove-Item $cfgPath -ErrorAction SilentlyContinue
Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) ASSERTION(S) FAILED:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "All offline replay assertions passed." -ForegroundColor Green
