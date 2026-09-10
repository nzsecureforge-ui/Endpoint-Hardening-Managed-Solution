<#
.SYNOPSIS
    Reads the live tenant via Microsoft Graph and diffs it against
    ../Intune-Baseline/manifest.json — the same file Deploy-IntuneBaseline.ps1 deploys from,
    generated independently from source JSON by ../scripts/build_baseline.py, not from
    anything the deploy script itself produces. A bug in Deploy-IntuneBaseline.ps1 (wrong
    endpoint, dropped field) shows up here as a MISMATCH/MISSING rather than being invisible
    to its own check — same reasoning as the CA-Baseline project's Verify-Deployment.ps1.

.DESCRIPTION
    Runs on the SAME already-open Graph connection as Deploy-IntuneBaseline.ps1 (app-only) and
    never calls Connect-MgGraph itself. It used to sign in delegated/interactive here, which in
    an app-only session either fails or silently re-authenticates as a different principal —
    so you could verify a tenant context you hadn't actually deployed to. See
    RECONCILIATION.md 18.

    For the 4 policies with customer-specific values (OneDrive/Teams tenant ID, Edge/Chrome
    extension allow-lists), this script only confirms the policy EXISTS and is assigned — it
    does not attempt to verify the injected values are correct, since that's specific to this
    customer's config, not something manifest.json (the generic source) can predict. Check
    those 4 by hand in the Intune portal.

    For every MATCHed policy, also fetches its live assignments and resolves them to group
    display names, so you can see at a glance which rollout tier (Intune-Pilot-<X> / the
    static Intune-Target-<X> / the -Dynamic tier) each policy is actually sitting at, and
    whether Intune-Excl-BreakGlass is present as an exclusion — see ../README.md
    "Rollout model". A policy that MATCHes but shows no assignment at all is flagged, since
    that means Deploy-IntuneBaseline.ps1 created/updated it but the /assign call either never
    ran (-WhatIf) or failed silently in a way this script wouldn't otherwise catch.

.PARAMETER Categories
    Optional. Restrict the check to these category folder names.

.PARAMETER SkipCategories
    Optional. Exclude these categories from the check. Pass the SAME scoping flags you passed
    Deploy-IntuneBaseline.ps1 — otherwise policies you deliberately skipped are reported as
    MISSING and bury the ones genuinely missing.

.PARAMETER CsvPath
    Optional. Writes a dated CSV record of this check, for a customer engagement file.
#>

#Requires -Modules Microsoft.Graph.Authentication

param(
    [string]$ManifestRoot = (Join-Path $PSScriptRoot "..\Intune-Baseline"),
    [string]$CsvPath,
    [string[]]$Categories,
    [string[]]$SkipCategories
)

# Deliberately does NOT call Connect-MgGraph. Deploy-IntuneBaseline.ps1 requires the caller to
# have already connected (app-only, via the credentials from bootstrap/New-AppRegistration.ps1),
# and this script has to run against that SAME connection to be meaningful. The previous version
# called Connect-MgGraph -Scopes ... here, which requests DELEGATED scopes: in an app-only
# session that either fails outright or silently re-authenticates as a different principal, so
# you could end up verifying a different context than the one you deployed with. Corrected
# 2026-09-08 during the pre-flight audit — see RECONCILIATION.md §18.
if (-not (Get-MgContext)) {
    throw "Not connected to Microsoft Graph. Connect first (app-only, same as for Deploy-IntuneBaseline.ps1), then re-run this script. It never manages the connection itself so that it always verifies the tenant you actually deployed to."
}
Write-Host "Verifying tenant: $((Get-MgContext).TenantId)`n" -ForegroundColor Cyan

$manifest = (Get-Content (Join-Path $ManifestRoot "manifest.json") -Raw | ConvertFrom-Json).policies

# Mirror the deploy script's own scoping switches. Without these, verifying after a run that
# used -SkipCategories reports every skipped policy as "MISSING", which buries the ones that
# are genuinely missing in noise you have to mentally subtract. Pass verify the same scoping
# flags you passed deploy.
if ($Categories)     { $manifest = $manifest | Where-Object { $_.category -in $Categories } }
if ($SkipCategories) { $manifest = $manifest | Where-Object { $_.category -notin $SkipCategories } }
Write-Host "$($manifest.Count) polic$(if ($manifest.Count -eq 1) {'y'} else {'ies'}) expected in this tenant." -ForegroundColor Cyan

