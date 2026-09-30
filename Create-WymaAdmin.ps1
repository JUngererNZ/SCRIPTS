<#
.SYNOPSIS
    Creates the local WymaAdmin account and adds it to the local
    Administrators group.

.DESCRIPTION
    This script securely prompts the technician to enter a password for the
    WymaAdmin local account. The password is not stored in the script and is
    not displayed while being entered.

    If the account already exists, the script does not reset its password.
    It checks whether the account is a member of the local Administrators
    group and adds it if required.

.NOTES
    Run this script from an elevated 64-bit PowerShell session.

    Account name:
        WymaAdmin
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$UserName   = 'WymaAdmin'
$FullName   = 'Wyma Local Administrator'
$Description = 'Local administrator account managed by IT'

try {
    # Check whether the local account already exists
    $ExistingUser = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue

    if (-not $ExistingUser) {
        Write-Host "Creating local user '$UserName'..." -ForegroundColor Cyan

        # Prompt securely for the password
        $SecurePassword = Read-Host `
            -Prompt "Enter the password for the local account '$UserName'" `
            -AsSecureString

        New-LocalUser `
            -Name $UserName `
            -Password $SecurePassword `
            -FullName $FullName `
            -Description $Description `
            -AccountNeverExpires `
            -UserMayNotChangePassword

        Write-Host "The local account '$UserName' was created successfully." `
            -ForegroundColor Green
    }
    else {
        Write-Host "The local account '$UserName' already exists." `
            -ForegroundColor Yellow

        if (-not $ExistingUser.Enabled) {
            Enable-LocalUser -Name $UserName

            Write-Host "The existing account '$UserName' was enabled." `
                -ForegroundColor Green
        }
    }

    # Use the well-known SID for the built-in Administrators group.
    # This also works if Windows uses a non-English group name.
    $AdministratorsGroup = Get-LocalGroup -SID 'S-1-5-32-544'

    # Explicitly reference the local account to avoid selecting a domain
    # account with the same username.
    $LocalAccount = "$env:COMPUTERNAME\$UserName"

    $AlreadyMember = Get-LocalGroupMember `
        -Group $AdministratorsGroup.Name `
        -ErrorAction Stop |
        Where-Object {
            $_.Name -ieq $LocalAccount
        }

    if (-not $AlreadyMember) {
        Add-LocalGroupMember `
            -Group $AdministratorsGroup.Name `
            -Member $LocalAccount

        Write-Host `
            "'$LocalAccount' was added to the local '$($AdministratorsGroup.Name)' group." `
            -ForegroundColor Green
    }
    else {
        Write-Host `
            "'$LocalAccount' is already a member of the local '$($AdministratorsGroup.Name)' group." `
            -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Local administrator configuration completed successfully." `
        -ForegroundColor Green
}
catch {
    Write-Error "Failed to configure the local administrator account: $($_.Exception.Message)"
    exit 1
}
finally {
    # Remove the password variable from the PowerShell session
    if (Get-Variable -Name SecurePassword -ErrorAction SilentlyContinue) {
        Remove-Variable -Name SecurePassword -Force
    }
}