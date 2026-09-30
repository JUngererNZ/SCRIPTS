<#
.SYNOPSIS
Updates AD user Description, Job Title and Manager.

.DESCRIPTION
Reads a list of users from a CSV file.

For each user:
1. Displays current values.
2. Prompts administrator for new Description.
3. Prompts administrator for new Job Title.
4. Prompts administrator for new Manager.
5. Displays proposed changes.
6. Requests confirmation.
7. Updates Active Directory.
8. Records changes to a CSV log file.

.NOTES
Author: Jason Ungerer
Requires:
- Active Directory PowerShell Module
- Appropriate permissions to modify AD users

CSV Format:
SamAccountName
j.smith
b.howard
#>

Import-Module ActiveDirectory

$CsvPath = Read-Host "Enter path to CSV file"

if (!(Test-Path $CsvPath)) {
    Write-Host "CSV file not found." -ForegroundColor Red
    exit
}

$Users = Import-Csv $CsvPath

$LogFile = ".\AD_Change_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

$Results = @()

foreach ($Entry in $Users) {

    $SamAccountName = $Entry.SamAccountName

    try {

        $User = Get-ADUser $SamAccountName `
            -Properties Description,Title,Manager

        if (!$User) {
            Write-Warning "User $SamAccountName not found."
            continue
        }

        $CurrentManager = ""

        if ($User.Manager) {
            $CurrentManager = (
                Get-ADUser $User.Manager -Properties DisplayName
            ).DisplayName
        }

        Write-Host ""
        Write-Host "==================================================" -ForegroundColor Cyan
        Write-Host "USER: $($User.SamAccountName)"
        Write-Host "==================================================" -ForegroundColor Cyan

        Write-Host ""
        Write-Host "CURRENT VALUES (AS IS)" -ForegroundColor Yellow
        Write-Host "Description : $($User.Description)"
        Write-Host "Job Title   : $($User.Title)"
        Write-Host "Manager     : $CurrentManager"
        Write-Host ""

        # Prompt for new values

        $NewDescription = Read-Host "New Description"
        $NewTitle = Read-Host "New Job Title"

        $NewManagerSam = Read-Host "New Manager SamAccountName"

        $ManagerUser = Get-ADUser $NewManagerSam -Properties DisplayName -ErrorAction Stop

        Write-Host ""
        Write-Host "PROPOSED CHANGES" -ForegroundColor Green
        Write-Host "--------------------------------------------------"
        Write-Host "Description"
        Write-Host "  OLD: $($User.Description)"
        Write-Host "  NEW: $NewDescription"
        Write-Host ""

        Write-Host "Job Title"
        Write-Host "  OLD: $($User.Title)"
        Write-Host "  NEW: $NewTitle"
        Write-Host ""

        Write-Host "Manager"
        Write-Host "  OLD: $CurrentManager"
        Write-Host "  NEW: $($ManagerUser.DisplayName)"
        Write-Host ""

        $Confirm = Read-Host "Apply changes? (Y/N)"

        if ($Confirm -eq 'Y') {

            Set-ADUser $User `
                -Description $NewDescription `
                -Title $NewTitle `
                -Manager $ManagerUser.DistinguishedName

            Write-Host "Changes applied." -ForegroundColor Green

            $Results += [PSCustomObject]@{
                DateTime           = Get-Date
                User               = $User.SamAccountName
                OldDescription     = $User.Description
                NewDescription     = $NewDescription
                OldTitle           = $User.Title
                NewTitle           = $NewTitle
                OldManager         = $CurrentManager
                NewManager         = $ManagerUser.DisplayName
                Status             = "Updated"
            }
        }
        else {

            Write-Host "Changes cancelled." -ForegroundColor Yellow

            $Results += [PSCustomObject]@{
                DateTime           = Get-Date
                User               = $User.SamAccountName
                OldDescription     = $User.Description
                NewDescription     = $NewDescription
                OldTitle           = $User.Title
                NewTitle           = $NewTitle
                OldManager         = $CurrentManager
                NewManager         = $ManagerUser.DisplayName
                Status             = "Cancelled"
            }
        }

    }
    catch {
        Write-Warning "Error processing $SamAccountName : $_"
    }
}

$Results | Export-Csv $LogFile -NoTypeInformation

Write-Host ""
Write-Host "Processing complete." -ForegroundColor Green
Write-Host "Log file created:"
Write-Host $LogFile