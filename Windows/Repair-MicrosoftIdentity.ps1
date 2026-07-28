# Diagnose and repair Microsoft Entra, Office, and Windows identity components.
<#
.SYNOPSIS
    Repairs Microsoft authentication components for the current Windows user.

.DESCRIPTION
    Provides tiered repair modes for Microsoft Entra ID, Web Account Manager,
    AAD BrokerPlugin, Windows Hello, Office identity caches, and related user state.

    Modes:
      Inspect            Collect diagnostics only.
      Repair             Re-register and reset authentication AppX packages.
      ResetUserIdentity  Rename per-user identity caches and optionally remove Hello.
      Nuclear            Reset broader Microsoft identity caches and Office identity state.

    This script deliberately does NOT run dsregcmd /leave and does not remove Intune enrollment.

.NOTES
    Run in the affected user's interactive session.
    Some actions require elevation.
    Test in your environment before broad deployment.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Inspect', 'Repair', 'ResetUserIdentity', 'Nuclear')]
    [string]$Mode = 'Inspect',

    [switch]$RemoveWindowsHello,

    [switch]$Restart,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Test-IsSystem {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return $identity.User.Value -eq 'S-1-5-18'
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Stop-MicrosoftApps {
    $processNames = @(
        'OUTLOOK',
        'WINWORD',
        'EXCEL',
        'POWERPNT',
        'ONENOTE',
        'MSACCESS',
        'MSPUB',
        'Teams',
        'ms-teams',
        'OneDrive',
        'Microsoft.SharePoint',
        'OfficeClickToRun',
        'olk'
    )

    foreach ($name in $processNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            if ($PSCmdlet.ShouldProcess($_.ProcessName, 'Stop process')) {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-PackageInfo {
    param([Parameter(Mandatory)][string[]]$Names)

    foreach ($name in $Names) {
        $pkg = Get-AppxPackage -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $pkg) {
            [pscustomobject]@{
                Name            = $name
                Present         = $false
                Status          = $null
                InstallLocation = $null
                PackageFullName = $null
            }
            continue
        }

        foreach ($item in $pkg) {
            [pscustomobject]@{
                Name            = $item.Name
                Present         = $true
                Status          = $item.Status
                InstallLocation = $item.InstallLocation
                PackageFullName = $item.PackageFullName
            }
        }
    }
}

function Register-IdentityPackages {
    param([Parameter(Mandatory)][string[]]$Names)

    foreach ($name in $Names) {
        $packages = Get-AppxPackage -Name $name -ErrorAction SilentlyContinue

        if (-not $packages) {
            Write-Warning "Package not found: $name"
            continue
        }

        foreach ($pkg in $packages) {
            $manifest = Join-Path $pkg.InstallLocation 'AppXManifest.xml'

            if (-not (Test-Path $manifest)) {
                Write-Warning "Manifest missing for $name at $manifest"
                continue
            }

            if ($PSCmdlet.ShouldProcess($name, "Re-register package from $manifest")) {
                Add-AppxPackage -DisableDevelopmentMode -Register $manifest
            }
        }
    }
}

function Reset-IdentityPackages {
    param([Parameter(Mandatory)][string[]]$Names)

    foreach ($name in $Names) {
        $packages = Get-AppxPackage -Name $name -ErrorAction SilentlyContinue

        if (-not $packages) {
            Write-Warning "Package not found: $name"
            continue
        }

        foreach ($pkg in $packages) {
            if ($PSCmdlet.ShouldProcess($pkg.Name, 'Reset AppX package')) {
                try {
                    Reset-AppxPackage -Package $pkg.PackageFullName
                }
                catch {
                    Write-Warning "Reset-AppxPackage failed for $($pkg.Name): $($_.Exception.Message)"
                }
            }
        }
    }
}

function Rename-PathSafe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BackupRoot
    )

    if (-not (Test-Path $Path)) {
        Write-Verbose "Path not present: $Path"
        return
    }

    $leaf = Split-Path $Path -Leaf
    $destination = Join-Path $BackupRoot $leaf

    if (Test-Path $destination) {
        $destination = "$destination.$([guid]::NewGuid().ToString('N'))"
    }

    if ($PSCmdlet.ShouldProcess($Path, "Move to $destination")) {
        Move-Item -LiteralPath $Path -Destination $destination -Force
    }
}

function Export-RegistryKey {
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$Destination
    )

    $nativePath = $RegistryPath -replace '^HKCU:', 'HKEY_CURRENT_USER'

    if (-not (Test-Path $RegistryPath)) {
        return
    }

    if ($PSCmdlet.ShouldProcess($RegistryPath, "Export to $Destination")) {
        & reg.exe export $nativePath $Destination /y | Out-Null
    }
}

function Remove-RegistryTreeSafe {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        return
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Remove registry tree')) {
        Remove-Item -Path $Path -Recurse -Force
    }
}

function Remove-WindowsHelloContainer {
    if (-not (Get-Command certutil.exe -ErrorAction SilentlyContinue)) {
        throw 'certutil.exe was not found.'
    }

    if ($PSCmdlet.ShouldProcess('Current user Windows Hello container', 'Delete')) {
        & certutil.exe -DeleteHelloContainer
        if ($LASTEXITCODE -ne 0) {
            throw "certutil.exe returned exit code $LASTEXITCODE"
        }
    }
}

