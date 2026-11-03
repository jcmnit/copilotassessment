function Get-Field($Object, [string]$Path) {
    $value = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $value) { return $null }
        if ($value -is [Collections.IDictionary]) { $value = $value[$part] }
        else { $value = $value.$part }
    }
    return ,$value
}
function Has-Field($Object, [string]$Name) {
    if ($null -eq $Object) { return $false }
    if ($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}
function Save-Json([string]$Name, $Data) {
    if ($Name -notmatch '^[\w.-]+$') { throw 'Nombre de evidencia no permitido.' }
    $path = Join-Path $script:evidencePath ($Name + '.json')
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Data -Depth 100), [Text.UTF8Encoding]::new($true))
}
function Save-Csv([string]$Name, $Rows) {
    $items = @($Rows)
    if (-not $items.Count) { return }
    $safe = foreach ($row in $items) {
        $copy = [ordered]@{TenantId=$TenantId.ToString();RunId=$script:runId;CapturadoUTC=$script:started.ToString('o');ModoEjecucion=$script:execution.Modo}
        foreach ($p in $row.PSObject.Properties) {
            if ($copy.Contains($p.Name)) { continue }
            $v = $p.Value
            if ($v -is [string] -and $v -match '^\s*[=+@-]') { $v = "'" + $v }
            $copy[$p.Name] = $v
        }
        [pscustomobject]$copy
    }
    $safe | Export-Csv -LiteralPath (Join-Path $script:runPath ($Name+'.csv')) -NoTypeInformation -Encoding utf8BOM
}
function Add-Status([string]$Name, [string]$State, [int]$Count, [string]$Detail) {
    $script:status.Add([pscustomobject]@{TenantId=$TenantId.ToString();RunId=$script:runId;Fuente=$Name;Estado=$State;Registros=$Count;Detalle=$Detail;UTC=[datetime]::UtcNow.ToString('o')})
}
function Get-SafeError($Record) {
    $http = Get-Field $Record.Exception 'Response.StatusCode'
    if ($null -eq $http) { $http = Get-Field $Record.Exception 'ResponseStatusCode' }
    if ($null -ne $http) {try {$http=[int]$http} catch {$http=$null}}
    $kind = 'ErrorDeServicio'
    if ($Record.Exception -is [IO.InvalidDataException]) { $kind='ErrorDeEsquema' }
    if ($Record.Exception -is [TimeoutException]) { $kind='TiempoAgotado' }
    if ($Record.Exception -is [OperationCanceledException]) { $kind='LimiteAlcance' }
    if ($http -in @(401,403)) { $kind='SinPermiso' }
    $requestId = Get-Field $Record.Exception 'Response.Headers.request-id'
    if ($requestId -and [string]$requestId -notmatch '^[a-zA-Z0-9-]{1,100}$') { $requestId=$null }
    # No se persisten Message, cuerpos, Location ni enlaces de descarga autenticados.
    [pscustomobject]@{Estado=$kind;HTTP=[string]$http;Tipo=$Record.Exception.GetType().Name;RequestId=[string]$requestId}
}
function Assert-Deadline {
    if ([datetime]::UtcNow -gt $script:deadline) { throw [TimeoutException]::new('Tiempo global agotado.') }
}
function Collect([string]$Name, [scriptblock]$Action) {
    $script:activeSource=$Name
    $script:sourcePages=0
    $script:querySequence=0
    Write-Host "Consultando $Name ..."
    try {
        Assert-Deadline
        $rows = @(& $Action)
        Save-Json $Name $rows
        Add-Status $Name 'Obtenido' $rows.Count 'Consulta completa dentro del alcance de esta fuente. Una coleccion vacia valida no es un error.'
        return $rows
    } catch {
        $e = Get-SafeError $_
        $script:diagnostics.Add([pscustomobject]@{Fuente=$Name;HTTP=$e.HTTP;Tipo=$e.Tipo;RequestId=$e.RequestId;PaginasRecuperadas=$script:sourcePages;UTC=[datetime]::UtcNow.ToString('o')})
        Add-Status $Name $e.Estado 0 ("HTTP={0}; tipo={1}; paginas conservadas={2}. No equivale a cero recursos; revisar diagnostico y permisos." -f $e.HTTP,$e.Tipo,$script:sourcePages)
        Write-Warning "$Name incompleto: $($e.Estado)."
        return @()
    } finally { $script:activeSource=$null }
}
function Assert-ReadRequest([string]$Service, [string]$Method, [string]$Url) {
    $u=[uri]$Url
    if (-not $u.IsAbsoluteUri -or $u.Scheme -ne 'https' -or $u.UserInfo -or $u.Port -ne 443 -or $u.Fragment) { throw 'URI no permitida.' }
    if ($Service -eq 'Graph') {
        $allowed = @(
            '^/v1\.0/(organization|subscribedSkus|users)$',
            '^/v1\.0/users/[0-9a-fA-F-]{36}$',
            '^/v1\.0/groups/[0-9a-fA-F-]{36}(/(owners|transitiveMembers))?$',
            '^/v1\.0/roleManagement/directory/(roleAssignments|roleDefinitions|roleEligibilityScheduleInstances|roleAssignmentScheduleInstances)$',
            '^/v1\.0/identity/conditionalAccess/policies$',
            '^/v1\.0/admin/reportSettings$',
            "^/v1\.0/copilot/reports/getMicrosoft365Copilot(UsageUserDetail|UserCountSummary|UserCountTrend)\(period='D(7|28|90|180)',version='v2'\)$"
        )
        if ($u.Host -ne 'graph.microsoft.com' -or $Method -ne 'GET' -or -not @($allowed | Where-Object {$u.AbsolutePath -match $_}).Count) { throw 'Consulta Graph fuera de la lista de lectura.' }
    } elseif ($Service -eq 'PowerPlatform') {
        if ($u.Host -ne 'api.powerplatform.com') { throw 'Host no permitido.' }
        $query=$u.AbsolutePath -eq '/resourcequery/resources/query' -and $Method -eq 'POST'
        $read=$Method -eq 'GET' -and $u.AbsolutePath -match '^/licensing/(billingPolicies|entitlements/MCSMessages|allocationsV2/availability)(/|$)'
        if (-not ($query -or $read)) { throw 'Operacion fuera de la lista de lectura.' }
    } elseif ($Service -eq 'Dataverse') {
        $origin=$u.GetLeftPart([UriPartial]::Authority)
        if (-not $script:dataverseTokens.ContainsKey($origin) -or $Method -ne 'GET' -or $u.AbsolutePath -notmatch '^/api/data/v9\.2/(WhoAmI|systemusers|teams|roles|bots|systemusers\([0-9a-fA-F-]{36}\)/systemuserroles_association|teams\([0-9a-fA-F-]{36}\)/(teamroles_association|teammembership_association))$') {throw 'Consulta Dataverse fuera de la lista de lectura.'}
    } else { throw 'Servicio no permitido.' }
}
function Get-PowerPlatformToken {
    if (-not $script:ppToken) { throw 'Power Platform no disponible.' }
    try { $null=Assert-PowerPlatformToken $script:ppToken $TenantId }
    catch {
        if ($PowerPlatformAccessToken -or $PowerPlatformClientId -ne [guid]::Empty) { throw 'Token externo no renovable; repetir autenticacion.' }
        $context=Get-AzContext
        if ((Get-Field $context 'Tenant.Id') -ne $TenantId.ToString()) { throw 'Cambio de tenant Azure detectado.' }
        $newToken=Get-AzAccessToken -ResourceUrl 'https://api.powerplatform.com' -TenantId $TenantId.ToString() -ErrorAction Stop
        $script:ppToken=ConvertFrom-SensitiveValue $newToken.Token
        $newToken=$null
        $null=Assert-PowerPlatformToken $script:ppToken $TenantId
    }
    return $script:ppToken
}
function Invoke-Read([string]$Service, [string]$Url, [string]$Method='GET', $Body=$null, [string]$OutputFile) {
    Assert-ReadRequest $Service $Method $Url
    for ($attempt=0; $attempt -lt 4; $attempt++) {
        Assert-Deadline
        try {
            if ($Service -eq 'Graph') {
                if (-not $script:graphReady -or (Get-MgContext).TenantId -ne $TenantId.ToString()) { throw 'Sesion Graph de otro tenant o no disponible.' }
                if ($OutputFile) {
                    $null=Invoke-MgGraphRequest -Method GET -Uri $Url -OutputFilePath $OutputFile -ErrorAction Stop
                    $r=$null
                } else {$r=Invoke-MgGraphRequest -Method GET -Uri $Url -OutputType PSObject -ErrorAction Stop}
            } else {
                $token=if ($Service -eq 'Dataverse') {Get-DataverseToken ([uri]$Url).GetLeftPart([UriPartial]::Authority)} else {Get-PowerPlatformToken}
                $rest=@{Uri=$Url;Method=$Method;Headers=@{Authorization="Bearer $token"};TimeoutSec=$RequestTimeoutSeconds;MaximumRedirection=0;ErrorAction='Stop'}
                if ($Method -eq 'POST') { $rest.ContentType='application/json';$rest.Body=ConvertTo-Json -InputObject $Body -Depth 30 -Compress }
                $r=Invoke-RestMethod @rest
                $token=$null;$rest=$null
            }
            $script:requests.Add([pscustomobject]@{Fuente=$script:activeSource;Servicio=$Service;Metodo=$Method;Ruta=([uri]$Url).AbsolutePath;Resultado='OK';Intento=$attempt+1;UTC=[datetime]::UtcNow.ToString('o')})
            return $r
        } catch {
            $safe=Get-SafeError $_
            $script:requests.Add([pscustomobject]@{Fuente=$script:activeSource;Servicio=$Service;Metodo=$Method;Ruta=([uri]$Url).AbsolutePath;Resultado="Error $($safe.HTTP)";Intento=$attempt+1;UTC=[datetime]::UtcNow.ToString('o')})
            if ($safe.HTTP -in @('429','500','502','503','504') -and $attempt -lt 3) {
                $delay=[math]::Pow(2,$attempt+1)+(Get-Random -Minimum 0 -Maximum 1000)/1000
                $retry=Get-Field $_.Exception 'Response.Headers.RetryAfter.Delta.TotalSeconds'
                if (-not $retry) { $retry=Get-Field $_.Exception 'Response.Headers.Retry-After' }
                $numeric=0.0
                if ([double]::TryParse([string]$retry,[ref]$numeric)) { $delay=[math]::Max($delay,$numeric) }
                else {
                    $dateValue=Get-Field $_.Exception 'Response.Headers.RetryAfter.Date'
                    if (-not $dateValue) {$dateValue=$retry}
                    $retryDate=[datetimeoffset]::MinValue
                    if ([datetimeoffset]::TryParse([string]$dateValue,[ref]$retryDate)) {$delay=[math]::Max($delay,($retryDate-[datetimeoffset]::UtcNow).TotalSeconds)}
                }
                if ($delay -gt 60) { throw } # no reintentar antes del intervalo pedido por el servidor
                Start-Sleep -Milliseconds ([int]($delay*1000))
            } else { throw }
        }
    }
}
function Read-Pages([string]$Service, [string]$Url) {
    $seen=@{};$baseUrl=$Url
    $script:querySequence++
    $queryId=$script:querySequence
    for ($page=0;$Url;$page++) {
        if ($page -ge $MaxPages -or $seen.ContainsKey($Url)) { throw [IO.InvalidDataException]::new('Paginacion incompleta o ciclica.') }
        $seen[$Url]=$true
        $r=Invoke-Read $Service $Url
        Save-Json ("pagina-$script:activeSource-q{0:D4}-{1:D4}" -f $queryId,$page) ([ordered]@{TenantId=$TenantId.ToString();RunId=$script:runId;Fuente=$script:activeSource;Consulta=$queryId;Ruta=([uri]$Url).AbsolutePath;Pagina=$page;Respuesta=$r})
        $script:sourcePages++
        $values=Get-Field $r 'value'
        if (-not (Has-Field $r 'value') -or $null -eq $values -or $values -is [string] -or $values -is [Collections.IDictionary] -or $values -isnot [Collections.IEnumerable]) { throw [IO.InvalidDataException]::new('Se esperaba una coleccion value no nula.') }
        foreach ($v in $values) {
            if ($null -eq $v -or $v -is [string]) {throw [IO.InvalidDataException]::new('Elemento nulo o incompatible.')}
            $required=$null
            if ($Service -eq 'Graph') {$required=if (([uri]$Url).AbsolutePath -eq '/v1.0/subscribedSkus') {'skuId'} else {'id'}}
            if ($Service -eq 'Dataverse') {
                $path=([uri]$Url).AbsolutePath
                $required=if ($path -match 'roles(_association)?$') {'roleid'} elseif ($path -match 'teams$') {'teamid'} elseif ($path -match 'bots$') {'botid'} else {'systemuserid'}
            }
            if ($required -and -not (Get-Field $v $required)) {throw [IO.InvalidDataException]::new('Registro sin identificador esperado.')}
            $v
        }
        $next=Get-Field $r '@odata.nextLink'
        if (-not $next) { $next=Get-Field $r 'nextLink' }
        $continuation=Get-Field $r 'continuationtoken'
        if (-not $next -and $continuation) { $next=$baseUrl+'&continuationToken='+[uri]::EscapeDataString($continuation) }
        if ($next -and -not ([uri]$next).IsAbsoluteUri) {$next=[uri]::new([uri]$baseUrl,[string]$next).AbsoluteUri}
        if ($next) { Assert-ReadRequest $Service GET $next }
        $Url=$next
    }
}
function Read-Inventory([string]$Type, [int]$Top=1000) {
    $skip='';$seen=@{}
    for ($page=0;$page -lt $MaxPages;$page++) {
        $body=@{TableName='PowerPlatformResources';Clauses=@(@{'$type'='where';FieldName='type';Operator='==';Values=@("'$Type'")},@{'$type'='orderby';FieldNamesAscDesc=@{id='asc'}});Options=@{Top=$Top;SkipToken=$skip}}
        $r=Invoke-Read PowerPlatform 'https://api.powerplatform.com/resourcequery/resources/query?api-version=2024-10-01' POST $body
        Save-Json ("pagina-$script:activeSource-{0:D4}" -f $page) $r
        $script:sourcePages++
        $data=Get-Field $r 'data'
        if (-not (Has-Field $r 'data') -or $null -eq $data -or $data -is [string] -or $data -is [Collections.IDictionary] -or $data -isnot [Collections.IEnumerable]) {throw [IO.InvalidDataException]::new('Inventario sin coleccion data valida.')}
        if ((Has-Field $r 'count') -and [long]$r.count -ne @($data).Count) {throw [IO.InvalidDataException]::new('count no coincide con los registros de pagina.')}
        foreach ($item in $data) {
            if (-not $item.name -or -not $item.properties) {throw [IO.InvalidDataException]::new('Recurso sin campos obligatorios.')}
            if ($item.tenantId -and [string]$item.tenantId -ne $TenantId.ToString()) {throw [IO.InvalidDataException]::new('Recurso de otro tenant.')}
            $item
        }
        $skip=[string](Get-Field $r 'skipToken')
        if (-not $skip) {
            if ((Get-Field $r 'resultTruncated') -in @(1,'true','True')) {throw [IO.InvalidDataException]::new('Inventario truncado sin continuacion.')}
            return
        }
        if ($seen.ContainsKey($skip)) {throw [IO.InvalidDataException]::new('Continuacion ciclica.')}
        $seen[$skip]=$true
        if ($PreflightOnly) {return} # solo probar autorizacion; no inventario completo
    }
    throw [IO.InvalidDataException]::new('Inventario excede MaxPages.')
}
function Read-Object([string]$Service,[string]$Url,[string[]]$RequiredFields) {
    $r=Invoke-Read $Service $Url
    foreach ($field in $RequiredFields) {if ($null -eq (Get-Field $r $field)) {throw [IO.InvalidDataException]::new('Objeto sin campo esperado.')}}
    return $r
}
function Read-GraphReport([string]$Function,[string[]]$RequiredHeaders) {
    $url="https://graph.microsoft.com/v1.0/copilot/reports/$Function(period='$ReportPeriod',version='v2')"
    Assert-ReadRequest Graph GET $url
    if ((Get-MgContext).TenantId -ne $TenantId.ToString()) {throw 'Sesion Graph cruzada.'}
    $raw=Join-Path $script:evidencePath ($script:activeSource+'-original.txt')
    # El SDK administra el transporte Graph y las descargas oficiales; no se copian tokens ni Location.
    $null=Invoke-Read -Service Graph -Url $url -OutputFile $raw
    $text=[IO.File]::ReadAllText($raw).TrimStart([char]0xfeff)
    if ($text.TrimStart().StartsWith('{') -or $text.TrimStart().StartsWith('<')) {throw [IO.InvalidDataException]::new('Se esperaba CSV v1.0; conservar original y revisar version/esquema.')}
    # Leer cabeceras aun cuando no hay filas. ConvertFrom-Csv valida nombres usando una fila sintetica.
    $header=($text -split '\r?\n',2)[0]
    $probe=@(($header+"`n__probe__") | ConvertFrom-Csv)
    foreach ($h in $RequiredHeaders) {if ($h -notin $probe[0].PSObject.Properties.Name) {throw [IO.InvalidDataException]::new('Cabecera de reporte inesperada.')}}
    $rows=@($text | ConvertFrom-Csv)
    foreach ($row in $rows) {
        if ([string]$row.'Report Period' -ne $ReportPeriod.Substring(1)) {throw [IO.InvalidDataException]::new('El periodo devuelto no coincide con el solicitado.')}
        $refresh=[datetime]::MinValue
        if (-not [datetime]::TryParse([string]$row.'Report Refresh Date',[ref]$refresh)) {throw [IO.InvalidDataException]::new('Reporte sin fecha de actualizacion valida.')}
    }
    Save-Csv $script:activeSource $rows
    foreach ($row in $rows) {$row}
}
function Write-Manifest {
    $rows=@(Get-ChildItem -LiteralPath $script:runPath -File -Recurse | Where-Object Name -ne 'manifiesto-sha256.csv' | ForEach-Object {
        [pscustomobject]@{Archivo=[IO.Path]::GetRelativePath($script:runPath,$_.FullName);SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
    })
    Save-Csv 'manifiesto-sha256' $rows
}
