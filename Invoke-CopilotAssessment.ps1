#Requires -Version 7.4
# Lanzador para automatizacion. El recolector devuelve un objeto y no cierra la consola.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigurationFile)
$ErrorActionPreference='Stop'
try {
    $config=Get-Content -LiteralPath $ConfigurationFile -Raw | ConvertFrom-Json -AsHashtable
    $result=& (Join-Path $PSScriptRoot 'Export-CopilotAssessment.ps1') @config
    $result | Format-List | Out-Host
    exit $result.ExitCode
} catch {
    $failure=$_
    $diagnostic=[ordered]@{UTC=[datetime]::UtcNow.ToString('o');Tipo=$failure.Exception.GetType().FullName;Archivo=$failure.InvocationInfo.ScriptName;Linea=$failure.InvocationInfo.ScriptLineNumber;PowerShell=$PSVersionTable.PSVersion.ToString();Nota='No se guardan mensajes, cuerpos de respuesta, tokens ni lineas de codigo.'}
    try {
        $folder=if ($config -and $config.OutputDirectory) {[string]$config.OutputDirectory} else {Join-Path $PSScriptRoot 'diagnostico-local'}
        $null=New-Item -ItemType Directory -Path $folder -Force
        $path=Join-Path $folder ('fallo-lanzador-'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.json')
        $diagnostic | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8BOM
        Write-Host "Diagnostico local sanitizado: $path"
    } catch {Write-Warning 'No fue posible guardar diagnostico local.'}
    Write-Error ('Fallo del lanzador: '+$failure.Exception.GetType().Name) -ErrorAction Continue
    exit 1
}
