# Levantamiento de Microsoft 365 Copilot — v2.0.2

Recolector PowerShell de lectura para ejecutar **por separado en cada tenant**, conservar evidencias y elaborar un informe y una propuesta de gobierno. Incluye Microsoft 365 Copilot, agentes Copilot Studio/Agent Builder, Power Platform, Entra, roles Dataverse y permisos/compartición SharePoint.

No instala módulos, registra aplicaciones, concede consentimiento, asigna roles, modifica DLP, publica agentes ni modifica permisos. No descarga contenido de documentos ni conversaciones. El POST de Power Platform es exclusivamente la consulta documentada de inventario. La autenticación puede generar registros y cachés normales del cliente.

## Requisitos y autorizaciones

- PowerShell **7.4.6 o posterior**. Windows es la opción recomendada si el módulo administrativo PowerApps necesita compatibilidad con Windows PowerShell. La versión 2 no se ejecuta directamente en Windows PowerShell 5.1.
- Módulos corporativos previamente preparados: `Microsoft.Graph.Authentication`, `Az.Accounts`, `Microsoft.PowerApps.Administration.PowerShell`, `PnP.PowerShell`. `MSAL.PS` solo si se usa `PowerPlatformClientId`.
- Cuenta autorizada y MFA por tenant. No se conceden permisos ni se elevan roles desde el script. Preparar consentimiento antes de la captura; si aparece una nueva solicitud de aprobación, gestionarla con el administrador.
- **Prerrequisito obligatorio para evaluar SharePoint:** una aplicación Entra preparada para el inicio de sesión interactivo de PnP.PowerShell, con consentimiento y permisos aprobados en el tenant evaluado. Su **Id. de aplicación (cliente)** es el valor de `SharePointClientId`. Instalar PnP.PowerShell o disponer de un rol administrador no proporciona ese ID ni prepara la aplicación. También se necesita la URL real del centro de administración. No se usa el antiguo cliente PnP compartido.
- Para Dataverse: sesión Azure de usuario y autorización del cliente para obtener token del entorno; privilegios de lectura sobre usuarios, equipos, roles, asociaciones y tabla de agentes. La falta de derechos queda como cobertura pendiente, sin autoasignar System Administrator.

Ver [permisos y fuentes](docs/PERMISOS-Y-FUENTES.md). Roles administrativos y permisos OAuth son requisitos distintos. No usar Global Administrator como solución general a un error 403.

La aplicación PnP necesita permisos para las operaciones de administración y lectura de asignaciones. Algunas operaciones requieren permisos que permiten más que lectura aunque el recolector solo use Get/consultas CSOM. Su aprobación corresponde al administrador; no se solicita ni concede FullControl automáticamente. El rol SharePoint Administrator no garantiza acceso al contenido/permisos de todos los sitios: no se agregan administradores de colección para sortear una denegación.

**Importante: el ejemplo manual de registro PnP que se enlaza usa `AllSites.Read` como permiso inicial. No es una matriz de permisos suficiente para este recolector.** Una cuenta Global Administrator no elimina el límite de los permisos delegados de la aplicación. El alcance administrativo (`Get-PnPTenant`, inventario de tenant y enumeración de permisos) debe prepararse y validarse expresamente; leer contenido y enumerar sus permisos son operaciones diferentes.

Para validar ese alcance con la aplicación dedicada al levantamiento, el permiso delegado SharePoint a evaluar/aprobar es **`AllSites.FullControl`**, con consentimiento de administrador. Se agrega en **Permisos de API → Agregar un permiso → SharePoint → Permisos delegados → AllSites.FullControl**, no como permiso de aplicación ni como `Microsoft Graph/Sites.FullControl.All`. No se requieren secretos ni certificados para el inicio de sesión interactivo utilizado aquí. Tras aprobar el cambio, iniciar una conexión nueva y probar `Get-PnPTenant` antes de repetir el levantamiento.

