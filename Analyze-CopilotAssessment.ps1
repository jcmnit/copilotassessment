#Requires -Version 7.4
<# Analisis offline. No importa modulos Microsoft ni realiza conexiones de red. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunDirectory)
$ErrorActionPreference='Stop'
$RunDirectory=(Get-Item -LiteralPath $RunDirectory).FullName
function Read-Evidence([string]$Name) {
    $p=Join-Path (Join-Path $RunDirectory 'evidencias') ($Name+'.json')
    if (Test-Path -LiteralPath $p) {
        if (('evidencias/'+$Name+'.json') -notin @($manifest.Archivo -replace '\\','/')) {throw 'Evidencia no incluida en el manifiesto.'}
        return Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    }
    return $null
}
function Resolve-EvidencePath([string]$RelativePath) {
    if ([IO.Path]::IsPathRooted($RelativePath)) {throw 'Ruta de evidencia absoluta no permitida.'}
    $path=[IO.Path]::GetFullPath((Join-Path $RunDirectory $RelativePath))
    $prefix=$RunDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $comparison=if ($IsWindows) {[StringComparison]::OrdinalIgnoreCase} else {[StringComparison]::Ordinal}
    if (-not $path.StartsWith($prefix,$comparison)) {throw 'Ruta fuera de la captura.'}
    $cursor=Get-Item -LiteralPath $path -Force
    while (-not [string]::Equals($cursor.FullName,$RunDirectory,$comparison)) {
        if ($cursor.LinkType) {throw 'No se admiten enlaces simbolicos en evidencias.'}
        $cursor=if ($cursor -is [IO.DirectoryInfo]) {$cursor.Parent} else {$cursor.Directory}
        if (-not $cursor) {throw 'Ruta no verificable.'}
    }
    return $path
}
$manifestPath=Join-Path $RunDirectory 'manifiesto-sha256.csv'
if (-not (Test-Path -LiteralPath $manifestPath)) {throw 'Falta manifiesto de la captura.'}
$manifest=@(Import-Csv -LiteralPath $manifestPath)
if (-not $manifest.Count) {throw 'Manifiesto vacio.'}
foreach ($entry in $manifest) {
    $p=Resolve-EvidencePath $entry.Archivo
    if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne $entry.SHA256) {throw 'Integridad de captura no valida.'}
}
if ('evidencias/ejecucion.json' -notin @($manifest.Archivo -replace '\\','/')) {throw 'Metadatos no incluidos en manifiesto.'}
$execution=Read-Evidence 'ejecucion'
$isRecovered=$execution.Modo -eq 'RecuperacionOffline'
$coverage=@(Read-Evidence 'cobertura')
if (-not $execution.TenantId -or -not $execution.RunId) {throw 'Metadatos incompletos.'}
if ($execution.RunId -notmatch '^\d{8}T\d{6}Z-[0-9a-f]{8}$' -or $execution.ReportPeriod -notin @('D7','D28','D90','D180') -or $execution.CopilotReportVersion -ne 'v2' -or $execution.EstadoRecoleccion -notin @('Fallido','Preflight','Parcial','CompletoSegunPerfil')) {throw 'Formato de metadatos de captura no admitido.'}
$TenantId=[guid]$execution.TenantId
$script:runId=$execution.RunId;$script:started=[datetime]$execution.InicioUTC
$analysisRoot=Join-Path $RunDirectory 'analisis'
$script:runPath=Join-Path $analysisRoot ([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$null=New-Item -ItemType Directory -Path $script:runPath -Force
$script:evidencePath=$script:runPath
. (Join-Path $PSScriptRoot 'lib/Core.ps1')
. (Join-Path $PSScriptRoot 'lib/OfflinePolicies.ps1')
$dlpRows=@(foreach ($environment in @(Read-Evidence 'Entornos')) {
    foreach ($policy in @(Read-Evidence 'PoliticasDLP')) {
        if (-not $policy) {continue}
        [pscustomobject]@{EntornoId=$environment.name;Politica=$policy.PolicyName;Nombre=$policy.DisplayName;Aplicabilidad=(Get-DlpApplicability $environment.name $policy);EstadoControl='NoEvaluado';Evidencia='evidencias/PoliticasDLP.json';Nota='Solo ambito declarado; validar grupos de conectores, operaciones, restricciones y combinacion de politicas.'}
    }
})
Save-Csv 'dlp-aplicabilidad' $dlpRows
$creditRows=@(foreach ($credit in @(Read-Evidence 'CopilotCredits')) {
    if (-not $credit) {continue}
    foreach ($field in @('entitlement.capacity.entitled.value','entitlement.capacity.consumed.value','entitlement.capacity.availableQuantity')) {
        [pscustomobject]@{EntitlementId=$credit.entitlementId;ConceptoOriginal=$field;ValorOriginal=(Get-Field $credit $field);UnidadOriginal=(Get-Field $credit 'entitlement.capacity.unit');Evidencia='evidencias/CopilotCredits.json';Nota='Conservar unidad y fecha del JSON; nulo=desconocido. No sumar ni convertir a dinero.'}
    }
})
Save-Csv 'creditos-resumen' $creditRows
$findings=[Collections.Generic.List[object]]::new()
function Add-Finding([string]$ControlId,[string]$Priority,[string]$Resource,[string]$Observation,[string]$Evidence,[string]$Action) {
    $findings.Add([pscustomobject]@{ControlId=$ControlId;Prioridad=$Priority;Recurso=$Resource;Observacion=$Observation;Evidencia=$Evidence;Accion=$Action})
}
foreach ($agent in @(Read-Evidence 'Agentes')) {
    if (-not $agent) {continue}
    $p=$agent.properties
    if (-not $p.ownerId) {Add-Finding 'AG-OWNER' 'Media' $agent.name 'Propietario no informado; no acredita agente huerfano.' 'evidencias/Agentes.json' 'Confirmar responsable funcional y tecnico.'}
    if ($p.authentication -eq 'None') {Add-Finding 'AG-AUTH' 'Alta' $agent.name 'Inventario informa autenticacion None; validar canal y datos.' 'evidencias/Agentes.json' 'Requerir autenticacion interna o excepcion aprobada para acceso publico.'}
    if ($p.sharedWithViewers.entireTenant -eq $true) {Add-Finding 'AG-AUDIENCE' 'Media' $agent.name 'Comparticion con todo el tenant observada.' 'evidencias/Agentes.json' 'Confirmar audiencia y acceso a las fuentes.'}
}
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $RunDirectory 'evidencias') -Filter 'SharePointPermisos-*-permisos.json')) {
    $relative='evidencias/'+$file.Name
    if ($relative -notin @($manifest.Archivo -replace '\\','/')) {throw 'Permisos SharePoint fuera del manifiesto.'}
    $data=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    foreach ($permission in @($data.Registros)) {
        if ($permission.Audiencia -in @('Everyone','EveryoneExceptExternalUsers') -and $permission.AccesoContenido -eq $true) {
            Add-Finding 'SP-BROAD' 'Alta' $permission.ScopeId ("Permiso de audiencia amplia observado: $($permission.Audiencia). Cobertura del sitio completa: $($data.Completo). No demuestra acceso a informacion sensible ni uso por Copilot.") $relative 'Validar necesidad de negocio, clasificacion, restricciones y retirar acceso excesivo mediante un cambio separado aprobado.'
        }
        if ($permission.Audiencia -eq 'GuestIdentity' -and $permission.AccesoContenido -eq $true) {Add-Finding 'SP-EXTERNAL' 'Media' $permission.ScopeId 'Identidad invitada con permiso observado; validar vigencia y justificacion.' $relative 'Revisar patrocinador y caducidad del acceso externo.'}
    }
}
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $RunDirectory 'evidencias') -Filter 'SharePointPermisos-*-enlaces.json')) {
    $relative='evidencias/'+$file.Name
    if ($relative -notin @($manifest.Archivo -replace '\\','/')) {throw 'Enlaces SharePoint fuera del manifiesto.'}
    $data=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    foreach ($link in @($data.Registros)) {
        $expired=$false
        $expiry=[datetimeoffset]::MinValue
        $referenceDate=if ($execution.FinUTC) {[datetimeoffset]$execution.FinUTC} else {[datetimeoffset]$execution.InicioUTC}
        if ($link.Expiration -and [datetimeoffset]::TryParse([string]$link.Expiration,[ref]$expiry)) {$expired=$expiry -le $referenceDate}
        if ($link.Scope -eq 'anonymous' -and -not $expired) {Add-Finding 'SP-ANON' 'Alta' $link.ScopeId 'Enlace anonimo observado, sin expiracion acreditada anterior a la captura. No implica que Copilot lo indexe o lo utilice.' $relative 'Confirmar contenido, excepcion y expiracion; revisar exposicion publica.'}
        if ($link.Scope -eq 'organization' -and -not $expired) {Add-Finding 'SP-ORG-LINK' 'Media' $link.ScopeId 'Enlace de organizacion observado; requiere posesion del enlace y controles aplicables.' $relative 'Validar audiencia prevista; no equiparar enlace a acceso directo universal.'}
    }
}
$metrics=[Collections.Generic.List[object]]::new()
foreach ($summary in @(Read-Evidence 'CopilotAdopcionResumen')) {
    if (-not $summary) {continue}
    foreach ($property in $summary.PSObject.Properties | Where-Object Name -like '* Enabled Users') {
        $app=$property.Name -replace ' Enabled Users$',''
        $enabled=0L;$active=0L
        if (-not [long]::TryParse([string]$property.Value,[ref]$enabled) -or -not [long]::TryParse([string]$summary.($app+' Active Users'),[ref]$active) -or $enabled -lt 0 -or $active -lt 0 -or $active -gt $enabled) {
            Add-Finding 'M365-USAGE' 'Media' $app 'Contadores de adopcion no comparables o inconsistentes; no se calcula tasa.' 'evidencias/CopilotAdopcionResumen.json' 'Confirmar definicion, version y periodo del reporte.'
            continue
        }
        $metrics.Add([pscustomobject]@{Aplicacion=$app;Habilitados=$enabled;Activos=$active;AdopcionPorcentaje=$(if ($enabled -gt 0) {[math]::Round(100.0*$active/$enabled,2)} else {$null});ReportRefreshDate=$summary.'Report Refresh Date';ReportPeriod=$summary.'Report Period';ReportVersion=$execution.CopilotReportVersion;Fuente='evidencias/CopilotAdopcionResumen.json'})
    }
}
$controls=@(
    @('AG-OWNER','Catalogo y responsables','Propietario funcional y tecnico','Agentes','Asignar responsables, clasificar riesgo y recertificar trimestralmente.','Inventario central y conciliacion M365/Teams.'),
    @('AG-AUTH','Autenticacion y audiencia','Seguridad / Entra','Agentes','Autenticacion Entra para agentes internos; excepciones publicas aprobadas.','Validar canales, identidades y acceso efectivo.'),
    @('AG-ALM','Creacion y publicacion','Administrador Power Platform / M365','PublicacionALM','Aprobacion y promocion controlada de cambios; grupos de autores.','Separacion autor/publicador y pipelines dependen del producto/licencias.'),
    @('M365-USAGE','Adopcion y uso','Responsable M365 / negocio','CopilotAdopcionResumen','Medir adopcion por aplicacion y realizar seguimiento de habilitados y activos.','Version v2; anonimato y demora de consolidacion; no inferir productividad.'),
    @('SP-BROAD','Permisos y sobreexposicion SharePoint','Propietario de datos / SharePoint','SharePointInventario','Recertificar audiencias amplias, grupos, invitados y enlaces.','Permisos observados no prueban contenido sensible; no incluye OneDrive.'),
    @('SP-ANON','Comparticion externa','Seguridad / SharePoint','SharePointInventario','Excepciones con justificacion y vencimiento para enlaces anonimos.','Requiere clasificacion de datos y validacion efectiva.'),
    @('SEC-DLP','Politicas de datos','Seguridad / Power Platform','DLPEfectiva','DLP por entorno y riesgo, con excepciones y analisis de conectores y canales.','Confirmar politica efectiva; inventario de DLP no acredita cumplimiento.'),
    @('SEC-ACCESS','Roles y acceso efectivo','Seguridad / Entra / Dataverse','DataversePermisos','Minimo privilegio, PIM, grupos y revision de identidades de ejecucion.','PIM capturado no representa historico completo ni acceso efectivo.'),
    @('FIN-LICENSE','Licencias y habilitacion','Licenciamiento','LicenciasSKU','Conciliar usuarios y derechos por producto y modalidad de uso.','No calcular creditos ni cargos a partir de licencias de usuario.'),
    @('FIN-CREDITS','Capacidad y consumo','FinOps / Power Platform','CreditosAsignaciones','Responsable y presupuesto por entorno; revisar TenantPool y sobreconsumo.','Disponible para asignar no es saldo restante; alertas no son topes.'),
    @('FIN-BILLING','Facturas y presupuesto','FinOps / facturacion','FacturasPagos','Conciliar cargos y estado de pago con el acuerdo comercial.','M365, Azure y/o CSP; requiere acceso financiero independiente.'),
    @('OPS-AUDIT','Auditoria y respuesta','Operaciones / SOC','MonitoreoAuditoria','Retencion acordada, alertas probadas y procedimiento de incidentes.','Capacidades y retencion dependen de licencia y configuracion.'),
    @('GOV-EXCEPTION','Excepciones y decisiones','Comite de gobierno','CatalogoM365Teams','RACI, aprobacion de riesgos, excepciones con caducidad y baja de agentes.','Formalizar decisiones por tenant; este informe no aplica cambios.')
)
$decisions=@{}
$supplementRoot=Join-Path $RunDirectory 'complementos'
if (Test-Path -LiteralPath $supplementRoot) {
    foreach ($file in Get-ChildItem -LiteralPath $supplementRoot -Filter 'registro.json' -Recurse) {
        $record=Get-Content -LiteralPath (Resolve-EvidencePath ([IO.Path]::GetRelativePath($RunDirectory,$file.FullName))) -Raw | ConvertFrom-Json
        if ($record.TenantId -ne $execution.TenantId -or $record.RunId -ne $execution.RunId) {throw 'Complemento de otro tenant o captura.'}
        $supplementFilePath=Resolve-EvidencePath $record.Archivo
        if ((Get-FileHash -LiteralPath $supplementFilePath -Algorithm SHA256).Hash -ne $record.SHA256) {throw 'Integridad del complemento no valida.'}
        if ($record.Estado -notin @('Cumple','NoCumple','NoEvaluado','NoAplica') -or -not $record.Revisor -or -not $record.Justificacion) {throw 'Decision manual incompleta.'}
        if ($decisions.ContainsKey($record.ControlId)) {throw 'Decisiones duplicadas; resolver el conflicto antes de analizar.'}
        $decisions[$record.ControlId]=$record
    }
}
$controlRows=@(foreach ($c in $controls) {
    $observed=@($coverage | Where-Object Fuente -eq $c[3] | Select-Object -Last 1)
    $state='NoEvaluado';$justification='Requiere validar politica, evidencia y capacidad del tenant.';$evidence=$c[3];$reviewer=''
    if ($decisions.ContainsKey($c[0])) {$d=$decisions[$c[0]];$state=$d.Estado;$justification=$d.Justificacion;$evidence=$d.Archivo;$reviewer=$d.Revisor}
    [pscustomobject]@{ControlId=$c[0];Control=$c[1];Responsable=$c[2];Estado=$state;EstadoFuente=($observed.Estado -join ';');Evidencia=$evidence;Recomendacion=$c[4];Condicion=$c[5];Justificacion=$justification;Revisor=$reviewer;CriterioAceptacion='Evidencia verificada y decision aprobada por el responsable; excepciones documentadas con fecha de revision.'}
})
$evaluation=if (@($controlRows | Where-Object Estado -eq 'NoEvaluado').Count) {'Pendiente'} else {'EvaluadoConDecisionesManuales'}
Save-Csv 'hallazgos' $findings.ToArray()
Save-Csv 'adopcion-indicadores' $metrics.ToArray()
Save-Csv 'controles-gobierno' $controlRows
Save-Json 'hallazgos' $findings.ToArray()
Save-Json 'controles-gobierno' $controlRows
$raci=@(
    [pscustomobject]@{Actividad='Aprobar casos, riesgos y excepciones';R='Propietario funcional';A='Comite de gobierno';C='Seguridad, cumplimiento, FinOps';I='Operaciones'},
    [pscustomobject]@{Actividad='Permisos, DLP e identidades';R='Administradores M365/SharePoint/Power Platform';A='Seguridad';C='Propietarios de datos';I='SOC'},
    [pscustomobject]@{Actividad='Publicacion y ALM';R='Responsable tecnico';A='Propietario del servicio';C='Seguridad y administradores';I='Usuarios'},
    [pscustomobject]@{Actividad='Consumo, licencias y presupuesto';R='FinOps y licenciamiento';A='Responsable presupuestario';C='Propietarios de agentes';I='Comite'},
    [pscustomobject]@{Actividad='Monitoreo, incidentes y baja';R='Operaciones / SOC';A='Propietario del servicio';C='Seguridad y negocio';I='Comite'}
)
Save-Csv 'raci-propuesta' $raci
$plan=@($findings | ForEach-Object {[pscustomobject]@{ControlId=$_.ControlId;Prioridad=$_.Prioridad;Recurso=$_.Recurso;Accion=$_.Accion;Evidencia=$_.Evidencia;Estado='Propuesto; no aplicado'}})
Save-Csv 'plan-acciones' $plan
$recoveryNotice=if ($isRecovered) {'<p><strong>RECUPERACION OFFLINE DE CAPTURA INTERRUMPIDA.</strong> Informe parcial. No se conoce la causa del cierre ni se acredita completitud de las fuentes. Los hashes se generaron al recuperar; no verifican integridad anterior. FinUTC original no se completa retroactivamente. Los hallazgos requieren validar la evidencia recuperada.</p>'} else {''}
$html=@"
<!doctype html><html lang="es"><meta charset="utf-8"><title>Evaluacion Copilot</title>
<style>body{font:15px system-ui;margin:32px;color:#172b42}table{border-collapse:collapse;width:100%;margin:16px 0}td,th{border:1px solid #ccd4df;padding:7px;text-align:left;overflow-wrap:anywhere}th{background:#eaf0f8}</style>
<h1>Microsoft 365 Copilot: levantamiento y propuesta de gobierno</h1>
$recoveryNotice
<p>Tenant: $($execution.TenantId) | RunId: $($execution.RunId). Captura: $($execution.EstadoRecoleccion). Evaluacion: $evaluation.</p>
<p>Periodo Copilot: $($execution.ReportPeriod), version $($execution.CopilotReportVersion). Los reportes preservan su fecha de actualizacion. Alcance SharePoint acotado por sitios, limites y permisos disponibles; no incluye OneDrive ni lectura de contenido. Permisos amplios son indicios para revisar, no prueba de filtracion ni de acceso por Copilot.</p>
<h2>Adopcion por aplicacion</h2>$($metrics.ToArray() | ConvertTo-Html -Fragment)
<h2>Hallazgos observados</h2>$($findings.ToArray() | ConvertTo-Html -Fragment)
<h2>Cobertura</h2>$($coverage | ConvertTo-Html -Fragment)
<h2>Controles y propuesta por tenant</h2>$($controlRows | ConvertTo-Html -Fragment)
<h2>RACI propuesto</h2>$($raci | ConvertTo-Html -Fragment)
<p>Prioridad: cerrar fuentes faltantes; confirmar responsables y exposicion; validar DLP, publicacion y presupuesto; aprobar controles y excepciones. Revision de accesos trimestral, consumo semanal y controles operativos mensual como propuesta a aprobar. No se aplicaron cambios al tenant.</p>
<p>El manifiesto detecta cambios frente a hashes conservados; no es firma digital. Proteger evidencias y decisiones manuales en ubicacion corporativa autorizada. Una ejecucion unica no acredita funcionamiento historico de los controles.</p></html>
"@
[IO.File]::WriteAllText((Join-Path $script:runPath 'informe.html'),$html,[Text.UTF8Encoding]::new($true))
Save-Json 'analisis' ([ordered]@{TenantId=$execution.TenantId;RunId=$execution.RunId;AnalizadoUTC=[datetime]::UtcNow.ToString('o');EstadoEvaluacion=$evaluation;IntegridadCaptura=$(if ($isRecovered) {'Verificada solo desde recuperacion; origen no verificable'} else {'Verificada frente al manifiesto conservado'});Hallazgos=$findings.Count;ControlesPendientes=@($controlRows | Where-Object Estado -eq 'NoEvaluado').Count;Version='2.0.2';AnalizadorSHA256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash})
Write-Manifest
[pscustomobject]@{EstadoEvaluacion=$evaluation;Informe=(Join-Path $script:runPath 'informe.html');CarpetaAnalisis=$script:runPath;Hallazgos=$findings.Count}
