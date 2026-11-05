# Validación

## Versión 2.0.4

PowerShell 7.4.6/Linux: **1521 aserciones y 738 llamadas simuladas** en la suite principal; **30 aserciones** de diagnóstico y **28** de recuperación. Sin conexiones reales a tenants.

Workers PowerShell reales con módulo PnP ficticio: 27 sitios y un subsitio por sitio completados con un solo intento interactivo. Cancelación inicial y token vencido no reintentan. HTTP 401 detiene el recorrido en el primer sitio; HTTP 403 registra las 27 denegaciones usando el mismo token. Las conexiones posteriores exigen AccessToken en la fixture y un segundo Connect-PnPOnline interactivo hace fallar el escenario. Los resultados no contienen tokens ni URL de compartición.

La interpretación de resultTruncated sigue el modelo ResourceQueryResponse del SDK oficial powerplatform-management 2.0.3578.333: 0 truncado, 1 completo. Se prueban inventario completo/vacío, paginado y truncado sin continuación, además de un indicador desconocido. La confirmación contra el tenant, las políticas de sesión y PnP 3.4.1/Windows continúa pendiente. No se acredita login único entre Graph, Azure, PowerApps y SharePoint.

## Versión 2.0.3

PowerShell 7.4.6/Linux: **1116 aserciones y 525 llamadas simuladas** en la suite principal; **30 aserciones** en diagnóstico (tres solicitudes simuladas normales y cinco ampliadas); **28 aserciones** de recuperación. Resultado OK, sin conexiones reales a tenants.

La regresión de serialización usa el lector polimórfico real de System.Text.Json: rechaza un `$type` colocado después de campos de la clase derivada y acepta la consulta ordenada. Se verifica también que el JSON efectivo del recolector emite `$type` primero en `where` y `orderby`, y que Set-MgRequestContext no agrega objetos incidentales a la salida final.

El diagnóstico del cliente confirmó `take 1` HTTP 200 (un recurso) y filtro+orden HTTP 400 con `KQLOM format is wrong or it cannot be null`. Se contrastaron modelos y secuencia de serialización del SDK oficial `powerplatform-management` 2.0.3578.333; la distribución descargada se verificó contra el SHA-256 de PyPI. Esto respalda la corrección de orden, pero su aceptación por el endpoint del tenant todavía requiere la prueba de diagnóstico versión 1.1. El HTTP 404 de MCSMessages no tiene una causa definitiva identificada.

## Herramienta de diagnóstico acotado Power Platform

`tests/Test-PowerPlatformProbe.ps1`: **14 aserciones y tres solicitudes simuladas, OK** en PowerShell 7.4.6/Linux. Verifica lectura de errores de validación Problem Details desde una respuesta byte[], comparación de consultas actual/mínima, preservación de HTTP/código de servicio, redacción del token conocido y omisión de recursos de inventario devueltos correctamente. No se ejecutó contra el tenant; el diagnóstico real requiere ejecución autorizada del usuario.

## Versión 2.0.2

Suite principal: **1046 aserciones y 525 llamadas simuladas, OK**, PowerShell 7.4.6/Linux. Los workers utilizan procesos `pwsh` reales con un módulo PnP ficticio creado en una carpeta temporal; no cargan PnP real ni se conectan al tenant. Se verifica PID diferente, captura de permisos/enlaces, cobertura común y supervivencia/cierre del padre cuando un hijo termina con código 77. Esta terminación controlada prueba el límite de proceso; no reproduce el stack overflow interno de PnP.

También se comprueban la consulta por `name`, HTTP 400 con código estructurado sin exportar el mensaje libre y HTTP 404 de créditos como disponibilidad no acreditada. La consulta corregida no se ha ejecutado aquí contra el tenant del cliente y el 404 no tiene una causa definitiva identificada.

Evidencia del cliente: PnP 3.4.1 conectó correctamente por separado en PowerShell 7.6.9, mientras la sesión combinada terminó por stack overflow en ResolveDependency. Esto respalda aislar procesos, sin identificar aún la dependencia concreta ni certificar acceso administrativo a todos los sitios.

