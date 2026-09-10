<#
.SYNOPSIS
    Checks a target tenant has the licensing this baseline actually needs before you create
    anything. Delegated, read-only, no standing credential — safe to run against a tenant
    you're only evaluating, same pattern as the CA-Baseline project's script of the same name.

.DESCRIPTION
    This pack assumes, at minimum: Microsoft Intune Plan 1 (device configuration, compliance,
    endpoint security), and Microsoft Defender for Endpoint Plan 2 (categories 01, 15, 16 —
    ASR rules, advanced AV, the macOS/Windows Server Defender baselines). Passwordless
    Authentication (category 12) needs nothing beyond Entra ID Free for WHFB itself, but the
    multi-factor-unlock template configuration references Conditional Access — if this
    customer doesn't have Entra ID P1/P2, deploy the other 4 WHFB policies and skip that one.

    This is a heuristic check against the tenant's subscribedSkus, not an exhaustive license
    audit — Microsoft's SKU-to-servicePlan mapping changes, and bundled SKUs (e.g. Microsoft
    365 E5) expose Intune and Defender for Endpoint under names this script may not recognize
    yet. Treat a "not found" result as "verify manually in the admin center", not gospel.
#>

#Requires -Modules Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Authentication

Connect-MgGraph -Scopes "Organization.Read.All" -NoWelcome

$skus = Get-MgSubscribedSku -All
$servicePlans = $skus.ServicePlans | Select-Object -ExpandProperty ServicePlanName -Unique

function Test-ServicePlan {
    param([string]$Label, [string[]]$AnyOf, [string]$ImpactIfMissing)
    $found = $servicePlans | Where-Object { $_ -in $AnyOf }
    if ($found) {
        Write-Host "  [OK]      $Label  (matched: $($found -join ', '))" -ForegroundColor Green
    } else {
        Write-Host "  [MISSING] $Label" -ForegroundColor Red
        Write-Host "            Impact: $ImpactIfMissing" -ForegroundColor DarkYellow
    }
    return [bool]$found
}

Write-Host "Checking licensing for tenant $((Get-MgContext).TenantId)...`n" -ForegroundColor Cyan

$intuneOk = Test-ServicePlan -Label "Microsoft Intune" `
    -AnyOf @("INTUNE_A", "SCCM_ADMIN") `
    -ImpactIfMissing "Nothing in this pack can deploy — nearly every policy is an Intune device configuration, compliance, or endpoint security object."

$mdeOk = Test-ServicePlan -Label "Microsoft Defender for Endpoint Plan 2" `
    -AnyOf @("WINDEFATP", "MDE_LITE") `
    -ImpactIfMissing "Categories 01 (client ASR/AV), 15 (Windows Server Defender), 16 (macOS Defender) will create in Intune but the Defender agent side (ASR enforcement, advanced hunting, onboarding) will not function. MDE_LITE (bundled in Business Premium) covers AV but not the full ASR rule set — verify which categories actually apply."

$entraP2Ok = Test-ServicePlan -Label "Entra ID P1/P2 (for the WHFB multi-factor-unlock template's Conditional Access reference)" `
    -AnyOf @("AAD_PREMIUM", "AAD_PREMIUM_P2") `
    -ImpactIfMissing "Deploy the other 4 Passwordless Authentication policies; skip 'Baseline - WHFB Muti-Factor unlock Template config' or confirm it degrades gracefully without Conditional Access licensing."

Write-Host ""
if (-not $intuneOk) {
    Write-Host "STOP: Intune licensing not detected. Confirm manually before proceeding — do not run Deploy-IntuneBaseline.ps1 against this tenant yet." -ForegroundColor Red
    exit 1
}
if (-not $mdeOk) {
    Write-Host "WARNING: proceed only after confirming with the customer which Defender for Endpoint categories are actually in scope for this engagement." -ForegroundColor Yellow
}
Write-Host "Prerequisite check complete." -ForegroundColor Cyan
