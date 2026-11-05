#Requires -Version 7.4
[CmdletBinding()]
param([string]$OutputDirectory=(Join-Path ([IO.Path]::GetTempPath()) ('copilot-recovery-tests-'+[guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$assertions=0
function Assert($Value,[string]$Message) {if (-not $Value) {throw "FALLO: $Message"};$script:assertions++}
$source=Join-Path $OutputDirectory 'captura-interrumpida'
$evidence=Join-Path $source 'evidencias'
$null=New-Item -ItemType Directory -Path $evidence -Force
$meta=[ordered]@{Version='2.0.0';TenantId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';RunId='20261104T143945Z-e2cf3249';InicioUTC='2026-11-04T14:39:45Z';FinUTC=$null;EstadoRecoleccion='EnCurso';EstadoEvaluacion='NoEvaluado';Modo='Captura';ReportPeriod='D28';CopilotReportVersion='v2';Requeridas=@('Agentes','LicenciasSKU','CopilotUsoDetalle','SharePointInventario')}
$meta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidence 'ejecucion.json') -Encoding utf8BOM
@([pscustomobject]@{skuId='sku1';skuPartNumber='TEST';capabilityStatus='Enabled'}) | ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $evidence 'LicenciasSKU.json') -Encoding utf8BOM
@([pscustomobject]@{name='agent1';properties=@{ownerId=$null;authentication='None'}}) | ConvertTo-Json -AsArray -Depth 10 | Set-Content -LiteralPath (Join-Path $evidence 'Agentes.json') -Encoding utf8BOM
'{ invalid JSON' | Set-Content -LiteralPath (Join-Path $evidence 'CopilotUsoDetalle.json')
$before=@(Get-ChildItem -LiteralPath $source -File -Recurse | ForEach-Object {[pscustomobject]@{Path=$_.FullName;Hash=(Get-FileHash -LiteralPath $_.FullName).Hash}})
$result=& (Join-Path $root 'Recover-CopilotAssessment.ps1') -RunDirectory $source
Assert ($result.Estado -eq 'RecuperacionParcial') 'Recuperacion identificada como parcial'
Assert ($result.CarpetaOriginal -ne $result.CarpetaRecuperada) 'Carpeta distinta'
Assert (-not (Test-Path -LiteralPath (Join-Path $source 'manifiesto-sha256.csv'))) 'No agregar manifiesto al original'
foreach ($item in $before) {Assert ((Get-FileHash -LiteralPath $item.Path).Hash -eq $item.Hash) 'Original intacto'}
Assert (@(Get-ChildItem -LiteralPath $source -File -Recurse).Count -eq $before.Count) 'Sin archivos nuevos en el original'
$new=Get-Content -LiteralPath (Join-Path $result.CarpetaRecuperada 'evidencias/ejecucion.json') -Raw | ConvertFrom-Json
Assert ($new.Modo -eq 'RecuperacionOffline' -and $new.EstadoRecoleccion -eq 'Parcial') 'Modo y estado veraces'
Assert (-not $new.FinUTC -and $new.EstadoOriginal -eq 'EnCurso') 'No inventar cierre original'
Assert ($new.RecuperacionUTC -and $new.RunId -eq $meta.RunId) 'Fecha propia y vinculacion con captura'
$coverage=Import-Csv -LiteralPath (Join-Path $result.CarpetaRecuperada 'cobertura.csv')
Assert ('Obtenido' -notin $coverage.Estado) 'No certificar exito de fuentes recuperadas'
Assert (@($coverage | Where-Object {$_.Fuente -eq 'SharePointInventario' -and $_.Estado -eq 'No obtenido'}).Count -eq 1) 'Fuente ausente desconocida'
Assert (Test-Path -LiteralPath (Join-Path $result.CarpetaRecuperada 'archivos-no-interpretados/evidencias/CopilotUsoDetalle.json')) 'JSON invalido preservado fuera del analisis'
Assert (-not (Test-Path -LiteralPath (Join-Path $result.CarpetaRecuperada 'evidencias/CopilotUsoDetalle.json'))) 'No interpretar JSON invalido'
foreach ($row in Import-Csv -LiteralPath (Join-Path $result.CarpetaRecuperada 'manifiesto-sha256.csv')) {Assert ((Get-FileHash -LiteralPath (Join-Path $result.CarpetaRecuperada $row.Archivo)).Hash -eq $row.SHA256) 'Integridad desde recuperacion'}
$html=Get-Content -LiteralPath $result.Informe -Raw
Assert ($html -match 'RECUPERACION OFFLINE DE CAPTURA INTERRUMPIDA' -and $html -match 'no verifican integridad anterior') 'Advertencia destacada en informe'
Assert ($result.EstadoEvaluacion -eq 'Pendiente') 'Controles no acreditados'
$blocked=$false
try {$null=& (Join-Path $root 'Recover-CopilotAssessment.ps1') -RunDirectory $result.CarpetaRecuperada} catch {$blocked=$true}
Assert $blocked 'No eludir manifiesto preexistente'
$reanalyzed=& (Join-Path $root 'Analyze-CopilotAssessment.ps1') -RunDirectory $result.CarpetaRecuperada
Assert ($reanalyzed.EstadoEvaluacion -eq 'Pendiente') 'Reanalisis offline repetible'
Write-Host "OK: $assertions aserciones de recuperacion; sin conexiones reales."
[pscustomobject]@{Estado='OK';Aserciones=$assertions;Resultados=$OutputDirectory}
