# Diagnose and repair Windows system files, component store, updates, disks, and pending reboots.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Menu', 'Inspect', 'DISM', 'SFC', 'FullRepair')]
    [string]$Mode = 'Menu',
    [string]$ReportRoot = "$env:ProgramData\Necktie\WindowsHealth"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RegistryPropertyValue {
    param([string]$Path, [string]$Name)
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    $property = $item.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $output | Tee-Object -FilePath $OutputPath | ForEach-Object { Write-Host $_ }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = @($output) }
}

function Get-PendingRebootState {
    $checks = [ordered]@{
        ComponentServicing = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        WindowsUpdate      = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        PendingFileRename  = $false
        ComputerRename     = $false
    }
    $sessionManager = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    $checks.PendingFileRename = $null -ne $sessionManager -and
        $null -ne $sessionManager.PSObject.Properties['PendingFileRenameOperations']
    $activeName = Get-RegistryPropertyValue 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' 'ComputerName'
    $pendingName = Get-RegistryPropertyValue 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' 'ComputerName'
    $checks.ComputerRename = $activeName -and $pendingName -and $activeName -ne $pendingName
    [pscustomobject]@{
        RebootPending = $checks.Values -contains $true
        Reasons       = @($checks.GetEnumerator() | Where-Object Value | ForEach-Object Key) -join ', '
    }
}

function Get-DiskHealth {
    try {
        $physical = @(Get-PhysicalDisk -ErrorAction Stop)
        return $physical | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus,
            @{ Name = 'SizeGB'; Expression = { [math]::Round($_.Size / 1GB, 1) } }
    }
    catch {
        return Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
            Select-Object Model, Status, @{ Name = 'SizeGB'; Expression = { [math]::Round($_.Size / 1GB, 1) } }
    }
}

function Get-UpdateDiagnostics {
    $services = 'wuauserv', 'bits', 'cryptsvc', 'trustedinstaller' | ForEach-Object {
        Get-Service -Name $_ -ErrorAction SilentlyContinue
    } | Select-Object Name, Status, StartType
    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'
            Level = 2, 3
            StartTime = (Get-Date).AddDays(-7)
        } -MaxEvents 25 -ErrorAction Stop | Select-Object TimeCreated, Id, LevelDisplayName, Message)
    } catch { }
    [pscustomobject]@{ Services = @($services); Events = $events }
}

function Invoke-WindowsInspection {
    param([Parameter(Mandatory)][string]$Path)
    Write-Host "`n=== Pending reboot ===" -ForegroundColor Cyan
    $reboot = Get-PendingRebootState
    if ($reboot.RebootPending) {
        Write-Host "Pending: YES ($($reboot.Reasons))" -ForegroundColor Yellow
    } else { Write-Host 'Pending: No' -ForegroundColor Green }
    $reboot | ConvertTo-Json | Set-Content (Join-Path $Path 'PendingReboot.json')

    Write-Host "`n=== Physical disk health ===" -ForegroundColor Cyan
    $disks = @(Get-DiskHealth)
    $disks | Format-Table -AutoSize
    $disks | Export-Csv (Join-Path $Path 'DiskHealth.csv') -NoTypeInformation

    Write-Host "`n=== Windows Update diagnostics ===" -ForegroundColor Cyan
    $updates = Get-UpdateDiagnostics
    $updates.Services | Format-Table -AutoSize
    $updates.Services | Export-Csv (Join-Path $Path 'UpdateServices.csv') -NoTypeInformation
    $updates.Events | Export-Csv (Join-Path $Path 'UpdateErrors.csv') -NoTypeInformation
    if ($updates.Events.Count) {
        Write-Host "$($updates.Events.Count) warning/error event(s) found in the last 7 days." -ForegroundColor Yellow
    } else { Write-Host 'No update warning/error events found in the last 7 days.' -ForegroundColor Green }

    Write-Host "`n=== Component store analysis ===" -ForegroundColor Cyan
    $dism = Invoke-NativeCapture dism.exe @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore') (Join-Path $Path 'DISM-Analyze.txt')
    if ($dism.ExitCode -eq 0) { Write-Host 'Component-store analysis completed.' -ForegroundColor Green }
    else { Write-Host "DISM analysis returned $($dism.ExitCode). Review DISM-Analyze.txt." -ForegroundColor Red }
}

