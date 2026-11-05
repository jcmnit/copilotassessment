#Requires -Version 7.4
<#
.SYNOPSIS
Recuperacion offline de una captura sin manifiesto. No consulta Microsoft.
.DESCRIPTION
Crea una carpeta hermana nueva, conserva originales y marca toda evidencia recuperada
como pendiente de validacion. Los hashes acreditan el estado desde la recuperacion,
no la integridad historica ni que la fuente se haya consultado completamente.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunDirectory)
$ErrorActionPreference='Stop'
$source=Get-Item -LiteralPath $RunDirectory -Force
if (-not $source.PSIsContainer -or $source.LinkType) {throw 'Indicar una carpeta de captura regular.'}
if (Test-Path -LiteralPath (Join-Path $source.FullName 'manifiesto-sha256.csv')) {throw 'Ya existe manifiesto. Utilice el analizador normal; no se elude una comprobacion de integridad fallida.'}
$entries=@(Get-ChildItem -LiteralPath $source.FullName -Recurse -Force)
if (@($entries | Where-Object LinkType).Count) {throw 'No se admiten enlaces simbolicos en la captura.'}
$metadataFile=Join-Path $source.FullName 'evidencias/ejecucion.json'
$original=Get-Content -LiteralPath $metadataFile -Raw | ConvertFrom-Json -AsHashtable
$TenantId=[guid]$original.TenantId
if ($TenantId -eq [guid]::Empty -or $original.RunId -notmatch '^\d{8}T\d{6}Z-[0-9a-f]{8}$' -or $original.ReportPeriod -notin @('D7','D28','D90','D180') -or $original.CopilotReportVersion -ne 'v2') {throw 'Metadatos de captura no compatibles con recuperacion.'}
$script:runId=$original.RunId
$script:started=[datetime]$original.InicioUTC
$recoveredAt=[datetime]::UtcNow
$destination=Join-Path $source.Parent.FullName ($source.Name+'-recuperado-'+$recoveredAt.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$null=New-Item -ItemType Directory -Path $destination
$script:runPath=$destination
$script:evidencePath=Join-Path $destination 'evidencias'
$null=New-Item -ItemType Directory -Path $script:evidencePath
$copied=[Collections.Generic.List[object]]::new()
foreach ($file in $entries | Where-Object {-not $_.PSIsContainer}) {
    $relative=[IO.Path]::GetRelativePath($source.FullName,$file.FullName)
    $portable=$relative -replace '\\','/'
    if ($portable -match '/' -and -not $portable.StartsWith('evidencias/')) {continue}
    if ($file.Extension -notin @('.json','.csv','.txt','.log')) {continue}
    $target=Join-Path $destination $relative
    $null=New-Item -ItemType Directory -Path (Split-Path $target) -Force
    $before=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $file.FullName -Destination $target
    $after=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    if ($before -ne $after -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $before) {throw 'Un archivo cambio durante la copia. No utilizar la recuperacion incompleta.'}
    $copied.Add([pscustomobject]@{ArchivoOriginal=$portable;SHA256EnRecuperacion=$before;Bytes=$file.Length})
}
# Archivar metadatos previos solo dentro de la copia; nunca sustituir los originales.
foreach ($name in @('ejecucion','cobertura','diagnostico')) {
    $path=Join-Path $script:evidencePath ($name+'.json')
    if (Test-Path -LiteralPath $path) {Move-Item -LiteralPath $path -Destination (Join-Path $script:evidencePath ($name+'-original.json'))}
}
$script:execution=$original
$script:execution.EstadoRecoleccion='Parcial'
$script:execution.EstadoEvaluacion='Pendiente'
$script:execution.Modo='RecuperacionOffline'
$script:execution.RecuperacionUTC=$recoveredAt.ToString('o')
$script:execution.VersionRecuperador='2.0.1'
$script:execution.OrigenRecuperacion=$source.FullName
$script:execution.EstadoOriginal=(Get-Content -LiteralPath (Join-Path $script:evidencePath 'ejecucion-original.json') -Raw | ConvertFrom-Json).EstadoRecoleccion
$script:execution.IntegridadOrigen='No verificable antes de la recuperacion. El manifiesto nuevo acredita solo el estado de la copia desde este momento.'
# FinUTC se conserva como estaba: recuperar no completa retroactivamente la captura.
. (Join-Path $PSScriptRoot 'lib/Core.ps1')
$script:checkpointEnabled=$false
$script:status=[Collections.Generic.List[object]]::new()
$script:requests=[Collections.Generic.List[object]]::new()
$script:diagnostics=[Collections.Generic.List[object]]::new()
$available=[Collections.Generic.HashSet[string]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath $script:evidencePath -Filter '*.json' -File -Recurse)) {
    if ($file.Name -in @('ejecucion-original.json','cobertura-original.json','diagnostico-original.json')) {continue}
    $valid=$true
    try {$data=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop} catch {$valid=$false}
    if (-not $valid) {
        $relative=[IO.Path]::GetRelativePath($destination,$file.FullName)
        $quarantine=Join-Path (Join-Path $destination 'archivos-no-interpretados') $relative
        $null=New-Item -ItemType Directory -Path (Split-Path $quarantine) -Force
        Move-Item -LiteralPath $file.FullName -Destination $quarantine
        Add-Status $file.BaseName 'ErrorDeEsquema' 0 'JSON no interpretable conservado en archivos-no-interpretados. No se usa para conclusiones.'
        continue
    }
    if ($file.BaseName -match '^(pagina-|inventario-)' -or $file.BaseName -eq 'autenticacion') {continue}
    $null=$available.Add($file.BaseName)
    $count=if ($null -eq $data) {0} else {@($data).Count}
    Add-Status $file.BaseName 'Validacion manual' $count 'Archivo recuperado; no acredita completitud, permisos, integridad historica ni exito de la consulta.'
}
foreach ($required in @($original.Requeridas)) {
    if (-not $available.Contains([string]$required)) {Add-Status $required 'No obtenido' 0 'Sin resultado normalizado recuperable para esta fuente. No equivale a cero recursos.'}
}
Add-Status 'RecuperacionOffline' 'Validacion manual' $copied.Count 'Captura interrumpida. Causa no determinada. No se realizaron consultas al tenant ni se modificaron originales.'
$script:execution.FuentesRequeridasPendientes=@($original.Requeridas)
Save-Json 'recuperacion' ([ordered]@{TenantId=$TenantId.ToString();RunId=$script:runId;RecuperacionUTC=$recoveredAt.ToString('o');Version='2.0.1';Archivos=$copied.ToArray();Advertencia=$script:execution.IntegridadOrigen})
Save-Json 'ejecucion' $script:execution
Save-Json 'cobertura' $script:status.ToArray()
Save-Json 'diagnostico' $script:diagnostics.ToArray()
Save-Csv 'cobertura' $script:status.ToArray()
Write-Manifest
$analysis=& (Join-Path $PSScriptRoot 'Analyze-CopilotAssessment.ps1') -RunDirectory $destination
Write-Host "Recuperacion parcial guardada en: $destination"
[pscustomobject]@{Estado='RecuperacionParcial';CarpetaOriginal=$source.FullName;CarpetaRecuperada=$destination;Informe=$analysis.Informe;EstadoEvaluacion=$analysis.EstadoEvaluacion;Advertencia=$script:execution.IntegridadOrigen}
