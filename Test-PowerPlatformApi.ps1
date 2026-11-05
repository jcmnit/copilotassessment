#Requires -Version 7.4
<#
.SYNOPSIS
Diagnostico acotado de lectura: inventario y GET de MCSMessages; cinco pruebas con IncludeClauseTests.
.DESCRIPTION
Solo Az.Accounts. No carga Graph/PnP, no modifica recursos ni permisos y no exporta
tokens, cabeceras Authorization, respuestas completas o datos de inventario.
Conserva mensajes de error saneados y errores de validacion para diagnosticar 400.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$OutputDirectory=(Join-Path (Get-Location) 'Diagnostico-PowerPlatform'),
    [switch]$NoInteractive,
    [switch]$IncludeClauseTests
)
$ErrorActionPreference='Stop'
if ($TenantId -eq [guid]::Empty) {throw 'TenantId vacio.'}
function Read-ProbeClaims([string]$Token) {
    $parts=$Token.Split('.')
    if ($parts.Count -lt 2) {throw 'Formato de token no compatible.'}
    $payload=$parts[1].Replace('-','+').Replace('_','/')
    $payload=$payload.PadRight($payload.Length+((4-$payload.Length%4)%4),'=')
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}
function Protect-ProbeText($Value,[string]$Token) {
    if ($Value -isnot [string]) {return $null}
    $safe=$Value.Replace($Token,'[TOKEN REDACTADO]')
    $safe=$safe -replace '(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*','Bearer [REDACTADO]'
    $safe=$safe -replace '\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+','[JWT REDACTADO]'
    $safe=$safe -replace '(?i)((?:access_token|refresh_token|client_secret|authorization)["'']?\s*[:=]\s*["'']?)[^\s"'',;}&]+','$1[REDACTADO]'
    if ($safe.Length -gt 1600) {$safe=$safe.Substring(0,1600)+' [TRUNCADO]'}
    return $safe
}
Import-Module Az.Accounts -ErrorAction Stop
$ctx=Get-AzContext
if (-not $ctx -or [string]$ctx.Tenant.Id -ne $TenantId.ToString() -or $ctx.Account.Type -ne 'User' -or $ctx.Environment.Name -ne 'AzureCloud') {
    if ($NoInteractive) {throw 'Se requiere una sesion Azure de usuario del tenant indicado.'}
    $null=Connect-AzAccount -Tenant $TenantId.ToString() -Scope Process -SkipContextPopulation -ErrorAction Stop
    $ctx=Get-AzContext
}
if ([string]$ctx.Tenant.Id -ne $TenantId.ToString() -or $ctx.Account.Type -ne 'User' -or $ctx.Environment.Name -ne 'AzureCloud') {throw 'Sesion Azure incompatible; no se consultaron recursos.'}
$token=$null
try {
    $access=Get-AzAccessToken -ResourceUrl 'https://api.powerplatform.com' -TenantId $TenantId.ToString() -ErrorAction Stop
    if ($access.Token -is [Security.SecureString]) {
        $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($access.Token)
        try {$token=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)} finally {[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
    } else {$token=[string]$access.Token}
    $access=$null
    $claims=Read-ProbeClaims $token
    if ([string]$claims.tid -ne $TenantId.ToString() -or -not $claims.scp -or $claims.aud -notin @('https://api.powerplatform.com','https://api.powerplatform.com/','8578e004-a5c6-46e7-913e-12f58912df43') -or [double]$claims.exp -le [datetimeoffset]::UtcNow.ToUnixTimeSeconds()) {throw 'Token delegado incompatible; no se consultaron recursos.'}
    $directory=Join-Path $OutputDirectory ([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $null=New-Item -ItemType Directory -Path $directory
    $directory=(Get-Item -LiteralPath $directory).FullName
    $where=[ordered]@{'$type'='where';FieldName='type';Operator='in~';Values=@("'microsoft.copilotstudio/agents'")}
    $sort=[ordered]@{'$type'='orderby';FieldNamesAscDesc=[ordered]@{name='asc'}}
    $current=[ordered]@{TableName='PowerPlatformResources';Clauses=@($where,$sort);Options=@{Top=1}}
    $minimal=[ordered]@{TableName='PowerPlatformResources';Clauses=@([ordered]@{'$type'='take';TakeCount=1});Options=@{Top=1}}
    $operations=@(
        @{Name='InventarioFormatoOrdenado';Method='POST';Path='/resourcequery/resources/query';Body=$current},
        @{Name='InventarioConsultaMinima';Method='POST';Path='/resourcequery/resources/query';Body=$minimal},
        @{Name='EntitlementMCSMessages';Method='GET';Path='/licensing/entitlements/MCSMessages';Body=$null}
    )
    if ($IncludeClauseTests) {
        $operations=@($operations[0],
            @{Name='InventarioSoloWhere';Method='POST';Path='/resourcequery/resources/query';Body=[ordered]@{TableName='PowerPlatformResources';Clauses=@($where);Options=@{Top=1}}},
            @{Name='InventarioSoloOrderBy';Method='POST';Path='/resourcequery/resources/query';Body=[ordered]@{TableName='PowerPlatformResources';Clauses=@($sort);Options=@{Top=1}}},
            $operations[1],$operations[2])
    }
    $results=[Collections.Generic.List[object]]::new()
    $file=Join-Path $directory 'diagnostico-api.json'
    $report=[ordered]@{Version='1.1';TenantId=$TenantId.ToString();UTC=[datetime]::UtcNow.ToString('o');ClientId=$(if ($claims.azp) {$claims.azp} else {$claims.appid});ScopesDeclarados=[string]$claims.scp;PowerShell=$PSVersionTable.PSVersion.ToString();DiscriminadorPrimero=$true;Nota='Consultas de lectura, con $type primero en cada clausula. Los scopes declarados no acreditan autorizacion efectiva. No contiene tokens, respuestas completas ni datos de inventario.';Resultados=@()}
    foreach ($op in $operations) {
        Write-Host ('Probando '+$op.Name+' ...')
        $requestId=[guid]::NewGuid().ToString()
        $argsWeb=@{Uri=('https://api.powerplatform.com'+$op.Path+'?api-version=2024-10-01');Method=$op.Method;Headers=@{Authorization="Bearer $token";'x-ms-client-request-id'=$requestId};SkipHttpErrorCheck=$true;MaximumRedirection=0;TimeoutSec=90;ErrorAction='Stop'}
        if ($op.Method -eq 'POST') {$argsWeb.ContentType='application/json; charset=utf-8';$argsWeb.Body=ConvertTo-Json -InputObject $op.Body -Depth 20 -Compress}
        $result=[ordered]@{Prueba=$op.Name;Metodo=$op.Method;Ruta=$op.Path;Consulta=$op.Body;SolicitudId=$requestId;HTTP=$null;TipoContenido=$null;CodigoServicio=$null;Titulo=$null;MensajeServicio=$null;ErroresValidacion=@();CamposRespuesta=@();RegistrosDevueltos=$null;TipoExcepcion=$null}
        try {
            $response=Invoke-WebRequest @argsWeb
            $result.HTTP=[int]$response.StatusCode
            $result.TipoContenido=[string]($response.Headers['Content-Type'] -join ';')
            $body=if ($response.Content -is [byte[]]) {[Text.Encoding]::UTF8.GetString($response.Content)} else {[string]$response.Content}
            $obj=$null
            if ($body.Length -le 65536 -and $body.TrimStart().StartsWith('{')) {try {$obj=ConvertFrom-Json -InputObject $body -ErrorAction Stop} catch {}}
            if ($result.HTTP -ge 200 -and $result.HTTP -lt 300) {
                if ($obj -and $null -ne $obj.count) {$result.RegistrosDevueltos=$obj.count}
                # No guardar datos de recursos, aunque el inventario de una fila responda correctamente.
            } elseif ($obj) {
                $result.CamposRespuesta=@($obj.PSObject.Properties.Name | ForEach-Object {Protect-ProbeText $_ $token})
                $result.CodigoServicio=Protect-ProbeText $(if ($obj.error.code) {$obj.error.code} else {$obj.code}) $token
                $result.Titulo=Protect-ProbeText $obj.title $token
                $message=if ($obj.error.message) {$obj.error.message} elseif ($obj.message) {$obj.message} elseif ($obj.detail) {$obj.detail} else {$obj.error_description}
                $result.MensajeServicio=Protect-ProbeText $message $token
                $validation=[Collections.Generic.List[object]]::new()
                if ($obj.errors -is [array]) {
                    foreach ($entry in $obj.errors | Select-Object -First 10) {$validation.Add([pscustomobject]@{Campo='errors';Codigo=(Protect-ProbeText $entry.code $token);Mensaje=(Protect-ProbeText $entry.message $token)})}
                } elseif ($obj.errors) {
                    foreach ($property in $obj.errors.PSObject.Properties | Select-Object -First 10) {foreach ($value in @($property.Value) | Select-Object -First 3) {$validation.Add([pscustomobject]@{Campo=(Protect-ProbeText $property.Name $token);Codigo=$null;Mensaje=(Protect-ProbeText $value $token)})}}
                }
                $result.ErroresValidacion=$validation.ToArray()
            } elseif ($body -and -not $body.TrimStart().StartsWith('<') -and $body.Length -le 65536) {
                $result.MensajeServicio=Protect-ProbeText $body $token
            }
        } catch {$result.TipoExcepcion=$_.Exception.GetType().FullName}
        finally {$argsWeb=$null;$response=$null;$body=$null;$obj=$null}
        $results.Add([pscustomobject]$result)
        $report.Resultados=$results.ToArray()
        $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file -Encoding utf8BOM
    }
    Write-Host "Diagnostico guardado en: $file"
    $results.ToArray() | Select-Object Prueba,HTTP,CodigoServicio,Titulo,TipoExcepcion | Format-Table -AutoSize | Out-Host
    [pscustomobject]@{Archivo=$file;Consultas=$results.Count;Nota='Compartir este JSON saneado; no compartir tokens ni respuestas completas.'}
} finally {$token=$null;$access=$null;$claims=$null}