`AllSites.FullControl` permite también escrituras dentro de los derechos del usuario; no es un permiso OAuth de solo lectura, aunque el script solo ejecute lecturas. Su aprobación es una preparación administrativa separada y no se realiza desde este paquete. Si ese alcance no se aprueba, mantener la aplicación con los permisos acordados y dejar las consultas administrativas/ACL como no obtenidas o aportar evidencia manual. No ampliar roles ni permisos de forma automática para completar el informe.

Un tenant CDX temporal con datos de demostración puede servir para validar los componentes habilitados. Su origen y duración no acreditan licencias Copilot, créditos, actividad real ni una restricción específica de las API. Un HTTP 400 del inventario debe diagnosticarse de forma independiente y no atribuirse sin evidencia al carácter demo del tenant.

### Aislamiento de módulos desde 2.0.2

El recolector inicia automáticamente un proceso `pwsh -NoProfile` exclusivo para SharePoint. PnP.PowerShell no se importa junto con Graph, Az.Accounts o PowerApps en el proceso principal. Ambos procesos forman parte de la misma captura y utilizan el mismo TenantId/RunId; no hay que ejecutar dos levantamientos ni transferir tokens entre procesos.

La conexión aislada se incorporó tras observar un stack overflow en el resolvedor de dependencias de PnP 3.4.1 dentro de una sesión combinada, mientras la conexión PnP aislada sí funcionaba. No se atribuye el conflicto a una DLL o módulo concreto sin evidencia adicional. No se requiere reinstalar módulos ni ampliar permisos para aplicar este cambio.

El worker guarda sus datos en `sharepoint-worker/`; el padre incorpora las evidencias SharePoint y su cobertura al informe común. `evidencias/SharePointProceso.json` registra PID y versión PnP del proceso hijo. Si el hijo termina abruptamente o agota su tiempo, el padre marca error de runtime/tiempo y conserva el resto de la captura. La terminación abrupta real del proceso principal todavía requiere recuperación offline.

La autenticación PnP correcta no demuestra permiso para todas las consultas administrativas o las ACL. Las denegaciones por sitio se siguen informando.

### Preparación previa de SharePoint y obtención del ClientId