function Invoke-DismRepair {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-IsElevated)) { throw 'DISM repair requires an elevated PowerShell session.' }
    if (-not $PSCmdlet.ShouldProcess('Windows component store', 'Run DISM RestoreHealth')) { return }
    Write-Host "`n=== DISM RestoreHealth ===" -ForegroundColor Cyan
    $result = Invoke-NativeCapture dism.exe @('/Online', '/Cleanup-Image', '/RestoreHealth') (Join-Path $Path 'DISM-RestoreHealth.txt')
    if ($result.ExitCode -ne 0) { throw "DISM returned exit code $($result.ExitCode)." }
    Write-Host 'DISM repaired or verified the component store.' -ForegroundColor Green
}

function Invoke-SfcScan {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-IsElevated)) { throw 'SFC requires an elevated PowerShell session.' }
    if (-not $PSCmdlet.ShouldProcess('Windows protected system files', 'Run SFC /scannow')) { return }
    Write-Host "`n=== System File Checker ===" -ForegroundColor Cyan
    $result = Invoke-NativeCapture sfc.exe @('/scannow') (Join-Path $Path 'SFC-Scannow.txt')
    if ($result.ExitCode -notin @(0, 1, 2, 3)) { throw "SFC returned unexpected exit code $($result.ExitCode)." }
    $text = $result.Output -join "`n"
    if ($text -match 'did not find any integrity violations') { Write-Host 'No system-file corruption was found.' -ForegroundColor Green }
    elseif ($text -match 'successfully repaired') { Write-Host 'Corrupt system files were repaired.' -ForegroundColor Green }
    elseif ($text -match 'unable to fix') { Write-Host 'Some files could not be repaired. Review SFC-Scannow.txt.' -ForegroundColor Red }
    else { Write-Host 'SFC completed. Review SFC-Scannow.txt for its localized result.' -ForegroundColor Yellow }
}

function Invoke-HealthRun {
    param([Parameter(Mandatory)][ValidateSet('Inspect', 'DISM', 'SFC', 'FullRepair')][string]$Action)
    $runPath = Join-Path $ReportRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Path $runPath -Force | Out-Null
    Start-Transcript -Path (Join-Path $runPath 'WindowsHealth.log') -Force | Out-Null
    try {
        Write-Host "Reports: $runPath" -ForegroundColor DarkGray
        switch ($Action) {
            'Inspect' { Invoke-WindowsInspection $runPath }
            'DISM' { Invoke-DismRepair $runPath }
            'SFC' { Invoke-SfcScan $runPath }
            'FullRepair' {
                Invoke-WindowsInspection $runPath
                Invoke-DismRepair $runPath
                Invoke-SfcScan $runPath
            }
        }
        Write-Host "`nCompleted. Reports are in $runPath" -ForegroundColor Green
        $pending = Get-PendingRebootState
        if ($pending.RebootPending) { Write-Host "A reboot is pending: $($pending.Reasons)" -ForegroundColor Yellow }
    } finally { Stop-Transcript | Out-Null }
}

function Show-HealthMenu {
    Clear-Host
    Write-Host ' WINDOWS HEALTH TOOLKIT ' -BackgroundColor DarkCyan -ForegroundColor White
    Write-Host " Elevated: $(Test-IsElevated)" -ForegroundColor $(if (Test-IsElevated) { 'Green' } else { 'Yellow' })
    Write-Host
    Write-Host ' [1] Inspect health' -ForegroundColor Cyan
    Write-Host '     Reboot state, disks, updates, and component-store analysis' -ForegroundColor Green
    Write-Host ' [2] Repair component store with DISM' -ForegroundColor Cyan
    Write-Host ' [3] Scan and repair system files with SFC' -ForegroundColor Cyan
    Write-Host ' [4] Full inspection and repair' -ForegroundColor Yellow
    Write-Host ' [Q] Quit' -ForegroundColor DarkGray
}

if ($Mode -ne 'Menu') {
    Invoke-HealthRun $Mode
    return
}

while ($true) {
    Show-HealthMenu
    $key = [Console]::ReadKey($true).Key
    $action = switch ($key) {
        'D1' { 'Inspect' }
        'NumPad1' { 'Inspect' }
        'D2' { 'DISM' }
        'NumPad2' { 'DISM' }
        'D3' { 'SFC' }
        'NumPad3' { 'SFC' }
        'D4' { 'FullRepair' }
        'NumPad4' { 'FullRepair' }
        'Q' { Clear-Host; return }
        'Escape' { Clear-Host; return }
    }
    if (-not $action) { continue }
    Clear-Host
    try { Invoke-HealthRun $action }
    catch { Write-Host "`n$($_.Exception.Message)" -ForegroundColor Red }
    Read-Host 'Press Enter to return to the menu' | Out-Null
}
