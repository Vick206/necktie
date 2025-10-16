param(
    [string]$ShellPath = "C:\Windows\System32\cmd.exe"
)

# Registry path
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

try {
    # Check for admin rights
    if (-not ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "This script must be run as Administrator."
        exit 1
    }

    # Set the Shell value
    Set-ItemProperty -Path $regPath -Name "Shell" -Value $ShellPath
    Write-Host "Winlogon shell changed to: $ShellPath"
}
catch {
    Write-Error "Failed to modify the registry: $_"
}

