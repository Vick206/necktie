# Build a styled wireless report document from netsh WLAN diagnostics.
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:ProgramData\Necktie\WirelessReports",
    [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NetshCapture {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OutputPath,
        [switch]$AllowFailure
    )

    $output = & netsh.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $output | Set-Content -Path $OutputPath -Encoding UTF8
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "netsh $($Arguments -join ' ') failed with exit code $exitCode."
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($output)
    }
}

function Convert-ToHtmlSafe {
    param([object[]]$Lines)
    $text = ($Lines -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = '(No output)'
    }
    return [System.Net.WebUtility]::HtmlEncode($text)
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $OutputRoot $timestamp
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

# Refresh the built-in WLAN report and collect related snapshots.
$wlanReportGeneration = Invoke-NetshCapture -Arguments @('wlan', 'show', 'wlanreport') -OutputPath (Join-Path $reportPath 'wlanreport-generation.txt') -AllowFailure
$interfaces = Invoke-NetshCapture -Arguments @('wlan', 'show', 'interfaces') -OutputPath (Join-Path $reportPath 'wlan-interfaces.txt') -AllowFailure
$profiles = Invoke-NetshCapture -Arguments @('wlan', 'show', 'profiles') -OutputPath (Join-Path $reportPath 'wlan-profiles.txt') -AllowFailure
$drivers = Invoke-NetshCapture -Arguments @('wlan', 'show', 'drivers') -OutputPath (Join-Path $reportPath 'wlan-drivers.txt') -AllowFailure

$latestWlanReport = Join-Path $env:ProgramData 'Microsoft\Windows\WlanReport\wlan-report-latest.html'
$rawCopyPath = Join-Path $reportPath 'wlan-report-latest.html'
$rawReportAvailable = Test-Path -LiteralPath $latestWlanReport
if ($rawReportAvailable) {
    Copy-Item -LiteralPath $latestWlanReport -Destination $rawCopyPath -Force
}

$htmlPath = Join-Path $reportPath 'WirelessReport.html'
$generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
$title = "Wireless Report - $env:COMPUTERNAME"

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>$title</title>
  <style>
    :root {
      --bg: #0f172a;
      --panel: #111827;
      --muted: #9ca3af;
      --text: #e5e7eb;
      --accent: #22d3ee;
      --border: #334155;
    }
    body {
      margin: 0;
      font-family: Segoe UI, Tahoma, sans-serif;
      background: linear-gradient(165deg, #020617, var(--bg));
      color: var(--text);
    }
    .container { max-width: 1080px; margin: 0 auto; padding: 24px; }
    .hero, .card {
      background: color-mix(in srgb, var(--panel) 92%, black);
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 18px 20px;
      margin-bottom: 16px;
    }
    h1, h2 { margin: 0 0 10px; }
    .meta { color: var(--muted); font-size: 0.95rem; }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    pre {
      margin: 0;
      padding: 14px;
      border-radius: 10px;
      border: 1px solid var(--border);
      background: #020617;
      color: #cbd5e1;
      overflow-x: auto;
      white-space: pre-wrap;
      word-break: break-word;
    }
  </style>
</head>
<body>
  <main class="container">
    <section class="hero">
      <h1>$title</h1>
      <div class="meta">Generated: $generated</div>
      <div class="meta">User: $env:USERDOMAIN\$env:USERNAME</div>
      <div class="meta">netsh wlanreport exit code: $($wlanReportGeneration.ExitCode)</div>
      <p>$(
            if ($rawReportAvailable) {
                '<a href="./wlan-report-latest.html">Open raw wlan-report-latest.html</a>'
            }
            else {
                'Raw wlan-report-latest.html was not found on this device.'
            }
        )</p>
    </section>

    <section class="card">
      <h2>Current Interfaces</h2>
      <pre>$(Convert-ToHtmlSafe -Lines $interfaces.Output)</pre>
    </section>

    <section class="card">
      <h2>Saved Profiles</h2>
      <pre>$(Convert-ToHtmlSafe -Lines $profiles.Output)</pre>
    </section>

    <section class="card">
      <h2>Wireless Driver Details</h2>
      <pre>$(Convert-ToHtmlSafe -Lines $drivers.Output)</pre>
    </section>
  </main>
</body>
</html>
"@

$html | Set-Content -Path $htmlPath -Encoding UTF8

Write-Host "Wireless report document created at: $htmlPath" -ForegroundColor Green
if ($rawReportAvailable) {
    Write-Host "Raw wlanreport copy: $rawCopyPath" -ForegroundColor Green
}
else {
    Write-Warning "Raw wlan-report-latest.html was not found at $latestWlanReport"
}

if ($Open) {
    Start-Process -FilePath $htmlPath | Out-Null
}
