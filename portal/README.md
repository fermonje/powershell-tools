# Portal CIT · Diagnóstico MFA

Portal privado con histórico y métricas agregadas por empresa. El HTML local contiene el detalle nominal. El portal recibe el JSON generado por PowerShell.

## Demo local

Con Node.js 22 o superior, desde la raíz del repositorio:

```powershell
node .\portal\server.mjs --demo
```

Abrí `http://127.0.0.1:3000`, seleccioná **Empresa demo A** y cargá [demo-report.json](demo-report.json). Esperá 120 usuarios, 75 % con alternativa registrada, 20 con solo SMS o voz y 10 sin método MFA. Seleccioná **Empresa demo B** para ver su historial vacío. Demo escucha solo en loopback, omite el inicio de sesión y usa `.demo-data` en el directorio de ejecución. Usá datos ficticios.

## Validar tu tenant

1. En Microsoft Entra, copiá el **Id. de inquilino** desde **Información general**. Usá una cuenta de trabajo con rol **Lector de informes** u otro rol admitido. El tenant necesita Entra ID P1/P2 y consentimiento de administrador para el permiso delegado `AuditLog.Read.All`. [Permisos de Microsoft Graph](https://learn.microsoft.com/graph/api/authenticationmethodsroot-list-userregistrationdetails)
2. Desde la raíz del repositorio, en PowerShell:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
$tenantId = '<GUID de tu tenant>'
.\New-CITAuthReadinessReport\New-CITAuthReadinessReport.ps1 -ExpectedTenantId $tenantId -ExportSummary
```

3. Iniciá sesión en la ventana de Microsoft y verificá el tenant que imprime la consola. Abrí el HTML generado y verificá que el total sea la suma de **Con alternativa registrada**, **Solo SMS o voz** y **Sin método MFA**. Contrastá una muestra de usuarios con el informe **Métodos de autenticación → Actividad → Registro** de Entra. Considerá el retraso del informe de Graph y las exclusiones de invitados y cuentas deshabilitadas.
4. Una vez configurado el portal privado, iniciá sesión, seleccioná tu empresa y cargá el **JSON** de esa misma ejecución. Compará el total, los conteos y el porcentaje con el HTML. Verificá que una segunda cuenta sin asignación reciba acceso denegado. Con una segunda empresa de prueba, intentá leer y cargar en su URL desde la primera cuenta y verificá el rechazo.

Un `403` de Graph requiere revisar consentimiento y rol. Un rechazo del portal al cargar requiere revisar que el tenant del JSON coincida con el tenant asociado a la empresa. Los indicadores describen métodos registrados y sirven para priorizar revisión. Confirmá políticas y métodos disponibles antes de asignar impacto individual.

## Despliegue privado

Usá **Azure App Service Linux** con Node.js 22 o superior y una sola instancia para el piloto. Empaquetá el contenido de `portal/` en la raíz del ZIP de despliegue y configurá `npm start` como comando de inicio. Habilitá HTTPS obligatorio y almacenamiento persistente. Verificá que un reinicio conserve el histórico.

Desde la raíz del repositorio, prepará el ZIP con los archivos de ejecución:

```powershell
$portalFiles = 'server.mjs','package.json','index.html','app.js','style.css','cit-logo.svg' |
    ForEach-Object { Join-Path .\portal $_ }
$zip = Join-Path ([IO.Path]::GetTempPath()) 'cit-portal-mfa.zip'
Compress-Archive -LiteralPath $portalFiles -DestinationPath $zip -Force
```

Para un piloto hasta febrero de 2027, usá el hostname HTTPS de App Service o vinculá un subdominio de CIT cuando tengas acceso al DNS. Configurá el valor de `CIT_ORIGIN` con el hostname que usarán los clientes. Antes de cerrar el servicio, exportá el histórico que deba conservarse, revocá las claves de carga y retirale a los clientes la asignación a la aplicación. Si el plan es exclusivo de este portal, retiralo al cierre para terminar la facturación. [Planes de App Service Linux](https://azure.microsoft.com/en-us/pricing/details/app-service/linux/)

En **Authentication**, agregá Microsoft Entra como proveedor de un solo tenant, el de CIT. Exigí inicio de sesión en todas las rutas del portal y configurá redirección a Microsoft. Asigná acceso a la aplicación a los operadores autorizados. Invitá a operadores de clientes como usuarios B2B en Entra CIT y registrá sus **Object IDs del directorio CIT** en la empresa que corresponda. Los Object IDs de la cuenta original en el directorio del cliente pueden ser distintos. La aplicación toma las identidades de los encabezados insertados por App Service Authentication. Desplegá el servidor detrás de esa capa en todos los accesos. [Identidades en App Service Authentication](https://learn.microsoft.com/azure/app-service/configure-authentication-user-identities)

Configuración de App Service:

| Variable | Valor |
|---|---|
| `CIT_LOGIN_TENANT` | GUID del directorio CIT, en minúsculas |
| `CIT_ORIGIN` | Origen público HTTPS, sin barra final |
| `CIT_DATA_DIR` | Directorio persistente privado, por ejemplo `/home/cit-data` |
| `CIT_CUSTOMERS` | JSON indexado por GUID de cada tenant relevado, en minúsculas |

Ejemplo de `CIT_CUSTOMERS`:

```json
{
  "11111111-1111-4111-8111-111111111111": {
    "name": "Empresa A",
    "members": ["33333333-3333-4333-8333-333333333333"]
  }
}
```

El portal guarda una copia validada por medición y deduplica cargas idénticas. Definí la retención y respaldá `CIT_DATA_DIR` antes de incorporar clientes reales. Para el piloto, el alta y la baja de usuarios se gestionan en la configuración de App Service.

## Carga automática opcional

1. En el **tenant del cliente**, registrá una aplicación de un solo tenant con certificado. Concedé y consentí **Microsoft Graph → Application → AuditLog.Read.All**. Instalá el certificado con clave privada para la cuenta Windows que ejecutará el colector. [Conexión de Graph con certificado](https://learn.microsoft.com/powershell/microsoftgraph/app-only)
2. Generá una clave aleatoria de 32 bytes codificada como 64 caracteres hexadecimales en minúsculas. Guardá la clave en el almacén de secretos del cliente y agregá su SHA-256 hexadecimal, calculado sobre el texto UTF-8 de la clave, como `ingestHash` en la empresa correspondiente. Usá una clave distinta por empresa.
3. Solo al habilitar la carga automática, excluí **exactamente** `/api/ingest` de la validación global de App Service Authentication mediante `globalValidation.excludedPaths` en `authsettingsV2`. Conservá las demás reglas. Esta ruta verifica la clave de la empresa en el servidor y solo admite cargas. Probá acceso anónimo a `/` y a las rutas de lectura desde fuera de Azure. [Configuración authsettingsV2](https://learn.microsoft.com/azure/templates/microsoft.web/sites/config-authsettingsv2)
4. Probá manualmente con los parámetros siguientes. Para programarlo, ejecutá el mismo comando desde el Programador de tareas bajo la cuenta que puede leer el certificado y recuperar el secreto. Reemplazá la lectura interactiva de la clave por una lectura desde ese almacén.

```powershell
$token = Read-Host 'Clave de carga CIT' -AsSecureString
.\New-CITAuthReadinessReport\New-CITAuthReadinessReport.ps1 `
  -ExpectedTenantId '<GUID del cliente>' -ClientId '<GUID de la aplicación>' `
  -CertificateThumbprint '<huella del certificado>' -SummaryOnly `
  -OutputFolder 'C:\CIT\Resumenes' -PortalUrl 'https://portal.ejemplo.com' -PortalToken $token
```

El resumen se guarda antes del envío. Si falla la red o la API, podés cargar ese archivo manualmente. Configurá alertas de tarea fallida y rotación del certificado y de la clave de carga.
