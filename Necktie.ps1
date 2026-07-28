# Launch and discover the Windows tools stored in this repository.
[CmdletBinding()]
param(
    [string]$RootPath,
    [switch]$List
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = Split-Path -Parent $PSCommandPath
}

$script:SupportedExtensions = @('.ps1', '.psm1', '.cmd', '.bat', '.exe')
$script:IgnoredDirectories = @('.git', '.agents', '.codex', 'node_modules', 'vendor')

function Get-NecktieTools {
    param([Parameter(Mandatory)][string]$Path)

    $wrapperPath = $PSCommandPath
    Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension.ToLowerInvariant() -in $script:SupportedExtensions -and
            $_.FullName -ne $wrapperPath -and
            -not ($_.FullName.Substring($Path.Length).Split([IO.Path]::DirectorySeparatorChar) |
                Where-Object { $_ -in $script:IgnoredDirectories })
        } |
        ForEach-Object {
            $description = Get-ToolDescription -Tool $_
            Add-Member -InputObject $_ -NotePropertyName Description -NotePropertyValue $description -Force
            $_
        } |
        Sort-Object DirectoryName, BaseName
}

function Get-ToolDescription {
    param([Parameter(Mandatory)][IO.FileInfo]$Tool)

    if ($Tool.Extension.ToLowerInvariant() -eq '.exe') { return '' }

    try {
        $firstLine = Get-Content -LiteralPath $Tool.FullName -TotalCount 1 -ErrorAction Stop
        if ($null -eq $firstLine) { return '' }

        # Accommodate the native first-line comment styles of supported scripts.
        if ($firstLine -match '^\s*(?:#|//|;|REM\s+|::)\s*(?<Description>.+?)\s*$') {
            return $Matches.Description
        }
    }
    catch {
        return ''
    }

    return ''
}

function Start-NecktieTool {
    param([Parameter(Mandatory)][IO.FileInfo]$Tool)

    Clear-Host
    Write-Host "Running $($Tool.FullName)" -ForegroundColor Cyan
    Write-Host ('-' * 72)

    Push-Location -LiteralPath $Tool.DirectoryName
    try {
        switch ($Tool.Extension.ToLowerInvariant()) {
            '.ps1' { & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Tool.FullName }
            '.psm1' { & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Import-Module -LiteralPath '$($Tool.FullName.Replace("'", "''"))' -Force" }
            '.cmd' { & cmd.exe /d /c ('"{0}"' -f $Tool.FullName) }
            '.bat' { & cmd.exe /d /c ('"{0}"' -f $Tool.FullName) }
            '.exe' { & $Tool.FullName }
        }
    }
    catch {
        Write-Host "Tool failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        Pop-Location
    }

    Write-Host
    Read-Host 'Press Enter to return to Necktie' | Out-Null
}

function Get-RelativeDirectory {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Directory
    )

    if ($Directory.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) { return '.' }
    return $Directory.Substring($Root.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
}

