#Requires -Version 5.1
<#
.SYNOPSIS
Levantamiento de Microsoft Copilot Studio y Microsoft 365. Solo lectura remota.
.DESCRIPTION
No instala modulos, concede permisos, cambia politicas, publica agentes ni asigna
licencias. Escribe evidencias e informes UNICAMENTE en una carpeta local nueva.
El unico POST es la consulta documentada de inventario (no modifica recursos).
Autenticacion automatica: Microsoft.Graph.Authentication y Az.Accounts.
Tenant detectado desde token/sesiones; ClientId personalizados son opcionales.
Power Platform tambien admite token delegado existente o MSAL.PS con app existente.
PowerApps: inicio de sesion explicito y consultas Get-* del modulo administrativo.
#>
[CmdletBinding()]
param(
    [guid]$TenantId = [guid]::Empty,
    [string]$OutputDirectory = (Join-Path (Get-Location) 'CopilotAssessment'),
    [Security.SecureString]$PowerPlatformAccessToken,
    [guid]$PowerPlatformClientId = [guid]::Empty,
    [guid]$GraphClientId = [guid]::Empty,
    # No inicia login ni pide consentimiento. Solo reutiliza sesiones/token.
    [switch]$NoInteractive,
    [switch]$SkipGraph,
    [switch]$SkipPowerApps,
    [guid[]]$SecurityGroupIds = @(),
    [switch]$IncludeGroupMembers,
    [switch]$IncludeLicensedUsers,
    # Endpoint de consumo por recurso marcado deprecated por Microsoft: opt-in.
    [switch]$IncludeLegacyConsumption,
    [datetime]$FromDate = (Get-Date -Day 1).Date,
    [datetime]$ToDate = (Get-Date).Date,
    [ValidateRange(1,10000)][int]$MaxPages = 1000
)
$ErrorActionPreference = 'Stop'
if ($FromDate.Date -gt $ToDate.Date) { throw 'FromDate debe ser menor o igual a ToDate.' }
$script:started = [datetime]::UtcNow
$script:runPath = Join-Path $OutputDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $script:runPath
$script:runPath = (Get-Item -LiteralPath $script:runPath).FullName
$script:evidencePath = Join-Path $script:runPath 'evidencias'
$null = New-Item -ItemType Directory -Path $script:evidencePath
$script:status = New-Object 'System.Collections.Generic.List[object]'
$script:requests = New-Object 'System.Collections.Generic.List[object]'
$script:ppToken = $null
$script:graphReady = $false
$script:authentication = [ordered]@{ TenantId=$null; OrigenTenant=$null; GraphClientId=$null; PowerPlatformClientId=$null; OrigenPowerPlatform=$null; NoInteractive=[bool]$NoInteractive }

