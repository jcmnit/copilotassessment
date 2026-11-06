function Assert-SharePointUrl([string]$Url,[switch]$Admin) {
    $u=[uri]$Url
    if (-not $u.IsAbsoluteUri -or $u.Scheme -ne 'https' -or $u.UserInfo -or $u.Port -ne 443 -or $u.Query -or $u.Fragment -or $u.Host -notmatch '^[a-zA-Z0-9-]+\.sharepoint\.com$') {throw 'URL SharePoint comercial no valida.'}
    if ($Admin -and ($u.Host -notmatch '-admin\.sharepoint\.com$' -or $u.AbsolutePath -ne '/')) {throw 'Indicar la URL del centro de administracion SharePoint.'}
}
# El contexto interactivo se utiliza SOLO para obtener el token inicial. Ningun
# cmdlet de inventario recibe ese contexto: podria abrir el navegador al renovar.
function Connect-AssessmentSharePoint([string]$Url) {
    Assert-Deadline
    Assert-SharePointUrl $Url
    if ($script:spoAuthStopped) {throw [Security.Authentication.AuthenticationException]::new('Autenticacion SharePoint detenida; no se reintentara interactivamente.')}
    try {
        if (-not $script:spoToken) {
            if ($NoInteractive -or $script:spoInteractiveAttempts -ge 1) {throw 'No se permite otro inicio interactivo de SharePoint.'}
            $script:spoInteractiveAttempts++ # Contar antes: cancelaciones tambien consumen el intento.
            $interactive=Connect-PnPOnline -Url $Url -Tenant $TenantId.ToString() -ClientId $SharePointClientId.ToString() -ReturnConnection -Interactive -ErrorAction Stop
            $script:spoToken=ConvertFrom-SensitiveValue (Get-PnPAccessToken -ResourceTypeName SharePoint -Connection $interactive -ErrorAction Stop)
            $interactive=$null
        }
        $claims=Read-TokenClaims $script:spoToken
        if ([string]$claims.tid -ne $TenantId.ToString() -or -not $claims.scp -or [double]$claims.exp -le ([datetimeoffset]::UtcNow.ToUnixTimeSeconds()+60)) {throw 'Token SharePoint caducado, no delegado o de otro tenant.'}
        $aud=[string]$claims.aud
        if ($aud -ne '00000003-0000-0ff1-ce00-000000000000' -and $aud.TrimEnd('/') -ne ('https://'+([uri]$Url).Host)) {throw 'Audiencia SharePoint no admitida para el sitio.'}
        # AccessToken no dispone de fallback interactivo ni de renovacion automatica.
        return Connect-PnPOnline -Url $Url -AccessToken $script:spoToken -ReturnConnection -ErrorAction Stop
    } catch {
        $script:spoAuthStopped=$true
        throw [Security.Authentication.AuthenticationException]::new('No se pudo reutilizar la autenticacion SharePoint. Bloque detenido sin nuevos inicios de sesion.')
    } finally {$claims=$null}
}
function Test-SpoAuthenticationFailure($Record) {
    $exception=$Record.Exception
    while ($exception) {
        if ($exception -is [Security.Authentication.AuthenticationException] -or $exception.GetType().Name -match 'Msal.*(UiRequired|Client|Service)Exception') {return $true}
        $http=Get-Field $exception 'Response.StatusCode'
        if ($null -eq $http) {$http=Get-Field $exception 'ResponseStatusCode'}
        if ($null -ne $http -and [int]$http -eq 401) {return $true}
        $exception=$exception.InnerException
    }
    return $false # 403 de un sitio no autoriza a abrir otra sesion ni a cambiar permisos.
}
function Get-BroadPrincipal([string]$Login) {
    if ($Login -match 'spo-grid-all-users/') {return 'EveryoneExceptExternalUsers'}
    if ($Login -match '^c:0\(\.s\|true$') {return 'Everyone'}
    if ($Login -match '#ext#') {return 'GuestIdentity'}
    return 'SpecificPrincipal'
}
function Read-SpoRoleScope($Object,[string]$ScopeType,[string]$ScopeId,[string]$SiteUrl,$Connection) {
    Assert-Deadline
    $script:spoStage='LeerAsignaciones-'+$ScopeType
    $assignments=@(Get-PnPProperty -ClientObject $Object -Property RoleAssignments -Connection $Connection -ErrorAction Stop)
    foreach ($assignment in $assignments) {
        $null=Get-PnPProperty -ClientObject $assignment -Property Member,RoleDefinitionBindings -Connection $Connection -ErrorAction Stop
        $principal=$assignment.Member
        $null=Get-PnPProperty -ClientObject $principal -Property Id,LoginName,PrincipalType -Connection $Connection -ErrorAction Stop
        foreach ($definition in $assignment.RoleDefinitionBindings) {$null=Get-PnPProperty -ClientObject $definition -Property Name,BasePermissions,RoleTypeKind -Connection $Connection -ErrorAction Stop}
        $roles=@($assignment.RoleDefinitionBindings | ForEach-Object {$_.Name}) -join ';'
        $roleKinds=@($assignment.RoleDefinitionBindings | ForEach-Object {[string]$_.RoleTypeKind})
        # Limited Access no prueba acceso al contenido: conservarlo, sin elevarlo a exposicion.
        $contentAccess=@($assignment.RoleDefinitionBindings | Where-Object {$_.BasePermissions.Has([Microsoft.SharePoint.Client.PermissionKind]::ViewListItems)}).Count -gt 0
        $script:spoPermissions.Add([pscustomobject]@{SiteUrl=$SiteUrl;WebUrl=$Connection.Url;ScopeType=$ScopeType;ScopeId=$ScopeId;PrincipalId=[string]$principal.Id;Principal=$principal.LoginName;PrincipalType=[string]$principal.PrincipalType;ViaGrupo='';Roles=$roles;AccesoContenido=$contentAccess;Audiencia=(Get-BroadPrincipal $principal.LoginName)})
        if ([string]$principal.PrincipalType -eq 'SharePointGroup') {
            $groupKey="$SiteUrl|$($principal.Id)"
            if (-not $script:spoGroupCache.ContainsKey($groupKey)) {
                $script:spoGroupCache[$groupKey]=@(Get-PnPGroupMember -Group $principal.Id -Connection $Connection -ErrorAction Stop)
            }
            foreach ($member in $script:spoGroupCache[$groupKey]) {
                $script:spoPermissions.Add([pscustomobject]@{SiteUrl=$SiteUrl;WebUrl=$Connection.Url;ScopeType=$ScopeType;ScopeId=$ScopeId;PrincipalId=[string]$member.Id;Principal=$member.LoginName;PrincipalType=[string]$member.PrincipalType;ViaGrupo=$principal.LoginName;Roles=$roles;AccesoContenido=$contentAccess;Audiencia=(Get-BroadPrincipal $member.LoginName)})
            }
        }
    }
}
function Read-SpoSharingLinks($Item,[string]$SiteUrl,$Connection) {
    $path=[string]$Item.FieldValues.FileRef
    if (-not $path) {throw [IO.InvalidDataException]::new('Item sin FileRef.')}
    $script:spoStage='LeerEnlaces'
    $links=@()
    if ([int]$Item.FieldValues.FSObjType -eq 1) {$links=@(Get-PnPFolderSharingLink -Folder $path -Connection $Connection -ErrorAction Stop)}
    else {$links=@(Get-PnPFileSharingLink -Identity $path -Connection $Connection -ErrorAction Stop)}
    foreach ($permission in $links) {
        # Nunca exportar WebUrl del enlace de comparticion, tokens, redemption URLs o contrasenas.
        $scope=Get-Field $permission 'Link.Scope'
        if (-not $scope) {throw [IO.InvalidDataException]::new('Enlace sin scope.')}
        $expiry=$permission.ExpirationDateTime
        $expiration=if ($expiry -is [datetimeoffset]) {$expiry.ToString('o')} elseif ($expiry -is [datetime]) {$expiry.ToUniversalTime().ToString('o')} else {[string]$expiry}
        $script:spoLinks.Add([pscustomobject]@{SiteUrl=$SiteUrl;ScopeId=$path;PermissionId=$permission.Id;Scope=[string]$scope;Type=[string](Get-Field $permission 'Link.Type');Expiration=$expiration;Roles=(@($permission.Roles)-join ';')})
    }
}
function Read-SharePointSite([string]$SiteUrl,[string]$SourceId) {
    $permissionStart=$script:spoPermissions.Count;$linkStart=$script:spoLinks.Count
    $itemsRead=0;$uniqueRead=0;$complete=$false
    try {
        $script:spoStage='ConectarSitio'
        $connection=Connect-AssessmentSharePoint $SiteUrl
        $script:spoStage='LeerWeb'
        $web=Get-PnPWeb -Includes Url,HasUniqueRoleAssignments -Connection $connection -ErrorAction Stop
        $script:spoStage='EnumerarSubwebs'
        $subwebs=@(Get-PnPSubWeb -Recurse -Includes Url -Connection $connection -ErrorAction Stop)
        if ($subwebs.Count -gt $MaxSubWebsPerSite) {throw [OperationCanceledException]::new('Limite de subwebs superado.')}
        $webUrls=@($web.Url)+@($subwebs | ForEach-Object {$_.Url})
        foreach ($webUrl in $webUrls) {
            Assert-Deadline
            if ($webUrl -ne $web.Url) {$connection=Connect-AssessmentSharePoint $webUrl}
            $currentWeb=Get-PnPWeb -Includes Url,HasUniqueRoleAssignments -Connection $connection -ErrorAction Stop
            Read-SpoRoleScope $currentWeb 'Web' $webUrl $SiteUrl $connection
            $script:spoStage='EnumerarListas'
            $lists=@(Get-PnPList -Includes Hidden,HasUniqueRoleAssignments,RootFolder,ItemCount,BaseType -Connection $connection -ErrorAction Stop)
            foreach ($list in $lists) {
                if ($list.Hidden) {continue}
                if ($list.HasUniqueRoleAssignments) {
                    $uniqueRead++
                    if ($uniqueRead -gt $MaxUniqueScopesPerSite) {throw [OperationCanceledException]::new('Limite de permisos unicos superado.')}
                    Read-SpoRoleScope $list 'List' ([string]$list.Id) $SiteUrl $connection
                }
                # Procesamiento streaming: no materializar toda la biblioteca antes de aplicar el limite.
                $script:spoStage='LeerMetadatosItems'
                Get-PnPListItem -List $list.Id -PageSize 200 -Fields FileRef,FileLeafRef,FSObjType -Connection $connection -ErrorAction Stop | ForEach-Object {
                    Assert-Deadline
                    if ($itemsRead -ge $MaxItemsPerSite) {throw [OperationCanceledException]::new('Limite de items superado.')}
                    $itemsRead++
                    $item=$_
                    $null=Get-PnPProperty -ClientObject $item -Property HasUniqueRoleAssignments -Connection $connection -ErrorAction Stop
                    if ($item.HasUniqueRoleAssignments) {
                        $uniqueRead++
                        if ($uniqueRead -gt $MaxUniqueScopesPerSite) {throw [OperationCanceledException]::new('Limite de permisos unicos superado.')}
                        Read-SpoRoleScope $item 'Item' ([string]$item.FieldValues.FileRef) $SiteUrl $connection
                    }
                    if ([string]$list.BaseType -eq 'DocumentLibrary') {Read-SpoSharingLinks $item $SiteUrl $connection}
                }
            }
        }
        $complete=$true
        [pscustomobject]@{SiteUrl=$SiteUrl;ItemsRevisados=$itemsRead;PermisosUnicos=$uniqueRead;WebsRevisadas=$webUrls.Count;Alcance='Webs, listas visibles e items; sin contenido de documentos ni sitios OneDrive';Completo=$true}
    } catch {
        if (Test-SpoAuthenticationFailure $_) {$script:spoAuthStopped=$true}
        throw
    } finally {
        $permissions=@($script:spoPermissions | Select-Object -Skip $permissionStart)
        $links=@($script:spoLinks | Select-Object -Skip $linkStart)
        foreach ($row in @($permissions)+@($links)) {$row | Add-Member -NotePropertyName CoberturaSitio -NotePropertyValue $(if ($complete) {'CompletaEnAlcance'} else {'Parcial'}) -Force}
        Save-Json ($SourceId+'-permisos') ([ordered]@{SiteUrl=$SiteUrl;Completo=$complete;ItemsRevisados=$itemsRead;Registros=$permissions})
        Save-Json ($SourceId+'-enlaces') ([ordered]@{SiteUrl=$SiteUrl;Completo=$complete;Registros=$links})
    }
}
function Collect-SharePoint {
    $script:spoInteractiveAttempts=0;$script:spoAuthStopped=$false;$script:spoToken=$null
    try { Collect-SharePointCore } finally {$script:spoToken=$null}
}
function Collect-SharePointCore {
    $script:spoPermissions=[Collections.Generic.List[object]]::new()
    $script:spoLinks=[Collections.Generic.List[object]]::new()
    $script:spoGroupCache=@{}
    if ($SkipSharePoint) {Add-Status 'SharePointInventario' 'Omitido' 0 'SkipSharePoint solicitado.';return}
    if (-not $SharePointAdminUrl -or $SharePointClientId -eq [guid]::Empty) {Add-Status 'SharePointInventario' 'No obtenido' 0 'Requiere SharePointAdminUrl y SharePointClientId de aplicacion ya autorizada. No se deduce el hostname del dominio Entra.';return}
    $sites=@(Collect 'SharePointInventario' {
        Import-Module PnP.PowerShell -ErrorAction Stop
        $script:spoStage='InventarioAdministrativo'
        Assert-SharePointUrl $SharePointAdminUrl -Admin
        $admin=Connect-AssessmentSharePoint $SharePointAdminUrl
        $tenantSettings=Get-PnPTenant -Connection $admin -ErrorAction Stop
        Save-Json 'SharePointTenantSettings' ([pscustomobject]@{SharingCapability=[string]$tenantSettings.SharingCapability;DefaultSharingLinkType=[string]$tenantSettings.DefaultSharingLinkType;RequireAnonymousLinksExpireInDays=$tenantSettings.RequireAnonymousLinksExpireInDays;SharingDomainRestrictionMode=[string]$tenantSettings.SharingDomainRestrictionMode;SharingAllowedDomainList=$tenantSettings.SharingAllowedDomainList;SharingBlockedDomainList=$tenantSettings.SharingBlockedDomainList})
        foreach ($site in (Get-PnPTenantSite -Detailed -Connection $admin -ErrorAction Stop)) {
            [pscustomobject]@{Url=$site.Url;Title=$site.Title;Owner=$site.Owner;Template=$site.Template;GroupId=[string]$site.GroupId;SharingCapability=[string]$site.SharingCapability;DisableCompanyWideSharingLinks=[string]$site.DisableCompanyWideSharingLinks;SensitivityLabel=[string]$site.SensitivityLabel;LockState=[string]$site.LockState;LastContentModifiedDate=[string]$site.LastContentModifiedDate}
        }
    })
    Save-Csv 'sharepoint-sitios' $sites
    if ($script:spoAuthStopped) {Add-Status 'SharePointAutenticacion' 'No obtenido' 0 'Autenticacion no disponible; bloque detenido sin nuevos intentos.';return}
    if ($PreflightOnly) {return}
    $selected=@($sites | Where-Object {-not $SharePointSiteUrls.Count -or $_.Url.TrimEnd('/') -in @($SharePointSiteUrls | ForEach-Object {$_.TrimEnd('/')})})
    if ($SharePointSiteUrls.Count) {
        foreach ($url in $SharePointSiteUrls) {if ($url.TrimEnd('/') -notin @($sites | ForEach-Object {$_.Url.TrimEnd('/')})) {Add-Status 'SharePointSitioSolicitado' 'No obtenido' 0 'Un sitio solicitado no aparece en el inventario administrativo.'}}
        Add-Status 'SharePointAlcanceTenant' 'Validacion manual' $selected.Count 'Muestra explicita; no representa evaluacion de permisos de todo el tenant.'
    }
    if ($selected.Count -gt $MaxSites) {Add-Status 'SharePointLimiteSitios' 'LimiteAlcance' $selected.Count 'Se revisara solo MaxSites; inventario de sitios conservado.'}
    $index=0
    foreach ($site in ($selected | Select-Object -First $MaxSites)) {
        $index++;$source='SharePointPermisos-{0:D4}' -f $index
        $null=Collect $source {Read-SharePointSite $site.Url $source}
        if ($script:spoAuthStopped) {
            Add-Status 'SharePointAutenticacion' 'No obtenido' 0 'Sesion no reutilizable; se detiene el recorrido. Sitios restantes sin evaluar. No se abre otra ventana de autenticacion.'
            break
        }
    }
    Save-Csv 'sharepoint-permisos' $script:spoPermissions.ToArray()
    Save-Csv 'sharepoint-enlaces' $script:spoLinks.ToArray()
    Add-Status 'SharePointAccesoEfectivo' 'Validacion manual' 0 'Permisos observados no prueban sobreexposicion de informacion sensible. Grupos Entra anidados, restricciones de acceso, etiquetas, listas ocultas y comparticion especifica requieren validacion. No se cambia SCA ni se abre contenido.'
}
