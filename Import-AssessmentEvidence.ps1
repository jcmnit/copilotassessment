#Requires -Version 7.4
<# Adjunta evidencia local y una decision humana; no consulta ni modifica el tenant. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidateSet('AG-OWNER','AG-AUTH','AG-ALM','M365-USAGE','SP-BROAD','SP-ANON','SEC-DLP','SEC-ACCESS','FIN-LICENSE','FIN-CREDITS','FIN-BILLING','OPS-AUDIT','GOV-EXCEPTION')][string]$ControlId,
    [Parameter(Mandatory)][string]$EvidenceFile,
    [Parameter(Mandatory)][ValidateSet('Cumple','NoCumple','NoEvaluado','NoAplica')][string]$Estado,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Revisor,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Justificacion
)
$ErrorActionPreference='Stop'
$execution=Get-Content -LiteralPath (Join-Path $RunDirectory 'evidencias/ejecucion.json') -Raw | ConvertFrom-Json
if ($execution.TenantId -ne $TenantId.ToString()) {throw 'La evidencia corresponde a otro tenant.'}
$source=Get-Item -LiteralPath $EvidenceFile
if ($source.PSIsContainer -or $source.LinkType) {throw 'Se requiere un archivo regular de evidencia.'}
$folder=Join-Path $RunDirectory ('complementos/'+$ControlId)
if ((Test-Path -LiteralPath (Join-Path $RunDirectory 'complementos')) -and (Get-Item -LiteralPath (Join-Path $RunDirectory 'complementos') -Force).LinkType) {throw 'Directorio de complementos no puede ser un enlace simbolico.'}
if (Test-Path -LiteralPath $folder) {throw 'Ya existe una decision para ese control. Conservar historial y resolverla antes de sustituirla.'}
$null=New-Item -ItemType Directory -Path $folder
$target=Join-Path $folder ('evidencia'+$source.Extension)
Copy-Item -LiteralPath $source.FullName -Destination $target
$record=[ordered]@{TenantId=$TenantId.ToString();RunId=$execution.RunId;ControlId=$ControlId;Estado=$Estado;Revisor=$Revisor;Justificacion=$Justificacion;UTC=[datetime]::UtcNow.ToString('o');Archivo=[IO.Path]::GetRelativePath((Get-Item -LiteralPath $RunDirectory).FullName,(Get-Item -LiteralPath $target).FullName);SHA256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash;Origen='Decision humana; no evaluacion automatica'}
$record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $folder 'registro.json') -Encoding utf8BOM
[pscustomobject]@{ControlId=$ControlId;Estado=$Estado;Registro=(Join-Path $folder 'registro.json')}
