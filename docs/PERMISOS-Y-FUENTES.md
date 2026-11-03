# Fuentes, permisos y preparación

## Microsoft Graph

El recolector utiliza cliente oficial Graph PowerShell o `GraphClientId` corporativo existente. Exige sesión delegada del tenant indicado, nube Global y valida `/organization` antes del resto de consultas. Una sesión reutilizada no obtiene scopes adicionales automáticamente.

| Fuente | Permiso de lectura solicitado al abrir sesión |
|---|---|
| Identidad del tenant | Organization.Read.All |
| SKU | LicenseAssignment.Read.All |
| Usuarios y resolución de propietarios | User.Read.All |
| Roles activos | RoleManagement.Read.Directory |
| PIM elegible/programado | RoleEligibilitySchedule.Read.Directory, RoleAssignmentSchedule.Read.Directory |
| Acceso condicional | Policy.Read.All |
| Grupos/propietarios | Group.Read.All |
| Miembros transitivos, optativo | GroupMember.Read.All |
| Reportes Copilot | Reports.Read.All |
| Privacidad de reportes | ReportSettings.Read.All |

Además del consentimiento delegado, el usuario necesita el rol admitido por cada API. Para los reportes de Copilot, consultar las matrices actuales de roles —incluida la de detalle individual—; no asumir que cualquier lector puede ver todos los reportes. Los miembros ocultos requieren autorización adicional y no se pide automáticamente Member.Read.Hidden.

API de reportes utilizada:

```text
GET /v1.0/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D28',version='v2')
GET /v1.0/copilot/reports/getMicrosoft365CopilotUserCountSummary(period='D28',version='v2')
GET /v1.0/copilot/reports/getMicrosoft365CopilotUserCountTrend(period='D28',version='v2')
```

Se utiliza CSV de v1.0; no se activa beta ni se cae silenciosamente a un endpoint legacy. Una respuesta inesperada queda como ErrorDeEsquema y conserva el original. Graph SDK gestiona el transporte de los reportes. No se guardan encabezados de autorización ni Location.

Fuentes oficiales consultadas:

- https://learn.microsoft.com/microsoft-365-copilot/extensibility/api/admin-settings/reports/copilotreportroot-getmicrosoft365copilotusageuserdetail
- https://learn.microsoft.com/microsoft-365-copilot/extensibility/api/admin-settings/reports/copilotreportroot-getmicrosoft365copilotusercountsummary
- https://learn.microsoft.com/microsoft-365-copilot/extensibility/api/admin-settings/reports/copilotreportroot-getmicrosoft365copilotusercounttrend
- Fuentes Markdown: `MicrosoftDocs/m365copilot-docs`, `docs/api/admin-settings/reports/`.

## Power Platform y PowerApps

- API comercial `https://api.powerplatform.com`, versión `2024-10-01`.
- Inventario: token delegado, `ResourceQuery.Resources.Read`. No se utiliza app-only para este inventario.
- Facturación/capacidad: permisos de lectura del namespace Licensing, incluidos `Licensing.BillingPolicies.Read` y `Licensing.Allocations.Read` según operación, más rol admitido por el servicio. No se asegura que estos scopes basten para todos los endpoints entitlement.
- Token mediante sesión `Az.Accounts`, MSAL con app existente o SecureString suministrado por mecanismo corporativo. Los clientes oficiales pueden estar bloqueados o no autorizados en el tenant.
- PowerApps: autenticación solicitada en el tenant indicado y comprobación independiente del identificador del entorno predeterminado antes de DLP y tenant settings. Si no puede comprobarse, se omiten las consultas administrativas.
- Importación nativa de PowerApps; en Windows se intenta compatibilidad `-UseWindowsPowerShell` si falla. Validar la combinación corporativa de módulos y runtime antes de la captura.

Referencias:

- https://learn.microsoft.com/power-platform/admin/inventory-api
- https://learn.microsoft.com/power-platform/admin/inventory-schema
- https://learn.microsoft.com/power-platform/admin/programmability-authentication-v2
- https://learn.microsoft.com/power-platform/admin/programmability-tutorial-manage-copilot-credit-allocations

## SharePoint

PnP.PowerShell requiere ClientId propio autorizado, acceso al centro de administración y permisos para consultar asignaciones en los sitios. Usa Connect-PnPOnline interactivo por conexión explícita y valida tenant, contexto delegado, audiencia y vigencia del token SharePoint antes de consultar.

Consultas: Get-PnPTenant, Get-PnPTenantSite, Get-PnPWeb, Get-PnPSubWeb, Get-PnPList, Get-PnPListItem, Get-PnPProperty, Get-PnPGroupMember, Get-PnPFileSharingLink y Get-PnPFolderSharingLink. Solo metadatos y permisos.

No se cambia ninguna asignación de permisos. Una denegación de acceso requiere evidencia/acción autorizada del cliente; nunca se añade SCA como solución automática.

- https://pnp.github.io/powershell/cmdlets/Get-PnPTenantSite.html
- https://pnp.github.io/powershell/cmdlets/Get-PnPAccessToken.html
- https://pnp.github.io/powershell/cmdlets/Get-PnPProperty.html
- https://pnp.github.io/powershell/cmdlets/Get-PnPFileSharingLink.html

## Dataverse

GET de Web API v9.2: WhoAmI; systemusers, teams, roles, bots; asociaciones systemuserroles_association, teamroles_association y teammembership_association. Hosts comerciales `*.crmN.dynamics.com` descubiertos desde el inventario administrativo. No se aceptan URL arbitrarias ni continuaciones hacia otro origen sin token registrado.

Az.Accounts obtiene token delegado del origen del entorno; se valida tenant, audiencia y expiración. El usuario necesita privilegios de lectura de dichas tablas/asociaciones. Algunos entornos o versiones pueden no exponer la tabla de agentes con el esquema esperado; se conserva el error y no se inventa un resultado vacío.

No se asignan privilegios, se crean application users ni se consulta contenido de tablas empresariales. Los metadatos de usuarios incluyen identidades de aplicación cuando el servicio las devuelve. Validar compartición y privilegios efectivos como evidencia adicional.

## Facturación y monitoreo

El paquete no solicita nuevos tokens financieros ni exporta facturas/Purview automáticamente. Adjuntar exportaciones oficiales con Import-AssessmentEvidence, identificando tenant, periodo, responsable y decisión. El informe conserva como NoEvaluado los controles sin decisión verificada. No debe confundirse esta limitación con una ausencia de controles del tenant.
