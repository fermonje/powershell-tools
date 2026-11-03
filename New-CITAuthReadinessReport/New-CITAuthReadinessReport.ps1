<#PSScriptInfo

.VERSION 1.0.2

.GUID e99f000c-55df-47ff-924f-325ce262a09e

.AUTHOR Consultores en IT (adaptación)

.COMPANYNAME CIT

.COPYRIGHT (c) 2026 Mandover (original), MIT

.TAGS Entra EntraID MFA Authentication Passkeys FIDO2 SMS Voice Microsoft365 M365 Graph Report Security CIT Windows

.LICENSEURI https://github.com/mandover-tools/powershell-tools/blob/main/LICENSE

.PROJECTURI https://www.consultoresenit.com.ar/

.ICONURI

.EXTERNALMODULEDEPENDENCIES

.REQUIREDSCRIPTS

.EXTERNALSCRIPTDEPENDENCIES

.RELEASENOTES
1.0.2 - The days-left counter now uses local calendar days (it changed at 01:00 Spanish time instead of midnight).
1.0.1 - The report now covers internal users (tenant members) only; guest accounts are always left out. Removed the phishing-resistant card. Notice wording aligned with Microsoft's documentation. Released under the MIT license.
1.0.0 - First public release. Readiness report for Microsoft's retirement of SMS and voice authentication in Entra ID.

.PRIVATEDATA

#>

#Requires -Version 5.1

<#
.SYNOPSIS
    Generates a self-contained HTML report showing how ready a Microsoft Entra tenant is for the retirement of SMS and voice authentication.

.DESCRIPTION
    - Reads the authentication methods registration report from Microsoft Graph (reports/authenticationMethods/userRegistrationDetails)
    and writes a single HTML file with no external dependencies. It answers one question: how many users are ready for
    Microsoft's retirement of SMS and voice authentication, and who is not.
      - Notice with Microsoft's published dates and the days left.
      - Cards: ready users, SMS or voice only, no MFA, and admins relying only on SMS or voice.
        Every card, bar segment and method opens the list of users.
      - ES / EN switch inside the report.
    Read-only: it changes nothing in the tenant. It runs locally and sends no data anywhere except to Microsoft Graph.
    Microsoft leaves disabled and recently deleted accounts out of this report. Only internal users (tenant members) are analysed; guest accounts are always left out.

.PARAMETER OutputFolder
    Folder where the HTML file is saved. Default: Documents\CIT

.PARAMETER Language
    Initial language of the report (es or en). It can be switched inside the report.

.PARAMETER NoOpen
    Do not open the HTML file when finished.

.PARAMETER Pause
    Wait for Enter before closing. It is enabled automatically when the script is started from File Explorer.

.PARAMETER TaglineEs
    Header text in Spanish (optional).

.PARAMETER TaglineEn
    Header text in English (optional).

.NOTES
    Delegated permission: AuditLog.Read.All (the minimum documented by Microsoft for userRegistrationDetails). An administrator must grant consent the first time.
    Roles: Reports Reader, Security Reader, Security Administrator, Global Reader or higher.
    Microsoft license required: Microsoft Entra ID P1 or P2.
    Script license: MIT.
    Module: Microsoft.Graph.Authentication (the full Microsoft Graph SDK is not needed).
    Save this file as UTF-8 with BOM for Windows PowerShell 5.1.

.LINK
    https://www.consultoresenit.com.ar/

.EXAMPLE
    New-CITAuthReadinessReport

.EXAMPLE
    New-CITAuthReadinessReport -Language en -NoOpen
#>

[CmdletBinding()]
param(
    [string]$OutputFolder = '',
    [ValidateSet('es', 'en')][string]$Language = 'es',
    [switch]$NoOpen,
    [switch]$Pause,
    [string]$TaglineEs = '',
    [string]$TaglineEn = '',
    [guid]$ExpectedTenantId,
    [switch]$ExportSummary,
    [switch]$SummaryOnly,
    [uri]$PortalUrl,
    [securestring]$PortalToken,
    [guid]$ClientId,
    [string]$CertificateThumbprint
)

$ErrorActionPreference = 'Stop'
if ($PortalUrl -or $PortalToken) {
    if (-not ($PortalUrl -and $PortalToken -and $ExpectedTenantId -and
        $PortalUrl.IsAbsoluteUri -and $PortalUrl.Scheme -eq 'https' -and
        -not $PortalUrl.UserInfo -and $PortalUrl.PathAndQuery -eq '/' -and -not $PortalUrl.Fragment)) {
        throw 'Para publicar indica PortalUrl (origen HTTPS), PortalToken y ExpectedTenantId.'
    }
}

# ----------------------------------------------------------------------------------------------
# Pausa para poder leer los mensajes cuando el script se lanza con clic derecho > "Ejecutar con
# PowerShell" (la ventana se cerraría sola al terminar). También se activa con -Pause.
# ----------------------------------------------------------------------------------------------
function Test-ShouldPause {
    if ($Pause) { return $true }
    try {
        $parentId = (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop).ParentProcessId
        return ((Get-Process -Id $parentId -ErrorAction Stop).ProcessName -eq 'explorer')
    }
    catch { return $false }
}
function Wait-ForKeyIfNeeded {
    if (Test-ShouldPause) {
        Write-Host ''
        [void](Read-Host 'Pulsa Intro para cerrar esta ventana')
    }
}
if (-not $OutputFolder) {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docs) { $docs = $HOME }
    $OutputFolder = Join-Path $docs 'CIT'
}
trap {
    if (Test-ShouldPause) {
        Write-Host ''
        Write-Host ($_ | Out-String) -ForegroundColor Red
        Wait-ForKeyIfNeeded
    }
    break
}

