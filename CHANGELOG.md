# Cambios

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
