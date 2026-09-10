<#
.SYNOPSIS
    Validates a customer.config.psd1 before Deploy-IntuneBaseline.ps1 is allowed to touch
    Microsoft Graph. Fails loudly and specifically rather than letting a placeholder value
    reach production — see customer.config.psd1.example for why each field matters and
    which Production Note it's protecting against.

.DESCRIPTION
    This is the PowerShell equivalent of the CA-Baseline project's variables.tf validation
    blocks. There is no Terraform variable system on this path (Intune policies deploy via
    the Graph PowerShell SDK, not a Terraform provider — see ../README.md), so the same
    "required + validated, hard stop on placeholder" discipline is implemented here instead.

.PARAMETER ConfigPath
    Path to the customer's copy of customer.config.psd1 (NOT the .example file — copy it
    first, per this project's per-customer-folder workflow, same as CA-Baseline).

.PARAMETER RequireMacOS
    Set when this deployment run includes category 16 (macOS). Escalates
    MacOSOnboardingXmlPath from optional to required.

.OUTPUTS
    The validated config hashtable, on success. Throws with a specific, actionable message
    on failure — never a generic "config invalid".
#>
function Test-CustomerConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ConfigPath,
        [switch]$RequireMacOS
    )

    if (-not (Test-Path $ConfigPath)) {
        throw "Customer config not found at '$ConfigPath'. Copy config/customer.config.psd1.example to a per-customer path first (see README.md 'Deploying this to a new customer')."
    }

    $cfg = Import-PowerShellDataFile -Path $ConfigPath
    $problems = [System.Collections.Generic.List[string]]::new()

    $placeholderTenant = "00000000-0000-0000-0000-000000000000"
    if (-not $cfg.EntraTenantId -or $cfg.EntraTenantId -eq $placeholderTenant) {
        $problems.Add("EntraTenantId is missing or still the placeholder GUID. Required by the OneDrive tenant-restriction and Teams tenant-restriction policies — deploying either without it breaks OneDrive sync / blocks all Teams sign-in (Production Notes #1, #23).")
    } elseif ($cfg.EntraTenantId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $problems.Add("EntraTenantId '$($cfg.EntraTenantId)' is not a valid GUID.")
    }

    if (-not $cfg.EdgeApprovedExtensionIds -or
        ($cfg.EdgeApprovedExtensionIds.Count -eq 1 -and $cfg.EdgeApprovedExtensionIds[0] -like "REPLACE-*")) {
        $problems.Add("EdgeApprovedExtensionIds is empty or still the placeholder. Deploying 'Configure extension management settings' unconfigured blocks ALL Edge extensions tenant-wide, including corporate VPN clients (Production Note #14). If this customer genuinely approves zero extensions, set an explicit empty array @() to make that intent visible in the config rather than leaving the placeholder.")
    }

    if (-not $cfg.ChromeApprovedExtensionIds -or
        ($cfg.ChromeApprovedExtensionIds.Count -eq 1 -and $cfg.ChromeApprovedExtensionIds[0] -like "REPLACE-*")) {
        $problems.Add("ChromeApprovedExtensionIds is empty or still the placeholder (Production Note #21 — same failure mode as the Edge extension list). If this customer is not in scope for category 13 (Google Chrome), pass -SkipCategories '13_Google_Chrome_CIS_Benchmark' to Deploy-IntuneBaseline.ps1 instead of leaving this unresolved.")
    }

    if ($RequireMacOS -and -not $cfg.MacOSOnboardingXmlPath) {
        $problems.Add("MacOSOnboardingXmlPath is not set but -RequireMacOS was specified. Download WindowsDefenderATPOnboarding.xml fresh from THIS customer's Defender portal before deploying category 16 — see 16_Defender_for_Endpoint_macOS/README_Onboarding_Package.md. It cannot be reused from another tenant (Production Note #32).")
    }
    if ($cfg.MacOSOnboardingXmlPath -and -not (Test-Path $cfg.MacOSOnboardingXmlPath)) {
        $problems.Add("MacOSOnboardingXmlPath is set to '$($cfg.MacOSOnboardingXmlPath)' but that file does not exist.")
    }

    if ($problems.Count -gt 0) {
        $msg = "Customer config at '$ConfigPath' failed validation:`n`n" + (($problems | ForEach-Object { " - $_" }) -join "`n") + "`n`nFix these before deploying. See config/customer.config.psd1.example for field-by-field context."
        throw $msg
    }

    Write-Host "Customer config OK: $ConfigPath" -ForegroundColor Green
    return $cfg
}
