#Requires -Version 7.4
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=Join-Path ([IO.Path]::GetTempPath()) ('spo-access-tests-'+[guid]::NewGuid().ToString('N'))
$global:SpoTestTenant='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';$global:SpoTests=0
function Assert($Value,$Message) {if (-not $Value) {throw "FALLO: $Message"};$global:SpoTests++}
Add-Type 'namespace Microsoft.SharePoint.Client {public enum PermissionKind {ViewListItems, EnumeratePermissions, ManagePermissions}}'
function Import-Module {[CmdletBinding()]param($Name) Assert ($Name -eq 'PnP.PowerShell') 'Solo PnP'}
function Connect-PnPOnline {[CmdletBinding()]param($Url,$Tenant,$ClientId,$AccessToken,[switch]$ReturnConnection,[switch]$Interactive)
    if ($Interactive) {$global:SpoLoginCount++;Assert ($global:SpoLoginCount -eq 1) 'Un solo intento PnP'}
    else {Assert ($AccessToken -eq $global:SpoToken) 'Conexion de inventario con token en memoria'}
    [pscustomobject]@{Url=$Url}
}
function Get-PnPAccessToken {[CmdletBinding()]param($ResourceTypeName,$Connection) $global:SpoToken}
function Get-PnPTenant {[CmdletBinding()]param($Connection) if ($global:SpoMode -eq 'admin-denied') {throw 'Attempted to perform an unauthorized operation.'}}
function Get-PnPWeb {[CmdletBinding()]param($Includes,$Connection)
    if ($global:SpoMode -eq 'site-denied') {throw [Exception]::new('wrapped SECRET', [UnauthorizedAccessException]::new('SECRET-INNER'))}
    $perms=[pscustomobject]@{}
    $perms | Add-Member ScriptMethod Has {param($kind) return ($global:SpoMode -ne 'acl-denied' -or [string]$kind -eq 'ViewListItems')}
    [pscustomobject]@{CurrentUser=[pscustomobject]@{IsSiteAdmin=($global:SpoMode -ne 'acl-denied')};EffectiveBasePermissions=$perms}
}
function Get-PnPProperty {[CmdletBinding()]param($ClientObject,$Property,$Connection)
    if ($Property -eq 'RoleAssignments' -and $global:SpoMode -eq 'acl-denied') {throw 'Access denied. SECRET-RAW-BODY fake.jwt.token'}
    return @()
}
function Get-PnPSubWeb {[CmdletBinding()]param([switch]$Recurse,$Includes,$Connection) return @()}
function Get-PnPList {[CmdletBinding()]param($Includes,$Connection) return @()}
foreach ($mode in @('normal','acl-denied','site-denied','admin-denied')) {
    $global:SpoMode=$mode;$global:SpoLoginCount=0
    $claims=@{tid=$global:SpoTestTenant;aud='00000003-0000-0ff1-ce00-000000000000';scp='AllSites.FullControl';exp=[datetimeoffset]::UtcNow.ToUnixTimeSeconds()+3600} | ConvertTo-Json -Compress
    $global:SpoToken='fake.'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_')+'.fake'
    $r=& (Join-Path $root 'Test-SharePointAccess.ps1') -TenantId $global:SpoTestTenant -SharePointClientId 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' -SharePointAdminUrl 'https://example-admin.sharepoint.com' -SiteUrl 'https://example.sharepoint.com/sites/test' -OutputDirectory $out
    $raw=Get-Content -LiteralPath $r.Diagnostico -Raw;$report=$raw | ConvertFrom-Json
    Assert ($r.IntentosInteractivos -eq 1 -and $global:SpoLoginCount -eq 1) 'Un login para todas las etapas'
    Assert ($raw -notmatch 'SECRET|fake\.[A-Za-z0-9_-]+\.fake|jwt.token') 'Sin mensajes ni tokens originales'
    Assert ($report.ScopesSharePoint -eq 'AllSites.FullControl') 'Scope delegado separado de derechos de usuario'
    if ($mode -eq 'normal') {Assert (@($report.Pasos | Where-Object Estado -ne 'Obtenido').Count -eq 0) 'Prueba completa sin errores'}
    if ($mode -eq 'acl-denied') {
        Assert (-not $report.DerechosCuenta.IsSiteAdmin -and -not $report.DerechosCuenta.EnumeratePermissions) 'FullControl de app no implica derechos de cuenta'
        $step=$report.Pasos | Where-Object Etapa -eq 'LeerAsignacionesWeb'
        Assert ($step.Estado -eq 'SinPermiso' -and $step.Diagnostico.Motivo -eq 'AccesoDenegado') 'Excepcion generica PnP clasificada sin mensaje'
        Assert ($step.Diagnostico.Linea -gt 0 -and $step.Diagnostico.Archivo) 'Ubicacion diagnostica'
    }
    if ($mode -eq 'site-denied') {
        $step=$report.Pasos | Where-Object Etapa -eq 'LeerWeb'
        Assert ($step.Estado -eq 'SinPermiso' -and $step.Diagnostico.TipoInterno -eq 'UnauthorizedAccessException') 'Excepcion interna clasificada'
        Assert ('LeerAsignacionesWeb' -notin $report.Pasos.Etapa) 'No simular ACL completas sin acceso al sitio'
    }
    if ($mode -eq 'admin-denied') {
        Assert (($report.Pasos | Where-Object Etapa -eq 'AdministracionTenant').Estado -eq 'SinPermiso') 'Derechos administrativos separados'
        Assert (($report.Pasos | Where-Object Etapa -eq 'LeerAsignacionesWeb').Estado -eq 'Obtenido') 'Sitio puede funcionar aunque administracion falle'
    }
}
Write-Host "OK: $global:SpoTests aserciones; sin conexiones reales ni cambios de permisos."