function Get-RecentIdentityEvents {
    param([datetime]$Since = (Get-Date).AddHours(-2))

    $logs = @(
        'Microsoft-Windows-AAD/Operational',
        'Microsoft-Windows-User Device Registration/Admin',
        'Microsoft-Windows-HelloForBusiness/Operational'
    )

    foreach ($log in $logs) {
        try {
            Get-WinEvent -FilterHashtable @{
                LogName   = $log
                StartTime = $Since
            } -ErrorAction Stop |
                Select-Object @{
                    Name='LogName'; Expression={$log}
                }, TimeCreated, Id, LevelDisplayName, Message
        }
        catch {
            Write-Verbose "Could not read log ${log}: $($_.Exception.Message)"
        }
    }
}

if (Test-IsSystem) {
    throw 'Refusing to run as SYSTEM. Run this in the affected user session.'
}

$identityPackages = @(
    'Microsoft.AAD.BrokerPlugin',
    'Microsoft.AccountsControl',
    'Microsoft.Windows.CloudExperienceHost'
)

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$basePath = Join-Path $env:ProgramData "MicrosoftIdentityRepair\$env:USERNAME\$timestamp"
$backupPath = Join-Path $basePath 'Backup'
$reportPath = Join-Path $basePath 'Reports'
$transcriptPath = Join-Path $basePath 'Repair.log'

New-Item -ItemType Directory -Path $backupPath, $reportPath -Force | Out-Null
Start-Transcript -Path $transcriptPath -Force | Out-Null

try {
    Write-Section 'Session'
    Write-Host "User:          $env:USERDOMAIN\$env:USERNAME"
    Write-Host "SID:           $([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"
    Write-Host "Mode:          $Mode"
    Write-Host "Elevated:      $(Test-IsElevated)"
    Write-Host "Backup path:   $backupPath"
    Write-Host "Report path:   $reportPath"

    Write-Section 'Package state'
    $packageInfo = Get-PackageInfo -Names $identityPackages
    $packageInfo | Format-Table -AutoSize
    $packageInfo | Export-Csv -Path (Join-Path $reportPath 'AppxPackages.csv') -NoTypeInformation

    Write-Section 'Entra device state'
    try {
        $dsregOutput = & dsregcmd.exe /status
        $dsregOutput | Tee-Object -FilePath (Join-Path $reportPath 'dsregcmd-status.txt')
    }
    catch {
        Write-Warning "Unable to run dsregcmd /status: $($_.Exception.Message)"
    }

    Write-Section 'Recent identity events'
    $events = Get-RecentIdentityEvents
    if ($events) {
        $events | Export-Csv -Path (Join-Path $reportPath 'IdentityEvents.csv') -NoTypeInformation
        $events | Select-Object TimeCreated, LogName, Id, LevelDisplayName, Message |
            Format-Table -Wrap
    }
    else {
        Write-Host 'No recent identity events collected.'
    }

    if ($Mode -eq 'Inspect') {
        Write-Host "`nInspection complete. No changes were made."
        return
    }

    if (-not $Force) {
        Write-Warning 'This operation can sign the user out of Microsoft applications.'
        Write-Warning 'Confirm the user knows their password and has access to MFA.'
    }

    Write-Section 'Stopping Microsoft applications'
    Stop-MicrosoftApps

    Write-Section 'Repairing AppX identity packages'
    Register-IdentityPackages -Names $identityPackages
    Reset-IdentityPackages -Names $identityPackages

    if ($Mode -in @('ResetUserIdentity', 'Nuclear')) {
        Write-Section 'Backing up and resetting per-user identity caches'

        $cachePaths = @(
            "$env:LOCALAPPDATA\Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy",
            "$env:LOCALAPPDATA\Packages\Microsoft.AccountsControl_cw5n1h2txyewy",
            "$env:LOCALAPPDATA\Microsoft\OneAuth",
            "$env:LOCALAPPDATA\Microsoft\IdentityCache"
        )

        foreach ($path in $cachePaths) {
            Rename-PathSafe -Path $path -BackupRoot $backupPath
        }

        if ($RemoveWindowsHello) {
            Write-Section 'Removing Windows Hello container'
            Remove-WindowsHelloContainer
        }
    }

    if ($Mode -eq 'Nuclear') {
        Write-Section 'Resetting broader Office and Microsoft identity state'

        $registryBackups = @(
            @{
                Path = 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity'
                File = 'OfficeIdentity.reg'
            },
            @{
                Path = 'HKCU:\Software\Microsoft\IdentityCRL'
                File = 'IdentityCRL.reg'
            }
        )

        foreach ($entry in $registryBackups) {
            Export-RegistryKey `
                -RegistryPath $entry.Path `
                -Destination (Join-Path $backupPath $entry.File)
        }

        Remove-RegistryTreeSafe -Path 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity'
        Remove-RegistryTreeSafe -Path 'HKCU:\Software\Microsoft\IdentityCRL'

        $officeCachePaths = @(
            "$env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing",
            "$env:LOCALAPPDATA\Microsoft\Office\Licenses"
        )

        foreach ($path in $officeCachePaths) {
            Rename-PathSafe -Path $path -BackupRoot $backupPath
        }

        if (-not $RemoveWindowsHello) {
            Write-Warning 'Nuclear mode was selected without -RemoveWindowsHello. The Hello container was preserved.'
        }
    }

    Write-Section 'Re-registering packages after cache reset'
    Register-IdentityPackages -Names $identityPackages

    Write-Section 'Complete'
    Write-Host "Repair completed."
    Write-Host "Logs and backups: $basePath"
    Write-Host 'Sign out or restart before testing Microsoft sign-in and Windows Hello.'

    if ($Restart) {
        if ($PSCmdlet.ShouldProcess('Computer', 'Restart')) {
            Restart-Computer -Force
        }
    }
}
finally {
    Stop-Transcript | Out-Null
}