# ----------------------------------------------------------------------------------------------
# Utilidades Graph
# ----------------------------------------------------------------------------------------------
function Invoke-GraphWithRetry {
    param([Parameter(Mandatory)][string]$Uri)
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            return Invoke-MgGraphRequest -Method GET -Uri $Uri
        }
        catch {
            $msg = $_.Exception.Message
            $transient = $msg -match '429|TooManyRequests|503|504|ServiceUnavailable|GatewayTimeout'
            if (-not $transient -or $attempt -eq 4) { throw }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt))
        }
    }
}

function Get-GraphPaged {
    param([Parameter(Mandatory)][string]$Uri)
    $items = New-Object System.Collections.Generic.List[object]
    $page = 0
    while ($Uri) {
        $page++
        Write-Progress -Activity 'Leyendo Microsoft Graph' -Status "Página $page ($($items.Count) registros)"
        $resp = Invoke-GraphWithRetry -Uri $Uri
        foreach ($i in $resp['value']) { $items.Add($i) }
        $Uri = $resp['@odata.nextLink']
    }
    Write-Progress -Activity 'Leyendo Microsoft Graph' -Completed
    return , $items
}

function Get-GraphErrorText {
    # Invoke-MgGraphRequest deja el cuerpo de la respuesta de error fuera de Exception.Message; lo recuperamos.
    param([Parameter(Mandatory)]$ErrorRecord)
    $text = [string]$ErrorRecord.Exception.Message
    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $text += ' ' + [string]$ErrorRecord.ErrorDetails.Message }
    }
    catch { Write-Verbose 'Sin ErrorDetails.' }
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp -and $resp.Content) { $text += ' ' + [string]$resp.Content.ReadAsStringAsync().Result }
    }
    catch { Write-Verbose 'Sin cuerpo de respuesta.' }
    return $text
}

# ----------------------------------------------------------------------------------------------
# Conexión
# ----------------------------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    $edition = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'Windows PowerShell' }
    Write-Host ''
    Write-Host "Falta el módulo Microsoft.Graph.Authentication en $edition $($PSVersionTable.PSVersion)." -ForegroundColor Yellow
    Write-Host 'Los módulos de Windows PowerShell 5.1 y de PowerShell 7 están en carpetas distintas: hay que instalarlo desde la misma ventana desde la que ejecutas este script:' -ForegroundColor Yellow
    Write-Host '    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser' -ForegroundColor Cyan
    Write-Host 'Si pide instalar NuGet o confiar en el repositorio PSGallery, acepta.' -ForegroundColor Yellow
    Wait-ForKeyIfNeeded
    throw "Instala Microsoft.Graph.Authentication antes de ejecutar el informe."
}
Import-Module Microsoft.Graph.Authentication

$connection = @{ ContextScope = 'Process'; NoWelcome = $true }
if ($ExpectedTenantId) { $connection.TenantId = $ExpectedTenantId.ToString() }
if ($ClientId -or $CertificateThumbprint) {
    if (-not ($ClientId -and $CertificateThumbprint -and $ExpectedTenantId)) {
        throw 'Para autenticar la aplicación indica ExpectedTenantId, ClientId y CertificateThumbprint.'
    }
    $connection.ClientId = $ClientId.ToString()
    $connection.CertificateThumbprint = $CertificateThumbprint
}
else {
    $connection.Scopes = @('AuditLog.Read.All')
}

