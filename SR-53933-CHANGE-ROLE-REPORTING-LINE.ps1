<#
.SYNOPSIS
    Updates Description, Job Title, and Manager for an Active Directory user.

.DESCRIPTION
    This script prompts an administrator to enter a new Description, Job Title,
    and the SamAccountName of a new Manager for a specified AD user.
    It displays the "as is" values, then the proposed changes, asks for
    confirmation, and finally applies the changes using Set-ADUser.

.NOTES
    Copy script to DC where the work is going to be done.
    Requires the ActiveDirectory PowerShell module.
    Run with an account that has permissions to modify user objects.
#>

# --- Import the Active Directory module ---
Import-Module ActiveDirectory -ErrorAction Stop

# --- Function to safely read a value from the user, allowing blank to keep current ---
function Get-NewValue {
    param(
        [string]$Prompt,
        [string]$CurrentValue
    )
    Write-Host ""
    Write-Host "Current value: " -NoNewline
    Write-Host $CurrentValue -ForegroundColor Yellow
    $newValue = Read-Host -Prompt $Prompt
    if ([string]::IsNullOrWhiteSpace($newValue)) {
        return $CurrentValue
    } else {
        return $newValue
    }
}

# --- Function to get the Manager's Distinguished Name from a SamAccountName ---
function Get-ManagerDN {
    param(
        [string]$ManagerSam
    )
    try {
        $manager = Get-ADUser -Identity $ManagerSam -Properties DistinguishedName -ErrorAction Stop
        return $manager.DistinguishedName
    } catch {
        Write-Warning "Manager '$ManagerSam' not found. The Manager attribute will not be changed."
        return $null
    }
}

# --- Main Script ---

# 1. Prompt for the target user
$targetSam = Read-Host -Prompt "Enter the SamAccountName of the user to modify"

# 2. Retrieve current values
try {
    $user = Get-ADUser -Identity $targetSam -Properties Description, Title, Manager -ErrorAction Stop
} catch {
    Write-Error "User '$targetSam' not found in Active Directory."
    return
}

$currentDescription = if ($user.Description) { $user.Description } else { "[not set]" }
$currentTitle       = if ($user.Title)       { $user.Title }       else { "[not set]" }

$currentManagerDN = $null
$currentManagerName = "[not set]"
if ($user.Manager) {
    $currentManagerDN = $user.Manager
    try {
        $currentManager = Get-ADUser -Identity $currentManagerDN -Properties DisplayName -ErrorAction Stop
        $currentManagerName = "$($currentManager.DisplayName) ($($currentManager.SamAccountName))"
    } catch {
        $currentManagerName = $currentManagerDN
    }
}

# 3. Display "as is currently" values
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " CURRENT VALUES FOR: $($user.Name) ($targetSam)" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "General Tab - Description : $currentDescription"
Write-Host "Organisation - Job Title  : $currentTitle"
Write-Host "Organisation - Manager    : $currentManagerName"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# 4. Prompt for new values (blank = keep current)
Write-Host "Enter new values. Press Enter to keep the current value." -ForegroundColor Green

$newDescription = Get-NewValue -Prompt "New Description" -CurrentValue $currentDescription
$newTitle       = Get-NewValue -Prompt "New Job Title"   -CurrentValue $currentTitle

# Manager is handled separately because it requires an AD lookup
$newManagerSam = Read-Host -Prompt "New Manager SamAccountName (press Enter to keep current)"
$newManagerDN  = $currentManagerDN
$newManagerName = $currentManagerName

if (-not [string]::IsNullOrWhiteSpace($newManagerSam)) {
    $resolvedDN = Get-ManagerDN -ManagerSam $newManagerSam
    if ($resolvedDN) {
        $newManagerDN = $resolvedDN
        try {
            $newManagerObj = Get-ADUser -Identity $newManagerDN -Properties DisplayName -ErrorAction Stop
            $newManagerName = "$($newManagerObj.DisplayName) ($($newManagerObj.SamAccountName))"
        } catch {
            $newManagerName = $newManagerDN
        }
    }
}

# 5. Show proposed changes
Write-Host ""
Write-Host "=============================================" -ForegroundColor Magenta
Write-Host " PROPOSED CHANGES FOR: $($user.Name) ($targetSam)" -ForegroundColor Magenta
Write-Host "=============================================" -ForegroundColor Magenta
Write-Host "Description : " -NoNewline
Write-Host "$currentDescription" -ForegroundColor Yellow -NoNewline
Write-Host "  ->  " -NoNewline
Write-Host $newDescription -ForegroundColor Green

Write-Host "Job Title   : " -NoNewline
Write-Host "$currentTitle" -ForegroundColor Yellow -NoNewline
Write-Host "  ->  " -NoNewline
Write-Host $newTitle -ForegroundColor Green

Write-Host "Manager     : " -NoNewline
Write-Host "$currentManagerName" -ForegroundColor Yellow -NoNewline
Write-Host "  ->  " -NoNewline
Write-Host $newManagerName -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Magenta
Write-Host ""

# 6. Confirm before applying
$confirm = Read-Host -Prompt "Do you want to apply these changes? (Y/N)"
if ($confirm -notmatch '^[Yy]') {
    Write-Host "Changes cancelled. No modifications were made." -ForegroundColor Red
    return
}

# 7. Apply changes to Active Directory
Write-Host ""
Write-Host "Applying changes..." -ForegroundColor Cyan

try {
    $setParams = @{
        Identity    = $targetSam
        Description = $newDescription
        Title       = $newTitle
    }

    # Only include Manager if a new DN was resolved or it was cleared
    if ($newManagerDN) {
        $setParams.Manager = $newManagerDN
    } elseif ($currentManagerDN -and -not $newManagerDN) {
        # If the user explicitly wanted to clear the manager (optional logic)
        $setParams.Manager = $null
    }

    Set-ADUser @setParams -ErrorAction Stop

    Write-Host ""
    Write-Host "SUCCESS: Changes applied to $($user.Name) ($targetSam)." -ForegroundColor Green
} catch {
    Write-Error "Failed to update user: $_"
}