function Get-Field($Object, [string]$Path) {
    $value = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $value) { return $null }
        if ($value -is [System.Collections.IDictionary]) { $value = $value[$part] }
        else { $value = $value.$part }
    }
    return $value
}
function Has-Field($Object, [string]$Name) {
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}
function Save-Json([string]$Name, $Data) {
    $json = ConvertTo-Json -InputObject $Data -Depth 100
    [IO.File]::WriteAllText((Join-Path $script:evidencePath ($Name + '.json')), $json, (New-Object Text.UTF8Encoding($true)))
}
function Save-Csv([string]$Name, $Rows) {
    $items = @($Rows)
    if ($items.Count -eq 0) { return } # JSON y cobertura diferencian vacio de fallido.
    # Neutraliza formulas al abrir CSV en Excel. El JSON conserva el valor original.
    $safe = foreach ($row in $items) {
        $copy = [ordered]@{}
        foreach ($p in $row.PSObject.Properties) {
            $v = $p.Value
            if ($v -is [string] -and $v -match '^\s*[=+@-]') { $v = "'" + $v }
            $copy[$p.Name] = $v
        }
        [pscustomobject]$copy
    }
    $safe | Export-Csv -LiteralPath (Join-Path $script:runPath ($Name + '.csv')) -NoTypeInformation -Encoding UTF8
}
function Add-Status([string]$Name, [string]$State, [int]$Count, [string]$Detail) {
    $script:status.Add([pscustomobject]@{ Fuente=$Name; Estado=$State; Registros=$Count; Detalle=$Detail; UTC=[datetime]::UtcNow.ToString('o') })
}
function Collect([string]$Name, [scriptblock]$Action) {
    Write-Host "Consultando $Name ..."
    try {
        $rows = @(& $Action)
        Save-Json $Name $rows
        Add-Status $Name 'Obtenido' $rows.Count 'Consulta finalizada; no acredita cobertura fuera de esta fuente.'
        return $rows
    } catch {
        # No registrar cuerpos de errores: podrian contener tokens o contenido sensible.
        $code = Get-Field $_.Exception 'Response.StatusCode'
        Add-Status $Name 'No obtenido' 0 ("Consulta interrumpida. HTTP={0}; tipo={1}. Revisar permisos, sesion y disponibilidad. No equivale a cero recursos." -f $code,$_.Exception.GetType().Name)
        Write-Warning "$Name no obtenido; ver cobertura.csv."
        return @()
    }
}
function Assert-ReadRequest([string]$Service, [string]$Method, [string]$Url) {
    $u = [uri]$Url
    if ($u.Scheme -ne 'https' -or $u.UserInfo -or $u.Port -ne 443 -or $u.Fragment) { throw 'URI no permitida.' }
    if ($Service -eq 'Graph') {
        if ($u.Host -ne 'graph.microsoft.com' -or $Method -ne 'GET' -or
            $u.AbsolutePath -notmatch '^/v1\.0/(subscribedSkus|users|groups|roleManagement/directory/(roleAssignments|roleDefinitions)|identity/conditionalAccess/policies)(/|$)') { throw 'Consulta Graph fuera de la lista de lectura.' }
    } elseif ($Service -eq 'PowerPlatform') {
        if ($u.Host -ne 'api.powerplatform.com') { throw 'Host Power Platform no permitido.' }
        $query = $u.AbsolutePath -eq '/resourcequery/resources/query' -and $Method -eq 'POST'
        $read = $Method -eq 'GET' -and $u.AbsolutePath -match '^/licensing/(billingPolicies|entitlements/MCSMessages|allocationsV2/availability)(/|$)'
        if (-not ($query -or $read)) { throw 'Operacion fuera de la lista de lectura.' }
    } else { throw 'Servicio no permitido.' }
}
function Invoke-Read([string]$Service, [string]$Url, [string]$Method = 'GET', $Body = $null) {
    Assert-ReadRequest $Service $Method $Url
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            if ($Service -eq 'Graph') {
                if (-not $script:graphReady) { throw 'Graph no disponible.' }
                $r = Invoke-MgGraphRequest -Method GET -Uri $Url -OutputType PSObject
            } else {
                if (-not $script:ppToken) { throw 'Token Power Platform no disponible.' }
                $argsRest = @{ Uri=$Url; Method=$Method; Headers=@{Authorization="Bearer $script:ppToken"}; TimeoutSec=120; MaximumRedirection=0; ErrorAction='Stop' }
                if ($Method -eq 'POST') {
                    $argsRest.ContentType = 'application/json'
                    $argsRest.Body = ConvertTo-Json -InputObject $Body -Depth 30 -Compress
                }
                $r = Invoke-RestMethod @argsRest
            }
            $script:requests.Add([pscustomobject]@{ UTC=[datetime]::UtcNow.ToString('o'); Servicio=$Service; Metodo=$Method; Ruta=([uri]$Url).AbsolutePath; Resultado='OK'; Intento=$attempt+1 })
            return $r
        } catch {
            $http = Get-Field $_.Exception 'Response.StatusCode'
            if ($null -eq $http) { $http = Get-Field $_.Exception 'ResponseStatusCode' }
            $script:requests.Add([pscustomobject]@{ UTC=[datetime]::UtcNow.ToString('o'); Servicio=$Service; Metodo=$Method; Ruta=([uri]$Url).AbsolutePath; Resultado="Error $http"; Intento=$attempt+1 })
            if ($http -in @(429,500,502,503,504) -and $attempt -lt 3) {
                $delay = [int][math]::Pow(2,$attempt+1)
                $retryAfter = Get-Field $_.Exception 'Response.Headers.RetryAfter.Delta.TotalSeconds'
                if ($retryAfter) { $delay = [math]::Max($delay,[math]::Min(60,[double]$retryAfter)) }
                Start-Sleep -Seconds $delay
            } else { throw }
        }
    }
}
function Read-Pages([string]$Service, [string]$Url) {
    $seen = @{}
    $baseUrl = $Url
    for ($page=0; $Url; $page++) {
        if ($page -ge $MaxPages -or $seen.ContainsKey($Url)) { throw 'Paginacion incompleta o ciclica.' }
        $seen[$Url] = $true
        $r = Invoke-Read $Service $Url
        # Se guarda cada pagina inmediatamente; una falla posterior queda como parcial.
        $pageName = 'pagina-' + [guid]::NewGuid().ToString('N')
        Save-Json $pageName ([ordered]@{ servicio=$Service; ruta=([uri]$Url).AbsolutePath; pagina=$page; respuesta=$r })
        $values = Get-Field $r 'value'
        if (Has-Field $r 'value') { foreach ($v in $values) { $v } }
        elseif ($null -ne $r) { $r }
        $next = $r.'@odata.nextLink'
        if (-not $next) { $next = Get-Field $r 'nextLink' }
        $continuation = Get-Field $r 'continuationtoken'
        if (-not $next -and $continuation) { $next = $baseUrl + '&continuationToken=' + [uri]::EscapeDataString($continuation) }
        if ($next -and -not ([uri]$next).IsAbsoluteUri) { $next = (New-Object uri([uri]$baseUrl, [string]$next)).AbsoluteUri }
        $Url = $next
    }
}
function Read-Inventory([string]$Type) {
    $skip = ''
    $seen = @{}
    for ($page=0; $page -lt $MaxPages; $page++) {
        $body = @{ TableName='PowerPlatformResources'; Clauses=@(
            @{ '$type'='where'; FieldName='type'; Operator='=='; Values=@("'$Type'") }
            @{ '$type'='orderby'; FieldNamesAscDesc=@{id='asc'} }
        ); Options=@{Top=1000; SkipToken=$skip} }
        $r = Invoke-Read PowerPlatform 'https://api.powerplatform.com/resourcequery/resources/query?api-version=2024-10-01' POST $body
        Save-Json (('inventario-{0}-{1:D4}' -f ($Type.Split('/')[-1]),$page)) $r
        if (-not (Has-Field $r 'data')) { throw 'Inventario sin propiedad data; respuesta inesperada.' }
        foreach ($item in $r.data) { $item }
        $skip = [string](Get-Field $r 'skipToken')
        if (-not $skip) {
            if ((Get-Field $r 'resultTruncated') -in @(1,'true','True')) { throw 'Inventario truncado sin continuacion.' }
            return
        }
        if ($seen.ContainsKey($skip)) { throw 'Inventario con continuacion ciclica.' }
        $seen[$skip] = $true
    }
    throw 'Inventario excede MaxPages; cobertura incompleta.'
}
function Read-TokenClaims([string]$Token) {
    $parts = $Token.Split('.')
    if ($parts.Length -lt 2) { throw 'Se requiere un access token JWT de Power Platform.' }
    $s = $parts[1].Replace('-','+').Replace('_','/')
    $s = $s.PadRight($s.Length + ((4 - $s.Length % 4) % 4), '=')
    return ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) | ConvertFrom-Json)
}
function ConvertFrom-SensitiveValue($Value) {
    if ($Value -isnot [Security.SecureString]) { return [string]$Value }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Assert-PowerPlatformToken([string]$Token, [guid]$ExpectedTenant = [guid]::Empty) {
    # Chequeo local de coherencia, no validacion criptografica. El servicio valida la firma.
    $c = Read-TokenClaims $Token
    $tokenTenant = [guid]$c.tid
    if ($tokenTenant -eq [guid]::Empty -or ($ExpectedTenant -ne [guid]::Empty -and $tokenTenant -ne $ExpectedTenant) -or
        $c.aud -notin @('https://api.powerplatform.com','https://api.powerplatform.com/','8578e004-a5c6-46e7-913e-12f58912df43') -or
        -not $c.scp -or [double]$c.exp -le ([datetimeoffset]::UtcNow.ToUnixTimeSeconds()+60)) { throw 'Token delegado, tenant, audiencia o vigencia incorrectos.' }
    return $c
}
function Connect-AssessmentGraph([guid]$TargetTenant) {
    if ($NoInteractive) { throw 'Login interactivo deshabilitado.' }
    $scopes = @('LicenseAssignment.Read.All','RoleManagement.Read.Directory','Policy.Read.All','Group.Read.All')
    if ($IncludeLicensedUsers) { $scopes += 'User.Read.All' }
    if ($IncludeGroupMembers) { $scopes += 'GroupMember.Read.All' }
    $login = @{ Scopes=$scopes; ContextScope='Process'; NoWelcome=$true; ErrorAction='Stop' }
    if ($TargetTenant -ne [guid]::Empty) { $login.TenantId = $TargetTenant.ToString() }
    if ($GraphClientId -ne [guid]::Empty) { $login.ClientId = $GraphClientId.ToString() }
    Write-Host 'Inicie sesion en Microsoft Graph con la cuenta del tenant que desea levantar.'
    $null = Connect-MgGraph @login
    return Get-MgContext
}
function Connect-AssessmentAzure([guid]$TargetTenant) {
    if ($NoInteractive) { throw 'Login interactivo deshabilitado.' }
    $login = @{ Scope='Process'; SkipContextPopulation=$true; ErrorAction='Stop' }
    if ($TargetTenant -ne [guid]::Empty) { $login.Tenant = $TargetTenant.ToString() }
    Write-Host 'Inicie sesion en Azure PowerShell para consultar Power Platform (sin ClientId manual).'
    $null = Connect-AzAccount @login
    return Get-AzContext
}

# Descubrir identidad ANTES de consultar recursos. No enumera ni crea app registrations.
$graphModuleReady = $false; $azModuleReady = $false; $ctx = $null; $azContext = $null
if (-not $SkipGraph) {
    try { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop; $graphModuleReady = $true; $ctx = Get-MgContext }
    catch { Add-Status 'ModuloGraph' 'No obtenido' 0 'Preparar Microsoft.Graph.Authentication; no se instala automaticamente.' }
}
if (-not $PowerPlatformAccessToken -and $PowerPlatformClientId -eq [guid]::Empty) {
    try { Import-Module Az.Accounts -ErrorAction Stop; $azModuleReady = $true; $azContext = Get-AzContext }
    catch { Add-Status 'ModuloAzure' 'No obtenido' 0 'Preparar Az.Accounts para autenticacion sin ClientId, o usar token/ClientId corporativo existente.' }
}
$explicitTokenClaims = $null
if ($PowerPlatformAccessToken) {
    # Token explicitamente proporcionado invalido o de otro tenant: detener, sin fallback.
    try {
        $script:ppToken = ConvertFrom-SensitiveValue $PowerPlatformAccessToken
        $explicitTokenClaims = Assert-PowerPlatformToken $script:ppToken $TenantId
    } catch { $script:ppToken = $null; throw 'El token Power Platform proporcionado es invalido, expiro o corresponde a otro tenant. No se consultaron recursos.' }
}
if ($TenantId -ne [guid]::Empty) { $script:authentication.OrigenTenant = 'Parametro TenantId' }
elseif ($explicitTokenClaims) {
    $TenantId = [guid]$explicitTokenClaims.tid
    $script:authentication.OrigenTenant = 'Token delegado Power Platform'
} else {
    $candidates = @()
    if ($ctx -and $ctx.Environment -eq 'Global' -and $ctx.TenantId) { $candidates += [guid]$ctx.TenantId }
    if ($azContext -and (Get-Field $azContext 'Environment.Name') -eq 'AzureCloud' -and (Get-Field $azContext 'Account.Type') -eq 'User' -and (Get-Field $azContext 'Tenant.Id')) { $candidates += [guid]$azContext.Tenant.Id }
    $candidates = @($candidates | Where-Object { $_ -ne [guid]::Empty } | Select-Object -Unique)
    if ($candidates.Count -gt 1) { throw 'Graph y Azure tienen sesiones de tenants distintos. Indique -TenantId para seleccionar el tenant; no se consultaron recursos.' }
    if ($candidates.Count -eq 1) {
        $TenantId = $candidates[0]
        $script:authentication.OrigenTenant = 'Sesion existente Graph/Azure'
    } else {
        if ($graphModuleReady -and -not $NoInteractive) {
            try {
                $ctx = Connect-AssessmentGraph ([guid]::Empty)
                if ($ctx -and $ctx.Environment -eq 'Global' -and $ctx.TenantId) {
                    $TenantId = [guid]$ctx.TenantId
                    $script:authentication.OrigenTenant = 'Inicio de sesion Graph'
                }
            } catch { Add-Status 'DescubrimientoGraph' 'No obtenido' 0 'No fue posible detectar tenant desde inicio de sesion Graph.' }
        }
        if ($TenantId -eq [guid]::Empty -and $azModuleReady -and -not $NoInteractive) {
            try {
                $azContext = Connect-AssessmentAzure ([guid]::Empty)
                if ((Get-Field $azContext 'Environment.Name') -eq 'AzureCloud' -and (Get-Field $azContext 'Account.Type') -eq 'User') {
                    $TenantId = [guid]$azContext.Tenant.Id
                    $script:authentication.OrigenTenant = 'Inicio de sesion Azure'
                }
            } catch { Add-Status 'DescubrimientoAzure' 'No obtenido' 0 'No fue posible detectar tenant desde inicio de sesion Azure.' }
        }
    }
}
if ($TenantId -eq [guid]::Empty) { throw 'No se pudo detectar el tenant. Inicie sesion Graph/Azure o indique -TenantId. No se consultaron recursos.' }
$script:authentication.TenantId = $TenantId.ToString()
Write-Host ("Tenant seleccionado: {0} ({1})" -f $TenantId,$script:authentication.OrigenTenant)

if (-not $SkipGraph) {
    try {
        if (-not $graphModuleReady) { throw 'Modulo Graph no disponible.' }
        if (-not $ctx -or $ctx.TenantId -ne $TenantId.ToString() -or $ctx.Environment -ne 'Global' -or
            ($GraphClientId -ne [guid]::Empty -and $ctx.ClientId -ne $GraphClientId.ToString())) { $ctx = Connect-AssessmentGraph $TenantId }
        if (-not $ctx -or $ctx.TenantId -ne $TenantId.ToString() -or $ctx.Environment -ne 'Global') { throw 'Sesion Graph ausente o de otro tenant/nube.' }
        $script:authentication.GraphClientId = $ctx.ClientId
        $script:graphReady = $true
        Add-Status 'AutenticacionGraph' 'Obtenido' 1 'Tenant y nube verificados. ClientId obtenido de la sesion; no se crea una aplicacion.'
    } catch { Add-Status 'AutenticacionGraph' 'No obtenido' 0 'Revisar sesion, modulo, permisos previamente autorizados y politica de acceso a Graph. No se crea una app ni concede consentimiento.' }
} else { Add-Status 'AutenticacionGraph' 'Omitido' 0 'SkipGraph solicitado.' }
try {
    if ($PowerPlatformAccessToken) {
        $script:authentication.OrigenPowerPlatform = 'Token proporcionado'
    } elseif ($PowerPlatformClientId -ne [guid]::Empty) {
        if ($NoInteractive) { throw 'MSAL interactivo deshabilitado; proporcionar token o sesion Azure.' }
        Import-Module MSAL.PS -ErrorAction Stop
        $auth = Get-MsalToken -ClientId $PowerPlatformClientId.ToString() -TenantId $TenantId.ToString() -Scopes 'https://api.powerplatform.com/.default' -Interactive
        $script:ppToken = $auth.AccessToken
        $auth = $null
        $script:authentication.OrigenPowerPlatform = 'MSAL con app corporativa existente'
    } else {
        if (-not $azModuleReady) { throw 'Modulo Az.Accounts no disponible.' }
        if (-not $azContext -or (Get-Field $azContext 'Tenant.Id') -ne $TenantId.ToString() -or
            (Get-Field $azContext 'Environment.Name') -ne 'AzureCloud' -or (Get-Field $azContext 'Account.Type') -ne 'User') { $azContext = Connect-AssessmentAzure $TenantId }
        if (-not $azContext -or (Get-Field $azContext 'Tenant.Id') -ne $TenantId.ToString() -or
            (Get-Field $azContext 'Environment.Name') -ne 'AzureCloud' -or (Get-Field $azContext 'Account.Type') -ne 'User') { throw 'Sesion Azure no es de usuario en el tenant/nube esperado.' }
        $azToken = Get-AzAccessToken -ResourceUrl 'https://api.powerplatform.com' -TenantId $TenantId.ToString() -ErrorAction Stop
        $script:ppToken = ConvertFrom-SensitiveValue $azToken.Token
        $azToken = $null
        $script:authentication.OrigenPowerPlatform = 'Az.Accounts (sin ClientId manual)'
    }
    $claims = Assert-PowerPlatformToken $script:ppToken $TenantId
    $client = Get-Field $claims 'azp'
    if (-not $client) { $client = Get-Field $claims 'appid' }
    $script:authentication.PowerPlatformClientId = $client
    Add-Status 'AutenticacionPowerPlatform' 'Obtenido' 1 'Tenant y audiencia coinciden; token delegado. ClientId informativo desde el token, cuando esta disponible. No se exporta token.'
} catch {
    $script:ppToken = $null
    Add-Status 'AutenticacionPowerPlatform' 'No obtenido' 0 'No se obtuvo token delegado de Power Platform. Revisar Az.Accounts y autorizacion corporativa; alternativa token o ClientId existente. No se conceden permisos ni se crean aplicaciones.'
}
Save-Json 'autenticacion' $script:authentication

$agents = @(); $environments = @(); $envGroups = @(); $credits = @(); $billing = @(); $skus = @(); $dlp = @(); $paEnvironments = @()
if ($script:ppToken) {
    $agents = @(Collect 'Agentes' { Read-Inventory 'microsoft.copilotstudio/agents' })
    $environments = @(Collect 'Entornos' { Read-Inventory 'microsoft.powerplatform/environments' })
    $envGroups = @(Collect 'GruposEntornos' { Read-Inventory 'microsoft.powerplatform/environmentgroups' })
    $billing = @(Collect 'PlanesFacturacion' { Read-Pages PowerPlatform 'https://api.powerplatform.com/licensing/billingPolicies?api-version=2024-10-01' })
    $credits = @(Collect 'CopilotCredits' { Invoke-Read PowerPlatform 'https://api.powerplatform.com/licensing/entitlements/MCSMessages?api-version=2024-10-01' })
    foreach ($env in $environments) {
        $envId = [string]$env.name
        if ($envId -notmatch '^(Default-)?[0-9a-fA-F-]{36}$') { Add-Status "Disponibilidad-$envId" 'Omitido' 0 'Identificador de entorno no reconocido.'; continue }
        $filter = [uri]::EscapeDataString("environmentId eq '$envId' and EntitlementId in ('MCSMessages')")
        $null = Collect "Disponibilidad-$envId" { Invoke-Read PowerPlatform ("https://api.powerplatform.com/licensing/allocationsV2/availability?api-version=2024-10-01&`$filter=$filter") }
    }
    if ($IncludeLegacyConsumption) {
        $from = $FromDate.ToString('yyyy-MM-dd'); $to = $ToDate.ToString('yyyy-MM-dd')
        $null = Collect 'ConsumoLegacy' { Read-Pages PowerPlatform "https://api.powerplatform.com/licensing/entitlements/MCSMessages/resources?fromDate=$from&toDate=$to&api-version=2024-10-01" }
    } else { Add-Status 'ConsumoPorAgente' 'Validacion manual' 0 'Exportar consumo por agente desde PPAC. El endpoint de recursos esta deprecated; alternativa optativa IncludeLegacyConsumption.' }
} else { Add-Status 'FuentesPowerPlatform' 'No obtenido' 0 'Agentes, entornos, grupos de entornos, facturacion y capacidad no consultados por falta de autenticacion.' }

if ($script:graphReady) {
    $skus = @(Collect 'LicenciasSKU' { Read-Pages Graph 'https://graph.microsoft.com/v1.0/subscribedSkus' })
    $null = Collect 'RolesEntraDefiniciones' { Read-Pages Graph 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions' }
    $null = Collect 'RolesEntraAsignaciones' { Read-Pages Graph 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' }
    $null = Collect 'AccesoCondicional' { Read-Pages Graph 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies' }
    if ($IncludeLicensedUsers) {
        $null = Collect 'UsuariosLicencias' { Read-Pages Graph 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,accountEnabled,assignedLicenses,assignedPlans,licenseAssignmentStates&$top=999' }
    } else { Add-Status 'UsuariosLicencias' 'Omitido' 0 'Detalle individual optativo: IncludeLicensedUsers. Se exportan todos los usuarios para revisar asignaciones.' }
}

if (-not $SkipPowerApps) {
    try {
        if ($NoInteractive) { throw 'PowerApps requiere login verificado; NoInteractive omite esta fuente.' }
        Import-Module Microsoft.PowerApps.Administration.PowerShell -ErrorAction Stop
        $null = Add-PowerAppsAccount -TenantID $TenantId.ToString() -ErrorAction Stop
        Add-Status 'AutenticacionPowerApps' 'Obtenido' 1 'Inicio de sesion solicitado expresamente en TenantId.'
        $paEnvironments = @(Collect 'EntornosAdministracion' { Get-AdminPowerAppEnvironment -ErrorAction Stop })
        $dlp = @(Collect 'PoliticasDLP' { Get-AdminDlpPolicy -ErrorAction Stop })
        $null = Collect 'ConfiguracionTenant' { Get-TenantSettings -ErrorAction Stop }
        foreach ($e in $paEnvironments) {
            $name = [string]$e.EnvironmentName
            if ($name -notmatch '^(Default-)?[0-9a-fA-F-]{36}$') { continue }
            # Esta API solo cubre roles Environment Admin/Maker SIN Dataverse.
            if (-not (Get-Field $e 'Internal.properties.linkedEnvironmentMetadata.instanceUrl')) {
                $null = Collect "RolesEntorno-$name" { Get-AdminPowerAppEnvironmentRoleAssignment -EnvironmentName $name -ErrorAction Stop }
            } else { Add-Status "RolesDataverse-$name" 'Validacion manual' 0 'Revisar roles directos, equipos, unidades de negocio, application users y comparticion de agentes en Dataverse. No cubierto por roles Environment Admin/Maker.' }
        }
    } catch { Add-Status 'AdministracionPowerApps' 'No obtenido' 0 'Modulo o autenticacion no disponible, o NoInteractive activo. Revisar compatibilidad del modulo; DLP y configuracion quedan pendientes.' }
} else { Add-Status 'AdministracionPowerApps' 'Omitido' 0 'SkipPowerApps solicitado; DLP y configuracion administrativa pendientes.' }

$groupIds = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($id in $SecurityGroupIds) { $null = $groupIds.Add($id.ToString()) }
foreach ($env in $environments) {
    $g = Get-Field $env 'properties.securityGroupId'
    if ($g -and [string]$g -match '^[0-9a-fA-F-]{36}$' -and [string]$g -ne [guid]::Empty.ToString()) { $null = $groupIds.Add([string]$g) }
}
foreach ($e in $paEnvironments) {
    foreach ($path in @('Internal.properties.linkedEnvironmentMetadata.securityGroupId','Internal.properties.securityGroupId','SecurityGroupId')) {
        $g = Get-Field $e $path
        if ($g -and [string]$g -match '^[0-9a-fA-F-]{36}$' -and [string]$g -ne [guid]::Empty.ToString()) { $null = $groupIds.Add([string]$g) }
    }
}
if ($script:graphReady) {
    foreach ($g in $groupIds) {
        $null = Collect "Grupo-$g" { Invoke-Read Graph "https://graph.microsoft.com/v1.0/groups/$g`?`$select=id,displayName,securityEnabled,groupTypes,membershipRule,membershipRuleProcessingState,isAssignableToRole" }
        $null = Collect "PropietariosGrupo-$g" { Read-Pages Graph "https://graph.microsoft.com/v1.0/groups/$g/owners?`$select=id,displayName" }
        if ($IncludeGroupMembers) {
            $null = Collect "MiembrosTransitivosGrupo-$g" { Read-Pages Graph "https://graph.microsoft.com/v1.0/groups/$g/transitiveMembers?`$select=id,displayName" }
        }
    }
}
Add-Status 'AlcanceGrupos' 'Validacion manual' $groupIds.Count 'Solo grupos detectados en entornos o indicados por SecurityGroupIds. Agregar grupos de autores, editores, usuarios y publicadores; no supone censo completo. Membresias ocultas pueden requerir permisos adicionales.'

$agentRows = @(foreach ($a in $agents) {
    $p = $a.properties
    $env = @($environments | Where-Object { $_.name -eq $p.environmentId } | Select-Object -First 1)
    [pscustomobject]@{
        AgentId=$a.name; Nombre=$p.displayName; EntornoId=$p.environmentId
        EntornoNombre=($env | ForEach-Object { $_.properties.displayName }) -join ';'
        PropietarioId=$p.ownerId; CreadorId=$p.createdBy; CreadoEn=$p.createdIn
        UltimaPublicacion=$p.lastPublishedAt; Canales=(@($p.channels) -join ';')
        Autenticacion=$p.authentication; Orquestacion=$p.orchestration; Modelo=$p.model
        SolucionAdministrada=$p.isManaged; Cuarentena=$p.isQuarantined
        CompartidoTenant=(Get-Field $p 'sharedWithViewers.entireTenant')
        EditoresUsuarios=(Get-Field $p 'sharedWithEditors.userCount'); EditoresGrupos=(Get-Field $p 'sharedWithEditors.groupCount')
        BotId=$p.botId; EntraAppId=$p.entraAppId; EntraAgentId=$p.entraAgentId
        Conectores=(@($p.powerPlatformConnectors | ForEach-Object { $_.connectorId }) -join ';')
    }
})
$skuRows = @(foreach ($s in $skus) {
    $enabled = Get-Field $s 'prepaidUnits.enabled'
    [pscustomobject]@{ SkuId=$s.skuId; SKU=$s.skuPartNumber; Estado=$s.capabilityStatus; Habilitadas=$enabled; Suspendidas=(Get-Field $s 'prepaidUnits.suspended'); Advertencia=(Get-Field $s 'prepaidUnits.warning'); Asignadas=$s.consumedUnits; SinAsignar=if ($null -ne $enabled -and $null -ne $s.consumedUnits) { [long]$enabled-[long]$s.consumedUnits } else { $null }; Planes=(@($s.servicePlans | ForEach-Object { $_.servicePlanName }) -join ';') }
})
$findings = New-Object 'System.Collections.Generic.List[object]'
foreach ($a in $agentRows) {
    if (-not $a.PropietarioId) { $findings.Add([pscustomobject]@{ Prioridad='Media'; Recurso=$a.AgentId; Observacion='Propietario no informado por esta fuente'; Accion='Confirmar responsable funcional y tecnico; creador no equivale a propietario.' }) }
    if ($a.Autenticacion -eq 'None') { $findings.Add([pscustomobject]@{ Prioridad='Alta'; Recurso=$a.AgentId; Observacion='Inventario informa autenticacion None'; Accion='Validar exposicion y datos; requerir autenticacion para uso interno y excepcion aprobada para uso publico.' }) }
    if ($a.CompartidoTenant -eq $true) { $findings.Add([pscustomobject]@{ Prioridad='Media'; Recurso=$a.AgentId; Observacion='Compartido con todo el tenant segun inventario'; Accion='Confirmar aprobacion, audiencia y acceso real a las fuentes.' }) }
}
Add-Status 'CoberturaInventario' 'Validacion manual' 0 'Inventario central excluye bots clasicos V1. Reconciliar Classic chatbots en PPAC y catalogos de agentes M365. Campos preview o nulos no prueban ausencia de controles.'
Add-Status 'PublicacionALM' 'Validacion manual' 0 'Canales y fecha no acreditan mecanismo ALM. Revisar soluciones, pipelines, historial, aprobadores, catalogo Teams/M365 y permisos de publicacion.'
Add-Status 'FacturasPagos' 'Validacion manual' 0 'Estado SKU/plan PAYG no acredita pago, deuda, presupuesto ni saldo de Copilot Credits.'
Add-Status 'MonitoreoLimites' 'Validacion manual' 0 'Comprobar Purview, retencion, alertas, Application Insights, presupuestos Azure, topes PAYG y reglas TenantPool/overage por entorno. No se exportan conversaciones ni eventos de auditoria.'
Add-Status 'PermisosEfectivos' 'Validacion manual' 0 'Roles Entra y grupos no equivalen a acceso efectivo. Falta PIM elegible/activaciones, roles Dataverse, comparticion, permisos de fuentes y prueba de autorizacion.'

Save-Csv 'agentes' $agentRows
Save-Csv 'licencias' $skuRows
Save-Csv 'hallazgos' $findings.ToArray()
Save-Csv 'cobertura' $script:status.ToArray()
Save-Csv 'consultas' $script:requests.ToArray()
Save-Json 'cobertura' $script:status.ToArray()
Save-Json 'hallazgos' $findings.ToArray()
Save-Json 'ejecucion' ([ordered]@{Version='1.1.0';TenantId=$TenantId.ToString();InicioUTC=$script:started.ToString('o');FinUTC=[datetime]::UtcNow.ToString('o');PowerShell=$PSVersionTable.PSVersion.ToString();SoloLecturaRemota=$true;MaxPages=$MaxPages;FromDate=$FromDate.ToString('yyyy-MM-dd');ToDate=$ToDate.ToString('yyyy-MM-dd');IncludeLegacyConsumption=[bool]$IncludeLegacyConsumption;AgentesObtenidos=$agents.Count;EntornosObtenidos=$environments.Count;Notas='Los recuentos corresponden solo a consultas completas de la fuente. Revisar cobertura y paginas parciales.'})
$unknown = @($script:status | Where-Object { $_.Estado -ne 'Obtenido' }).Count
$html = @"
<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Levantamiento Copilot</title>
<style>body{font:15px system-ui;max-width:1250px;margin:36px auto;padding:0 24px;color:#19273a}table{border-collapse:collapse;width:100%;margin:20px 0}td,th{border:1px solid #ccd4df;padding:8px;text-align:left;overflow-wrap:anywhere}th{background:#eaf0f8}h1,h2{color:#174777}.nota{background:#fff2d8;padding:14px}</style></head><body>
<h1>Levantamiento de Copilot</h1><p>Tenant: $TenantId | UTC: $([datetime]::UtcNow.ToString('o'))</p>
<p class="nota">Resultado parcial hasta cerrar las validaciones. Agentes obtenidos: $($agents.Count). Entornos obtenidos: $($environments.Count). Fuentes omitidas, pendientes o fallidas: $unknown. Ninguna ausencia de evidencia se interpreta como ausencia del control.</p>
<h2>Cobertura y pendientes</h2>$($script:status.ToArray() | ConvertTo-Html -Fragment)
<h2>Observaciones para revisar</h2>$($findings.ToArray() | ConvertTo-Html -Fragment)
<h2>Propuesta tecnica inicial de gobierno</h2>
<p>Estas recomendaciones son una base para decision; no son una configuracion aplicada ni un dictamen del tenant. Se ajustan con las evidencias obtenidas y con los controles pendientes de validacion.</p>
<table><tr><th>Responsable</th><th>Responsabilidad y control recomendado</th><th>Evidencia/condicion</th></tr>
<tr><td>Comite de gobierno / negocio</td><td>Aprobar casos de uso, riesgo, excepciones y responsable por agente. Recertificacion trimestral.</td><td>Inventario y propietarios confirmados; riesgo de datos y audiencia.</td></tr>
<tr><td>Administrador Power Platform</td><td>Separar desarrollo, pruebas y produccion; limitar creacion a grupos; controlar canales y promover mediante soluciones y aprobaciones.</td><td>Entornos, DLP y configuracion. Confirmar licenciamiento antes de depender de Managed Environments o pipelines. Los editores pueden publicar: separar aprobacion mediante proceso y ALM cuando el producto lo permita.</td></tr>
<tr><td>Seguridad / Entra</td><td>Minimo privilegio; grupos para autores, editores y consumidores; autenticacion Entra para agentes internos; acceso condicional segun riesgo.</td><td>Roles, grupos y politicas obtenidos. Verificar Dataverse, PIM y permisos de fuentes antes de afirmar acceso efectivo.</td></tr>
<tr><td>Seguridad de datos / cumplimiento</td><td>Clasificar fuentes; definir DLP por entorno, conectores, HTTP, conocimiento y canales; excepciones con vencimiento.</td><td>Aplicabilidad de cada politica y restricciones del tenant por revisar. La existencia de una politica no acredita cobertura efectiva.</td></tr>
<tr><td>Propietario funcional y tecnico</td><td>Mantener proposito, fuentes, audiencia, soporte, pruebas y respaldo de propiedad. Revisar agentes sin propietario informado.</td><td>agentes.csv; propietario y creador son campos distintos. Campos vacios requieren confirmacion.</td></tr>
<tr><td>FinOps / licenciamiento</td><td>Presupuesto por entorno y responsable; revisar consumo semanal; proponer alertas 50/80/100%; revisar PAYG y reglas de sobreconsumo antes de aprobar gasto.</td><td>Licencias, planes, CopilotCredits y disponibilidad por entorno. Alertas no son topes de gasto; disponibilidad para asignar no es consumo restante. No calcular costo multiplicando conversaciones por una tarifa fija.</td></tr>
<tr><td>Operaciones / SOC</td><td>Validar Purview y retencion, supervisar fallos y consumo, probar alertas y respuesta a incidentes. Revision mensual y ante cada publicacion.</td><td>Conservar exportaciones PPAC con periodo y fecha de actualizacion; confirmar integraciones, retencion y licencias disponibles.</td></tr></table>
<p>Prioridad inicial: cerrar fuentes no obtenidas; reconciliar bots clasicos y agentes M365; confirmar propietarios, autenticacion y publicacion; validar DLP y permisos efectivos; aprobar presupuesto y procedimiento de paso a produccion.</p>
<p>Las evidencias JSON conservan el detalle original de las respuestas. Los CSV neutralizan formulas de Excel. Consultar GUIA.txt para limitaciones, permisos y referencias oficiales.</p></body></html>
"@
[IO.File]::WriteAllText((Join-Path $script:runPath 'informe.html'),$html,(New-Object Text.UTF8Encoding($true)))
# Hashes de integridad de todos los archivos existentes, sin incluir el manifiesto.
$hashes = @(Get-ChildItem -LiteralPath $script:runPath -File -Recurse | ForEach-Object {
    [pscustomobject]@{ Archivo=$_.FullName.Substring($script:runPath.Length+1); SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
Save-Csv 'manifiesto-sha256' $hashes
$script:ppToken = $null
Write-Host "Levantamiento finalizado. Revisar cobertura.csv antes de interpretar los datos: $script:runPath"
[pscustomobject]@{ Carpeta=$script:runPath; Informe=(Join-Path $script:runPath 'informe.html'); AgentesObtenidos=$agents.Count; Pendientes=$unknown }
