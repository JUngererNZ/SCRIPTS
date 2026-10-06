# Run this from your admin workstation.
# It connects to the old workstation name, prompts for the new name,
# renames the remote domain computer, then asks whether to restart it.

$OldName = Read-Host "Enter the current/old computer name (e.g., KETANL-ZB15G8)"
if ([string]::IsNullOrWhiteSpace($OldName)) {
    $OldName = "KETANL-ZB15G8"
}

$NewName = Read-Host "Enter the new computer name for $OldName (e.g., WYMACHCLT67)"
if ([string]::IsNullOrWhiteSpace($NewName)) {
    Write-Host "No new name provided. Exiting." -ForegroundColor Red
    exit 1
}

# Credentials with rights to rename the computer object in AD
$Cred = Get-Credential -Message "Enter domain credentials with permission to rename $OldName"

try {
    Write-Host "Renaming '$OldName' to '$NewName'..." -ForegroundColor Cyan
    Rename-Computer -ComputerName $OldName -NewName $NewName -DomainCredential $Cred -Force -ErrorAction Stop
    Write-Host "Rename command completed successfully." -ForegroundColor Green
    Write-Host "A restart is required before the new name takes effect." -ForegroundColor Yellow
}
catch {
    Write-Host "Failed to rename '$OldName': $_" -ForegroundColor Red
    exit 1
}

$restartNow = Read-Host "Restart '$OldName' now to apply the new name? (Y/N)"
if ($restartNow -match '^[Yy]') {
    try {
        Write-Host "Restarting '$OldName'..." -ForegroundColor Yellow
        Restart-Computer -ComputerName $OldName -Force -ErrorAction Stop
        Write-Host "Restart command sent successfully." -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to restart '$OldName': $_" -ForegroundColor Red
        Write-Host "Please restart the workstation manually later." -ForegroundColor Yellow
    }
}
else {
    Write-Host "Restart skipped. Please restart '$OldName' manually later for the name change to take effect." -ForegroundColor Yellow
}