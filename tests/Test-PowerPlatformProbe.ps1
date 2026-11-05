#Requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$output=Join-Path ([IO.Path]::GetTempPath()) ('copilot-probe-test-'+[guid]::NewGuid().ToString('N'))
$global:ProbeTestTenant='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$global:ProbeTestCalls=0;$global:ProbeTestAssertions=0
function Assert($Condition,[string]$Message) {if (-not $Condition) {throw "FALLO: $Message"};$global:ProbeTestAssertions++}
$claims=@{tid=$global:ProbeTestTenant;aud='https://api.powerplatform.com';azp='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';scp='ResourceQuery.Resources.Read';exp=[datetimeoffset]::UtcNow.ToUnixTimeSeconds()+3600} | ConvertTo-Json -Compress
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_')
$global:ProbeTestToken='fake.'+$encoded+'.fake'
function Import-Module {[CmdletBinding()]param($Name) Assert ($Name -eq 'Az.Accounts') 'Solo cargar Az.Accounts'}
function Get-AzContext {[pscustomobject]@{Tenant=@{Id=$global:ProbeTestTenant};Account=@{Type='User'};Environment=@{Name='AzureCloud'}}}
function Get-AzAccessToken {[CmdletBinding()]param($ResourceUrl,$TenantId) Assert ($ResourceUrl -eq 'https://api.powerplatform.com' -and $TenantId -eq $global:ProbeTestTenant) 'Token del destino y tenant esperado';[pscustomobject]@{Token=(ConvertTo-SecureString $global:ProbeTestToken -AsPlainText -Force)}}
function Invoke-WebRequest {
    [CmdletBinding()]param($Uri,$Method,$Headers,[switch]$SkipHttpErrorCheck,$MaximumRedirection,$TimeoutSec,$ContentType,$Body)
    $global:ProbeTestCalls++
    Assert ($Uri -like 'https://api.powerplatform.com/*' -and $MaximumRedirection -eq 0 -and $SkipHttpErrorCheck) 'Destino fijo, sin redireccion ni ocultar errores HTTP'
    if ($global:ProbeTestCalls -eq 1) {
        Assert ($Method -eq 'POST') 'Consulta de inventario usa POST documentado'
        $errorBody=@{type='https://example.invalid/problem';title='One or more validation errors occurred.';status=400;errors=@{'$.Clauses[1]'=@('Unsupported query clause. Bearer '+$global:ProbeTestToken)}} | ConvertTo-Json -Depth 10
        return [pscustomobject]@{StatusCode=400;Headers=@{'Content-Type'='application/problem+json'};Content=[Text.Encoding]::UTF8.GetBytes($errorBody)}
    }
    if ($global:ProbeTestCalls -eq 2) {
        $query=$Body | ConvertFrom-Json
        Assert ($Method -eq 'POST' -and $query.Clauses[0].'$type' -eq 'take') 'Segunda consulta minima distinta'
        return [pscustomobject]@{StatusCode=200;Headers=@{'Content-Type'='application/json'};Content='{"count":1,"data":[{"name":"DO-NOT-EXPORT-INVENTORY"}]}'}
    }
    Assert ($Method -eq 'GET' -and $Uri -like '*/licensing/entitlements/MCSMessages?*') 'Ultima operacion solo GET de capacidad'
    [pscustomobject]@{StatusCode=404;Headers=@{'Content-Type'='application/json'};Content='{"error":{"code":"ResourceNotFound","message":"Entitlement not found"}}'}
}
$result=& (Join-Path $root 'Test-PowerPlatformApi.ps1') -TenantId $global:ProbeTestTenant -OutputDirectory $output -NoInteractive
$text=Get-Content -LiteralPath $result.Archivo -Raw
$report=$text | ConvertFrom-Json
Assert ($global:ProbeTestCalls -eq 3) 'Solo tres consultas'
Assert ($report.Resultados[0].HTTP -eq 400 -and $report.Resultados[0].ErroresValidacion.Count -eq 1) 'Leer validation problem details y respuesta byte[]'
Assert ($text -notmatch [regex]::Escape($global:ProbeTestToken)) 'Token exacto redactado'
Assert ($text -notmatch 'DO-NOT-EXPORT-INVENTORY') 'No exportar recursos de respuesta correcta'
Assert ($report.Resultados[1].HTTP -eq 200 -and $report.Resultados[1].RegistrosDevueltos -eq 1) 'Inventario minimo distingue validez de consulta'
Assert ($report.Resultados[2].HTTP -eq 404 -and $report.Resultados[2].CodigoServicio -eq 'ResourceNotFound') 'Conservar error estructurado de capacidad sin inferir saldo'
Write-Host "OK: $global:ProbeTestAssertions aserciones; tres solicitudes simuladas; sin red."
[pscustomobject]@{Estado='OK';Aserciones=$global:ProbeTestAssertions}
