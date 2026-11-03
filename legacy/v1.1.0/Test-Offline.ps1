#Requires -Version 5.1
# Prueba sin conexiones reales: todas las llamadas externas estan simuladas.
[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'pruebas-locales'))
$ErrorActionPreference = 'Stop'
$tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$envId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
$groupId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
$global:CopilotOfflineScenario = 'normal'
$global:CopilotOfflineAuth = 'existing'
$global:CopilotOfflineGraphLogins = 0
$global:CopilotOfflineAzureLogins = 0
$global:CopilotOfflineCalls = New-Object 'System.Collections.Generic.List[string]'
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FALLO: $Message" } }
function Import-Module { [CmdletBinding()]param([Parameter(Position=0)][string]$Name) }
function Get-MgContext {
    if ($global:CopilotOfflineAuth -eq 'fresh' -and $global:CopilotOfflineGraphLogins -eq 0) { return $null }
    [pscustomobject]@{ TenantId=$tenant; Environment='Global';ClientId='dddddddd-dddd-dddd-dddd-dddddddddddd' }
}
function Get-AzContext {
    if ($global:CopilotOfflineAuth -eq 'fresh' -and $global:CopilotOfflineAzureLogins -eq 0) { return $null }
    $activeTenant = $tenant
    if ($global:CopilotOfflineAuth -eq 'conflict') { $activeTenant = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' }
    [pscustomobject]@{ Tenant=@{Id=$activeTenant};Account=@{Type='User'};Environment=@{Name='AzureCloud'} }
}
function Connect-MgGraph { [CmdletBinding()]param($TenantId,$ClientId,$Scopes,$ContextScope,[switch]$NoWelcome)
    Assert ($ContextScope -eq 'Process') 'Graph login limitado al proceso'
    Assert (-not @($Scopes | Where-Object { $_ -match 'Write' }).Count) 'No pedir scopes Write'
    Assert (-not $ClientId) 'Modo automatico sin GraphClientId manual'
    $global:CopilotOfflineGraphLogins++
}
function Connect-AzAccount { [CmdletBinding()]param($Tenant,$Scope,[switch]$SkipContextPopulation)
    Assert ($Tenant -eq $tenant) 'Azure login debe fijar tenant ya detectado'
    Assert ($Scope -eq 'Process' -and $SkipContextPopulation) 'No poblar contextos globales'
    $global:CopilotOfflineAzureLogins++
}
function Get-AzAccessToken { [CmdletBinding()]param($ResourceUrl,$TenantId)
    Assert ($ResourceUrl -eq 'https://api.powerplatform.com') 'Audiencia PP'
    Assert ($TenantId -eq $tenant) 'Token del tenant detectado'
    [pscustomobject]@{Token=$fakeToken}
}
function Add-PowerAppsAccount { [CmdletBinding()]param([string]$TenantID) Assert ($TenantID -eq $tenant) 'PowerApps debe usar el tenant solicitado' }
function Get-AdminPowerAppEnvironment { [CmdletBinding()]param()
    [pscustomobject]@{EnvironmentName=$envId;Internal=@{properties=@{linkedEnvironmentMetadata=@{instanceUrl='https://example.crm.dynamics.com';securityGroupId=$groupId}}}}
}
function Get-AdminDlpPolicy { [CmdletBinding()]param() [pscustomobject]@{PolicyName='DLP de ejemplo';environments=@($envId)} }
function Get-TenantSettings { [CmdletBinding()]param() [pscustomobject]@{Ejemplo=$true} }
function Get-AdminPowerAppEnvironmentRoleAssignment { [CmdletBinding()]param([string]$EnvironmentName) throw 'No debe consultarse RBAC sin Dataverse para este entorno.' }
function Invoke-MgGraphRequest { [CmdletBinding()]param($Method,$Uri,$OutputType)
    Assert ($Method -eq 'GET') 'Graph solo GET'
    $global:CopilotOfflineCalls.Add("Graph $Method $Uri")
    if ($Uri -match '/subscribedSkus') {
        if ($Uri -match 'skiptoken') { return [pscustomobject]@{value=@();'@odata.nextLink'=$null} }
        return [pscustomobject]@{value=@([pscustomobject]@{skuId='sku1';skuPartNumber='TEST_COPILOT';capabilityStatus='Enabled';prepaidUnits=@{enabled=10;suspended=0;warning=0};consumedUnits=4;servicePlans=@(@{servicePlanName='COPILOT'})});'@odata.nextLink'='https://graph.microsoft.com/v1.0/subscribedSkus?$skiptoken=page2'}
    }
    if ($Uri -match '/groups/.+\?') { return [pscustomobject]@{id=$groupId;displayName='Grupo de ejemplo';securityEnabled=$true} }
    return [pscustomobject]@{value=@();'@odata.nextLink'=$null}
}
function Invoke-RestMethod { [CmdletBinding()]param($Uri,$Method,$Headers,$Body,$ContentType,$TimeoutSec,$MaximumRedirection)
    $global:CopilotOfflineCalls.Add("PP $Method $Uri")
    Assert ($Headers.Authorization -like 'Bearer *') 'Debe enviar token en encabezado'
    Assert ($MaximumRedirection -eq 0) 'No seguir redirects Power Platform'
    if ($Uri -match '/resourcequery/resources/query\?') {
        Assert ($Method -eq 'POST') 'Solo POST para consulta de inventario'
        $b = $Body | ConvertFrom-Json
        $type = $b.Clauses[0].Values[0]
        if ($type -eq "'microsoft.copilotstudio/agents'") {
            if ($global:CopilotOfflineScenario -eq 'partial' -and $b.Options.SkipToken) { throw 'Falla simulada de segunda pagina.' }
            if ($b.Options.SkipToken) { return [pscustomobject]@{data=@();skipToken='';resultTruncated=0} }
            $agent = [pscustomobject]@{name='agent-1';properties=@{displayName='=1+1';environmentId=$envId;ownerId=$null;createdBy='creator';authentication='None';channels=@('Teams');sharedWithViewers=@{entireTenant=$true};powerPlatformConnectors=@(@{connectorId='shared_sharepointonline'})}}
            return [pscustomobject]@{data=@($agent);skipToken='page2';resultTruncated=1}
        }
        if ($type -eq "'microsoft.powerplatform/environments'") { return [pscustomobject]@{data=@([pscustomobject]@{name=$envId;properties=@{displayName='Produccion';securityGroupId=$groupId}});skipToken='';resultTruncated=0} }
        return [pscustomobject]@{data=@();skipToken='';resultTruncated=0}
    }
    Assert ($Method -eq 'GET') 'Todas las otras rutas PP usan GET'
    if ($Uri -match '/billingPolicies') { return [pscustomobject]@{value=@()} }
    if ($Uri -match '/entitlements/MCSMessages/resources') {
        if ($Uri -match 'continuationToken') { return [pscustomobject]@{value=@();continuationtoken=$null} }
        return [pscustomobject]@{value=@(@{environmentId=$envId;resourceId='agent-1';consumed=12});continuationtoken='next-test'}
    }
    if ($Uri -match '/entitlements/MCSMessages\?') { return [pscustomobject]@{entitlementId='MCSMessages';entitlement=@{capacity=@{entitled=@{value=25000};consumed=@{value=10;lastUpdatedOn='2026-11-01'};availableQuantity=24990}}} }
    if ($Uri -match '/allocationsV2/availability') { return [pscustomobject]@{entitlementAllocationsAvailable=@(@{entitlementId='MCSMessages';availableQuantity=20000})} }
    throw 'Ruta simulada no implementada; se bloquea antes de cualquier conexion.'
}
$claims = @{tid=$tenant;aud='https://api.powerplatform.com';azp='ffffffff-ffff-ffff-ffff-ffffffffffff';scp='ResourceQuery.Resources.Read';exp=([datetimeoffset]::UtcNow.ToUnixTimeSeconds()+3600)} | ConvertTo-Json -Compress
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_')
$fakeToken = ConvertTo-SecureString "fake.$encoded.fake" -AsPlainText -Force
$target = Join-Path $PSScriptRoot 'Export-CopilotAssessment.ps1'
$result = & $target -TenantId $tenant -PowerPlatformAccessToken $fakeToken -IncludeGroupMembers -IncludeLicensedUsers -IncludeLegacyConsumption -OutputDirectory $OutputDirectory
$coverage = Import-Csv (Join-Path $result.Carpeta 'cobertura.csv')
Assert ($result.AgentesObtenidos -eq 1) 'Debe devolver exactamente un agente'
Assert (@($coverage | Where-Object Estado -eq 'No obtenido').Count -eq 0) 'No debe haber fuentes fallidas en escenario normal'
Assert (($coverage | Where-Object Fuente -eq 'GruposEntornos').Registros -eq 0) 'Inventario vacio no es un error'
Assert (($coverage | Where-Object Fuente -eq 'PlanesFacturacion').Registros -eq 0) 'Coleccion OData vacia no debe convertirse en un recurso'
Assert (($coverage | Where-Object Fuente -eq 'LicenciasSKU').Registros -eq 1) 'Graph debe paginar y no contar pagina vacia'
Assert (($coverage | Where-Object Fuente -eq 'ConsumoLegacy').Registros -eq 1) 'Consumo debe seguir continuationtoken'
$csv = Import-Csv (Join-Path $result.Carpeta 'agentes.csv')
Assert ($csv.Nombre -eq "'=1+1") 'CSV debe neutralizar formulas'
Assert ($csv.PropietarioId -eq '' -and $csv.CreadorId -eq 'creator') 'No reemplazar propietario por creador'
Assert ((Import-Csv (Join-Path $result.Carpeta 'licencias.csv')).SinAsignar -eq '6') 'Licencias sin asignar'
Assert (Test-Path (Join-Path $result.Carpeta 'informe.html')) 'Debe generar informe'
$manifest = Import-Csv (Join-Path $result.Carpeta 'manifiesto-sha256.csv')
foreach ($row in $manifest) { Assert ((Get-FileHash (Join-Path $result.Carpeta $row.Archivo)).Hash -eq $row.SHA256) 'Integridad del manifiesto' }

$global:CopilotOfflineScenario = 'partial'
$partial = & $target -TenantId $tenant -PowerPlatformAccessToken $fakeToken -SkipPowerApps -SkipGraph -OutputDirectory $OutputDirectory
$pc = Import-Csv (Join-Path $partial.Carpeta 'cobertura.csv')
Assert (($pc | Where-Object Fuente -eq 'Agentes').Estado -eq 'No obtenido') 'Falla de segunda pagina debe marcar fuente incompleta'
Assert ($partial.AgentesObtenidos -eq 0) 'No publicar inventario parcial como completo'
Assert (-not (Test-Path (Join-Path $partial.Carpeta 'agentes.csv'))) 'No generar CSV aparentemente completo de una consulta fallida'
Assert (@(Get-ChildItem (Join-Path $partial.Carpeta 'evidencias') -Filter 'inventario-agents-*.json').Count -eq 1) 'Conservar evidencia parcial'

$global:CopilotOfflineScenario = 'normal'
$auto = & $target -OutputDirectory $OutputDirectory
$autoAuth = Get-Content (Join-Path $auto.Carpeta 'evidencias\autenticacion.json') -Raw | ConvertFrom-Json
Assert ($auto.AgentesObtenidos -eq 1 -and $autoAuth.TenantId -eq $tenant) 'Detectar tenant desde sesiones existentes sin parametros'
Assert ($autoAuth.GraphClientId -eq 'dddddddd-dddd-dddd-dddd-dddddddddddd') 'Obtener GraphClientId de la sesion'
Assert ($autoAuth.PowerPlatformClientId -eq 'ffffffff-ffff-ffff-ffff-ffffffffffff') 'Obtener PP ClientId informativo del token'
Assert ($global:CopilotOfflineGraphLogins -eq 0 -and $global:CopilotOfflineAzureLogins -eq 0) 'Reutilizar sesiones sin login adicional'

$global:CopilotOfflineAuth = 'fresh'
$fresh = & $target -OutputDirectory $OutputDirectory
Assert ($fresh.AgentesObtenidos -eq 1) 'Modo automatico desde login sin GUID'
Assert ($global:CopilotOfflineGraphLogins -eq 1 -and $global:CopilotOfflineAzureLogins -eq 1) 'Autenticaciones simuladas fijan tenant y no requieren ClientId'

$global:CopilotOfflineAuth = 'conflict'
$beforeCalls=$global:CopilotOfflineCalls.Count
$blocked=$false
try { $null = & $target -OutputDirectory $OutputDirectory } catch { $blocked=$_.Exception.Message -like '*tenants distintos*' }
Assert $blocked 'Sesiones de tenants distintos requieren seleccion explicita'
Assert ($global:CopilotOfflineCalls.Count -eq $beforeCalls) 'No consultar recursos cuando hay conflicto de tenant'

$global:CopilotOfflineAuth = 'fresh'
$global:CopilotOfflineGraphLogins = 0; $global:CopilotOfflineAzureLogins = 0
$blocked=$false
try { $null = & $target -NoInteractive -OutputDirectory $OutputDirectory } catch { $blocked=$_.Exception.Message -like '*detectar el tenant*' }
Assert $blocked 'NoInteractive sin contexto debe detenerse'
Assert ($global:CopilotOfflineGraphLogins -eq 0 -and $global:CopilotOfflineAzureLogins -eq 0) 'NoInteractive no abre logins'

$byToken = & $target -PowerPlatformAccessToken $fakeToken -NoInteractive -SkipGraph -SkipPowerApps -OutputDirectory $OutputDirectory
$tokenAuth = Get-Content (Join-Path $byToken.Carpeta 'evidencias\autenticacion.json') -Raw | ConvertFrom-Json
Assert ($byToken.AgentesObtenidos -eq 1 -and $tokenAuth.TenantId -eq $tenant) 'Detectar tenant desde token sin Graph/Azure'
$beforeCalls=$global:CopilotOfflineCalls.Count; $blocked=$false
try { $null = & $target -TenantId 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' -PowerPlatformAccessToken $fakeToken -SkipGraph -SkipPowerApps -OutputDirectory $OutputDirectory } catch { $blocked=$_.Exception.Message -like '*token Power Platform proporcionado*' }
Assert $blocked 'Rechazar token de otro tenant'
Assert ($global:CopilotOfflineCalls.Count -eq $beforeCalls) 'No consultar recursos con token de otro tenant'

# Cargar solo las funciones de proteccion desde AST, sin ejecutar otra recoleccion.
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($target,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Analisis sintactico'
$guard = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-ReadRequest'},$true)
Invoke-Expression $guard.Extent.Text
foreach ($test in @(
    @('Graph','POST','https://graph.microsoft.com/v1.0/users'),
    @('Graph','GET','https://evil.example/v1.0/users'),
    @('PowerPlatform','PUT','https://api.powerplatform.com/licensing/allocationsV2'),
    @('PowerPlatform','POST','https://api.powerplatform.com/licensing/billingPolicies'),
    @('PowerPlatform','GET','http://api.powerplatform.com/licensing/billingPolicies')
)) {
    $blocked=$false
    try { Assert-ReadRequest $test[0] $test[1] $test[2] } catch { $blocked=$true }
    Assert $blocked ('Debe bloquear: ' + ($test -join ' '))
}
Write-Host 'OK: autenticacion automatica, conflicto de tenants, NoInteractive, paginacion, vacios, falla parcial, proteccion de lectura, CSV, propietarios y hashes. Sin conexiones reales.'
[pscustomobject]@{Estado='OK';LlamadasSimuladas=$global:CopilotOfflineCalls.Count;ResultadoNormal=$result.Carpeta;ResultadoParcial=$partial.Carpeta}
