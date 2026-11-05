#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version='2.0.3',
    [string]$OutputDirectory=(Join-Path $PSScriptRoot 'dist')
)
$ErrorActionPreference='Stop'
$null=New-Item -ItemType Directory -Path $OutputDirectory -Force
$zipPath=Join-Path (Get-Item -LiteralPath $OutputDirectory).FullName ('copilot-levantamiento-v'+$Version+'.zip')
if (Test-Path -LiteralPath $zipPath) {throw 'El paquete ya existe. Conservarlo o elegir otra carpeta de salida.'}
$stage=Join-Path ([IO.Path]::GetTempPath()) ('copilot-package-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $stage
try {
    # Lista positiva: nunca empaquetar resultados, configuraciones locales, credenciales o .git.
    $files=@(
        'Export-CopilotAssessment.ps1','Analyze-CopilotAssessment.ps1','Recover-CopilotAssessment.ps1','Import-AssessmentEvidence.ps1','Invoke-CopilotAssessment.ps1','Invoke-SharePointWorker.ps1','Test-PowerPlatformApi.ps1','New-AssessmentPackage.ps1','README.md','CHANGELOG.md','.gitignore',
        'lib/Core.ps1','lib/Authentication.ps1','lib/Tokens.ps1','lib/Agents.ps1','lib/Dataverse.ps1','lib/SharePoint.ps1','lib/SharePoint.Process.ps1','lib/OfflinePolicies.ps1',
        'docs/PERMISOS-Y-FUENTES.md','docs/VALIDACION.md','docs/tenant.example.json','tests/Test-Offline.ps1','tests/Test-Recovery.ps1','tests/Test-PowerPlatformProbe.ps1',
        'legacy/v1.1.0/Export-CopilotAssessment.ps1','legacy/v1.1.0/GUIA.txt','legacy/v1.1.0/Test-Offline.ps1'
    )
    foreach ($file in $files) {
        $null=New-Item -ItemType Directory -Path (Split-Path (Join-Path $stage $file)) -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $stage $file)
    }
    # Rechazar salidas o archivos inesperados en carpetas permitidas.
    $unexpected=@(Get-ChildItem -LiteralPath $stage -File -Recurse -Force | Where-Object {$_.Extension -notin @('.ps1','.md','.txt','.json') -and $_.Name -ne '.gitignore'})
    if ($unexpected.Count) {throw 'Hay archivos no previstos en el paquete.'}
    $build=[ordered]@{Version=$Version;BuildUTC=[datetime]::UtcNow.ToString('o');PowerShell=$PSVersionTable.PSVersion.ToString();Alcance='Codigo y pruebas simuladas; sin datos de tenant'}
    $build | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'BUILD.json') -Encoding utf8BOM
    $hashes=@(Get-ChildItem -LiteralPath $stage -File -Recurse -Force | Sort-Object FullName | ForEach-Object {[pscustomobject]@{Archivo=[IO.Path]::GetRelativePath($stage,$_.FullName);SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
    $hashes | Export-Csv -LiteralPath (Join-Path $stage 'PACKAGE-MANIFEST.csv') -NoTypeInformation -Encoding utf8BOM
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$zipPath)
    $hash=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    ($hash+'  '+[IO.Path]::GetFileName($zipPath)) | Set-Content -LiteralPath ($zipPath+'.sha256') -Encoding ascii
    [pscustomobject]@{Paquete=$zipPath;SHA256=$hash;Archivos=$hashes.Count+1}
} finally {if (Test-Path -LiteralPath $stage) {Remove-Item -LiteralPath $stage -Recurse -Force}}