## Versión 2.0.1

Pruebas locales en PowerShell 7.4.6/Linux, sin tenant: suite principal **811 aserciones y 435 llamadas simuladas, OK**; suite adicional `tests/Test-Recovery.ps1`, **28 aserciones, OK**. Verifica copia independiente, originales intactos, estado parcial, FinUTC original sin cambios, JSON inválido conservado, fuentes ausentes no equiparadas a inventario vacío, hashes desde recuperación, advertencia en informe, reanálisis offline y rechazo de recuperación sobre una captura con manifiesto.

La suite principal verifica además progreso persistente y checkpoint final coherente. La recuperación de la carpeta real del cliente y la causa del cierre en Windows/PowerShell 7.6.9 no se han validado aquí. No se afirma que el cambio corrija una terminación del runtime o del equipo.

## Versión 2.0.0

Validación local del código en PowerShell 7.4.6 sobre Linux. No se utilizaron cuentas, credenciales ni conexiones reales a tenants Microsoft 365.

## Pruebas simuladas

`tests/Test-Offline.ps1`: **807 aserciones, 435 llamadas simuladas, resultado OK**.

Cobertura relevante:

- Dos tenants válidos y carpetas independientes; sesión Graph de otro tenant reconectada explícitamente; rechazo de token incompatible sin consultar recursos.
- Tenant PowerApps verificado por su entorno predeterminado y rechazo de tenant SharePoint incompatible.
- Reportes de detalle, resumen y tendencia v2 con periodo D28; cálculos de adopción; CSV vacío válido, cuerpo incompatible y periodo devuelto incorrecto.
- Colecciones Graph sin `value`, inventario con `data=null`, paginación incompleta y ciclos; conservación de páginas parciales.
- Roles directos/de equipos Dataverse y consultas de metadatos mediante transporte simulado.
- Permisos de audiencia amplia vía grupos SharePoint, enlaces anónimos, límites y conservación de evidencia parcial.
- HTTP 403 diferenciado de inventario vacío; 429 con HttpStatusCode enum y reintento; renovación de token gestionado y rechazo de token externo expirado.
- Identificadores por fila, neutralización de fórmulas, ausencia de tokens/URL de compartición en los resultados simulados e integridad SHA-256.
- Análisis offline repetible, evidencia complementaria con decisión humana, detección de alteración y DLP de esquema desconocido sin inferir exclusión.
- Preflight y NoInteractive diferenciados de una captura completa.

Los avisos de fuentes fallidas en escenarios adversos son resultados esperados de estas pruebas. El recuento de llamadas es del transporte simulado, no de solicitudes a Microsoft.

## Validación adicional

- Lanzador ejecutado en un proceso independiente con todas las fuentes deshabilitadas: resultado Fallido y código de proceso **1**, sin consultas remotas.
- Revisión sintáctica de los scripts con el parser de PowerShell.
- Conservación byte por byte de los tres archivos adjuntos originales en `legacy/v1.1.0/`.
- Paquete de distribución con lista explícita de archivos y manifiesto SHA-256; excluye datos de tenant, configuración local y metadatos Git.

## Validación pendiente fuera de este entorno

- Piloto autorizado en cada tenant y combinación corporativa de módulos/PowerShell.
- Ejecución en Windows y del fallback de compatibilidad de PowerApps; no probados aquí con módulos reales.
- Disponibilidad, permisos, esquema efectivo y retraso de actualización de las fuentes Microsoft en cada tenant.
- Evidencia adicional de catálogo/publicación, DLP efectiva, privilegios y acceso efectivo, asignaciones/consumo/facturación, auditoría y controles operativos.

Un resultado local OK no acredita funcionamiento contra tenants reales ni cumplimiento de los controles. Las decisiones de gobierno deben cerrarse con evidencia verificada por los responsables de cada tenant.
