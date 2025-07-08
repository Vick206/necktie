<#
.SYNOPSIS
    Display the 20 most recently accessed mailboxes and how long ago
    each one was last opened (Exchange on‑prem).

.NOTES
    Run inside the Exchange Management Shell (or after loading the
    Microsoft Exchange snap‑in).
    LastLogonTime can lag by up to ~2 hours and is stored per database
    copy, so treat this as “close enough” rather than gospel.
#>

param (
    [int]$Top = 20   # Change if you need more or fewer rows
)

$now = Get-Date

Get-Mailbox -ResultSize Unlimited |
    Get-MailboxStatistics |
    Where-Object { $_.LastLogonTime } |               # skip never‑used boxes
    Sort-Object   LastLogonTime -Descending |
    Select-Object -First $Top  `
        @{ Name = 'Mailbox'      ; Expression = { $_.DisplayName     } },
        @{ Name = 'LastLogonUTC' ; Expression = { $_.LastLogonTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') } },
        @{ Name = 'Ago'          ; Expression = {
                $ts = New-TimeSpan -Start $_.LastLogonTime -End $now
                '{0}d {1}h {2}m' -f $ts.Days, $ts.Hours, $ts.Minutes
        }} |
    Format-Table -AutoSize

