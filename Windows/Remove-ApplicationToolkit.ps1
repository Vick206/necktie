# Discover related applications, uninstall them normally, and clean orphaned registrations safely.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$Search = 'WordPerfect',
    [switch]$List
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:UninstallRoots = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
)

function Get-PropertyValue {
    param($InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return '' }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Get-InstalledApplication {
    param([string]$Filter)

    $seen = @{}
    foreach ($root in $script:UninstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            $displayName = Get-PropertyValue -InputObject $item -Name 'DisplayName'
            $publisher = Get-PropertyValue -InputObject $item -Name 'Publisher'
            if (-not $displayName) { continue }
            if ($Filter -and
                $displayName -notlike "*$Filter*" -and
                $publisher -notlike "*$Filter*") { continue }
            if ($seen.ContainsKey($key.PSPath)) { continue }
            $seen[$key.PSPath] = $true

            $quietCommand = Get-PropertyValue -InputObject $item -Name 'QuietUninstallString'
            $normalCommand = Get-PropertyValue -InputObject $item -Name 'UninstallString'
            $command = if ($quietCommand) { $quietCommand } else { $normalCommand }
            [pscustomobject]@{
                Name            = $displayName
                Version         = Get-PropertyValue -InputObject $item -Name 'DisplayVersion'
                Publisher       = $publisher
                InstallLocation = Get-PropertyValue -InputObject $item -Name 'InstallLocation'
                Uninstall       = [string]$command
                RegistryPath    = $key.PSPath
                RegistryName    = $key.PSChildName
                IsMsi           = $key.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$' -or $command -match '(?i)msiexec'
                IsOrphaned      = Test-OrphanedRegistration -Item $item -RegistryName $key.PSChildName
            }
        }
    }
}

function Test-OrphanedRegistration {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$RegistryName
    )

    if ($RegistryName -match '^\{[0-9A-Fa-f-]{36}\}$') {
        # MSI registrations are not called orphaned merely because their cached installer is absent.
        return -not (Get-PropertyValue $Item 'UninstallString') -and
            -not (Get-PropertyValue $Item 'QuietUninstallString')
    }

    $installLocation = Get-PropertyValue $Item 'InstallLocation'
    $quietCommand = Get-PropertyValue $Item 'QuietUninstallString'
    $command = if ($quietCommand) { $quietCommand } else { Get-PropertyValue $Item 'UninstallString' }
    $locationExists = $installLocation -and (Test-Path -LiteralPath $installLocation -ErrorAction SilentlyContinue)
    $executable = Get-CommandExecutable -CommandLine $command
    $uninstallerExists = $executable -and (
        (Test-Path -LiteralPath $executable -ErrorAction SilentlyContinue) -or
        (Get-Command $executable -ErrorAction SilentlyContinue)
    )
    return -not $locationExists -and -not $uninstallerExists
}

function Get-CommandExecutable {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($expanded -match '^"(?<Exe>[^"]+)"') { return $Matches.Exe }
    if ($expanded -match '^(?<Exe>\S+?\.(?:exe|com|bat|cmd))(?:\s|$)') { return $Matches.Exe }
    return $null
}

function Split-UninstallCommand {
    param([Parameter(Mandatory)][string]$CommandLine)
    $expanded = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($expanded -match '^"(?<Exe>[^"]+)"\s*(?<Args>.*)$') {
        return @{ FilePath = $Matches.Exe; Arguments = $Matches.Args }
    }
    if ($expanded -match '^(?<Exe>\S+?\.(?:exe|com|bat|cmd))\s*(?<Args>.*)$') {
        return @{ FilePath = $Matches.Exe; Arguments = $Matches.Args }
    }
    throw "Could not safely parse uninstall command: $CommandLine"
}

function Invoke-ApplicationUninstall {
    param([Parameter(Mandatory)]$Application)

    if ([string]::IsNullOrWhiteSpace($Application.Uninstall)) {
        throw 'No registered uninstaller is available. Rescan and use orphan cleanup only if verified.'
    }
    if (-not $PSCmdlet.ShouldProcess($Application.Name, 'Run registered uninstaller')) { return }

    if ($Application.IsMsi) {
        $guid = [regex]::Match($Application.RegistryName + ' ' + $Application.Uninstall, '\{[0-9A-Fa-f-]{36}\}').Value
        if (-not $guid) { throw 'The MSI product code could not be determined.' }
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $guid) -Wait -PassThru
    }
    else {
        $parts = Split-UninstallCommand -CommandLine $Application.Uninstall
        $process = Start-Process -FilePath $parts.FilePath -ArgumentList $parts.Arguments -Wait -PassThru
    }
    if ($process.ExitCode -notin @(0, 1605, 1614, 1641, 3010)) {
        throw "The uninstaller returned exit code $($process.ExitCode)."
    }
}

