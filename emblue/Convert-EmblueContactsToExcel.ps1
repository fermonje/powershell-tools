param(
    [Parameter(Mandatory)] [string] $Entrada,
    [string] $Salida,
    [string[]] $DominiosExcluidos = @()
)

$ErrorActionPreference = 'Stop'
$Entrada = (Resolve-Path -LiteralPath $Entrada).Path
if (-not $Salida) { $Salida = [IO.Path]::ChangeExtension($Entrada, '.xlsx') }
$Salida = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Salida)
if ([IO.Path]::GetExtension($Salida) -ne '.xlsx' -or (Test-Path -LiteralPath $Salida)) {
    throw 'Indica un archivo .xlsx nuevo para la salida.'
}

$emailPattern = [regex]'(?im)^[ \t]*(?<email>[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+)[ \t]*\r?$'
$statusPattern = [regex]'(?m)^[ \t]*(?<estado>[^\r\n]+?)[ \t]*\r?\n[ \t]*\d{1,2}/\d{1,2}/\d{4},?\s+\d{1,2}:\d{2}:\d{2}'
$raw = [IO.File]::ReadAllText($Entrada)
$pages = [regex]::Split($raw, '(?m)^===== Pagina (\d+) =====\r?$')
$contacts = [Collections.Generic.List[object]]::new()

for ($pageIndex = 1; $pageIndex -lt $pages.Length; $pageIndex += 2) {
    $body = $pages[$pageIndex + 1]
    $emails = $emailPattern.Matches($body)
    for ($index = 0; $index -lt $emails.Count; $index++) {
        $email = $emails[$index]
        $start = $email.Index + $email.Length
        $end = if ($index + 1 -lt $emails.Count) { $emails[$index + 1].Index } else { $body.Length }
        $status = $statusPattern.Match($body.Substring($start, $end - $start))
        $contacts.Add(@($email.Groups['email'].Value, $status.Groups['estado'].Value.Trim(), [int]$pages[$pageIndex]))
    }
}

if (-not $contacts.Count) { throw 'No se encontraron correos en las paginas del TXT.' }
if ($contacts.Count -gt 1048575) { throw 'Los contactos superan el limite de una hoja de Excel.' }

$commonDomains = @(
    'gmail.com', 'googlemail.com', 'hotmail.com', 'hotmail.com.ar', 'hotmail.es',
    'outlook.com', 'outlook.es', 'live.com', 'live.com.ar', 'msn.com',
    'yahoo.com', 'yahoo.com.ar', 'yahoo.es', 'ymail.com', 'rocketmail.com',
    'icloud.com', 'me.com', 'mac.com', 'aol.com', 'proton.me', 'protonmail.com',
    'pm.me', 'gmx.com', 'gmx.net', 'mail.com', 'zoho.com', 'zohomail.com',
    'yandex.com', 'yandex.ru', 'mail.ru', 'qq.com'
) + $DominiosExcluidos
$excluded = @{}
foreach ($domain in $commonDomains) { $excluded[$domain.Trim()] = $true }
$contacts = @($contacts | Where-Object { -not $excluded.ContainsKey($_[0].Split('@')[-1]) })
if (-not $contacts.Count) { throw 'No quedaron correos tras excluir los dominios comunes.' }

$mxCache = @{}
$checkpoint = [IO.Path]::ChangeExtension($Salida, '.mx.csv')
$domains = @($contacts | ForEach-Object { $_[0].Split('@')[-1].ToLowerInvariant() } | Sort-Object -Unique)
$pending = @{}
foreach ($domain in $domains) { $pending[$domain] = $true }
if (Test-Path -LiteralPath $checkpoint) {
    foreach ($saved in (Import-Csv -LiteralPath $checkpoint -Encoding UTF8)) {
        if ($saved.Dominio -and $saved.MX -and $pending.ContainsKey($saved.Dominio)) {
            $mxCache[$saved.Dominio] = $saved.MX
        }
    }
}
Write-Host "Dominios recuperados: $($mxCache.Count) de $($domains.Count). CSV: $checkpoint"
$values = [object[,]]::new($contacts.Count + 1, 5)
$values[0,0] = 'Correo'
$values[0,1] = 'Estado'
$values[0,2] = 'Pagina'
$values[0,3] = 'Dominio'
$values[0,4] = 'MX (prioridad y servidor)'
for ($index = 0; $index -lt $contacts.Count; $index++) {
    for ($column = 0; $column -lt 3; $column++) {
        $values[($index + 1), $column] = $contacts[$index][$column]
    }
    $domain = $contacts[$index][0].Split('@')[-1].ToLowerInvariant()
    if (-not $mxCache.ContainsKey($domain)) {
        try {
            $records = @(Resolve-DnsName -Name "$domain." -Type MX -DnsOnly -QuickTimeout -ErrorAction Stop |
                Where-Object Type -eq 'MX' | Sort-Object Preference, NameExchange)
            $mxCache[$domain] = if ($records.Count) {
                ($records | ForEach-Object { "$($_.Preference) $($_.NameExchange)" }) -join ' | '
            } else { 'Sin registro MX' }
        }
        catch {
            $mxCache[$domain] = if ($_.FullyQualifiedErrorId -match 'DNS_ERROR_(RCODE_NAME_ERROR|NAME_DOES_NOT_EXIST|RECORD_DOES_NOT_EXIST|NO_RECORDS)') {
                'Sin registro MX'
            } else { "Error DNS: $($_.FullyQualifiedErrorId.Split(',')[0])" }
        }
        [pscustomobject]@{ Dominio = $domain; MX = $mxCache[$domain] } |
            Export-Csv -LiteralPath $checkpoint -Encoding UTF8 -Append -NoTypeInformation
        Write-Progress -Activity 'Consulta MX' -Status "$($mxCache.Count) de $($domains.Count) - $domain" `
            -PercentComplete (100 * $mxCache.Count / $domains.Count)
        if ($mxCache.Count % 100 -eq 0) {
            Write-Host "Dominios procesados: $($mxCache.Count) de $($domains.Count)."
        }
    }
    $values[($index + 1), 3] = $domain
    $values[($index + 1), 4] = $mxCache[$domain]
}
Write-Progress -Activity 'Consulta MX' -Completed

$excel = New-Object -ComObject Excel.Application
$book = $null
try {
    $excel.DisplayAlerts = $false
    $book = $excel.Workbooks.Add(-4167)
    $sheet = $book.Worksheets.Item(1)
    $sheet.Name = 'Contactos'
    $lastRow = $contacts.Count + 1
    $sheet.Range("A1:B$lastRow").NumberFormat = '@'
    $data = $sheet.Range("A1:E$lastRow")
    $data.Value2 = $values
    $sheet.Range('A1:E1').Font.Bold = $true
    $data.AutoFilter() | Out-Null
    $data.EntireColumn.AutoFit() | Out-Null
    $excel.ActiveWindow.SplitRow = 1
    $excel.ActiveWindow.FreezePanes = $true
    $book.SaveAs($Salida, 51)
}
finally {
    if ($book) { $book.Close($false) }
    $excel.Quit()
}

$missingStatus = @($contacts | Where-Object { -not $_[1] }).Count
Write-Host "Contactos exportados: $($contacts.Count). Dominios consultados: $($mxCache.Count). Estados sin identificar: $missingStatus."
Write-Host "Excel: $Salida"