function Get-NecktieEntries {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Tools
    )

    $entries = @()
    $childDirectories = $Tools |
        Where-Object { $_.DirectoryName.StartsWith("$Path$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object {
            $remainder = $_.DirectoryName.Substring($Path.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
            $firstPart = $remainder.Split([IO.Path]::DirectorySeparatorChar)[0]
            Join-Path $Path $firstPart
        } |
        Sort-Object -Unique

    foreach ($directory in $childDirectories) {
        $toolCount = @($Tools | Where-Object {
            $_.FullName.StartsWith("$directory$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)
        }).Count
        $entries += [pscustomobject]@{
            Kind        = 'Directory'
            Name        = Split-Path $directory -Leaf
            Description = "$toolCount tool(s)"
            Path        = $directory
            Tool        = $null
        }
    }

    foreach ($tool in $Tools | Where-Object { $_.DirectoryName.Equals($Path, [StringComparison]::OrdinalIgnoreCase) }) {
        $entries += [pscustomobject]@{
            Kind        = 'Tool'
            Name        = $tool.Name
            Description = $tool.Description
            Path        = $tool.FullName
            Tool        = $tool
        }
    }

    return $entries
}

function Show-NecktieMenu {
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [Parameter(Mandatory)][string]$CurrentPath,
        [int]$Selected = 0
    )

    Clear-Host
    Write-Host ' NECKTIE ' -NoNewline -BackgroundColor DarkCyan -ForegroundColor White
    Write-Host ' Windows tool launcher' -ForegroundColor Cyan
    $location = Get-RelativeDirectory -Root $RootPath -Directory $CurrentPath
    Write-Host " Location: [$location]" -ForegroundColor Yellow
    Write-Host ' Up/Down: move   Enter/Right: open   Backspace/Left: back   R: refresh   Q: quit' -ForegroundColor DarkGray
    Write-Host

    if ($Entries.Count -eq 0) {
        Write-Host ' This folder contains no supported tools.' -ForegroundColor Yellow
        return
    }

    $labels = @($Entries | ForEach-Object {
        if ($_.Kind -eq 'Directory') { "+--> [$($_.Name)]" } else { "     $($_.Name)" }
    })
    $nameWidth = [Math]::Max(1, ($labels | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum)
    for ($index = 0; $index -lt $Entries.Count; $index++) {
        $entry = $Entries[$index]
        $label = $labels[$index]
        $nameEntry = (' {0,-' + $nameWidth + '}  ') -f $label
        if ($index -eq $Selected) {
            Write-Host " >$nameEntry" -NoNewline -BackgroundColor DarkCyan -ForegroundColor White
            Write-Host $entry.Description -BackgroundColor DarkCyan -ForegroundColor Green
        }
        else {
            $nameColor = if ($entry.Kind -eq 'Directory') { 'Yellow' } else { 'White' }
            Write-Host "  $nameEntry" -NoNewline -ForegroundColor $nameColor
            Write-Host $entry.Description -ForegroundColor Green
        }
    }
}

$RootPath = (Resolve-Path -LiteralPath $RootPath).Path.TrimEnd([IO.Path]::DirectorySeparatorChar)
$selected = 0
$tools = @(Get-NecktieTools -Path $RootPath)

if ($List) {
    $tools | Select-Object Name, Description, Extension, @{ Name = 'Directory'; Expression = {
        Get-RelativeDirectory -Root $RootPath -Directory $_.DirectoryName
    } }, FullName
    return
}

$currentPath = $RootPath
while ($true) {
    $entries = @(Get-NecktieEntries -Path $currentPath -Tools $tools)
    if ($selected -ge $entries.Count) { $selected = [Math]::Max(0, $entries.Count - 1) }
    Show-NecktieMenu -Entries $entries -CurrentPath $currentPath -Selected $selected
    $key = [Console]::ReadKey($true)

    switch ($key.Key) {
        'UpArrow'   { if ($entries.Count) { $selected = ($selected - 1 + $entries.Count) % $entries.Count } }
        'DownArrow' { if ($entries.Count) { $selected = ($selected + 1) % $entries.Count } }
        { $_ -in @('Enter', 'RightArrow') } {
            if ($entries.Count) {
                if ($entries[$selected].Kind -eq 'Directory') {
                    $currentPath = $entries[$selected].Path
                    $selected = 0
                }
                else {
                    Start-NecktieTool -Tool $entries[$selected].Tool
                }
            }
        }
        { $_ -in @('Backspace', 'LeftArrow') } {
            if (-not $currentPath.Equals($RootPath, [StringComparison]::OrdinalIgnoreCase)) {
                $currentPath = Split-Path $currentPath -Parent
                $selected = 0
            }
        }
        'Q'         { Clear-Host; return }
        'Escape'    { Clear-Host; return }
    }

    # Re-scan after every interaction so newly added directories and tools appear.
    $tools = @(Get-NecktieTools -Path $RootPath)
}
