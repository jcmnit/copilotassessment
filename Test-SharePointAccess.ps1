#Requires -Version 7.4
<# Diagnostico de solo lectura de UN sitio. No cambia propietarios ni permisos. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$SharePointClientId,
    [Parameter(Mandatory)][string]$SharePointAdminUrl,
    [Parameter(Mandatory)][string]$SiteUrl,
    [string]$OutputDirectory=(Join-Path (Get-Location) 'Diagnostico-SharePoint')
)
$ErrorActionPreference='Stop'
if ($TenantId -eq [guid]::Empty -or $SharePointClientId -eq [guid]::Empty) {throw 'TenantId y SharePointClientId deben ser GUID validos.'}
. (Join-Path $PSScriptRoot 'lib/Core.ps1')
. (Join-Path $PSScriptRoot 'lib/Tokens.ps1')
. (Join-Path $PSScriptRoot 'lib/SharePoint.ps1')
Assert-SharePointUrl $SharePointAdminUrl -Admin
Assert-SharePointUrl $SiteUrl
# El proceso debe permanecer aislado de los SDK que causaron conflicto con PnP.
if (@(Get-Module | Where-Object Name -in @('Microsoft.Graph.Authentication','Az.Accounts','Microsoft.PowerApps.Administration.PowerShell')).Count) {throw 'Ejecutar en pwsh -NoProfile independiente, sin Graph/Azure/PowerApps cargados.'}
$NoInteractive=$false
$script:deadline=[datetime]::UtcNow.AddMinutes(10)
$script:spoInteractiveAttempts=0;$script:spoAuthStopped=$false;$script:spoToken=$null
$results=[Collections.Generic.List[object]]::new()
$scopes=@();$admin=$null;$site=$null;$web=$null;$effective=$null
function Invoke-SpoAccessStep([string]$Stage,[scriptblock]$Action) {
    $script:spoStage=$Stage
    try {
        Assert-Deadline
        $value=& $Action
        $results.Add([pscustomobject]@{Etapa=$Stage;Estado='Obtenido';Diagnostico=$null})
        return $value
    } catch {
        $safe=Get-SafeError $_
        $results.Add([pscustomobject]@{Etapa=$Stage;Estado=$safe.Estado;Diagnostico=$safe})
        return $null
    }
}
try {
    Import-Module PnP.PowerShell -ErrorAction Stop
    $admin=Invoke-SpoAccessStep 'ConexionAdministrativa' {Connect-AssessmentSharePoint $SharePointAdminUrl}
    if ($script:spoToken) {
        $claims=Read-TokenClaims $script:spoToken
        # Solo nombres conocidos de scopes; no exportar claims, token ni identificadores de usuario.
        $scopes=@(([string]$claims.scp).Split(' ') | Where-Object {$_ -in @('AllSites.Read','AllSites.Write','AllSites.Manage','AllSites.FullControl')})
        $claims=$null
    }
    if ($admin) {$null=Invoke-SpoAccessStep 'AdministracionTenant' {Get-PnPTenant -Connection $admin -ErrorAction Stop | Out-Null}}
    if (-not $script:spoAuthStopped -and $script:spoToken) {
        $site=Invoke-SpoAccessStep 'ConexionSitio' {Connect-AssessmentSharePoint $SiteUrl}
        if ($site) {
            $web=Invoke-SpoAccessStep 'LeerWeb' {Get-PnPWeb -Includes Url,EffectiveBasePermissions,CurrentUser -Connection $site -ErrorAction Stop}
            if ($web) {
                $effective=Invoke-SpoAccessStep 'DerechosCuenta' {
                    $null=Get-PnPProperty -ClientObject $web.CurrentUser -Property IsSiteAdmin -Connection $site -ErrorAction Stop
                    [pscustomobject]@{
                        IsSiteAdmin=[bool]$web.CurrentUser.IsSiteAdmin
                        EnumeratePermissions=$web.EffectiveBasePermissions.Has([Microsoft.SharePoint.Client.PermissionKind]::EnumeratePermissions)
                        ManagePermissions=$web.EffectiveBasePermissions.Has([Microsoft.SharePoint.Client.PermissionKind]::ManagePermissions)
                        ViewListItems=$web.EffectiveBasePermissions.Has([Microsoft.SharePoint.Client.PermissionKind]::ViewListItems)
                    }
                }
                $null=Invoke-SpoAccessStep 'LeerAsignacionesWeb' {Get-PnPProperty -ClientObject $web -Property RoleAssignments -Connection $site -ErrorAction Stop | Out-Null}
                $null=Invoke-SpoAccessStep 'EnumerarSubwebs' {Get-PnPSubWeb -Recurse -Includes Url -Connection $site -ErrorAction Stop | Out-Null}
                $null=Invoke-SpoAccessStep 'EnumerarListas' {Get-PnPList -Includes Hidden,HasUniqueRoleAssignments -Connection $site -ErrorAction Stop | Out-Null}
            }
        }
    }
} finally {
    $script:spoToken=$null;$admin=$null;$site=$null;$web=$null
    $null=New-Item -ItemType Directory -Path $OutputDirectory -Force
    $folder=Join-Path (Get-Item -LiteralPath $OutputDirectory).FullName ([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $null=New-Item -ItemType Directory -Path $folder
    $report=[ordered]@{Version='1.0';TenantId=$TenantId.ToString();ClientId=$SharePointClientId.ToString();SiteUrl=$SiteUrl;UTC=[datetime]::UtcNow.ToString('o');IntentosInteractivos=$script:spoInteractiveAttempts;ScopesSharePoint=$scopes;DerechosCuenta=$effective;Pasos=$results.ToArray();Nota='Prueba parcial de un sitio. No consulta items/enlaces ni garantiza acceso a todos los alcances. No cambia permisos ni conserva tokens.'}
    $path=Join-Path $folder 'diagnostico-sharepoint.json'
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8BOM
}
$results | Select-Object Etapa,Estado | Format-Table -AutoSize | Out-Host
[pscustomobject]@{Diagnostico=$path;IntentosInteractivos=$script:spoInteractiveAttempts;ScopesSharePoint=$scopes;DerechosCuenta=$effective}
