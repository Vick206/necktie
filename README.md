# necktie
Set of utilities for daily carry, and other shenanigans
One day I will be cool, and use this stuff at a new job to seem like a greybeard.

## Windows launcher

Run `powershell.exe -ExecutionPolicy Bypass -File .\Necktie.ps1` from the repo
root. The dependency-free TUI recursively discovers `.ps1`, `.psm1`, `.cmd`,
`.bat`, and `.exe` tools, groups them by directory, and refreshes its list after
each key press (or when you press `R`).

The opening screen shows folder categories such as `+--> [Windows]`. Press
Enter or Right Arrow to browse a category, and Backspace or Left Arrow to move
back up the folder tree.

Use `powershell.exe -File .\Necktie.ps1 -List` to print the discovered tools
without opening the interactive menu.

### Tool descriptions

Put a short description in a tool's first-line comment. Necktie displays it to
the right of the filename:

```powershell
# Export or import Outlook profile settings and related user data.
```

PowerShell and shell-style `#` comments are supported, along with `//`, `;`,
`REM`, and `::` comments for other script types. Compiled `.exe` files do not
have first-line descriptions.

## Windows health toolkit

Run `powershell.exe -ExecutionPolicy Bypass -File .\Windows\Repair-WindowsHealth.ps1`
for the health TUI. Inspection reports pending reboots, disk state, Windows
Update errors, and component-store health. DISM, SFC, and full repair are
separate elevated actions with confirmation and timestamped reports under
`%ProgramData%\Necktie\WindowsHealth`.

## Microsoft identity repair

Run `Windows\Repair-MicrosoftIdentity.ps1` in the affected user's interactive
session to diagnose or repair Microsoft Entra, Web Account Manager, AAD
BrokerPlugin, Windows Hello, and Office identity state. The default `Inspect`
mode only collects diagnostics:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Windows\Repair-MicrosoftIdentity.ps1
```

Use `-Mode Repair` to re-register and reset identity AppX packages,
`-Mode ResetUserIdentity` to also back up and reset per-user identity caches,
or `-Mode Nuclear` to additionally reset broader Office identity state. Add
`-RemoveWindowsHello` only when the user's Hello container should be removed,
and `-Restart` to restart after the repair. The script never runs
`dsregcmd /leave` or removes Intune enrollment. Logs, reports, and backups are
stored under `%ProgramData%\MicrosoftIdentityRepair`.

## Outlook settings transfer

`Windows\OutlookSettings.ps1` exports classic Outlook profile settings and
related user data to a ZIP archive, or imports a previously created archive.
Classic Outlook must be closed first.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Windows\OutlookSettings.ps1 Export C:\Temp\OutlookSettings.zip
powershell.exe -ExecutionPolicy Bypass -File .\Windows\OutlookSettings.ps1 Import C:\Temp\OutlookSettings.zip
```

## Application removal toolkit

Run `Windows\Remove-ApplicationToolkit.ps1` to search registered applications
by product name or publisher, invoke their normal uninstallers, and identify
orphaned uninstall registrations. Orphan cleanup is refused unless the entry
is revalidated and its registry data is backed up under
`%ProgramData%\Necktie\ApplicationRemovalBackups`.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Windows\Remove-ApplicationToolkit.ps1 -Search WordPerfect
powershell.exe -ExecutionPolicy Bypass -File .\Windows\Remove-ApplicationToolkit.ps1 -Search WordPerfect -List
```