$collectionByShape = @{
    settings_catalog_policy      = @{ Url = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"; NameField = "name" }
    compliance_policy            = @{ Url = "https://graph.microsoft.com/beta/deviceManagement/compliancePolicies"; NameField = "name" }
    legacy_device_configuration  = @{ Url = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations"; NameField = "displayName" }
    endpoint_security_intent     = @{ Url = "https://graph.microsoft.com/beta/deviceManagement/intents"; NameField = "displayName" }
    macos_custom_configuration   = @{ Url = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations"; NameField = "displayName" }
}

function Get-AllPages {
    param([string]$Uri)
    $items = @()
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $Uri
        $items += $resp.value
        $Uri = $resp.'@odata.nextLink'
    } while ($Uri)
    return $items
}

Write-Host "Fetching live tenant state..." -ForegroundColor DarkGray
$liveByShape = @{}
foreach ($shape in $collectionByShape.Keys | Select-Object -Unique) {
    $liveByShape[$shape] = Get-AllPages -Uri $collectionByShape[$shape].Url
}
# legacy_device_configuration and macos_custom_configuration share one Graph collection;
# avoid fetching deviceConfigurations twice.
$liveByShape['macos_custom_configuration'] = $liveByShape['legacy_device_configuration']

Write-Host "Fetching group names for assignment resolution..." -ForegroundColor DarkGray
$groupNameById = @{}
foreach ($g in (Get-AllPages -Uri "https://graph.microsoft.com/v1.0/groups?`$select=id,displayName")) {
    $groupNameById[$g.id] = $g.displayName
}
$breakGlassId = ($groupNameById.GetEnumerator() | Where-Object { $_.Value -eq 'Intune-Excl-BreakGlass' } | Select-Object -First 1).Key

function Get-AssignmentSummary {
    param([string]$CollectionUrl, [string]$Id)
    try {
        $resp = Invoke-MgGraphRequest -Method GET -Uri "$CollectionUrl('$Id')/assignments" -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{ AssignedTo = "(couldn't read assignments: $($_.Exception.Message))"; ExcludesBreakGlass = "?" }
    }
    $included = @()
    $excludesBreakGlass = $false
    foreach ($a in $resp.value) {
        $odataType = $a.target.'@odata.type'
        $gid = $a.target.groupId
        $name = if ($gid -and $groupNameById.ContainsKey($gid)) { $groupNameById[$gid] } elseif ($gid) { $gid } else { $null }
        if ($odataType -eq '#microsoft.graph.groupAssignmentTarget' -and $name) {
            $included += $name
        } elseif ($odataType -eq '#microsoft.graph.exclusionGroupAssignmentTarget' -and $gid -eq $breakGlassId) {
            $excludesBreakGlass = $true
        }
    }
    $assignedTo = if ($included.Count -gt 0) { $included -join ', ' } else { 'NONE — created but not assigned' }
    return [PSCustomObject]@{ AssignedTo = $assignedTo; ExcludesBreakGlass = if ($excludesBreakGlass) { 'Yes' } else { 'No' } }
}

$results = [System.Collections.Generic.List[object]]::new()
$recognizedNames = [System.Collections.Generic.HashSet[string]]::new()

foreach ($policy in $manifest) {
    $coll = $collectionByShape[$policy.shape]
    $expectedName = if ($policy.shape -eq 'macos_custom_configuration') { "Baseline - macOS - $($policy.display_name)" } else {
        # name/displayName as recorded in the cleaned source JSON
        (Get-Content (Join-Path $ManifestRoot $policy.clean_file) -Raw -ErrorAction SilentlyContinue |
            ConvertFrom-Json -ErrorAction SilentlyContinue).$($coll.NameField)
    }
    if (-not $expectedName) { $expectedName = $policy.display_name }
    $recognizedNames.Add($expectedName) | Out-Null

    $live = $liveByShape[$policy.shape] | Where-Object { $_.$($coll.NameField) -eq $expectedName } | Select-Object -First 1
    $status = if ($live) { "MATCH" } else { "MISSING" }
    $note = if ($policy.requires_customer_value -and $live) { "exists — verify injected customer value manually" } else { "" }

    $assignedTo = ""
    $excludesBreakGlass = ""
    if ($live) {
        $summary = Get-AssignmentSummary -CollectionUrl $coll.Url -Id $live.id
        $assignedTo = $summary.AssignedTo
        $excludesBreakGlass = $summary.ExcludesBreakGlass
    }

    $results.Add([PSCustomObject]@{
        Category            = $policy.category
        Policy              = $policy.display_name
        Shape               = $policy.shape
        Status              = $status
        AssignedTo          = $assignedTo
        ExcludesBreakGlass  = $excludesBreakGlass
        Note                = $note
    })

    $color = switch ($status) { "MATCH" { "Green" }; "MISSING" { "Red" }; default { "Yellow" } }
    Write-Host ("  {0,-8} {1}" -f $status, $policy.display_name) -ForegroundColor $color
    if ($live) {
        $assignColor = if ($assignedTo -like 'NONE*') { 'Red' } else { 'DarkGray' }
        Write-Host ("           -> $assignedTo (break-glass excluded: $excludesBreakGlass)") -ForegroundColor $assignColor
    }
    if ($note) { Write-Host ("           {0}" -f $note) -ForegroundColor DarkYellow }
}

Write-Host "`nPolicies in the tenant NOT recognized as part of this baseline (informational — a real customer tenant may have its own bespoke policies):" -ForegroundColor Cyan
foreach ($shape in $collectionByShape.Keys | Select-Object -Unique) {
    foreach ($item in $liveByShape[$shape]) {
        $nameField = $collectionByShape[$shape].NameField
        if ($item.$nameField -and -not $recognizedNames.Contains($item.$nameField)) {
            Write-Host "  [$shape] $($item.$nameField)" -ForegroundColor DarkGray
        }
    }
}

$missingCount    = ($results | Where-Object Status -eq "MISSING").Count
$unassignedCount = ($results | Where-Object { $_.AssignedTo -like 'NONE*' }).Count
$noExclusionCount = ($results | Where-Object { $_.Status -eq 'MATCH' -and $_.ExcludesBreakGlass -eq 'No' }).Count
Write-Host "`n$($results.Count) checked, $missingCount missing, $unassignedCount created-but-unassigned, $noExclusionCount missing the break-glass exclusion." -ForegroundColor $(if ($missingCount -eq 0 -and $unassignedCount -eq 0 -and $noExclusionCount -eq 0) { "Green" } else { "Red" })
Write-Host "Tip: group each policy's AssignedTo value by which rollout tier it names (Intune-Pilot-<X> / Intune-Target-<X> / Intune-Target-<X>-Dynamic) to confirm the whole category actually landed at the stage you intended." -ForegroundColor DarkGray

if ($CsvPath) {
    $results | Export-Csv -Path $CsvPath -NoTypeInformation
    Write-Host "Wrote $CsvPath" -ForegroundColor DarkGray
}