try {
    try {
        Connect-MgGraph @connection | Out-Null
    }
    catch {
        Write-Host ''
        Write-Host 'No se pudo iniciar sesión en Microsoft Graph.' -ForegroundColor Yellow
        Write-Host $_.Exception.Message -ForegroundColor DarkGray
        Write-Host 'Si el mensaje habla de un ensamblado (assembly) o de una versión, suele ser un conflicto con otros módulos cargados (Exchange Online, Az...).' -ForegroundColor Yellow
        Write-Host 'Cierra esta ventana, abre una nueva solo con este script y actualiza el módulo: Update-Module Microsoft.Graph.Authentication' -ForegroundColor Yellow
        Wait-ForKeyIfNeeded
        throw
    }
    $ctx = Get-MgContext
    $tenantId = ([guid]$ctx.TenantId).ToString()
    if ($ExpectedTenantId -and $tenantId -ne $ExpectedTenantId.ToString()) {
        throw "El tenant conectado ($tenantId) no coincide con el esperado ($ExpectedTenantId)."
    }
    $base = 'https://graph.microsoft.com/v1.0'

    # Nombre del tenant (opcional: si falta permiso se usa el identificador)
    $tenantName = $tenantId
    try {
        $org = Invoke-GraphWithRetry -Uri "$base/organization?`$select=displayName"
        if ($org['value'] -and $org['value'][0]['displayName']) { $tenantName = [string]$org['value'][0]['displayName'] }
    }
    catch { Write-Verbose 'No se pudo leer el nombre del tenant; se usará el identificador.' }

    # ------------------------------------------------------------------------------------------
    # Datos de registro de métodos
    # ------------------------------------------------------------------------------------------
    Write-Host "Tenant: $tenantName ($tenantId)" -ForegroundColor Cyan
    Write-Host 'Leyendo el informe de registro de métodos de autenticación...' -ForegroundColor Cyan
    try {
        $rows = Get-GraphPaged -Uri "$base/reports/authenticationMethods/userRegistrationDetails?`$top=999"
    }
    catch {
        $m = Get-GraphErrorText $_
        $code = [regex]::Match($m, '"code"\s*:\s*"([^"]+)"').Groups[1].Value
        $reqId = [regex]::Match($m, '"request-id"\s*:\s*"([^"]+)"').Groups[1].Value
        $detail = if ($code) { "Graph: $code (request-id $reqId)" } else { $m.Substring(0, [math]::Min(300, $m.Length)) }
        if ($m -match 'NonPremium|premium license') {
            Write-Host ''
            Write-Host 'No se puede generar el panel: este tenant no tiene licencia Microsoft Entra ID P1 o P2.' -ForegroundColor Yellow
            Write-Host 'Microsoft exige P1 o P2 para el informe de registro de métodos de autenticación.' -ForegroundColor Yellow
            Write-Host 'P1 se incluye, por ejemplo, en Microsoft 365 Business Premium, E3 y E5.' -ForegroundColor Yellow
            Write-Host $detail -ForegroundColor DarkGray
            Wait-ForKeyIfNeeded
            throw
        }
        elseif ($m -match 'Forbidden|403|Authorization_RequestDenied|Insufficient') {
            Write-Host ''
            Write-Host 'Acceso denegado (403) al informe de métodos de autenticación. Causas posibles:' -ForegroundColor Yellow
            Write-Host '  1) El tenant no tiene Entra ID P1 o P2.' -ForegroundColor Yellow
            Write-Host '  2) Falta el permiso AuditLog.Read.All consentido (lo concede un administrador la primera vez).' -ForegroundColor Yellow
            Write-Host '  3) La cuenta no tiene un rol Reports Reader, Security Reader, Security Administrator, Global Reader o superior.' -ForegroundColor Yellow
            Write-Host $detail -ForegroundColor DarkGray
            Wait-ForKeyIfNeeded
            throw
        }
        else { throw }
    }

    # ------------------------------------------------------------------------------------------
    # Normalización
    # ------------------------------------------------------------------------------------------
    $phoneMethods = @('mobilePhone', 'alternateMobilePhone', 'officePhone')
    $users = foreach ($r in $rows) {
        $methods = [string[]]@($r['methodsRegistered'] | Where-Object { $_ })
        $mfaMethods = @($methods | Where-Object { $_ -cnotin @('email', 'securityQuestion', 'temporaryAccessPass') })
        $category = if ($mfaMethods.Count -eq 0) { 'noMfa' }
            elseif ($mfaMethods | Where-Object { $_ -cnotin $phoneMethods }) { 'ready' }
            else { 'smsOnly' }
        $default = $r['userPreferredMethodForSecondaryAuthentication']
        if (-not $default) { $default = $r['defaultMfaMethod'] }
        $updated = ''
        if ($r['lastUpdatedDateTime']) { $updated = ([datetime]$r['lastUpdatedDateTime']).ToUniversalTime().ToString('yyyy-MM-dd') }

        [pscustomobject]@{
            name                = [string]$r['userDisplayName']
            upn                 = [string]$r['userPrincipalName']
            type                = ([string]$r['userType']).ToLowerInvariant()
            admin               = [bool]$r['isAdmin']
            methods             = $methods
            category            = $category
            defaultMethod       = [string]$default
            mfaRegistered       = [bool]$r['isMfaRegistered']
            mfaCapable          = [bool]$r['isMfaCapable']
            ssprEnabled         = [bool]$r['isSsprEnabled']
            ssprRegistered      = [bool]$r['isSsprRegistered']
            ssprCapable         = [bool]$r['isSsprCapable']
            passwordlessCapable = [bool]$r['isPasswordlessCapable']
            lastUpdated         = $updated
        }
    }
    $users = @($users)
    # Solo usuarios internos (miembros del tenant): los invitados se excluyen siempre.
    $guestsExcluded = @($users | Where-Object { $_.type -eq 'guest' }).Count
    $users = @($users | Where-Object { $_.type -ne 'guest' })
    Write-Host ("Usuarios analizados: {0}" -f $users.Count) -ForegroundColor Green
    if ($guestsExcluded -gt 0) {
        Write-Host ("Invitados excluidos: {0}" -f $guestsExcluded) -ForegroundColor DarkGray
    }
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

# ----------------------------------------------------------------------------------------------
# Generación del HTML
# ----------------------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$idShort = if ($tenantId.Length -ge 8) { $tenantId.Substring(0, 8) } else { $tenantId }
$reportName = "CIT-AuthReadiness-$idShort-$stamp"
if ($ExportSummary -or $SummaryOnly -or $PortalUrl) {
    $counts = [ordered]@{ total = $users.Count; ready = 0; smsOnly = 0; noMfa = 0; adminSms = 0; guestsExcluded = $guestsExcluded }
    foreach ($user in $users) {
        $counts[$user.category]++
        if ($user.admin -and $user.category -eq 'smsOnly') { $counts.adminSms++ }
    }
    $summary = [ordered]@{
        version = 1
        tenantId = $tenantId
        collectedAt = [datetime]::UtcNow.ToString('o')
        counts = $counts
    }
    $summaryPath = Join-Path $OutputFolder "$reportName.json"
    [IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    Write-Host "Resumen para el portal: $summaryPath" -ForegroundColor Green
    if ($PortalUrl) {
        $headers = @{ Authorization = 'Bearer ' + ([pscredential]::new('cit', $PortalToken)).GetNetworkCredential().Password }
        $endpoint = [uri]::new($PortalUrl, '/api/ingest')
        Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -ContentType 'application/json' -InFile $summaryPath -MaximumRedirection 0 | Out-Null
        Write-Host 'Resumen enviado al portal CIT.' -ForegroundColor Green
    }
}
if ($SummaryOnly) { return }

$meta = [pscustomobject]@{
    tenantId             = $tenantId
    tenantName           = $tenantName
    generated            = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    lang                 = $Language
    taglineEs            = $TaglineEs
    taglineEn            = $TaglineEn
    guestsExcluded       = [int]$guestsExcluded
    phoneMethods         = $phoneMethods
}


function ConvertTo-SafeJson($obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 5 -Compress
    # Evita cerrar el <script> y separadores de línea Unicode problemáticos en JS
    return $json.Replace('</', '<\/').Replace([string][char]0x2028, '\u2028').Replace([string][char]0x2029, '\u2029')
}

$template = @'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CIT · SMS and voice retirement readiness</title>
<style>
:root{--bg:#0B1E38;--surf:#0F2A4A;--surf2:#14355d;--brand:#233DFF;--light:#97C9FC;--gray:#979DAD;--ok:#2ECC71;--warn:#F2A93B;--bad:#EA5A5F;--line:rgba(151,201,252,.16);--txt:#E8EEF8;color-scheme:dark}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--txt);font:13px/1.45 'Poppins','Segoe UI',system-ui,sans-serif}
.wrap{max-width:1320px;margin:0 auto;padding:22px 24px 40px}
header{background:var(--surf);border:1px solid var(--line);border-radius:14px;padding:14px 20px;margin-bottom:22px}
.top{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:12px 20px}
.brandrow{display:flex;flex-wrap:wrap;align-items:center;gap:10px 18px}
.logo-link{display:block;border-radius:8px}
.logo{display:block;height:60px;width:auto}
.promo{font-size:14px;font-weight:500;color:var(--txt);max-width:600px;line-height:1.35}
.cta{display:inline-flex;align-items:center;gap:6px;background:var(--brand);color:#fff;text-decoration:none;border-radius:99px;font-weight:600;font-size:12px;padding:7px 16px;white-space:nowrap}
.cta:hover{filter:brightness(1.15)}
.logo-link:focus-visible,.cta:focus-visible{outline:2px solid var(--light);outline-offset:2px}
.hr{height:1px;background:var(--line);margin:12px 0 10px}
h1{margin:2px 0 0;font-size:22px;font-weight:700}
.meta{color:var(--gray);font-size:12px;margin-top:4px}
.meta b{color:var(--light);font-weight:500}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:99px;padding:3px;background:var(--bg)}
.seg button{border:0;background:transparent;color:var(--gray);font:inherit;font-weight:600;padding:5px 16px;border-radius:99px;cursor:pointer}
.seg button[aria-pressed="true"]{background:var(--brand);color:#fff}
.seg button:focus-visible,.card:focus-visible,.brow:focus-visible,.btn:focus-visible,.x:focus-visible{outline:2px solid var(--light);outline-offset:2px}
h2{font-size:16px;font-weight:600;margin:26px 0 12px;color:var(--light)}
.hint{color:var(--gray);font-size:12px;margin:-4px 0 14px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(215px,1fr));gap:14px}
.card{position:relative;text-align:left;background:var(--surf);border:1px solid var(--line);border-radius:14px;padding:13px 16px 13px 20px;color:inherit;font:inherit;cursor:pointer;overflow:hidden;min-height:116px;display:flex;flex-direction:column;gap:2px;box-shadow:0 2px 8px rgba(0,0,0,.18)}
.card::before{content:'';position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--accent,var(--brand))}
.card:hover,.brow:hover{background:var(--surf2)}
.card.ok{--accent:var(--ok)}.card.warn{--accent:var(--warn)}.card.bad{--accent:var(--bad)}
.lbl{font-size:12px;font-weight:500;color:var(--light)}
.val{font-size:28px;font-weight:700;line-height:1.15}
.sub{font-size:11px;color:var(--gray)}
.tag{display:inline-flex;align-items:center;gap:6px;align-self:flex-start;font-size:11px;font-weight:500;padding:1px 9px;border-radius:99px;background:rgba(255,255,255,.07);margin-top:auto}
.tag::before{content:'';width:7px;height:7px;border-radius:50%;background:currentColor}
.tag.ok{color:var(--ok)}.tag.warn{color:var(--warn)}.tag.bad{color:var(--bad)}
.panel{background:var(--surf);border:1px solid var(--line);border-radius:14px;padding:14px 16px;box-shadow:0 2px 8px rgba(0,0,0,.18)}
.cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(380px,100%),1fr));gap:14px}
.panel h3{margin:0 0 10px;font-size:13px;font-weight:600;color:var(--light)}
.brow{display:grid;grid-template-columns:minmax(220px,1.7fr) 1fr 104px;gap:10px;align-items:center;width:100%;text-align:left;background:transparent;border:0;border-radius:8px;padding:6px 6px;color:inherit;font:inherit;cursor:pointer}
.bl{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.track{display:block;height:10px;border-radius:99px;background:rgba(151,201,252,.12);overflow:hidden}
.fill{display:block;height:100%;background:var(--brand);border-radius:99px}
.bn{text-align:right;font-variant-numeric:tabular-nums;color:var(--light)}
.mini{font-size:10px;font-weight:500;margin-left:6px;padding:0 7px;border-radius:99px;background:rgba(255,255,255,.07)}
.mini.ok{color:var(--ok)}.mini.warn{color:var(--warn)}
.foot{margin-top:28px;color:var(--gray);font-size:11px;line-height:1.7}
.mono,td.mono{font-family:Consolas,'Cascadia Mono','Courier New',monospace;font-size:12px}
@media (max-width:600px){.brow{grid-template-columns:1fr auto}.track{display:none}.bl{white-space:normal}}
/* Modal */
.ov{position:fixed;inset:0;background:rgba(5,14,28,.78);display:none;align-items:center;justify-content:center;z-index:10;padding:16px}
.ov.open{display:flex}
.modal{width:min(1240px,100%);max-height:90vh;display:flex;flex-direction:column;background:var(--surf);border:1px solid var(--line);border-radius:14px;box-shadow:0 12px 40px rgba(0,0,0,.5)}
.mh{display:flex;flex-wrap:wrap;gap:12px;align-items:center;padding:14px 18px;border-bottom:1px solid var(--line)}
.mh h3{margin:0;font-size:16px;font-weight:600;flex:1 1 260px}
.mh h3 small{display:block;color:var(--gray);font-size:12px;font-weight:400;margin-top:2px}
.mh input{background:var(--bg);border:1px solid var(--line);border-radius:99px;color:var(--txt);font:inherit;padding:7px 14px;min-width:240px}
.btn{border:0;border-radius:99px;background:var(--brand);color:#fff;font:inherit;font-weight:600;padding:8px 18px;cursor:pointer}
.btn.sec{background:transparent;border:1px solid var(--line);color:var(--light)}
.btn:disabled{opacity:.45;cursor:default}
.tw{overflow:auto;flex:1}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:7px 12px;border-bottom:1px solid var(--line);white-space:nowrap}
td.wrapc{white-space:normal;min-width:220px}
th{position:sticky;top:0;background:var(--surf2);color:var(--light);font-weight:500;font-size:11px;z-index:1}
tbody tr:hover{background:rgba(151,201,252,.06)}
.yn{display:inline-flex;align-items:center;gap:6px;font-size:12px}
.yn::before{content:'';width:7px;height:7px;border-radius:50%;background:var(--gray)}
.yn.y::before{background:var(--ok)}.yn.n::before{background:var(--bad)}
.mf{padding:9px 18px;color:var(--gray);font-size:11px;border-top:1px solid var(--line)}
.empty{padding:36px;text-align:center;color:var(--gray)}
.alert{display:flex;flex-wrap:wrap;gap:16px 28px;align-items:center;justify-content:space-between;background:var(--surf);border:1px solid var(--line);border-left:3px solid var(--warn);border-radius:14px;padding:14px 20px;margin-bottom:18px}
.adt{flex:1 1 380px}
.adt b{font-size:14px;color:var(--txt)}
.adt p{margin:4px 0 8px;color:var(--gray);font-size:12px}
.more{color:var(--light);font-size:12px;font-weight:600;text-decoration:none}
.more:hover{text-decoration:underline}
.more:focus-visible{outline:2px solid var(--light);outline-offset:2px}
.dates{display:flex;flex-wrap:wrap;gap:12px 28px}
.dt{display:flex;align-items:center;gap:12px}
.dn{font-size:30px;font-weight:700;color:var(--warn);line-height:1;font-variant-numeric:tabular-nums}
.dl{font-size:11px;color:var(--gray);line-height:1.4}
.dl b{color:var(--txt);font-weight:600}
.stack{display:flex;gap:3px;height:44px;border-radius:10px;overflow:hidden}
.seg-b{border:0;color:#0B1E38;font:inherit;font-weight:700;font-size:12px;cursor:pointer;min-width:6px;padding:0}
.seg-b:hover{filter:brightness(1.12)}
.legend{margin-top:12px;display:flex;flex-direction:column;gap:2px}
.lg{display:grid;grid-template-columns:14px 1fr auto;gap:10px;align-items:center;width:100%;text-align:left;background:transparent;border:0;border-radius:8px;padding:7px 6px;color:inherit;font:inherit;cursor:pointer}
.lg:hover{background:var(--surf2)}
.grid6{grid-template-columns:repeat(auto-fit,minmax(190px,1fr))}
.dot{width:10px;height:10px;border-radius:50%}
.seg-b:focus-visible,.lg:focus-visible{outline:2px solid var(--light);outline-offset:2px}
</style>
</head>
<body>
<div class="wrap" id="app"></div>
<div class="ov" id="ov" role="dialog" aria-modal="true"><div class="modal" id="modal"></div></div>
<script>
(function(){
'use strict';
const DATA = __DATA__;
const META = __META__;
const SITE = 'https://www.consultoresenit.com.ar/';
const MSDOC = 'https://learn.microsoft.com/en-us/entra/identity/authentication/concept-sms-voice-retirement';
let lang = META.lang === 'en' ? 'en' : 'es';

const L = {
 es:{
  tagline:'Diagnóstico de métodos de autenticación de Microsoft Entra ID.',
  title:'Preparación para la retirada de SMS y voz', sub:'Autenticación del tenant', generated:'Generado', tenant:'Tenant',
  scopeNote:'Microsoft no incluye en este informe las cuentas deshabilitadas ni las eliminadas recientemente',
  guestNote:'Solo usuarios internos (miembros del tenant). Invitados excluidos: {n}',
  hintClick:'Pulsa una tarjeta, un tramo de la barra o un método para ver qué usuarios son.',
  b_title:'Microsoft retira el SMS y la voz propios de Entra ID',
  b_text:'Si el único MFA disponible es SMS o voz de Microsoft, los usuarios alcanzados deberán registrar una passkey al iniciar sesión tras la fecha aplicable. Revisá las políticas y el proveedor de telefonía del tenant.',
  b_who1:'Todos los usuarios, excepto Global Administrators y usuarios externos', b_who2:'Global Administrators y usuarios externos', b_d1:'1 feb 2027', b_d2:'1 jul 2027', b_days:'días', b_done:'Ya vigente', b_more:'Ver el calendario de Microsoft',
  s_summary:'Estado del tenant', s_ready:'Preparación para el 1 de febrero de 2027', s_methods:'Usuarios por método de autenticación',
  c_all:'Usuarios analizados', c_ready:'Con alternativa registrada', c_smsOnly:'Dependen solo de SMS o voz', c_noMfa:'Sin ningún método MFA', c_adminSms:'Admins que dependen solo de SMS o voz',
  l_ready:'Con alternativa registrada', l_smsOnly:'Solo SMS o voz', l_noMfa:'Sin MFA',
  h_all:'Cuentas incluidas en el análisis.',
  h_ready:'Tienen al menos un método MFA que no es SMS ni voz (Authenticator, app OATH, token, FIDO2, passkey, Windows Hello o certificado).',
  h_smsOnly:'Su único MFA disponible es SMS o llamada de voz. El correo y las preguntas de seguridad no cuentan, porque solo sirven para SSPR. Tendrán que registrar un passkey.',
  h_noMfa:'No tienen ningún método MFA registrado. Para registrar un passkey hace falta pasar antes por MFA, así que son los más difíciles de migrar.',
  h_adminSms:'Cuentas con rol de administrador cuyo único MFA es SMS o voz. Son la prioridad.',
  ok:'OK', review:'Revisar', critical:'Crítico', ofUsers:'de los usuarios', ofAdmins:'de los administradores',
  weak:'SMS / voz',
  search:'Buscar por nombre o UPN…', close:'Cerrar', showing:'Mostrando {a} de {b}', cap:'Se muestran los primeros {n}; usa el buscador para acotar.',
  noRows:'No hay usuarios en esta lista.',
  col_name:'Nombre', col_upn:'UPN', col_type:'Tipo', col_admin:'Admin', col_methods:'Métodos registrados', col_updated:'Informe actualizado',
  yes:'Sí', no:'No', member:'Miembro', guest:'Invitado',
  n1:'Preparado = al menos un método MFA que no es SMS ni voz. Solo SMS o voz = su único MFA es telefónico. Sin MFA = ningún método MFA (el correo y las preguntas de seguridad solo sirven para SSPR). Los tres grupos suman el total.',
  n2:'El informe de Microsoft agrupa SMS y voz bajo el método teléfono y no los distingue. Las fechas son las publicadas por Microsoft; confírmalas en su documentación, porque pueden cambiar. Los datos del informe pueden tener hasta 36 horas de retraso y no reflejan el MFA aplicado fuera de Microsoft Entra ID (proveedor externo o federado).',
  n3:'Fuente: Microsoft Graph · reports/authenticationMethods/userRegistrationDetails. Panel de solo lectura generado por CIT.'
 },
 en:{
  tagline:'Microsoft Entra ID authentication methods assessment.',
  title:'SMS and voice retirement readiness', sub:'Tenant authentication', generated:'Generated', tenant:'Tenant',
  scopeNote:'Microsoft leaves disabled and recently deleted accounts out of this report',
  guestNote:'Internal users only (tenant members). Guests excluded: {n}',
  hintClick:'Click a card, a bar segment or a method to see which users they are.',
  b_title:'Microsoft is retiring its own SMS and voice authentication in Entra ID',
  b_text:'If Microsoft-provided SMS or voice is the only available MFA, affected users must register a passkey at sign-in after their applicable date. Check tenant policies and telephony providers.',
  b_who1:'All users except Global Administrators and external users', b_who2:'Global Administrators and external users', b_d1:'1 Feb 2027', b_d2:'1 Jul 2027', b_days:'days', b_done:'Already in effect', b_more:"See Microsoft's timeline",
  s_summary:'Tenant status', s_ready:'Readiness for 1 February 2027', s_methods:'Users by authentication method',
  c_all:'Users analysed', c_ready:'Alternative registered', c_smsOnly:'Rely only on SMS or voice', c_noMfa:'No MFA method at all', c_adminSms:'Admins relying only on SMS or voice',
  l_ready:'Alternative registered', l_smsOnly:'SMS or voice only', l_noMfa:'No MFA',
  h_all:'Accounts included in the analysis.',
  h_ready:'Have at least one MFA method that is not SMS or voice (Authenticator, OATH app, token, FIDO2, passkey, Windows Hello or certificate).',
  h_smsOnly:'Their only available MFA is SMS or a voice call. Email and security questions do not count, because they only work for SSPR. They will have to register a passkey.',
  h_noMfa:'No MFA method registered. Registering a passkey requires passing MFA first, so they are the hardest to migrate.',
  h_adminSms:'Admin-role accounts whose only MFA is SMS or voice. These are the priority.',
  ok:'OK', review:'Review', critical:'Critical', ofUsers:'of users', ofAdmins:'of admins',
  weak:'SMS / voice',
  search:'Search by name or UPN…', close:'Close', showing:'Showing {a} of {b}', cap:'Showing the first {n}; use the search box to narrow down.',
  noRows:'There are no users in this list.',
  col_name:'Name', col_upn:'UPN', col_type:'Type', col_admin:'Admin', col_methods:'Registered methods', col_updated:'Report updated',
  yes:'Yes', no:'No', member:'Member', guest:'Guest',
  n1:'Ready = at least one MFA method that is not SMS or voice. SMS or voice only = their only MFA is by phone. No MFA = no MFA method (email and security questions only work for SSPR). The three groups add up to the total.',
  n2:'The Microsoft report groups SMS and voice under the phone method and does not tell them apart. Dates are those published by Microsoft; confirm them in their documentation, as they may change. Report data can lag by up to 36 hours and does not reflect MFA enforced outside Microsoft Entra ID (third-party or federated).',
  n3:'Source: Microsoft Graph · reports/authenticationMethods/userRegistrationDetails. Read-only panel generated by CIT.'
 }
};
const t = k => (L[lang][k] !== undefined ? L[lang][k] : k);

const ML = {
 mobilePhone:['SMS / llamada móvil','SMS / mobile call'], alternateMobilePhone:['Móvil alternativo (SMS / llamada)','Alternate mobile (SMS / call)'], officePhone:['Teléfono de oficina (llamada)','Office phone (call)'],
 email:['Correo electrónico (solo SSPR)','Email (SSPR only)'], securityQuestion:['Preguntas de seguridad (solo SSPR)','Security questions (SSPR only)'],
 microsoftAuthenticatorPush:['Authenticator (notificación)','Authenticator (push)'], microsoftAuthenticatorPasswordless:['Authenticator (sin contraseña)','Authenticator (passwordless)'],
 softwareOneTimePasscode:['App OATH / TOTP','OATH / TOTP app'], hardwareOneTimePasscode:['Token OATH hardware','Hardware OATH token'], temporaryAccessPass:['Pase de acceso temporal','Temporary Access Pass'],
 fido2:['Llave FIDO2','FIDO2 key'], windowsHelloForBusiness:['Windows Hello para empresas','Windows Hello for Business'],
 passKeyDeviceBound:['Passkey (dispositivo)','Passkey (device-bound)'], passKeyDeviceBoundAuthenticator:['Passkey (Authenticator)','Passkey (Authenticator)'], passKeyDeviceBoundWindowsHello:['Passkey (Windows Hello)','Passkey (Windows Hello)'],
 certificateBasedAuthentication:['Certificado (CBA)','Certificate (CBA)']
};
const mlabel = m => ML[m] ? ML[m][lang === 'en' ? 1 : 0] : m;
const isReady = u => u.category === 'ready';
const isSmsOnly = u => u.category === 'smsOnly';
const isNoMfa = u => u.category === 'noMfa';

const F = {
 all: () => true,
 ready: isReady,
 smsOnly: isSmsOnly,
 noMfa: isNoMfa,
 adminSms: u => u.admin && isSmsOnly(u)
};
function filt(key){
 if (F[key]) return F[key];
 const i = key.indexOf(':'), k = key.slice(0, i), v = key.slice(i + 1);
 if (k === 'm') return u => u.methods.indexOf(v) >= 0;
 return () => false;
}
const cache = {};
const count = key => (cache[key] !== undefined ? cache[key] : (cache[key] = DATA.filter(filt(key)).length));
const TOTAL = DATA.length;
const ADMINS = DATA.filter(u => u.admin).length;
const pct = (n, d) => (d ? (n / d * 100).toFixed(1) : '0.0') + '%';
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const num = n => n.toLocaleString(lang === 'en' ? 'en-GB' : 'es-ES');
const daysTo = (y, m, d) => { const n = new Date(); return Math.round((Date.UTC(y, m, d) - Date.UTC(n.getFullYear(), n.getMonth(), n.getDate())) / 864e5); };

const CARDS = ['all', 'ready', 'smsOnly', 'noMfa', 'adminSms'];
const titleFor = key => F[key] ? t('c_' + key) : mlabel(key.slice(key.indexOf(':') + 1));

function card(key){
 const n = count(key);
 let cls = '', tag = '', sub;
 const sev = (key === 'smsOnly' || key === 'noMfa') ? 'warn' : (key === 'adminSms' ? 'bad' : '');
 if (sev){
  if (n === 0){ cls = 'ok'; tag = '<span class="tag ok">' + t('ok') + '</span>'; }
  else { cls = sev; tag = '<span class="tag ' + sev + '">' + t(sev === 'bad' ? 'critical' : 'review') + '</span>'; }
 }
 if (key === 'all') sub = '&nbsp;';
 else if (key === 'adminSms') sub = pct(n, ADMINS) + ' ' + t('ofAdmins');
 else sub = pct(n, TOTAL) + ' ' + t('ofUsers');
 return '<button class="card ' + cls + '" data-k="' + esc(key) + '" title="' + esc(t('h_' + key)) + '">' +
  '<span class="lbl">' + esc(t('c_' + key)) + '</span><span class="val">' + num(n) + '</span><span class="sub">' + sub + '</span>' + tag + '</button>';
}

function banner(){
 const d1 = daysTo(2027, 1, 1), d2 = daysTo(2027, 6, 1);
 const dt = (d, date, who) => '<div class="dt"><span class="dn">' + (d > 0 ? num(d) : '—') + '</span><span class="dl">' + (d > 0 ? t('b_days') : t('b_done')) + ' · <b>' + esc(date) + '</b><br>' + esc(who) + '</span></div>';
 return '<div class="alert"><div class="adt"><b>' + esc(t('b_title')) + '</b><p>' + esc(t('b_text')) + '</p>' +
  '<a class="more" href="' + MSDOC + '" target="_blank" rel="noopener noreferrer">' + esc(t('b_more')) + ' <span aria-hidden="true">&#8599;</span></a></div>' +
  '<div class="dates">' + dt(d1, t('b_d1'), t('b_who1')) + dt(d2, t('b_d2'), t('b_who2')) + '</div></div>';
}

function stack(){
 const segs = [['ready', 'var(--ok)'], ['smsOnly', 'var(--warn)'], ['noMfa', 'var(--bad)']];
 if (!TOTAL) return '<div class="empty">' + t('noRows') + '</div>';
 const bar = segs.filter(s => count(s[0]) > 0).map(s => {
  const n = count(s[0]), share = n / TOTAL;
  return '<button class="seg-b" data-k="' + s[0] + '" style="flex:' + n + ';background:' + s[1] + '" aria-label="' + esc(t('l_' + s[0]) + ': ' + num(n)) + '">' + (share >= 0.07 ? Math.round(share * 100) + '%' : '') + '</button>';
 }).join('');
 const legend = segs.map(s => {
  const n = count(s[0]);
  return '<button class="lg" data-k="' + s[0] + '"><span class="dot" style="background:' + s[1] + '"></span><span class="lgl">' + esc(t('l_' + s[0])) + '</span><span class="bn">' + num(n) + ' · ' + pct(n, TOTAL) + '</span></button>';
 }).join('');
 return '<div class="stack">' + bar + '</div><div class="legend">' + legend + '</div>';
}

function methodRows(){
 const tally = {};
 DATA.forEach(u => u.methods.forEach(m => { tally[m] = (tally[m] || 0) + 1; }));
 return Object.keys(tally).sort((a, b) => tally[b] - tally[a]).map(m => {
  const n = tally[m], w = n > 0 ? Math.max(1, n / (TOTAL || 1) * 100) : 0;
  const tg = META.phoneMethods.includes(m) ? '<span class="mini warn">' + t('weak') + '</span>' : '';
  return '<button class="brow" data-k="m:' + esc(m) + '"><span class="bl">' + esc(mlabel(m)) + tg + '</span>' +
   '<span class="track"><span class="fill" style="width:' + w.toFixed(1) + '%"></span></span><span class="bn">' + num(n) + ' · ' + pct(n, TOTAL) + '</span></button>';
 }).join('');
}

function render(){
 document.documentElement.lang = lang;
 document.title = 'CIT · ' + t('title');
 const tagline = (lang === 'en' ? META.taglineEn : META.taglineEs) || t('tagline');
 const scope = t('scopeNote') + ' · ' + t('guestNote').replace('{n}', num(META.guestsExcluded || 0));
 document.getElementById('app').innerHTML =
  '<header><div class="top"><div class="brandrow">' +
  '<a class="logo-link" href="' + SITE + '" target="_blank" rel="noopener noreferrer" aria-label="CIT"><strong>CIT</strong></a>' +
  '<span class="promo">' + esc(tagline) + '</span>' +
  '<a class="cta" href="' + SITE + '" target="_blank" rel="noopener noreferrer">Consultores en IT <span aria-hidden="true">&#8599;</span></a></div>' +
  '<div class="seg" role="group" aria-label="Language"><button data-lang="es" aria-pressed="' + (lang === 'es') + '">ES</button><button data-lang="en" aria-pressed="' + (lang === 'en') + '">EN</button></div></div>' +
  '<div class="hr"></div><h1>' + esc(t('title')) + ' · ' + esc(t('sub')) + '</h1>' +
  '<div class="meta">' + t('tenant') + ': <b>' + esc(META.tenantName) + '</b> · <span class="mono">' + esc(META.tenantId) + '</span> · ' + t('generated') + ': <b>' + esc(META.generated) + '</b> · ' + esc(scope) + '</div></header>' +
  banner() +
  '<p class="hint">' + t('hintClick') + '</p>' +
  '<h2>' + t('s_summary') + '</h2><div class="grid grid6">' + CARDS.map(card).join('') + '</div>' +
  '<div class="cols" style="margin-top:26px">' +
   '<div><h2 style="margin-top:0">' + t('s_ready') + '</h2><div class="panel">' + stack() + '</div></div>' +
   '<div><h2 style="margin-top:0">' + t('s_methods') + '</h2><div class="panel">' + methodRows() + '</div></div></div>' +
  '<div class="foot">' + t('n1') + '<br>' + t('n2') + '<br>' + t('n3') + '</div>';
 if (cur) renderModal(false);
}

/* ---------- Lista de usuarios (modal, solo lectura) ---------- */
let cur = null, opener = null;
const CAP = 2000;
function rowsNow(){
 const f = filt(cur.key), q = cur.q.trim().toLowerCase();
 return DATA.filter(f).filter(u => !q || (u.name + ' ' + u.upn).toLowerCase().indexOf(q) >= 0);
}
const ynNeutral = v => '<span class="yn ' + (v ? 'y' : '') + '">' + t(v ? 'yes' : 'no') + '</span>';
function tbody(rs){
 if (!rs.length) return '<tr><td colspan="6" class="empty">' + t('noRows') + '</td></tr>';
 return rs.slice(0, CAP).map(u =>
  '<tr><td>' + esc(u.name) + '</td><td class="mono">' + esc(u.upn) + '</td><td>' + t(u.type === 'guest' ? 'guest' : 'member') + '</td><td>' + ynNeutral(u.admin) + '</td>' +
  '<td class="wrapc">' + esc(u.methods.map(mlabel).join(', ') || '—') + '</td><td>' + esc(u.lastUpdated || '—') + '</td></tr>').join('');
}
function counter(rs){
 let s = t('showing').replace('{a}', num(Math.min(rs.length, CAP))).replace('{b}', num(rs.length));
 if (rs.length > CAP) s += ' · ' + t('cap').replace('{n}', num(CAP));
 return s;
}
function renderModal(focusSearch){
 const rs = rowsNow();
 document.getElementById('modal').innerHTML =
  '<div class="mh"><h3>' + esc(titleFor(cur.key)) + '<small id="cnt">' + esc(counter(rs)) + '</small></h3>' +
  '<input id="q" type="search" placeholder="' + esc(t('search')) + '" value="' + esc(cur.q) + '" aria-label="' + esc(t('search')) + '">' +
  '<button class="btn sec x" id="cls">' + t('close') + '</button></div>' +
  '<div class="tw"><table><thead><tr><th>' + t('col_name') + '</th><th>' + t('col_upn') + '</th><th>' + t('col_type') + '</th><th>' + t('col_admin') + '</th><th>' + t('col_methods') + '</th><th>' + t('col_updated') + '</th></tr></thead>' +
  '<tbody id="tb">' + tbody(rs) + '</tbody></table></div>';
 document.getElementById('ov').classList.add('open');
 if (focusSearch) document.getElementById('q').focus();
}
function openList(key){ cur = { key: key, q: '' }; renderModal(true); }
function closeList(){
 cur = null;
 document.getElementById('ov').classList.remove('open');
 document.getElementById('modal').innerHTML = '';
 if (opener && opener.focus) opener.focus();
}
function refreshRows(){
 const rs = rowsNow();
 document.getElementById('tb').innerHTML = tbody(rs);
 document.getElementById('cnt').textContent = counter(rs);
}

/* ---------- Eventos ---------- */
document.getElementById('app').addEventListener('click', e => {
 const lg = e.target.closest('[data-lang]');
 if (lg){ lang = lg.getAttribute('data-lang'); render(); return; }
 const k = e.target.closest('[data-k]');
 if (k){ opener = k; openList(k.getAttribute('data-k')); }
});
document.getElementById('ov').addEventListener('click', e => {
 if (e.target.id === 'ov' || e.target.id === 'cls') closeList();
});
document.getElementById('ov').addEventListener('input', e => {
 if (e.target.id === 'q' && cur){ cur.q = e.target.value; refreshRows(); }
});
document.addEventListener('keydown', e => { if (e.key === 'Escape' && cur) closeList(); });

render();
})();
</script>
</body>
</html>
'@

$html = $template.Replace('__DATA__', (ConvertTo-SafeJson $users)).Replace('__META__', (ConvertTo-SafeJson $meta))

$file = Join-Path $OutputFolder "$reportName.html"
[System.IO.File]::WriteAllText($file, $html, (New-Object System.Text.UTF8Encoding($true)))


Write-Host "Panel generado: $file" -ForegroundColor Green
if (-not $NoOpen) { Start-Process $file }
Wait-ForKeyIfNeeded
