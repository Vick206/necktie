while ($true) {
    Get-MessageTrackingLog -Start (Get-Date).AddMinutes(-10) -ResultSize 50 |
        Sort-Object Timestamp |
        Select-Object Timestamp, Sender, Recipients, EventId, MessageSubject |
        Format-Table -AutoSize
    Start-Sleep -Seconds 10
    Clear-Host
}

