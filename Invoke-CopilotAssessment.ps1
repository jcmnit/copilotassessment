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
} catch {Write-Error ('Fallo del lanzador: '+$_.Exception.GetType().Name);exit 1}
