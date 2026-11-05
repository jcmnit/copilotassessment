#Requires -Version 7.4
<# Worker de solo lectura. No importar Graph, Az.Accounts ni PowerApps en este proceso. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigurationFile)
$ErrorActionPreference='Stop'
$config=Get-Content -LiteralPath $ConfigurationFile -Raw | ConvertFrom-Json -AsHashtable
$TenantId=[guid]$config.TenantId
if ($TenantId -eq [guid]::Empty -or $config.RunId -notmatch '^\d{8}T\d{6}Z-[0-9a-f]{8}$') {throw 'Configuracion de worker invalida.'}
$expected=[IO.Path]::GetFullPath((Join-Path $config.RunDirectory 'sharepoint-worker'))
if ([IO.Path]::GetFullPath($config.WorkerDirectory) -ne $expected) {throw 'Directorio de worker invalido.'}
$script:runPath=(Get-Item -LiteralPath $expected).FullName
$script:evidencePath=Join-Path $script:runPath 'evidencias'
$null=New-Item -ItemType Directory -Path $script:evidencePath
$script:runId=[string]$config.RunId
$script:started=[datetime]$config.InicioUTC
$script:deadline=[datetime]$config.DeadlineUTC
$SharePointAdminUrl=[string]$config.SharePointAdminUrl
$SharePointClientId=[guid]$config.SharePointClientId
$SharePointSiteUrls=@($config.SharePointSiteUrls)
$PreflightOnly=[bool]$config.PreflightOnly;$NoInteractive=[bool]$config.NoInteractive;$SkipSharePoint=$false
$MaxSites=[int]$config.MaxSites;$MaxItemsPerSite=[int]$config.MaxItemsPerSite
$MaxUniqueScopesPerSite=[int]$config.MaxUniqueScopesPerSite;$MaxSubWebsPerSite=[int]$config.MaxSubWebsPerSite
$script:execution=@{Modo=$(if ($PreflightOnly) {'Preflight'} else {'Captura'})}
$script:status=[Collections.Generic.List[object]]::new();$script:diagnostics=[Collections.Generic.List[object]]::new();$script:requests=[Collections.Generic.List[object]]::new()
$script:checkpointEnabled=$true
. (Join-Path $PSScriptRoot 'lib/Core.ps1')
. (Join-Path $PSScriptRoot 'lib/Tokens.ps1')
. (Join-Path $PSScriptRoot 'lib/SharePoint.ps1')
$finished=$false
try {
    if (@(Get-Module | Where-Object Name -in @('Microsoft.Graph.Authentication','Az.Accounts','Microsoft.PowerApps.Administration.PowerShell')).Count) {throw 'Worker no aislado.'}
    Collect-SharePoint
    $finished=$true
} catch {
    $safe=Get-SafeError $_
    Add-Status 'SharePointWorker' $safe.Estado 0 ('Error del worker; tipo='+$safe.Tipo)
} finally {
    $script:checkpointEnabled=$false
    Save-Json 'cobertura' $script:status.ToArray()
    Save-Json 'diagnostico' $script:diagnostics.ToArray()
    $result=[ordered]@{TenantId=$TenantId.ToString();RunId=$script:runId;Terminado=$finished;FinUTC=[datetime]::UtcNow.ToString('o');ProcesoId=$PID;Modulos=@(Get-Module | Where-Object Name -eq 'PnP.PowerShell' | ForEach-Object {[pscustomobject]@{Nombre=$_.Name;Version=$_.Version.ToString()}});Nota='Proceso aislado de los SDK Graph/Azure/PowerApps.'}
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $script:runPath 'resultado.json') -Encoding utf8BOM
    Write-Manifest
}
if (-not $finished) {exit 1}
