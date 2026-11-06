# Cambios

## 2.0.5

- Documenta la distinción entre AllSites.FullControl delegado de la aplicación y Enumerate Permissions/Control total del usuario en cada alcance. Administrador global no equivale a administrador de todos los sitios.
- Prueba acotada Test-SharePointAccess.ps1: un sitio, un intento PnP, scopes conocidos, derechos efectivos, lectura de asignaciones/subwebs/listas; sin cambios de permisos ni tokens exportados.
- Diagnósticos conservan etapa, archivo/línea, tipo interno y código CSOM; reconoce denegaciones conocidas aunque PnP las reduzca a Exception sin HTTP. No guarda mensajes originales ni inventa códigos HTTP.
- Mantiene el login PnP único y los demás clientes independientes. No afirma corregidos en tenant los 27 errores originales sin ejecutar la prueba de acceso.

## 2.0.4

- Corrige el login interactivo por sitio/subsitio: un intento PnP y reutilización de token delegado exclusivamente en memoria, también para el contexto administrativo.
- Las consultas usan conexiones AccessToken sin fallback interactivo; cancelación, token inválido/caducado y HTTP 401 detienen SharePoint, conservan evidencias y registran cobertura parcial. HTTP 403 no abre otra sesión.
- Registra número de intentos interactivos y detención de autenticación en SharePointProceso.json, sin tokens.
- Corrige resultTruncated según el SDK oficial de Power Platform: 0 significa truncado y 1 completo; deja de rechazar inventarios completos/vacíos como ErrorDeEsquema.
- Regresiones con 27 sitios y subsitios, cancelación, caducidad, HTTP 401/403 e indicadores de truncamiento. Graph, Azure, PowerApps y PnP conservan autenticaciones iniciales independientes; no se promete login único global.

## 2.0.3

- Las cláusulas KQLOM usan `[ordered]` para colocar `$type` antes de los campos derivados, de acuerdo con la secuencia del serializador del SDK oficial.
- Regresión con el lector polimórfico de .NET: discriminador tardío rechazado y JSON ordenado aceptado. Validación contra el tenant pendiente.
- Diagnóstico versión 1.1 con consulta ordenada y opción `-IncludeClauseTests` para comparar filtro, orden y consulta mínima, además de créditos.
- Se suprime la salida incidental de Set-MgRequestContext para que no oculte el objeto final de resultados en la consola.
- No se modifican permisos o licencias y no se interpreta HTTP 404 de créditos como ausencia confirmada de capacidad.

## 2.0.2

- SharePoint/PnP se ejecuta en un proceso PowerShell propio, separado de Graph, Azure y PowerApps; conserva el TenantId/RunId de la captura y no transfiere tokens.
- El padre importa resultados y cobertura del worker, detecta salida abrupta/timeout y puede finalizar la captura parcial con manifiesto.
- Funciones locales de token separadas de la autenticación Graph/Azure para evitar importar esos SDK en el worker PnP.
- Inventario ordenado por `name` documentado; tipo comparado con `in~`; SkipToken omitido en la primera página; especificación de consulta registrada sin tokens de continuación.
- Diagnóstico distingue HTTP 400/404 de denegaciones 401/403 y conserva solo códigos estructurados del servicio, sin mensajes completos ni cuerpos.
- El HTTP 400 original y el 404 de créditos requieren validación posterior en el tenant; no se afirma resueltos ni se interpretan como cero recursos/capacidad.

## 2.0.1

- Recuperador offline para capturas sin manifiesto: nueva carpeta, originales intactos, evidencia corrupta separada e informe parcial con límites de integridad explícitos.
- Conserva FinUTC original y registra la fecha de recuperación por separado; no convierte archivos recuperados en consultas acreditadas como completas.
- Checkpoints de cobertura, diagnóstico y progreso; escritura JSON mediante archivo temporal y reemplazo atómico.
- Diagnóstico sanitizado persistente del lanzador y guía de inicio interactivo con `-NoExit`.
- El análisis de enlaces admite una captura sin FinUTC y utiliza InicioUTC como referencia provisional, sin afirmar cierre.
- No se atribuye una causa al cierre de la ventana reportado ni se afirma corregido un fallo no reproducido en el equipo del cliente.

## 2.0.0

- Alcance general M365 Copilot: reportes oficiales de detalle, adopción y tendencia, API v1.0 y reporte v2 explícito; periodo D28, privacidad y fecha de actualización.
- SharePoint: inventario administrativo, configuración, webs/subwebs, listas visibles, permisos únicos, miembros de grupos SharePoint y enlaces, sin contenido ni URL de compartición.
- Dataverse: usuarios/application users, equipos, roles, asociaciones y metadatos de agentes; PIM y resolución de identidades por Graph.
- Validación estricta de colecciones y objetos, paginación correlacionada, conservación de evidencia parcial y diagnóstico sanitizado.
- TenantId obligatorio, resultados segregados por tenant/captura, estados de recolección/evaluación separados y lanzador con códigos 0/1/2.
- Límites y tiempo de ejecución, renovación disponible de tokens, reintentos REST/Graph acotados, manifiestos y análisis offline repetible.
- Matriz de controles, indicadores, aplicabilidad DLP declarada, RACI y plan; incorporación explícita de evidencia y decisiones humanas.
- Conservación intacta del paquete original v1.1.0; pruebas simuladas ampliadas. Requiere PowerShell 7.4.6+; sin validación contra tenants reales.
