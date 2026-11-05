#Requires -Version 7.4
<#
.SYNOPSIS
Levantamiento de Microsoft 365 Copilot, agentes y SharePoint. Solo lectura remota.
.DESCRIPTION
Una ejecucion por tenant explicito. No instala modulos, concede permisos ni cambia recursos.
Usar una consola independiente por tenant. README.md contiene permisos y limites de cobertura.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$OutputDirectory=(Join-Path (Get-Location) 'Resultados'),
    [ValidateSet('D7','D28','D90','D180')][string]$ReportPeriod='D28',
    [Security.SecureString]$PowerPlatformAccessToken,
    [guid]$PowerPlatformClientId=[guid]::Empty,
    [guid]$GraphClientId=[guid]::Empty,
    [uri]$SharePointAdminUrl,
    [guid]$SharePointClientId=[guid]::Empty,
    [string[]]$SharePointSiteUrls=@(),
    [guid[]]$SecurityGroupIds=@(),
    [switch]$IncludeLicensedUsers,
    [switch]$IncludeGroupMembers,
    [switch]$IncludeLegacyConsumption,
    [datetime]$FromDate=(Get-Date -Day 1).Date,
    [datetime]$ToDate=(Get-Date).Date,
    [switch]$NoInteractive,
    [switch]$SkipGraph,
    [switch]$SkipPowerPlatform,
    [switch]$SkipPowerApps,
    [switch]$SkipSharePoint,
    [switch]$SkipDataverse,
    [switch]$SkipCopilotReports,
    [switch]$PreflightOnly,
    [ValidateRange(1,10000)][int]$MaxPages=1000,
    [ValidateRange(1,100000)][int]$MaxSites=500,
    [ValidateRange(1,10000)][int]$MaxSubWebsPerSite=100,
    [ValidateRange(1,1000000)][int]$MaxItemsPerSite=20000,
    [ValidateRange(1,100000)][int]$MaxUniqueScopesPerSite=5000,
    [ValidateRange(1,100000)][int]$MaxDataversePrincipals=5000,
    [ValidateRange(30,600)][int]$RequestTimeoutSeconds=120,
    [ValidateRange(1,1440)][int]$MaxDurationMinutes=240
)
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.4.6') {throw 'Se requiere PowerShell 7.4.6 o posterior.'}
if ($TenantId -eq [guid]::Empty) {throw 'TenantId no puede estar vacio.'}
if ($FromDate.Date -gt $ToDate.Date) {throw 'FromDate debe ser anterior o igual a ToDate.'}
foreach ($url in $SharePointSiteUrls) {if (-not [uri]::IsWellFormedUriString($url,[UriKind]::Absolute)) {throw 'SharePointSiteUrls contiene una URL invalida.'}}
$script:started=[datetime]::UtcNow
$script:deadline=$script:started.AddMinutes($MaxDurationMinutes)
$script:runId=$script:started.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$script:runPath=Join-Path (Join-Path $OutputDirectory $TenantId.ToString()) $script:runId
$null=New-Item -ItemType Directory -Path $script:runPath
$script:runPath=(Get-Item -LiteralPath $script:runPath).FullName
$script:evidencePath=Join-Path $script:runPath 'evidencias'
$null=New-Item -ItemType Directory -Path $script:evidencePath
$script:status=[Collections.Generic.List[object]]::new()
$script:requests=[Collections.Generic.List[object]]::new()
$script:diagnostics=[Collections.Generic.List[object]]::new()
$script:sourcePages=0;$script:activeSource=$null
$script:ppToken=$null;$script:graphReady=$false
$script:checkpointEnabled=$false
$script:authentication=[ordered]@{TenantId=$TenantId.ToString();OrigenTenant='Parametro obligatorio';GraphClientId=$null;PowerPlatformClientId=$null;OrigenPowerPlatform=$null;NoInteractive=[bool]$NoInteractive}
. (Join-Path $PSScriptRoot 'lib/Core.ps1')
$script:execution=[ordered]@{
    Version='2.0.3';SchemaVersion='2.0';TenantId=$TenantId.ToString();RunId=$script:runId
    InicioUTC=$script:started.ToString('o');FinUTC=$null;EstadoRecoleccion='EnCurso';EstadoEvaluacion='NoEvaluado'
    SoloLecturaRemota=$true;PowerShell=$PSVersionTable.PSVersion.ToString();Sistema=$PSVersionTable.OS
    ScriptSHA256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    ReportPeriod=$ReportPeriod;CopilotReportVersion='v2';Modo=$(if ($PreflightOnly) {'Preflight'} else {'Captura'})
    Opciones=[ordered]@{IncludeLicensedUsers=[bool]$IncludeLicensedUsers;IncludeGroupMembers=[bool]$IncludeGroupMembers;IncludeLegacyConsumption=[bool]$IncludeLegacyConsumption;FromDate=$FromDate.ToString('yyyy-MM-dd');ToDate=$ToDate.ToString('yyyy-MM-dd');MaxPages=$MaxPages;MaxSites=$MaxSites;MaxItemsPerSite=$MaxItemsPerSite;MaxUniqueScopesPerSite=$MaxUniqueScopesPerSite;MaxSubWebsPerSite=$MaxSubWebsPerSite;MaxDurationMinutes=$MaxDurationMinutes;SharePointSiteUrls=$SharePointSiteUrls;RequestTimeoutSeconds=$RequestTimeoutSeconds}
    Modulos=@();Requeridas=@('IdentidadTenant','LicenciasSKU','Agentes','Entornos','PlanesFacturacion','CopilotCredits','PoliticasDLP','ConfiguracionTenant','DataverseRoles','CopilotUsoDetalle','CopilotAdopcionResumen','CopilotAdopcionTendencia','SharePointInventario')
}
$script:execution.ArchivosPrograma=@(@(Get-Item -LiteralPath $PSCommandPath)+@(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'lib') -Filter '*.ps1') | ForEach-Object {[pscustomobject]@{Archivo=[IO.Path]::GetRelativePath($PSScriptRoot,$_.FullName);SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
foreach ($option in @('NoInteractive','SkipGraph','SkipPowerPlatform','SkipPowerApps','SkipDataverse','SkipSharePoint','SkipCopilotReports','PreflightOnly')) {$script:execution.Opciones[$option]=[bool](Get-Variable -Name $option -ValueOnly)}
$script:execution.Opciones.MaxDataversePrincipals=$MaxDataversePrincipals
$script:execution.Opciones.SharePointAdminUrl=[string]$SharePointAdminUrl
$script:execution.Opciones.SharePointClientId=$SharePointClientId.ToString()
Save-Json 'ejecucion' $script:execution
$script:checkpointEnabled=$true
try {
    . (Join-Path $PSScriptRoot 'lib/Authentication.ps1')
    if ($script:graphReady) {
        $organization=@(Collect 'IdentidadTenant' {Read-Pages Graph 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName,verifiedDomains'})
        if ($organization.Count -ne 1 -or $organization[0].id -ne $TenantId.ToString()) {throw 'La identidad del tenant Graph no pudo verificarse.'}
        $null=Collect 'PrivacidadReportes' {Read-Object Graph 'https://graph.microsoft.com/v1.0/admin/reportSettings' @('displayConcealedNames')}
        $null=Collect 'PIMElegible' {Read-Pages Graph 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances'}
        $null=Collect 'PIMAsignacionesProgramadas' {Read-Pages Graph 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances'}
        if (-not $SkipCopilotReports) {
            $null=Collect 'CopilotUsoDetalle' {Read-GraphReport 'getMicrosoft365CopilotUsageUserDetail' @('Report Refresh Date','Report Period','User Principal Name','Last Activity Date')}
            $null=Collect 'CopilotAdopcionResumen' {Read-GraphReport 'getMicrosoft365CopilotUserCountSummary' @('Report Refresh Date','Report Period','Any App Enabled Users','Any App Active Users')}
            $null=Collect 'CopilotAdopcionTendencia' {Read-GraphReport 'getMicrosoft365CopilotUserCountTrend' @('Report Refresh Date','Report Period','Report Date','Any App Enabled Users','Any App Active Users')}
        } else {Add-Status 'ReportesCopilot' 'Omitido' 0 'SkipCopilotReports solicitado.'}
    }
    . (Join-Path $PSScriptRoot 'lib/Agents.ps1')
    . (Join-Path $PSScriptRoot 'lib/Dataverse.ps1')
    Collect-Dataverse
    . (Join-Path $PSScriptRoot 'lib/SharePoint.Process.ps1')
    Collect-SharePointIsolated
    foreach ($pending in @(
        @('CatalogoM365Teams','Conciliar inventario con catalogos M365/Teams y bots clasicos; exportacion oficial.'),
        @('PublicacionALM','Soluciones, pipelines, aprobaciones y permisos de publicacion; no inferirlos de canales.'),
        @('DataversePermisos','Roles directos/equipos/application users y comparticion por agente. No se conceden roles ni permisos.'),
        @('DLPEfectiva','Correlacionar inclusion/exclusion por entorno, conectores, acciones, conocimiento y canales. Existencia no acredita aplicabilidad efectiva.'),
        @('CreditosAsignaciones','Adjuntar asignaciones, consumo y reglas TenantPool/overage por entorno desde fuente soportada; availability solo acredita disponibilidad para asignar.'),
        @('FacturasPagos','Conciliar contrato M365/Azure/CSP, cargos, facturas, estado de pago y presupuestos; no inferirlos de SKU o PAYG habilitado.'),
        @('MonitoreoAuditoria','Adjuntar configuracion de Purview, retencion, actividad, alertas y limites con periodo y ultima actualizacion; sin exportar conversaciones.'),
        @('AccesoFuentes','Evaluar etiquetas/restricciones, identidades de acciones, grupos anidados y acceso efectivo a fuentes; el alcance SharePoint no incluye OneDrive ni otras cargas.')
    )) {Add-Status $pending[0] 'Validacion manual' 0 $pending[1]}
} catch {
    $safe=Get-SafeError $_
    Add-Status 'Ejecucion' $safe.Estado 0 ('Captura interrumpida; tipo='+$safe.Tipo+'. Evidencia conservada; ver diagnostico.')
    $script:diagnostics.Add([pscustomobject]@{Fuente='Ejecucion';HTTP=$safe.HTTP;Tipo=$safe.Tipo;RequestId=$safe.RequestId;UTC=[datetime]::UtcNow.ToString('o')})
} finally {
    $script:checkpointEnabled=$false
    $script:ppToken=$null;$PowerPlatformAccessToken=$null
    $script:dataverseTokens=@{}
    $script:execution.FinUTC=[datetime]::UtcNow.ToString('o')
    $script:execution.Modulos=@(Get-Module | Where-Object Name -in @('Microsoft.Graph.Authentication','Az.Accounts','MSAL.PS','Microsoft.PowerApps.Administration.PowerShell','PnP.PowerShell') | ForEach-Object {[pscustomobject]@{Nombre=$_.Name;Version=$_.Version.ToString()}})
    $obtained=@($script:status | Where-Object Estado -eq 'Obtenido')
    $missing=@($script:execution.Requeridas | Where-Object {$_ -notin $obtained.Fuente})
    $failed=@($script:status | Where-Object {$_.Estado -notin @('Obtenido','Validacion manual','Omitido')})
    $dataObtained=@($obtained | Where-Object Fuente -in $script:execution.Requeridas)
    $script:execution.EstadoRecoleccion=if (-not $dataObtained.Count) {'Fallido'} elseif ($PreflightOnly) {'Preflight'} elseif ($missing.Count -or $failed.Count) {'Parcial'} else {'CompletoSegunPerfil'}
    $script:execution.FuentesRequeridasPendientes=$missing
    Save-Json 'ejecucion' $script:execution
    Save-Json 'progreso' ([ordered]@{UTC=[datetime]::UtcNow.ToString('o');UltimaFuente='Cierre';EstadoRecoleccion=$script:execution.EstadoRecoleccion;Nota='Consultar cobertura y manifiesto.'})
    Save-Json 'cobertura' $script:status.ToArray()
    Save-Json 'diagnostico' $script:diagnostics.ToArray()
    Save-Csv 'cobertura' $script:status.ToArray()
    Save-Csv 'consultas' $script:requests.ToArray()
    Save-Csv 'diagnostico' $script:diagnostics.ToArray()
    Write-Manifest
}
$analysis=& (Join-Path $PSScriptRoot 'Analyze-CopilotAssessment.ps1') -RunDirectory $script:runPath
$code=if ($script:execution.EstadoRecoleccion -eq 'Fallido') {1} elseif ($script:execution.EstadoRecoleccion -in @('Parcial','Preflight')) {2} else {0}
Write-Host "Captura: $($script:execution.EstadoRecoleccion). Evaluacion: requiere cierre de controles. $script:runPath"
[pscustomobject]@{TenantId=$TenantId.ToString();RunId=$script:runId;Carpeta=$script:runPath;EstadoRecoleccion=$script:execution.EstadoRecoleccion;EstadoEvaluacion=$analysis.EstadoEvaluacion;ExitCode=$code;Informe=$analysis.Informe}
