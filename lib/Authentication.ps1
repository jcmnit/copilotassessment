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
    $scopes = @('LicenseAssignment.Read.All','RoleManagement.Read.Directory','Policy.Read.All','Group.Read.All','Organization.Read.All','Reports.Read.All','ReportSettings.Read.All','User.Read.All','RoleEligibilitySchedule.Read.Directory','RoleAssignmentSchedule.Read.Directory')
    if ($IncludeLicensedUsers) { $scopes += 'User.Read.All' }
    if ($IncludeGroupMembers) { $scopes += 'GroupMember.Read.All' }
    $login = @{ Scopes=$scopes; ContextScope='Process'; NoWelcome=$true; ErrorAction='Stop' }
    if ($TargetTenant -ne [guid]::Empty) { $login.TenantId = $TargetTenant.ToString() }
    if ($GraphClientId -ne [guid]::Empty) { $login.ClientId = $GraphClientId.ToString() }
    Write-Host 'Inicie sesion en Microsoft Graph con la cuenta del tenant que desea levantar.'
    $null = Connect-MgGraph @login
    Set-MgRequestContext -ClientTimeout $RequestTimeoutSeconds -ErrorAction Stop
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


$graphModuleReady = $false; $azModuleReady = $false; $ctx = $null; $azContext = $null
if (-not $SkipGraph) {
    try { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop; $graphModuleReady = $true; $ctx = Get-MgContext }
    catch { Add-Status 'ModuloGraph' 'No obtenido' 0 'Preparar Microsoft.Graph.Authentication; no se instala automaticamente.' }
}
if (-not $SkipPowerPlatform -and -not $PowerPlatformAccessToken -and $PowerPlatformClientId -eq [guid]::Empty) {
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
$script:authentication.OrigenTenant='Parametro TenantId obligatorio'
$script:authentication.TenantId = $TenantId.ToString()
Write-Host ("Tenant seleccionado: {0} ({1})" -f $TenantId,$script:authentication.OrigenTenant)

if (-not $SkipGraph) {
    try {
        if (-not $graphModuleReady) { throw 'Modulo Graph no disponible.' }
        if (-not $ctx -or $ctx.TenantId -ne $TenantId.ToString() -or $ctx.Environment -ne 'Global' -or
            ($GraphClientId -ne [guid]::Empty -and $ctx.ClientId -ne $GraphClientId.ToString())) { $ctx = Connect-AssessmentGraph $TenantId }
        if (-not $ctx -or $ctx.TenantId -ne $TenantId.ToString() -or $ctx.Environment -ne 'Global' -or $ctx.AuthType -ne 'Delegated' -or ($GraphClientId -ne [guid]::Empty -and $ctx.ClientId -ne $GraphClientId.ToString())) { throw 'Sesion Graph ausente o de otro tenant/nube.' }
        Set-MgRequestContext -ClientTimeout $RequestTimeoutSeconds -ErrorAction Stop
        $script:authentication.GraphClientId = $ctx.ClientId
        $script:authentication.GraphScopes = @($ctx.Scopes)
        $script:graphReady = $true
        Add-Status 'AutenticacionGraph' 'Obtenido' 1 'Tenant y nube verificados. ClientId obtenido de la sesion; no se crea una aplicacion.'
    } catch { Add-Status 'AutenticacionGraph' 'No obtenido' 0 'Revisar sesion, modulo, permisos previamente autorizados y politica de acceso a Graph. No se crea una app ni concede consentimiento.' }
} else { Add-Status 'AutenticacionGraph' 'Omitido' 0 'SkipGraph solicitado.' }
if (-not $SkipPowerPlatform) {
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
} else { Add-Status 'AutenticacionPowerPlatform' 'Omitido' 0 'SkipPowerPlatform solicitado.' }
Save-Json 'autenticacion' $script:authentication
