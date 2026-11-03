$agents = @(); $environments = @(); $envGroups = @(); $credits = @(); $billing = @(); $skus = @(); $dlp = @(); $paEnvironments = @()
if ($script:ppToken) {
    $agents = @(Collect 'Agentes' { Read-Inventory 'microsoft.copilotstudio/agents' $(if ($PreflightOnly) {1} else {1000}) })
    $environments = @(Collect 'Entornos' { Read-Inventory 'microsoft.powerplatform/environments' $(if ($PreflightOnly) {1} else {1000}) })
    $envGroups = @(Collect 'GruposEntornos' { Read-Inventory 'microsoft.powerplatform/environmentgroups' $(if ($PreflightOnly) {1} else {1000}) })
    $billing = @(Collect 'PlanesFacturacion' { Read-Pages PowerPlatform 'https://api.powerplatform.com/licensing/billingPolicies?api-version=2024-10-01' })
    $credits = @(Collect 'CopilotCredits' { Read-Object PowerPlatform 'https://api.powerplatform.com/licensing/entitlements/MCSMessages?api-version=2024-10-01' @('entitlementId') })
    foreach ($env in $environments) {
        $envId = [string]$env.name
        if ($envId -notmatch '^(Default-)?[0-9a-fA-F-]{36}$') { Add-Status "Disponibilidad-$envId" 'Omitido' 0 'Identificador de entorno no reconocido.'; continue }
        $filter = [uri]::EscapeDataString("environmentId eq '$envId' and EntitlementId in ('MCSMessages')")
        $null = Collect "Disponibilidad-$envId" { Read-Object PowerPlatform ("https://api.powerplatform.com/licensing/allocationsV2/availability?api-version=2024-10-01&`$filter=$filter") @('entitlementAllocationsAvailable') }
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
    if ($IncludeLicensedUsers -and -not $PreflightOnly) {
        $null = Collect 'UsuariosLicencias' { Read-Pages Graph 'https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,accountEnabled,assignedLicenses,assignedPlans,licenseAssignmentStates&$top=999' }
    } else { Add-Status 'UsuariosLicencias' 'Omitido' 0 'Detalle individual optativo: IncludeLicensedUsers. Se exportan todos los usuarios para revisar asignaciones.' }
}

if (-not $SkipPowerApps) {
    try {
        if ($NoInteractive) { throw 'PowerApps requiere login verificado; NoInteractive omite esta fuente.' }
        try {Import-Module Microsoft.PowerApps.Administration.PowerShell -ErrorAction Stop}
        catch {
            if (-not $IsWindows) {throw}
            Import-Module Microsoft.PowerApps.Administration.PowerShell -UseWindowsPowerShell -ErrorAction Stop
        }
        $null = Add-PowerAppsAccount -TenantID $TenantId.ToString() -ErrorAction Stop
        $defaultEnvironment=@(Get-AdminPowerAppEnvironment -Default -ErrorAction Stop)
        if ($defaultEnvironment.Count -ne 1 -or $defaultEnvironment[0].EnvironmentName -ne ('Default-'+$TenantId.ToString())) { throw 'No se pudo verificar independientemente el tenant PowerApps.' }
        Add-Status 'AutenticacionPowerApps' 'Obtenido' 1 'Tenant comprobado mediante el identificador del entorno predeterminado.'
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

Save-Csv 'agentes' $agentRows
Save-Csv 'licencias' $skuRows
Save-Csv 'planes-facturacion' $billing
$ownerIds=@($agentRows | ForEach-Object {$_.PropietarioId;$_.CreadorId} | Where-Object {$_ -match '^[0-9a-fA-F-]{36}$'} | Select-Object -Unique)
if ($script:graphReady -and -not $PreflightOnly) {
    $resolved=@(foreach ($ownerId in $ownerIds) {
        Collect "Identidad-$ownerId" {
            Read-Object Graph "https://graph.microsoft.com/v1.0/users/$ownerId`?`$select=id,displayName,userPrincipalName,accountEnabled,userType" @('id')
        }
    })
    # Cada identidad se conserva por separado; una identidad de grupo/app o eliminada requiere conciliacion.
}

if ($resolved) { Save-Csv 'identidades-agentes' $resolved }
