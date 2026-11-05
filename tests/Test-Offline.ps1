#Requires -Version 7.4
[CmdletBinding()]
param([string]$OutputDirectory=(Join-Path ([IO.Path]::GetTempPath()) ('copilot-tests-'+[guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$target=Join-Path $root 'Export-CopilotAssessment.ps1'
$global:CopilotTestassertions=0;$global:CopilotTestcalls=0
function Assert($Condition,[string]$Message) {if (-not $Condition) {throw "FALLO: $Message"};$global:CopilotTestassertions++}
$global:CopilotTesttenant='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$global:CopilotTestenvId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
$global:CopilotTestscenario='normal'
$global:CopilotTestgraphTenant=$global:CopilotTesttenant
$global:CopilotTestppTokenTenant=$global:CopilotTesttenant
$global:CopilotTestspoTenant=$global:CopilotTesttenant
$global:CopilotTestgroup='cccccccc-cccc-cccc-cccc-cccccccccccc'
function New-FakeToken([string]$Tid,[string]$Audience='https://api.powerplatform.com',[long]$Expires=([datetimeoffset]::UtcNow.ToUnixTimeSeconds()+3600)) {
    $claims=@{tid=$Tid;aud=$Audience;scp='ResourceQuery.Resources.Read';exp=$Expires;azp='dddddddd-dddd-dddd-dddd-dddddddddddd'} | ConvertTo-Json -Compress
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_')
    return "fake.$payload.fake"
}
function Import-Module { [CmdletBinding()]param([Parameter(Position=0)]$Name) }
function Get-MgContext {[pscustomobject]@{TenantId=$global:CopilotTestgraphTenant;Environment='Global';ClientId='dddddddd-dddd-dddd-dddd-dddddddddddd';AuthType='Delegated';Scopes=@('Reports.Read.All')}}
function Connect-MgGraph {[CmdletBinding()]param($TenantId,$ClientId,$Scopes,$ContextScope,[switch]$NoWelcome) $global:CopilotTestgraphTenant=$TenantId}
function Set-MgRequestContext {[CmdletBinding()]param($ClientTimeout)}
function Get-AzContext {[pscustomobject]@{Tenant=@{Id=$global:CopilotTesttenant};Account=@{Type='User'};Environment=@{Name='AzureCloud'}}}
function Get-AzAccessToken {[CmdletBinding()]param($ResourceUrl,$TenantId) [pscustomobject]@{Token=(New-FakeToken $global:CopilotTesttenant $ResourceUrl)}}
function Add-PowerAppsAccount {[CmdletBinding()]param($TenantID)}
function Get-AdminPowerAppEnvironment {[CmdletBinding()]param([switch]$Default)
    if ($Default) {
        $id=$global:CopilotTesttenant
        if ($global:CopilotTestscenario -eq 'powerapps-cross') {$id='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'}
        return [pscustomobject]@{EnvironmentName=('Default-'+$id)}
    }
    [pscustomobject]@{EnvironmentName=$global:CopilotTestenvId;Internal=@{properties=@{linkedEnvironmentMetadata=@{instanceUrl='https://example.crm.dynamics.com';securityGroupId=$global:CopilotTestgroup}}}}
}
function Get-AdminDlpPolicy {[CmdletBinding()]param() [pscustomobject]@{PolicyName='DLP';Environments=@($global:CopilotTestenvId)}}
function Get-TenantSettings {[CmdletBinding()]param() [pscustomobject]@{Example=$true}}
function Get-AdminPowerAppEnvironmentRoleAssignment {[CmdletBinding()]param($EnvironmentName) throw 'No consultar roles sin Dataverse para este entorno.'}
function Invoke-MgGraphRequest {
    [CmdletBinding()]param($Method,$Uri,$OutputType,$OutputFilePath)
    $global:CopilotTestcalls++
    Assert ($Method -eq 'GET') 'Graph solo GET'
    if ($Uri -like '*copilot/reports/*') {
        Assert ($Uri -like "*period='D28',version='v2'*") 'Periodo y version explicitos'
        if ($global:CopilotTestscenario -eq 'report-malformed') {[IO.File]::WriteAllText($OutputFilePath,'<html>not a report</html>');return}
        if ($Uri -like '*UsageUserDetail*') {$csv="Report Refresh Date,Report Period,User Principal Name,Last Activity Date`n2026-11-01,28,user@example.com,2026-10-31"}
        elseif ($Uri -like '*UserCountTrend*') {$csv="Report Refresh Date,Report Period,Report Date,Any App Enabled Users,Any App Active Users`n2026-11-01,28,2026-10-31,10,4"}
        else {$csv="Report Refresh Date,Report Period,Any App Enabled Users,Any App Active Users`n2026-11-01,28,10,4"}
        if ($global:CopilotTestscenario -eq 'report-period') {$csv=$csv.Replace(',28,',',30,')}
        if ($global:CopilotTestscenario -eq 'report-empty') {$csv=($csv -split "`n")[0]}
        [IO.File]::WriteAllText($OutputFilePath,$csv);return
    }
    if ($Uri -like '*/organization*') {return @{value=@(@{id=$global:CopilotTesttenant;displayName='Test tenant';verifiedDomains=@()})}}
    if ($Uri -like '*/admin/reportSettings*') {return @{displayConcealedNames=$true}}
    if ($Uri -like '*/subscribedSkus*') {
        if ($global:CopilotTestscenario -eq 'forbidden') {$ex=[Exception]::new('SECRET-ERROR-BODY');$ex | Add-Member NoteProperty ResponseStatusCode 403;throw $ex}
        if ($global:CopilotTestscenario -eq 'graph-malformed') {return @{unexpected='schema-drift'}}
        return @{value=@(@{skuId='sku1';skuPartNumber='COPILOT';capabilityStatus='Enabled';prepaidUnits=@{enabled=10;suspended=0;warning=0};consumedUnits=4;servicePlans=@(@{servicePlanName='COPILOT'})})}
    }
    if ($Uri -match '/users/[0-9a-f-]{36}') {return @{id='11111111-1111-1111-1111-111111111111';displayName='Owner';accountEnabled=$true}}
    if ($Uri -match '/groups/[0-9a-f-]{36}\?') {return @{id=$global:CopilotTestgroup;displayName='Group';securityEnabled=$true}}
    return @{value=@()}
}
function Invoke-RestMethod {
    [CmdletBinding()]param($Uri,$Method,$Headers,$Body,$ContentType,$TimeoutSec,$MaximumRedirection)
    $global:CopilotTestcalls++
    Assert ($MaximumRedirection -eq 0) 'No redireccionar token Power Platform'
    if ($Uri -like '*/api/data/v9.2/*') {
        Assert ($Method -eq 'GET') 'Dataverse solo GET'
        if ($Uri -like '*/WhoAmI') {return @{UserId='11111111-1111-1111-1111-111111111111';OrganizationId=$global:CopilotTestenvId}}
        if ($Uri -match '/systemusers\?') {return @{value=@(@{systemuserid='11111111-1111-1111-1111-111111111111';fullname='User'})}}
        if ($Uri -match '/teams\?') {return @{value=@(@{teamid='22222222-2222-2222-2222-222222222222';name='Team'})}}
        if ($Uri -match 'roles|roles_association') {return @{value=@(@{roleid='33333333-3333-3333-3333-333333333333';name='Reader'})}}
        return @{value=@()}
    }
    if ($Uri -like '*/resourcequery/resources/query*') {
        Assert ($Method -eq 'POST') 'POST solo consulta de inventario'
        $bodyObject=$Body | ConvertFrom-Json
        $type=$bodyObject.Clauses[0].Values[0]
        if ($type -like '*copilotstudio/agents*') {
            if ($global:CopilotTestscenario -eq 'inventory-null') {return @{data=$null;count=3;resultTruncated=0}}
            if ($bodyObject.Options.SkipToken) {
                if ($global:CopilotTestscenario -eq 'partial') {throw 'Segunda pagina fallida'}
                return @{data=@();count=0;skipToken='';resultTruncated=0}
            }
            return @{data=@(@{name='agent-1';tenantId=$global:CopilotTesttenant;properties=@{displayName='=1+1';environmentId=$global:CopilotTestenvId;ownerId=$null;createdBy='11111111-1111-1111-1111-111111111111';authentication='None';sharedWithViewers=@{entireTenant=$true}}});count=1;skipToken='next';resultTruncated=1}
        }
        if ($type -like '*powerplatform/environments*') {return @{data=@(@{name=$global:CopilotTestenvId;properties=@{displayName='Production';securityGroupId=$global:CopilotTestgroup}});count=1;resultTruncated=0}}
        return @{data=@();count=0;resultTruncated=0}
    }
    Assert ($Method -eq 'GET') 'Resto Power Platform solo GET'
    if ($Uri -like '*/billingPolicies*') {return @{value=@()}}
    if ($Uri -like '*/allocationsV2/availability*') {return @{entitlementAllocationsAvailable=@(@{entitlementId='MCSMessages';availableQuantity=20000})}}
    if ($Uri -like '*/entitlements/MCSMessages?*') {return @{entitlementId='MCSMessages';entitlement=@{capacity=@{entitled=@{value=25000};consumed=@{value=10}}}}}
    throw 'Ruta PP no simulada.'
}
# Mock de CSOM y PnP. No se cargan ensamblados ni modulos Microsoft reales.
if (-not ('Microsoft.SharePoint.Client.PermissionKind' -as [type])) {Add-Type 'namespace Microsoft.SharePoint.Client { public enum PermissionKind { ViewListItems } }'}
function New-RoleAssignments {
    $base=[pscustomobject]@{}
    $base | Add-Member ScriptMethod Has {param($kind) return $true}
    @([pscustomobject]@{Member=[pscustomobject]@{Id=7;LoginName='Site Members';PrincipalType='SharePointGroup'};RoleDefinitionBindings=@([pscustomobject]@{Name='Read';RoleTypeKind='Reader';BasePermissions=$base})})
}
function Connect-PnPOnline {[CmdletBinding()]param($Url,$Tenant,$ClientId,[switch]$ReturnConnection,[switch]$Interactive) [pscustomobject]@{Url=$Url}}
function Get-PnPAccessToken {[CmdletBinding()]param($ResourceTypeName,$Connection) New-FakeToken $global:CopilotTestspoTenant '00000003-0000-0ff1-ce00-000000000000'}
function Get-PnPTenant {[CmdletBinding()]param($Connection) [pscustomobject]@{SharingCapability='ExternalUserAndGuestSharing';DefaultSharingLinkType='Direct'}}
function Get-PnPTenantSite {[CmdletBinding()]param([switch]$Detailed,$Connection) [pscustomobject]@{Url='https://example.sharepoint.com/sites/test';Title='Test';Owner='owner@example.com';SharingCapability='ExternalUserAndGuestSharing'}}
function Get-PnPWeb {[CmdletBinding()]param($Includes,$Connection) [pscustomobject]@{Url=$Connection.Url;HasUniqueRoleAssignments=$true;RoleAssignments=(New-RoleAssignments)}}
function Get-PnPSubWeb {[CmdletBinding()]param([switch]$Recurse,$Includes,$Connection) return @()}
function Get-PnPList {[CmdletBinding()]param($Includes,$Connection) [pscustomobject]@{Id='list1';Hidden=$false;HasUniqueRoleAssignments=$true;BaseType='DocumentLibrary';RoleAssignments=(New-RoleAssignments)}}
function Get-PnPListItem {[CmdletBinding()]param($List,$PageSize,$Fields,$Connection)
    foreach ($i in 1..2) {[pscustomobject]@{HasUniqueRoleAssignments=$true;FieldValues=@{FileRef="/sites/test/Shared Documents/file$i.docx";FSObjType=0};RoleAssignments=(New-RoleAssignments)}}
}
function Get-PnPProperty {[CmdletBinding()]param($ClientObject,[string[]]$Property,$Connection) if (@($Property).Count -eq 1) {return $ClientObject.($Property[0])}}
function Get-PnPGroupMember {[CmdletBinding()]param($Group,$Connection) [pscustomobject]@{Id=8;LoginName=('c:0-.f|rolemanager|spo-grid-all-users/'+$global:CopilotTesttenant);PrincipalType='SecurityGroup'}}
function Get-PnPFileSharingLink {[CmdletBinding()]param($Identity,$Connection) [pscustomobject]@{Id='link1';Link=@{Scope='anonymous';Type='view';WebUrl='https://secret-link.example/DO-NOT-EXPORT'};Roles=@('read');ExpirationDateTime='2099-01-01T00:00:00Z'}}
function Get-PnPFolderSharingLink {[CmdletBinding()]param($Folder,$Connection) return @()}
function Run-Scenario([string]$Scenario) {
    $global:CopilotTestscenario=$Scenario
    $token=ConvertTo-SecureString (New-FakeToken $global:CopilotTesttenant) -AsPlainText -Force
    & $target -TenantId $global:CopilotTesttenant -PowerPlatformAccessToken $token -OutputDirectory $OutputDirectory -SharePointAdminUrl 'https://example-admin.sharepoint.com' -SharePointClientId 'ffffffff-ffff-ffff-ffff-ffffffffffff' -IncludeLicensedUsers -IncludeGroupMembers
}
$normal=Run-Scenario 'normal'
$coverage=Import-Csv (Join-Path $normal.Carpeta 'cobertura.csv')
Assert (Test-Path -LiteralPath (Join-Path $normal.Carpeta 'evidencias/progreso.json')) 'Progreso persistente'
$checkpoint=Get-Content -LiteralPath (Join-Path $normal.Carpeta 'evidencias/progreso.json') -Raw | ConvertFrom-Json
Assert ($checkpoint.UltimaFuente -eq 'Cierre' -and $checkpoint.EstadoRecoleccion -eq $normal.EstadoRecoleccion) 'Checkpoint final consistente'
Assert ($normal.EstadoRecoleccion -eq 'CompletoSegunPerfil') 'Captura automatica completa en alcance simulado'
Assert ($normal.EstadoEvaluacion -eq 'Pendiente') 'Captura completa no equivale a controles cumplidos'
Assert (@($coverage | Where-Object {$_.Estado -notin @('Obtenido','Validacion manual')}).Count -eq 0) 'Sin fuentes inesperadamente fallidas'
$csv=Import-Csv (Join-Path $normal.Carpeta 'agentes.csv')
Assert ($csv.Nombre -eq "'=1+1") 'Neutralizacion CSV'
Assert ($csv.TenantId -eq $global:CopilotTesttenant -and $csv.RunId -eq $normal.RunId) 'Metadatos por fila'
Assert ($csv.PropietarioId -eq '' -and $csv.CreadorId -eq '11111111-1111-1111-1111-111111111111') 'No confundir propietario/creador'
$metrics=Import-Csv (Join-Path (Split-Path $normal.Informe) 'adopcion-indicadores.csv')
Assert ($metrics.AdopcionPorcentaje -eq '40') 'Adopcion calculada para mismo reporte y periodo'
$findings=Import-Csv (Join-Path (Split-Path $normal.Informe) 'hallazgos.csv')
Assert ('SP-BROAD' -in $findings.ControlId -and 'SP-ANON' -in $findings.ControlId) 'Hallazgos por permisos y enlaces observados'
$content=(Get-ChildItem -LiteralPath $normal.Carpeta -File -Recurse | Where-Object Extension -in @('.json','.csv','.html','.txt') | ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw}) -join ''
Assert ($content -notmatch 'DO-NOT-EXPORT' -and $content -notmatch 'fake\.[A-Za-z0-9_-]+\.fake') 'Sin enlaces autenticados ni tokens en evidencia'
foreach ($entry in Import-Csv (Join-Path $normal.Carpeta 'manifiesto-sha256.csv')) {Assert ((Get-FileHash -LiteralPath (Join-Path $normal.Carpeta $entry.Archivo)).Hash -eq $entry.SHA256) 'Hash captura'}
foreach ($case in @(@('graph-malformed','LicenciasSKU'),@('inventory-null','Agentes'),@('report-malformed','CopilotUsoDetalle'),@('report-period','CopilotUsoDetalle'))) {
    $r=Run-Scenario $case[0]
    $c=Import-Csv (Join-Path $r.Carpeta 'cobertura.csv')
    Assert (($c | Where-Object Fuente -eq $case[1]).Estado -eq 'ErrorDeEsquema') ('Rechazar esquema: '+$case[0])
    Assert ($r.ExitCode -eq 2) 'Estado parcial no equivale a exito completo'
}
$partial=Run-Scenario 'partial'
$c=Import-Csv (Join-Path $partial.Carpeta 'cobertura.csv')
Assert (($c | Where-Object Fuente -eq 'Agentes').Estado -ne 'Obtenido') 'Falla de segunda pagina invalida inventario'
Assert (-not (Test-Path (Join-Path $partial.Carpeta 'agentes.csv'))) 'No publicar agentes parciales como completos'
Assert (@(Get-ChildItem (Join-Path $partial.Carpeta 'evidencias') -Filter 'pagina-Agentes-*.json').Count -eq 1) 'Conservar pagina parcial'
$forbidden=Run-Scenario 'forbidden'
$c=Import-Csv (Join-Path $forbidden.Carpeta 'cobertura.csv')
Assert (($c | Where-Object Fuente -eq 'LicenciasSKU').Estado -eq 'SinPermiso') '403 se distingue de inventario vacio'
$diagnostic=Get-Content -LiteralPath (Join-Path $forbidden.Carpeta 'evidencias/diagnostico.json') -Raw
Assert ($diagnostic -notmatch 'SECRET-ERROR-BODY') 'No registrar cuerpos de errores sensibles'
$empty=Run-Scenario 'report-empty'
$c=Import-Csv (Join-Path $empty.Carpeta 'cobertura.csv')
Assert (($c | Where-Object Fuente -eq 'CopilotUsoDetalle').Estado -eq 'Obtenido' -and ($c | Where-Object Fuente -eq 'CopilotUsoDetalle').Registros -eq '0') 'CSV de reporte vacio con cabeceras validas es exito vacio'
$before=$global:CopilotTestcalls
$badToken=ConvertTo-SecureString (New-FakeToken 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee') -AsPlainText -Force
$bad=& $target -TenantId $global:CopilotTesttenant -PowerPlatformAccessToken $badToken -OutputDirectory $OutputDirectory
Assert ($bad.ExitCode -eq 1 -and $global:CopilotTestcalls -eq $before) 'Token explicito de otro tenant detiene consultas de recursos'
$global:CopilotTestgraphTenant='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
$fixed=Run-Scenario 'normal'
Assert ($fixed.TenantId -eq $global:CopilotTesttenant -and $global:CopilotTestgraphTenant -eq $global:CopilotTesttenant) 'Sesion Graph de otro tenant se reconecta al tenant explicito'
$global:CopilotTestscenario='normal'
$preflight=& $target -TenantId $global:CopilotTesttenant -PowerPlatformAccessToken (ConvertTo-SecureString (New-FakeToken $global:CopilotTesttenant) -AsPlainText -Force) -OutputDirectory $OutputDirectory -SharePointAdminUrl 'https://example-admin.sharepoint.com' -SharePointClientId 'ffffffff-ffff-ffff-ffff-ffffffffffff' -PreflightOnly
Assert ($preflight.EstadoRecoleccion -eq 'Preflight' -and $preflight.ExitCode -eq 2) 'Preflight no declara captura completa'
$noninteractive=& $target -TenantId $global:CopilotTesttenant -PowerPlatformAccessToken (ConvertTo-SecureString (New-FakeToken $global:CopilotTesttenant) -AsPlainText -Force) -OutputDirectory $OutputDirectory -SharePointAdminUrl 'https://example-admin.sharepoint.com' -SharePointClientId 'ffffffff-ffff-ffff-ffff-ffffffffffff' -NoInteractive
$niCoverage=Import-Csv (Join-Path $noninteractive.Carpeta 'cobertura.csv')
Assert ('PoliticasDLP' -notin $niCoverage.Fuente -and $noninteractive.ExitCode -eq 2) 'NoInteractive no convierte fuentes administrativas omitidas en captura completa'
$cross=Run-Scenario 'powerapps-cross'
$c=Import-Csv (Join-Path $cross.Carpeta 'cobertura.csv')
Assert ('PoliticasDLP' -notin $c.Fuente) 'No consultar DLP con tenant PowerApps no verificado'
$global:CopilotTestspoTenant='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
$cross=Run-Scenario 'normal'
$c=Import-Csv (Join-Path $cross.Carpeta 'cobertura.csv')
Assert (($c | Where-Object Fuente -eq 'SharePointInventario').Estado -ne 'Obtenido') 'Rechazar tenant SharePoint cruzado'
$global:CopilotTestspoTenant=$global:CopilotTesttenant
$global:CopilotTesttenant='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';$global:CopilotTestgraphTenant=$global:CopilotTesttenant;$global:CopilotTestspoTenant=$global:CopilotTesttenant
$second=Run-Scenario 'normal'
Assert ($second.TenantId -ne $normal.TenantId -and $second.Carpeta -ne $normal.Carpeta) 'Segundo tenant valido y aislado'
$global:CopilotTestscenario='normal'
$limited=& $target -TenantId $global:CopilotTesttenant -PowerPlatformAccessToken (ConvertTo-SecureString (New-FakeToken $global:CopilotTesttenant) -AsPlainText -Force) -OutputDirectory $OutputDirectory -SharePointAdminUrl 'https://example-admin.sharepoint.com' -SharePointClientId 'ffffffff-ffff-ffff-ffff-ffffffffffff' -MaxItemsPerSite 1
$c=Import-Csv (Join-Path $limited.Carpeta 'cobertura.csv')
Assert (($c | Where-Object Fuente -eq 'SharePointPermisos-0001').Estado -eq 'LimiteAlcance') 'Limite de items marca cobertura parcial'
$preserved=Get-Content (Join-Path $limited.Carpeta 'evidencias/SharePointPermisos-0001-permisos.json') -Raw | ConvertFrom-Json
Assert (-not $preserved.Completo -and $preserved.Registros.Count -gt 0) 'Evidencia parcial SharePoint conservada'
$manualFile=Join-Path $OutputDirectory 'evidencia-manual.txt'
'Evidencia simulada revisada' | Set-Content $manualFile
$null=& (Join-Path $root 'Import-AssessmentEvidence.ps1') -RunDirectory $second.Carpeta -TenantId $global:CopilotTesttenant -ControlId FIN-BILLING -EvidenceFile $manualFile -Estado NoCumple -Revisor 'Revisor simulado' -Justificacion 'Prueba de decision humana.'
$again=& (Join-Path $root 'Analyze-CopilotAssessment.ps1') -RunDirectory $second.Carpeta
$controls=Import-Csv (Join-Path $again.CarpetaAnalisis 'controles-gobierno.csv')
Assert (($controls | Where-Object ControlId -eq 'FIN-BILLING').Estado -eq 'NoCumple') 'Integrar decision humana sin autenticar'
Add-Content -LiteralPath (Join-Path $second.Carpeta 'evidencias/Agentes.json') -Value 'tampered'
$blocked=$false
try {$null=& (Join-Path $root 'Analyze-CopilotAssessment.ps1') -RunDirectory $second.Carpeta} catch {$blocked=$true}
Assert $blocked 'Detectar alteracion de evidencia'
# Pruebas unitarias de proteccion extraidas por AST, sin ejecutar autenticacion.
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'lib/Core.ps1'),[ref]$t,[ref]$e)
foreach ($name in @('Assert-ReadRequest','Get-Field','Has-Field','Read-Pages')) {
    $f=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Invoke-Expression $f.Extent.Text
}
foreach ($url in @('https://evil.example/v1.0/users','https://graph.microsoft.com/v1.0/users/abc/messages','http://graph.microsoft.com/v1.0/users')) {
    $blocked=$false;try {Assert-ReadRequest Graph GET $url} catch {$blocked=$true};Assert $blocked 'Lista estricta de lectura'
}
$script:sourcePages=0;$script:activeSource='Unit';$MaxPages=2
function Save-Json {param($Name,$Data)}
function Invoke-Read {param($Service,$Url) @{value=@();'@odata.nextLink'='https://graph.microsoft.com/v1.0/users'}}
$blocked=$false;try {$null=@(Read-Pages Graph 'https://graph.microsoft.com/v1.0/users')} catch {$blocked=$true}
Assert $blocked 'Bloquear ciclo de paginacion'
# Throttling y renovacion con las implementaciones reales, transporte simulado.
foreach ($name in @('Get-SafeError','Assert-Deadline','Invoke-Read','Get-PowerPlatformToken')) {
    $f=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Invoke-Expression $f.Extent.Text
}
$authAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'lib/Authentication.ps1'),[ref]$t,[ref]$e)
foreach ($name in @('Read-TokenClaims','ConvertFrom-SensitiveValue','Assert-PowerPlatformToken')) {
    $f=$authAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Invoke-Expression $f.Extent.Text
}
$TenantId=[guid]$global:CopilotTesttenant
$script:graphReady=$true;$script:deadline=[datetime]::UtcNow.AddMinutes(5);$script:requests=[Collections.Generic.List[object]]::new()
$global:CopilotTestRetries=0
function Start-Sleep {param($Milliseconds) Assert ($Milliseconds -ge 2000 -and $Milliseconds -le 60000) 'Reintento acotado'}
function Invoke-MgGraphRequest {
    [CmdletBinding()]param($Method,$Uri,$OutputType)
    $global:CopilotTestRetries++
    if ($global:CopilotTestRetries -eq 1) {
        $ex=[Exception]::new('throttled')
        $ex | Add-Member NoteProperty Response ([pscustomobject]@{StatusCode=[Net.HttpStatusCode]::TooManyRequests;Headers=@{'Retry-After'='2'}})
        throw $ex
    }
    return @{value=@()}
}
$null=Invoke-Read Graph 'https://graph.microsoft.com/v1.0/users'
Assert ($global:CopilotTestRetries -eq 2) 'Reintentar 429 con HttpStatusCode enum'
$PowerPlatformAccessToken=$null;$PowerPlatformClientId=[guid]::Empty
$script:ppToken=New-FakeToken $global:CopilotTesttenant 'https://api.powerplatform.com' ([datetimeoffset]::UtcNow.ToUnixTimeSeconds()-10)
$renewed=Get-PowerPlatformToken
$claims=Assert-PowerPlatformToken $renewed $TenantId
Assert ($claims.tid -eq $global:CopilotTesttenant) 'Renovar token del tenant esperado'
$PowerPlatformAccessToken=ConvertTo-SecureString 'externo' -AsPlainText -Force
$script:ppToken=New-FakeToken $global:CopilotTesttenant 'https://api.powerplatform.com' ([datetimeoffset]::UtcNow.ToUnixTimeSeconds()-10)
$blocked=$false;try {$null=Get-PowerPlatformToken} catch {$blocked=$true}
Assert $blocked 'Token externo expirado no se sustituye silenciosamente'
. (Join-Path $root 'lib/OfflinePolicies.ps1')
Assert ((Get-DlpApplicability $global:CopilotTestenvId @{EnvironmentType='AllEnvironments'}) -eq 'AplicaSegunAmbitoDeclarado') 'DLP ambito global'
Assert ((Get-DlpApplicability $global:CopilotTestenvId @{EnvironmentType='OnlyEnvironments';Environments=@()}) -eq 'NoAplicaSegunAmbitoDeclarado') 'DLP inclusion vacia explicita'
Assert ((Get-DlpApplicability $global:CopilotTestenvId @{EnvironmentType='OnlyEnvironments';Environments=@(@{unexpected='x'})}) -eq 'Desconocido') 'DLP formato desconocido no acredita exclusion'
Write-Host "OK: $global:CopilotTestassertions aserciones; $global:CopilotTestcalls llamadas simuladas; sin conexiones reales."
[pscustomobject]@{Estado='OK';Aserciones=$global:CopilotTestassertions;LlamadasSimuladas=$global:CopilotTestcalls;Resultados=$OutputDirectory}