1. El administrador del cliente debe confirmar si existe una aplicación corporativa para **PnP.PowerShell con autenticación interactiva delegada**. No elegir una aplicación arbitraria ni usar el ClientId del cliente oficial Graph como sustituto.
2. En [Microsoft Entra](https://entra.microsoft.com/), abrir **Registros de aplicaciones → Todas las aplicaciones → aplicación autorizada → Información general**. Copiar **Id. de aplicación (cliente)**; no el Id. de objeto ni el Id. de directorio.
3. Si no existe una aplicación adecuada, el administrador debe registrarla o adaptar una existente **antes del levantamiento**, según el procedimiento de [registro de aplicaciones PnP](https://pnp.github.io/powershell/articles/registerapplication.html). Para este script se necesita cliente interactivo de escritorio con URI de redirección de bucle local compatible, normalmente `http://localhost`, y permisos delegados SharePoint revisados para los cmdlets utilizados. No se requiere secreto de cliente para este flujo.
4. El administrador debe aprobar el consentimiento requerido y comprobar que la cuenta puede consultar el centro de administración y las asignaciones de los sitios incluidos. Un ClientId válido, o poder leer archivos, no garantiza poder enumerar permisos. La aprobación de permisos más amplios que lectura es un cambio administrativo previo separado, no una acción del recolector.
5. Ejecutar la comprobación previa del comando de levantamiento agregando `-PreflightOnly`; revisar `SharePointInventario` en cobertura. Este modo comprueba inventario/autenticación, **no** todas las ACL o enlaces de cada sitio. La captura completa registra las denegaciones y el alcance efectivo por sitio.

Para los dos clientes, registrar por separado **TenantId, SharePointAdminUrl, SharePointClientId y cuenta autorizada**. Pueden utilizarse aplicaciones distintas de un solo tenant. El ClientId no es un secreto; no enviar contraseñas, tokens o secretos por chat.

**Si el cliente no autoriza preparar esta aplicación**, puede ejecutarse el resto con `-SkipSharePoint`, pero quedará parcial y **no incluirá la evaluación de permisos/sobreexposición SharePoint solicitada**. El script no crea la aplicación ni concede consentimiento para completar ese requisito.

## Ejecución por tenant

Usar una consola nueva por tenant y **TenantId explícito**. No es necesario convertir la aplicación en multi-tenant: pueden utilizarse aplicaciones ya autorizadas diferentes en cada cliente.

```powershell
./Export-CopilotAssessment.ps1 `
  -TenantId 'GUID-TENANT-A' `
  -SharePointAdminUrl 'https://clienteA-admin.sharepoint.com' `
  -SharePointClientId 'GUID-APP-PNP-A' `
  -ReportPeriod D28 `
  -IncludeLicensedUsers -IncludeGroupMembers `
  -OutputDirectory './Resultados'
```

Reemplazar los GUID y URL. Repetir en otra consola para el tenant B. Los resultados se guardan como `Resultados/<TenantId>/<RunId>/`; nunca se sobrescribe una captura.

Antes de la captura definitiva puede ejecutarse el mismo comando con `-PreflightOnly`. Comprueba autenticación y acceso real a las fuentes, guarda evidencia y se identifica como preflight; no representa un inventario completo. Algunas fuentes, como los reportes, se descargan completas para comprobar permisos y esquema. La preparación previa evita descubrir permisos faltantes durante la única captura acordada.

Parámetros relevantes:

| Parámetro | Comportamiento |
|---|---|
| `ReportPeriod` | D7, **D28**, D90 o D180, versión de reporte **v2** explícita. No sustituir D28 por D30. |
| `SharePointSiteUrls` | Muestra explícita de sitios; el informe conserva que no representa todo el tenant. Sin esta opción revisa los sitios inventariados hasta MaxSites. |
| `MaxSites` | 500 sitios por defecto. Si se supera, cobertura parcial. |
| `MaxItemsPerSite` | 20.000 ítems por sitio; escaneo de metadatos/permisos y enlaces, sin contenido. |
| `MaxUniqueScopesPerSite` | 5.000 ámbitos con permisos únicos por sitio. |
| `MaxSubWebsPerSite` | 100 subwebs por sitio. |
| `MaxDataversePrincipals` | 5.000 usuarios/equipos por entorno para consultar asociaciones; superar el límite conserva metadatos y marca parcial. |
| `MaxPages` | 1.000 por consulta; ciclos o truncamiento invalidan la fuente. |
| `MaxDurationMinutes` | 240; comprobado entre operaciones. No interrumpe forzosamente un cmdlet o login en curso. |
| `RequestTimeoutSeconds` | 120 para REST y contexto Graph. PnP usa su transporte y gestión de throttling. |
| `IncludeLicensedUsers` | Exporta todos los usuarios y asignaciones, no solo Copilot. Activar si el alcance requiere detalle individual. |
| `IncludeGroupMembers` | Miembros transitivos de los grupos detectados/indicados. No descubre por sí solo todos los grupos del tenant. |
| `SecurityGroupIds` | Agrega grupos de autores, consumidores y publicadores que no aparezcan asociados a entornos. |
| `NoInteractive` | No abre login. PowerApps y SharePoint no se capturan si no pueden autenticarse según el modo verificado. No representa una captura integral por sí solo. |
| `SkipGraph/PowerPlatform/PowerApps/Dataverse/SharePoint/CopilotReports` | Omite fuentes explícitamente; faltar una fuente requerida produce resultado parcial. |
| `IncludeLegacyConsumption` | Solo compatibilidad: endpoint declarado deprecated en v1.1; omitido por defecto. `FromDate/ToDate` solo afectan esta consulta. |

La captura puede requerir varios inicios de sesión, pero es una ejecución por tenant. No se promete recolección total ante denegaciones o indisponibilidad; conservar los fallos y completar únicamente las fuentes pendientes con procedencia/fecha, sin presentar cortes diferentes como una fotografía simultánea.

### Preflight tras los errores de inventario y créditos

La versión 2.0.2 utiliza `name`, identificador del recurso documentado en el inventario, como clave de orden estable; compara el tipo con `in~` y solo envía SkipToken cuando existe una continuación. La especificación no sensible de la consulta queda en `evidencias/consulta-*.json`. Es un ajuste al contrato documentado, **no prueba que el HTTP 400 observado en un tenant esté resuelto**.

HTTP 400 se identifica como `SolicitudInvalida`; HTTP 404 como `NoDisponible`. Cuando el servicio devuelve un código estructurado, `CodigoServicio` se conserva en diagnóstico, sin mensajes completos ni cuerpos de error. Un 400 no acredita falta de permisos. Un 404 de MCSMessages no distingue por sí solo entre entitlement no disponible, recurso inexistente u operación no disponible, y no se convierte en cero créditos ni en ausencia de licencia.

Antes de una captura completa, ejecutar preflight con la carpeta nueva. Ejemplo en una sola línea, sustituyendo los valores:

```powershell
pwsh -NoExit -NoProfile -File 'C:\pw7\Copilot-2.0.2\Export-CopilotAssessment.ps1' -TenantId 'GUID-TENANT' -SharePointAdminUrl 'https://CLIENTE-admin.sharepoint.com' -SharePointClientId 'GUID-APP-PNP' -ReportPeriod D28 -IncludeLicensedUsers -IncludeGroupMembers -OutputDirectory 'C:\pw7\Copilot\Resultados-v2.0.2' -PreflightOnly
```

Si persiste un 400, revisar el código estructurado y la consulta registrada antes de modificar roles o consentimiento. Si persiste el 404 de créditos, contrastar capacidad/licenciamiento en PPAC y conservar el estado desconocido en el informe.

### Diagnóstico acotado cuando CodigoServicio aparece vacío

`Test-PowerPlatformApi.ps1` evita repetir todo el levantamiento: usa solo Az.Accounts y realiza tres solicitudes de lectura, dos POST de inventario (consulta actual y consulta mínima `take 1`) y un GET de MCSMessages. No carga Graph/PnP ni modifica datos, roles, consentimiento, aplicaciones o licencias.

```powershell
pwsh -NoExit -NoProfile -File 'C:\pw7\Copilot-2.0.2\Test-PowerPlatformApi.ps1' -TenantId 'GUID-TENANT' -OutputDirectory 'C:\pw7\Copilot\Diagnostico-PowerPlatform'
```

El archivo `diagnostico-api.json` conserva estado HTTP y mensajes de error saneados, incluidos `title/detail/errors` de respuestas de validación Problem Details. No conserva cuerpos completos, cabeceras Authorization, tokens ni datos devueltos por inventarios correctos. Revisa el archivo antes de compartirlo; puede incluir nombres de campos y detalles técnicos del servicio. Comparar las dos consultas ayuda a distinguir un problema de construcción de consulta de un rechazo común a ambas, sin asumir su causa anticipadamente. Los scopes declarados en el token no acreditan autorización efectiva.

## Resultados y análisis offline

- `evidencias/*.json`: respuestas, páginas, identidad, cobertura, diagnóstico, versiones y parámetros no secretos.
- `CopilotUsoDetalle`, `CopilotAdopcionResumen`, `CopilotAdopcionTendencia`: CSV normalizado y original del reporte. Conservan columnas, periodo y fecha de actualización del servicio; la privacidad del tenant puede ocultar nombres. No se cambia esa configuración ni se intenta desanonimizar.
- `agentes.csv`, `licencias.csv`, `identidades-agentes.csv`, `planes-facturacion.csv`.
- `dataverse-asignaciones.csv`: roles directos y de equipos; JSON de miembros/application users/metadatos por entorno. No equivale a autorización efectiva.
- `sharepoint-sitios.csv`, `sharepoint-permisos.csv`, `sharepoint-enlaces.csv`: configuración y permisos observados; cobertura parcial identificada por sitio. Nunca exporta la URL del enlace de compartición.
- `cobertura.csv`, `consultas.csv`, `diagnostico.csv`, `manifiesto-sha256.csv`.
- `analisis/<id>/informe.html`, `adopcion-indicadores.csv`, `dlp-aplicabilidad.csv`, `creditos-resumen.csv`, `hallazgos.csv`, `controles-gobierno.csv`, `raci-propuesta.csv`, `plan-acciones.csv` y manifiesto independiente.

Cada CSV incluye TenantId y RunId. Los JSON originales pueden conservar unidades, campos preview y detalle que no se aplanan. Un CSV sin filas puede no existir: consultar siempre JSON y cobertura para distinguir vacío válido de fuente fallida.

Reanalizar sin conectarse a Microsoft:

```powershell
./Analyze-CopilotAssessment.ps1 -RunDirectory './Resultados/TENANT/RUN'
```

El analizador verifica el manifiesto antes de leer la captura y crea una carpeta nueva; no modifica las evidencias. Los hashes detectan cambios frente al manifiesto conservado, pero no sustituyen firma digital o almacenamiento con control de acceso.

## Captura interrumpida o ventana cerrada sin manifiesto

Si `ejecucion.json` conserva `EstadoRecoleccion=EnCurso` y no tiene `FinUTC`, no existe cierre acreditado. Cerrar una ventana, reiniciar el equipo o terminar el proceso puede perder el error de la sesión. La ausencia del cierre no determina por sí sola la causa y no debe interpretarse como finalización satisfactoria.

La versión 2.0.1 guarda cobertura, diagnóstico y progreso después de cada estado, usando reemplazo atómico de JSON. No garantiza ejecutar `finally` ante una terminación del proceso, un fallo del runtime o un corte del equipo. El lanzador guarda además errores sanitizados cuando su `catch` llega a ejecutarse; no registra tokens ni cuerpos de respuesta.

**Para recuperar lo ya guardado no repita la consulta al tenant ni genere un manifiesto dentro del original.** Extraiga el paquete nuevo en otra carpeta y ejecute el recuperador contra la carpeta antigua. Ejemplo de una sola línea, reemplazando rutas:

```powershell
pwsh -NoExit -NoProfile -File 'C:\pw7\Copilot-2.0.1\Recover-CopilotAssessment.ps1' -RunDirectory 'C:\pw7\Copilot\Resultados\TENANT\RUN'
```

El recuperador no requiere autenticación ni módulos Microsoft y no realiza llamadas de red. Crea una carpeta hermana cuyo nombre contiene `-recuperado-`, conserva los archivos originales sin modificación y analiza una copia. Mantiene `FinUTC` original sin inventar un cierre; registra `RecuperacionUTC` por separado. Conserva los JSON no interpretables en `archivos-no-interpretados/` dentro de la copia.

El informe lleva una advertencia destacada y toda fuente recuperada requiere validación. El manifiesto nuevo acredita solo el estado de la copia **desde la recuperación**, no la integridad histórica ni la completitud de las consultas. No se admite recuperar una captura que ya tenga manifiesto: una comprobación fallida no debe eludirse mediante regeneración de hashes.

Para futuras capturas interactivas puede iniciarse el recolector directo con `pwsh -NoExit -NoProfile -File ...`; mantiene la sesión tras terminar el archivo, salvo una terminación explícita o un fallo del proceso. No confundir este modo con el lanzador de automatización `Invoke-CopilotAssessment.ps1`, que utiliza códigos de salida y `exit`. Los errores locales del lanzador se guardan en la carpeta de salida configurada o, si no puede leerse la configuración, en `diagnostico-local/` junto al programa.

Prueba específica de recuperación, sin tenant:

```powershell
pwsh -NoProfile -File ./tests/Test-Recovery.ps1
```

## Evidencia adicional y decisiones humanas

El informe distingue **estado de recolección** de **estado de evaluación**. `CompletoSegunPerfil` significa que las consultas automáticas requeridas finalizaron; no certifica cumplimiento ni ausencia de exposición. Los controles empiezan en `NoEvaluado`. La matriz incluye riesgo, responsable, recomendación, condición y evidencia. RACI y plan son propuestas, no cambios aplicados.

Para incorporar una exportación oficial, revisión de permisos efectivos o validación financiera:

```powershell
./Import-AssessmentEvidence.ps1 `
  -RunDirectory './Resultados/TENANT/RUN' -TenantId 'GUID-TENANT' `
  -ControlId FIN-BILLING -EvidenceFile './Factura-revisada.pdf' `
  -Estado Cumple -Revisor 'Responsable FinOps' `
  -Justificacion 'Periodo y contrato verificados por el responsable.'
./Analyze-CopilotAssessment.ps1 -RunDirectory './Resultados/TENANT/RUN'
```

`Cumple/NoCumple/NoEvaluado/NoAplica` es una decisión humana documentada, no una conclusión inferida por el importador. Evidencia y decisión se conservan en `complementos/` con hash, tenant y captura. No se admiten decisiones duplicadas silenciosas. Proteger también el registro de decisión: no está firmado criptográficamente. Los IDs de control admitidos aparecen en `controles-gobierno.csv`.

## Límites que deben constar en el informe final

- SharePoint: sitios comerciales inventariados por PnP, webs/subwebs, listas visibles e ítems dentro de límites y acceso disponible. Excluye OneDrive, listas ocultas y contenido. Los grupos SharePoint se expanden; grupos Entra anidados requieren análisis adicional. Un enlace de organización no equivale a permiso directo para toda la organización. Un enlace anónimo no demuestra que Copilot lo utilice.
- Los permisos amplios son indicios de posible sobreexposición. Validar necesidad, clasificación, etiquetas, acceso restringido y políticas antes de afirmar exposición de datos sensibles o incumplimiento.
- DLP: se calcula solo la inclusión/exclusión declarada por entorno cuando se reconoce el esquema; no se certifica la política efectiva ni restricciones de operaciones/canales.
- Dataverse: roles, equipos y miembros no prueban privilegios efectivos, profundidad, compartición de agentes ni acceso a fuentes. No se consultan tablas de contenido empresarial.
- Reconciliar catálogo M365/Teams, bots clásicos, ALM, aprobaciones y permisos de publicación con evidencias adicionales. No asumir separación nativa entre autor y publicador.
- Facturas y pagos dependen del contrato M365/Azure/CSP. Licencias, planes PAYG habilitados, disponibilidad para asignar créditos, consumo y dinero son conceptos distintos. Adjuntar asignaciones/reglas TenantPool/overage, consumo y fecha de consolidación; no convertir sesiones ni sumar unidades incompatibles.
- Auditoría, retención, alertas y límites requieren evidencia de configuración y operación. Una captura única no demuestra meses de funcionamiento ni recupera datos cuya retención venció.
- No cubre por sí solo toda la seguridad Microsoft 365, OneDrive, Exchange, Teams ni contenido de terceros. El alcance general de Copilot se apoya en uso/adopción, licencias, agentes y evaluación SharePoint más las validaciones indicadas.

## Automatización y códigos de salida

El recolector devuelve `ExitCode` sin cerrar la consola. Para un proceso con código de salida real usar el lanzador:

```powershell
pwsh -NoProfile -File ./Invoke-CopilotAssessment.ps1 -ConfigurationFile './tenant-a.json'
```

Copiar `docs/tenant.example.json`, completar los identificadores no secretos y guardar un archivo por tenant. Nunca guardar tokens o contraseñas en JSON.

- `0`: consultas requeridas completas según perfil automático; revisar siempre evaluación pendiente.
- `2`: captura parcial o preflight; no acreditar evaluación completa.
- `1`: captura fallida o error del lanzador/analizador.

## Pruebas y publicación

```powershell
pwsh -NoProfile -File ./tests/Test-Offline.ps1
```

Las pruebas sustituyen todas las conexiones por simulaciones. Incluyen dos tenants válidos, tenant cruzado, errores de esquema, paginación parcial, reportes, permisos/enlaces SharePoint, roles Dataverse, límites, integridad, CSV y decisiones manuales. No sustituyen un piloto autorizado con las versiones de módulos de cada cliente. No se ha validado contra un tenant real.

`legacy/v1.1.0/` conserva exactamente los tres archivos recibidos. Usar los scripts de la raíz para la versión nueva. Publicar código o ZIP no ejecuta el recolector ni publica agentes o el entorno en la nube.
