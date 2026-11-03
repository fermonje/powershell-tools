param(
    [ValidateRange(1, 100000)] [int] $Paginas = 1114,
    [ValidateRange(0, 100000)] [int] $UltimaGuardada = 0,
    [string] $Salida = (Join-Path (Join-Path $PSScriptRoot 'datos') "emblue-$(Get-Date -Format yyyyMMdd-HHmmss).txt")
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class EmblueMouse {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
}
'@

Write-Host 'En 8 segundos empieza la captura. Activa Chrome en Contactos.'
Start-Sleep -Seconds 8
$window = [EmblueMouse]::GetForegroundWindow()
$browser = [Windows.Automation.AutomationElement]::FromHandle($window)
$nextButton = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::NameProperty, 'Página siguiente'
)
$mode = if ($UltimaGuardada) { [IO.FileMode]::Append } else { [IO.FileMode]::CreateNew }
if ($UltimaGuardada -and -not (Test-Path -LiteralPath $Salida -PathType Leaf)) {
    throw 'No existe el archivo para reanudar.'
}
$file = [IO.File]::Open($Salida, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
$writer = [IO.StreamWriter]::new($file, [Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true

try {
    $previous = $null
    $firstPage = if ($UltimaGuardada) { $UltimaGuardada + 1 } else { $null }
    for ($index = 0; $index -lt $Paginas; $index++) {
        $content = $null
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            if ([EmblueMouse]::GetForegroundWindow() -ne $window) {
                throw 'Cambio la ventana activa. Se guardaron las paginas anteriores.'
            }
            Set-Clipboard -Value 'EMBLUE_PENDIENTE'
            [Windows.Forms.SendKeys]::SendWait('^a')
            [Windows.Forms.SendKeys]::SendWait('^c')
            Start-Sleep -Milliseconds 200
            $content = Get-Clipboard -Raw
            $page = [regex]::Match([string]$content, '(?m)^\s*(\d+)\s+de\s+(\d+)\s*$')
            if ($page.Success -and $content -match '@' -and $content -ne $previous -and $content -notmatch 'Loading\.\.\.') {
                $number = [int]$page.Groups[1].Value
                if ($null -eq $firstPage) { $firstPage = $number }
                if ($number -eq ($firstPage + $index)) { break }
            }
            Start-Sleep -Milliseconds 500
        }
        if ($attempt -eq 60) { throw 'No se pudo confirmar la pagina esperada en el portapapeles.' }
        $writer.WriteLine("===== Pagina $number =====")
        $writer.WriteLine($content)
        $previous = $content
        Write-Host "Pagina $number guardada"

        if ($number -ge [int]$page.Groups[2].Value -or $index -eq ($Paginas - 1)) { break }
        if ([EmblueMouse]::GetForegroundWindow() -ne $window) { throw 'Cambio la ventana activa.' }
        $button = $browser.FindFirst([Windows.Automation.TreeScope]::Descendants, $nextButton)
        $invoke = $null
        if ($null -eq $button -or -not $button.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) {
            throw 'No se encontro el boton Pagina siguiente. Se guardaron las paginas anteriores.'
        }
        $invoke.Invoke()
        Start-Sleep -Seconds 1
    }
}
finally {
    $writer.Dispose()
    Write-Host "Archivo: $Salida"
}