function Remove-OrphanedRegistration {
    param([Parameter(Mandatory)]$Application)

    $current = Get-ItemProperty -LiteralPath $Application.RegistryPath -ErrorAction SilentlyContinue
    if (-not $current) { return }
    if (-not (Test-OrphanedRegistration -Item $current -RegistryName $Application.RegistryName)) {
        throw 'This registration is not currently verified as orphaned. Cleanup was refused.'
    }

    $backupRoot = Join-Path $env:ProgramData 'Necktie\ApplicationRemovalBackups'
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $safeName = $Application.Name -replace '[^A-Za-z0-9._-]', '_'
    $backup = Join-Path $backupRoot ("{0}-{1}.reg" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $safeName)
    $nativePath = $Application.RegistryPath -replace '^Microsoft.PowerShell.Core\\Registry::', ''

    if ($PSCmdlet.ShouldProcess($Application.Name, "Back up and remove orphaned registration")) {
        & reg.exe export $nativePath $backup /y | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $backup)) {
            throw 'Registry backup failed; the registration was not removed.'
        }
        Remove-Item -LiteralPath $Application.RegistryPath -Recurse -Force
        Write-Host "Backup saved to $backup" -ForegroundColor Green
    }
}

function Read-SearchTerm {
    Clear-Host
    Write-Host 'Search by product name or publisher' -ForegroundColor Cyan
    $value = Read-Host "Search [$Search]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Search }
    return $value.Trim()
}

function Show-Toolkit {
    param([object[]]$Applications, [int]$Selected, [string]$Filter)
    Clear-Host
    Write-Host ' APPLICATION REMOVAL TOOLKIT ' -BackgroundColor DarkCyan -ForegroundColor White
    Write-Host " Search: $Filter" -ForegroundColor Cyan
    Write-Host ' Up/Down: select   U: uninstall   C: clean orphan   S: search   R: rescan   Q: quit' -ForegroundColor DarkGray
    Write-Host ' Normal uninstall always comes before orphan cleanup.' -ForegroundColor Yellow
    Write-Host
    if (-not $Applications.Count) {
        Write-Host ' No matching registered applications.' -ForegroundColor Yellow
        return
    }
    for ($i = 0; $i -lt $Applications.Count; $i++) {
        $app = $Applications[$i]
        $state = if ($app.IsOrphaned) { '[ORPHAN]' } elseif ($app.IsMsi) { '[MSI]' } else { '[APP]' }
        $line = '{0,-9} {1} {2}' -f $state, $app.Name, $app.Version
        if ($i -eq $Selected) {
            Write-Host " > $line" -BackgroundColor DarkCyan -ForegroundColor White
        } else {
            $color = if ($app.IsOrphaned) { 'Yellow' } else { 'White' }
            Write-Host "   $line" -ForegroundColor $color
        }
        Write-Host ("     Publisher: {0}" -f $app.Publisher) -ForegroundColor Green
    }
}

$filter = $Search
$selected = 0
if ($List) {
    Get-InstalledApplication -Filter $filter |
        Sort-Object Name, Version |
        Select-Object Name, Version, Publisher, IsMsi, IsOrphaned, Uninstall, RegistryPath
    return
}

while ($true) {
    $applications = @(Get-InstalledApplication -Filter $filter | Sort-Object Name, Version)
    if ($selected -ge $applications.Count) { $selected = [Math]::Max(0, $applications.Count - 1) }
    Show-Toolkit -Applications $applications -Selected $selected -Filter $filter
    $key = [Console]::ReadKey($true).Key
    try {
        switch ($key) {
            'UpArrow'   { if ($applications.Count) { $selected = ($selected - 1 + $applications.Count) % $applications.Count } }
            'DownArrow' { if ($applications.Count) { $selected = ($selected + 1) % $applications.Count } }
            'U'         { if ($applications.Count) { Invoke-ApplicationUninstall -Application $applications[$selected] } }
            'C'         { if ($applications.Count) { Remove-OrphanedRegistration -Application $applications[$selected] } }
            'S'         { $filter = Read-SearchTerm; $selected = 0 }
            'Q'         { Clear-Host; return }
            'Escape'    { Clear-Host; return }
        }
    }
    catch {
        Write-Host "`n$($_.Exception.Message)" -ForegroundColor Red
        Read-Host 'Press Enter to continue' | Out-Null
    }
}
