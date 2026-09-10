<#
.SYNOPSIS
    One-time setup: creates the app registration used for BOTH the Terraform azuread
    provider (assignment groups only — see ../terraform/groups.tf) and
    ../deploy/Deploy-IntuneBaseline.ps1 (the 222 Intune policies themselves), and prints
    the environment variables / Graph connection command to use.

.DESCRIPTION
    One app registration, one set of credentials, one thing to delete at end of engagement —
    same "no standing access" principle as the CA-Baseline project's bootstrap script, just
    covering two call paths (azuread provider + Invoke-MgGraphRequest) instead of one.

    Requires the Microsoft.Graph PowerShell module and a Global Administrator (or Privileged
    Role Administrator + Application Administrator) signed in interactively.

    Written for a single-engagement tenant. For anything longer-lived, replace the client
    secret with a federated credential (OIDC) — see
    https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation.

.NOTES
    Run once per tenant you're deploying into. Re-running is safe — it looks for an existing
    app by display name first rather than creating a duplicate.
#>

#Requires -Modules Microsoft.Graph.Applications, Microsoft.Graph.Authentication

param(
    [string]$AppDisplayName = "Intune-Baseline-Deploy",
    [int]$SecretValidityMonths = 6
)

Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All", "Directory.Read.All"

# Application (app-only) permissions actually touched by groups.tf + Deploy-IntuneBaseline.ps1:
#   DeviceManagementConfiguration.ReadWrite.All — configurationPolicies, deviceConfigurations,
#                                                  compliancePolicies, intents (all 5 shapes in
#                                                  Intune-Baseline/manifest.json)
#   Group.ReadWrite.All                         — create the 9 assignment groups (terraform),
#                                                  resolve them by name (deploy script)
#   Application.Read.All                        — same as CA-Baseline, general app lookup
# Deliberately NOT requesting DeviceManagementManagedDevices.* or DeviceManagementApps.* —
# this deployment creates and assigns policies, it does not need to read managed-device
# inventory or manage app deployments.
$graphAppId = "00000003-0000-0000-c000-000000000000"
$requiredRoleNames = @(
    "DeviceManagementConfiguration.ReadWrite.All",
    "Group.ReadWrite.All",
    "Application.Read.All"
)

$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
$requiredRoles = foreach ($roleName in $requiredRoleNames) {
    $role = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleName -and $_.AllowedMemberTypes -contains "Application" }
    if (-not $role) {
        throw "Could not find an application-permission app role named '$roleName' on the Microsoft Graph service principal. Check the name against https://learn.microsoft.com/en-us/graph/permissions-reference"
    }
    @{ Name = $roleName; Id = $role.Id }
}

$existing = Get-MgApplication -Filter "displayName eq '$AppDisplayName'"
if ($existing) {
    Write-Host "Found existing app registration '$AppDisplayName' ($($existing.AppId)) — reusing it." -ForegroundColor Yellow
    $app = $existing
} else {
    $resourceAccess = $requiredRoles | ForEach-Object { @{ Id = $_.Id; Type = "Role" } }
    $app = New-MgApplication -DisplayName $AppDisplayName -RequiredResourceAccess @(
        @{ ResourceAppId = $graphAppId; ResourceAccess = $resourceAccess }
    )
    Write-Host "Created app registration '$AppDisplayName' ($($app.AppId))." -ForegroundColor Green
}

$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"
if (-not $sp) {
    $sp = New-MgServicePrincipal -AppId $app.AppId
}

foreach ($role in $requiredRoles) {
    $already = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id |
        Where-Object { $_.AppRoleId -eq $role.Id -and $_.ResourceId -eq $graphSp.Id }
    if ($already) {
        Write-Host "  [already granted] $($role.Name)" -ForegroundColor DarkGray
        continue
    }
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -PrincipalId $sp.Id `
        -ResourceId $graphSp.Id -AppRoleId $role.Id | Out-Null
    Write-Host "  [granted]          $($role.Name)" -ForegroundColor Green
}

$secretParams = @{
    ApplicationId = $app.Id
    PasswordCredential = @{
        DisplayName = "intune-baseline-deploy"
        EndDateTime = (Get-Date).AddMonths($SecretValidityMonths)
    }
}
$secret = Add-MgApplicationPassword @secretParams

$tenantId = (Get-MgContext).TenantId

Write-Host ""
Write-Host "=== For terraform apply (groups.tf) — export these, or put in app-registration.env ===" -ForegroundColor Cyan
$envLines = @(
    "export ARM_TENANT_ID=`"$tenantId`""
    "export ARM_CLIENT_ID=`"$($app.AppId)`""
    "export ARM_CLIENT_SECRET=`"$($secret.SecretText)`""
)
$envLines | ForEach-Object { Write-Host $_ }
$envLines | Out-File -FilePath "./app-registration.env" -Encoding utf8

Write-Host ""
Write-Host "=== For Deploy-IntuneBaseline.ps1 — run this before the deploy script ===" -ForegroundColor Cyan
Write-Host "  `$cert = ConvertTo-SecureString '$($secret.SecretText)' -AsPlainText -Force" -ForegroundColor Cyan
Write-Host "  Connect-MgGraph -TenantId '$tenantId' -ClientSecretCredential (New-Object System.Management.Automation.PSCredential('$($app.AppId)', `$cert))" -ForegroundColor Cyan

Write-Host ""
Write-Host "IMPORTANT: DeviceManagementConfiguration.ReadWrite.All, Group.ReadWrite.All, and" -ForegroundColor Yellow
Write-Host "Application.Read.All are application (app-only) permissions and require tenant-admin" -ForegroundColor Yellow
Write-Host "consent before either Terraform or the deploy script can use them. Grant it now:" -ForegroundColor Yellow
Write-Host "  https://login.microsoftonline.com/$tenantId/adminconsent?client_id=$($app.AppId)" -ForegroundColor Yellow
Write-Host ""
Write-Host "app-registration.env contains a live client secret — do not commit it. Delete it" -ForegroundColor Yellow
Write-Host "once you've exported the values (this repo's .gitignore already covers it)." -ForegroundColor Yellow
