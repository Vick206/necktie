# Generate a device network report with adapter, IP, DNS, route, and connection details.
[CmdletBinding()]
param(
    [string]$ReportRoot = "$env:ProgramData\Necktie\NetworkReports",
    [switch]$IncludeNetstat
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $output | Set-Content -Path $OutputPath -Encoding UTF8
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($output)
    }
}

function Convert-ToMarkdownTable {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][string[]]$Columns
    )

    if (-not $Rows.Count) {
        return @('No data.')
    }

    $header = '| ' + (($Columns | ForEach-Object { $_ }) -join ' | ') + ' |'
    $divider = '| ' + (($Columns | ForEach-Object { '---' }) -join ' | ') + ' |'
    $lines = @($header, $divider)

    foreach ($row in $Rows) {
        $values = foreach ($column in $Columns) {
            $property = $row.PSObject.Properties[$column]
            if ($null -eq $property -or $null -eq $property.Value) {
                ''
            }
            else {
                [string]$property.Value -replace '\|', '\|'
            }
        }
        $lines += '| ' + ($values -join ' | ') + ' |'
    }

    return $lines
}

function Join-PropertyValues {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return ''
    }

    $values = @($InputObject | ForEach-Object {
            $property = $_.PSObject.Properties[$PropertyName]
            if ($null -ne $property -and $null -ne $property.Value) {
                [string]$property.Value
            }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return $values -join ', '
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $ReportRoot $timestamp
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

$adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress)
$profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Sort-Object InterfaceAlias | Select-Object Name, InterfaceAlias, NetworkCategory, IPv4Connectivity, IPv6Connectivity)
$dnsServers = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Sort-Object InterfaceAlias |
    Select-Object InterfaceAlias, InterfaceIndex, @{ Name = 'ServerAddresses'; Expression = { ($_.ServerAddresses -join ', ') } })
$ipConfigs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Sort-Object InterfaceAlias | ForEach-Object {
        $dnsSuffix = ''
        if ($null -ne $_.NetProfile) {
            $dnsSuffixProperty = $_.NetProfile.PSObject.Properties['DnsSuffix']
            if ($null -ne $dnsSuffixProperty -and $null -ne $dnsSuffixProperty.Value) {
                $dnsSuffix = [string]$dnsSuffixProperty.Value
            }
        }
        [pscustomobject]@{
            InterfaceAlias = $_.InterfaceAlias
            IPv4Address    = Join-PropertyValues -InputObject $_.IPv4Address -PropertyName 'IPAddress'
            IPv4Gateway    = Join-PropertyValues -InputObject $_.IPv4DefaultGateway -PropertyName 'NextHop'
            DNSSuffix      = $dnsSuffix
        }
    })

$routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric, DestinationPrefix |
    Select-Object -First 40 DestinationPrefix, NextHop, InterfaceAlias, RouteMetric)

$adapters | Export-Csv -Path (Join-Path $reportPath 'Adapters.csv') -NoTypeInformation
$profiles | Export-Csv -Path (Join-Path $reportPath 'ConnectionProfiles.csv') -NoTypeInformation
$dnsServers | Export-Csv -Path (Join-Path $reportPath 'DnsServers.csv') -NoTypeInformation
$ipConfigs | Export-Csv -Path (Join-Path $reportPath 'IpConfiguration.csv') -NoTypeInformation
$routes | Export-Csv -Path (Join-Path $reportPath 'RoutesTop40.csv') -NoTypeInformation

Invoke-NativeCapture -FilePath 'ipconfig.exe' -Arguments @('/all') -OutputPath (Join-Path $reportPath 'ipconfig-all.txt') | Out-Null
Invoke-NativeCapture -FilePath 'route.exe' -Arguments @('print') -OutputPath (Join-Path $reportPath 'route-print.txt') | Out-Null
Invoke-NativeCapture -FilePath 'arp.exe' -Arguments @('-a') -OutputPath (Join-Path $reportPath 'arp-a.txt') | Out-Null
Invoke-NativeCapture -FilePath 'netsh.exe' -Arguments @('winhttp', 'show', 'proxy') -OutputPath (Join-Path $reportPath 'winhttp-proxy.txt') | Out-Null

if ($IncludeNetstat) {
    Invoke-NativeCapture -FilePath 'netstat.exe' -Arguments @('-ano') -OutputPath (Join-Path $reportPath 'netstat-ano.txt') | Out-Null
}

$reportLines = @()
$reportLines += '# Device Network Report'
$reportLines += ''
$reportLines += "- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
$reportLines += "- Computer: $env:COMPUTERNAME"
$reportLines += "- User: $env:USERDOMAIN\$env:USERNAME"
$reportLines += ''
$reportLines += '## Network Adapters'
$reportLines += Convert-ToMarkdownTable -Rows $adapters -Columns @('Name', 'Status', 'LinkSpeed', 'MacAddress')
$reportLines += ''
$reportLines += '## Interface IP Overview'
$reportLines += Convert-ToMarkdownTable -Rows $ipConfigs -Columns @('InterfaceAlias', 'IPv4Address', 'IPv4Gateway', 'DNSSuffix')
$reportLines += ''
$reportLines += '## Connection Profiles'
$reportLines += Convert-ToMarkdownTable -Rows $profiles -Columns @('Name', 'InterfaceAlias', 'NetworkCategory', 'IPv4Connectivity')
$reportLines += ''
$reportLines += '## DNS Servers'
$reportLines += Convert-ToMarkdownTable -Rows $dnsServers -Columns @('InterfaceAlias', 'ServerAddresses')
$reportLines += ''
$reportLines += '## Top Routes (first 40 by metric)'
$reportLines += Convert-ToMarkdownTable -Rows $routes -Columns @('DestinationPrefix', 'NextHop', 'InterfaceAlias', 'RouteMetric')
$reportLines += ''
$reportLines += '## Raw Command Outputs'
$reportLines += '- ipconfig-all.txt'
$reportLines += '- route-print.txt'
$reportLines += '- arp-a.txt'
$reportLines += '- winhttp-proxy.txt'
if ($IncludeNetstat) {
    $reportLines += '- netstat-ano.txt'
}

$markdownPath = Join-Path $reportPath 'NetworkReport.md'
$reportLines | Set-Content -Path $markdownPath -Encoding UTF8

Write-Host "Network report created at: $reportPath" -ForegroundColor Green
Write-Host "Summary document: $markdownPath" -ForegroundColor Green
