function Get-DataverseToken([string]$Origin) {
    $token=$script:dataverseTokens[$Origin]
    $valid=$false
    if ($token) {
        $claims=Read-TokenClaims $token
        $valid=[string]$claims.tid -eq $TenantId.ToString() -and [double]$claims.exp -gt ([datetimeoffset]::UtcNow.ToUnixTimeSeconds()+60)
    }
    if (-not $valid) {
        $ctx=Get-AzContext
        if ((Get-Field $ctx 'Tenant.Id') -ne $TenantId.ToString() -or (Get-Field $ctx 'Account.Type') -ne 'User') {
            if ($NoInteractive) {throw 'Dataverse requiere sesion de usuario del tenant esperado.'}
            $ctx=Connect-AssessmentAzure $TenantId
        }
        if ((Get-Field $ctx 'Tenant.Id') -ne $TenantId.ToString() -or (Get-Field $ctx 'Account.Type') -ne 'User') {throw 'Sesion Azure cruzada.'}
        $auth=Get-AzAccessToken -ResourceUrl $Origin -TenantId $TenantId.ToString() -ErrorAction Stop
        $token=ConvertFrom-SensitiveValue $auth.Token
        $auth=$null
        $claims=Read-TokenClaims $token
        if ([string]$claims.tid -ne $TenantId.ToString() -or -not $claims.scp -or ([string]$claims.aud).TrimEnd('/') -ne $Origin.TrimEnd('/') -or [double]$claims.exp -le ([datetimeoffset]::UtcNow.ToUnixTimeSeconds()+60)) {throw 'Token Dataverse incompatible.'}
        $script:dataverseTokens[$Origin]=$token
    }
    return $token
}
function Collect-Dataverse {
    $script:dataverseTokens=@{}
    if ($SkipDataverse) {Add-Status 'DataverseRoles' 'Omitido' 0 'SkipDataverse solicitado; permisos pendientes.';return}
    $rows=[Collections.Generic.List[object]]::new()
    $envs=@($paEnvironments | Where-Object {Get-Field $_ 'Internal.properties.linkedEnvironmentMetadata.instanceUrl'})
    if (-not $envs.Count) {
        $complete=@($script:status | Where-Object {$_.Fuente -eq 'EntornosAdministracion' -and $_.Estado -eq 'Obtenido'}).Count -gt 0
        Add-Status 'DataverseRoles' $(if ($complete) {'Obtenido'} else {'No obtenido'}) 0 'No se identificaron entornos Dataverse en la fuente administrativa; revisar cobertura de dicha fuente.'
        return
    }
    foreach ($environment in $envs) {
        $environmentId=[string]$environment.EnvironmentName
        $origin=([string](Get-Field $environment 'Internal.properties.linkedEnvironmentMetadata.instanceUrl')).TrimEnd('/')
        $source='Dataverse-'+$environmentId
        $null=Collect $source {
            $uri=[uri]$origin
            if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Port -ne 443 -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or $uri.Host -notmatch '^[a-zA-Z0-9-]+\.crm[0-9]*\.dynamics\.com$') {throw 'URL Dataverse comercial no admitida.'}
            Import-Module Az.Accounts -ErrorAction Stop
            $null=Get-DataverseToken $origin
            $base=$origin+'/api/data/v9.2'
            $null=Read-Object Dataverse ($base+'/WhoAmI') @('UserId','OrganizationId')
            $users=@(Read-Pages Dataverse ($base+'/systemusers?$select=systemuserid,fullname,domainname,isdisabled,azureactivedirectoryobjectid,applicationid,accessmode'))
            Save-Json ($source+'-usuarios') $users
            $teams=@(Read-Pages Dataverse ($base+'/teams?$select=teamid,name,teamtype,azureactivedirectoryobjectid,_businessunitid_value'))
            Save-Json ($source+'-equipos') $teams
            $roles=@(Read-Pages Dataverse ($base+'/roles?$select=roleid,name,_businessunitid_value,_parentrootroleid_value'))
            Save-Json ($source+'-roles') $roles
            $bots=@(Read-Pages Dataverse ($base+'/bots?$select=botid,name,_ownerid_value,statecode,statuscode'))
            Save-Json ($source+'-agentes') $bots
            if ($PreflightOnly) {return [pscustomobject]@{EntornoId=$environmentId;Modo='Preflight';Roles=$roles.Count}}
            if (($users.Count+$teams.Count) -gt $MaxDataversePrincipals) {throw [OperationCanceledException]::new('Limite de principales Dataverse superado. Metadatos conservados; no se afirma censo de asignaciones.')}
            foreach ($user in $users) {
                if ([string]$user.systemuserid -notmatch '^[0-9a-fA-F-]{36}$') {throw [IO.InvalidDataException]::new('Identificador de usuario Dataverse invalido.')}
                foreach ($role in @(Read-Pages Dataverse ("$base/systemusers($($user.systemuserid))/systemuserroles_association?`$select=roleid,name"))) {
                    $rows.Add([pscustomobject]@{EntornoId=$environmentId;PrincipalId=$user.systemuserid;EntraObjectId=$user.azureactivedirectoryobjectid;Nombre=$user.fullname;Tipo='UsuarioDirecto';RoleId=$role.roleid;RoleName=$role.name})
                }
            }
            foreach ($team in $teams) {
                if ([string]$team.teamid -notmatch '^[0-9a-fA-F-]{36}$') {throw [IO.InvalidDataException]::new('Identificador de equipo Dataverse invalido.')}
                foreach ($role in @(Read-Pages Dataverse ("$base/teams($($team.teamid))/teamroles_association?`$select=roleid,name"))) {
                    $rows.Add([pscustomobject]@{EntornoId=$environmentId;PrincipalId=$team.teamid;EntraObjectId=$team.azureactivedirectoryobjectid;Nombre=$team.name;Tipo='Equipo';RoleId=$role.roleid;RoleName=$role.name})
                }
                $members=@(Read-Pages Dataverse ("$base/teams($($team.teamid))/teammembership_association?`$select=systemuserid,fullname,azureactivedirectoryobjectid"))
                Save-Json ($source+'-equipo-'+$team.teamid) $members
            }
            [pscustomobject]@{EntornoId=$environmentId;Usuarios=$users.Count;Equipos=$teams.Count;Roles=$roles.Count;Agentes=$bots.Count;Nota='Roles y miembros observados; sin prueba de autorizacion, privilegios efectivos ni acceso a tablas/fuentes.'}
        }
        $state=@($script:status | Where-Object Fuente -eq $source | Select-Object -Last 1).Estado
        foreach ($row in $rows | Where-Object EntornoId -eq $environmentId) {$row | Add-Member -NotePropertyName CoberturaEntorno -NotePropertyValue $state -Force}
    }
    Save-Csv 'dataverse-asignaciones' $rows.ToArray()
    Save-Json 'DataverseAsignaciones' $rows.ToArray()
    $success=@($script:status | Where-Object {$_.Fuente -like 'Dataverse-*' -and $_.Estado -eq 'Obtenido'}).Count
    Add-Status 'DataverseRoles' $(if ($success -eq $envs.Count) {'Obtenido'} else {'No obtenido'}) $success 'Consultar cobertura individual y metadatos por entorno; asignaciones parciales identificadas.'
    Add-Status 'DataverseAccesoEfectivo' 'Validacion manual' 0 'Validar comparticion por agente, privilegios/profundidad, unidades de negocio, equipos Entra dinamicos y acceso a tablas y fuentes. Los roles no acreditan permisos efectivos.'
}
