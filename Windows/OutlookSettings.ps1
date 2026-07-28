# Export or import Outlook profile settings and related user data.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Export', 'Import')]
    [string]$Mode,

    [Parameter(Mandatory, Position = 1)]
    [string]$Path,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Assert-OutlookClosed {
    if (Get-Process OUTLOOK -ErrorAction SilentlyContinue) {
        throw 'Classic Outlook is running. Close it before continuing.'
    }
}

function Copy-Tree {
    param([string]$Source, [string]$Destination, [string[]]$Exclude = @())
    if (-not (Test-Path -LiteralPath $Source)) { return }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Where-Object {
        $name = $_.Name
        -not ($Exclude | Where-Object { $name -like $_ })
    } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-OfficeVersions {
    $root = 'HKCU:\Software\Microsoft\Office'
    if (-not (Test-Path $root)) { return @() }
    @(Get-ChildItem $root | Where-Object { $_.PSChildName -match '^\d+\.\d+$' } |
        Select-Object -ExpandProperty PSChildName)
}

Assert-OutlookClosed

if ($Mode -eq 'Export') {
    $zipPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($zipPath) -ne '.zip') { $zipPath += '.zip' }
    if ((Test-Path $zipPath) -and -not $Force) {
        throw "The archive already exists: $zipPath. Use -Force to replace it."
    }

    $stage = Join-Path $env:TEMP ("OutlookContext_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        $roaming = Join-Path $stage 'AppData\Roaming\Microsoft'
        $local   = Join-Path $stage 'AppData\Local\Microsoft'

        Copy-Tree "$env:APPDATA\Microsoft\Signatures" "$roaming\Signatures"
        Copy-Tree "$env:APPDATA\Microsoft\Templates"  "$roaming\Templates"
        Copy-Tree "$env:APPDATA\Microsoft\UProof"     "$roaming\UProof"
        Copy-Tree "$env:APPDATA\Microsoft\Outlook"   "$roaming\Outlook" @('*.ost','*.pst','*.nst','*.oab','*.tmp')
        Copy-Tree "$env:LOCALAPPDATA\Microsoft\Office" "$local\Office" @('*.ost','*.pst','*.nst','OfficeFileCache')

        $regDir = Join-Path $stage 'Registry'
        New-Item -ItemType Directory -Path $regDir -Force | Out-Null
        $regKeys = [ordered]@{
            'Office-Common.reg' = 'HKCU\Software\Microsoft\Office\Common'
        }
        foreach ($version in Get-OfficeVersions) {
            $regKeys["Outlook-$version.reg"] = "HKCU\Software\Microsoft\Office\$version\Outlook"
        }
        foreach ($item in $regKeys.GetEnumerator()) {
            & reg.exe query $item.Value *> $null
            if ($LASTEXITCODE -eq 0) {
                & reg.exe export $item.Value (Join-Path $regDir $item.Key) /y *> $null
                if ($LASTEXITCODE -ne 0) { throw "Registry export failed: $($item.Value)" }
            }
        }

        [ordered]@{
            CreatedUtc     = (Get-Date).ToUniversalTime().ToString('o')
            ComputerName   = $env:COMPUTERNAME
            UserName       = $env:USERNAME
            OfficeVersions = @(Get-OfficeVersions)
            Notes          = 'OST, PST, NST, OAB, cache, credentials, and mailbox data are intentionally excluded.'
        } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $stage 'manifest.json') -Encoding UTF8

        if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal
        Write-Host "Outlook context exported to: $zipPath" -ForegroundColor Green
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
else {
    $zipPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $zipPath)) { throw "Archive not found: $zipPath" }

    $stage = Join-Path $env:TEMP ("OutlookContext_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $stage -Force
        if (-not (Test-Path (Join-Path $stage 'manifest.json'))) {
            throw 'This does not appear to be an Outlook context archive created by this script.'
        }

        $copies = @(
            @('AppData\Roaming\Microsoft\Signatures', "$env:APPDATA\Microsoft\Signatures"),
            @('AppData\Roaming\Microsoft\Templates',  "$env:APPDATA\Microsoft\Templates"),
            @('AppData\Roaming\Microsoft\UProof',     "$env:APPDATA\Microsoft\UProof"),
            @('AppData\Roaming\Microsoft\Outlook',   "$env:APPDATA\Microsoft\Outlook"),
            @('AppData\Local\Microsoft\Office',      "$env:LOCALAPPDATA\Microsoft\Office")
        )
        foreach ($copy in $copies) {
            $source = Join-Path $stage $copy[0]
            if (Test-Path $source) { Copy-Tree $source $copy[1] }
        }

        if ($Force) {
            Get-ChildItem (Join-Path $stage 'Registry') -Filter '*.reg' -ErrorAction SilentlyContinue |
                ForEach-Object {
                    & reg.exe import $_.FullName *> $null
                    if ($LASTEXITCODE -ne 0) { throw "Registry import failed: $($_.Name)" }
                }
            Write-Warning 'Registry settings were imported. Account and profile specific settings may require repair.'
        }
        else {
            Write-Warning 'Files restored. Registry settings were NOT imported. Re-run Import with -Force to include them.'
        }
        Write-Host 'Outlook context import completed. Start Outlook and verify signatures, Favorites, views, ribbon, and Quick Access Toolbar.' -ForegroundColor Green
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
