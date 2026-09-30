# PowerShell script to check domain group membership and folder share permissions

## Configuration
$username     = "hc\m.gray"
# Real FQDN of the DC. Set to "" to let the AD module auto-discover a domain controller.
$adServer     = "ad.hadencustance.com"
$folderShares = @(
    "\\mhm-chc-fp1\M-Files",
    "\\mhm-chc-fp1\M-Files\FP02"
)

## Functions

function Get-UserEffectiveIdentities {
    param(
        [Parameter(Mandatory)][string]$User,
        [string]$ADServer
    )

    try {
        # Get-ADUser -Identity expects sAMAccountName (not DOMAIN\user)
        $sam = $User -replace '^.*\\', ''

        $adParams = @{ Identity = $sam; ErrorAction = 'Stop' }
        if ($ADServer) { $adParams.Server = $ADServer }

        $userObj = Get-ADUser @adParams
        if (-not $userObj) { return $null }

        $identities = [System.Collections.Generic.List[string]]::new()

        $identities.Add($userObj.SamAccountName)
        $identities.Add($userObj.Name)
        if ($userObj.SID) { $identities.Add($userObj.SID.Value) }

        $groupParams = @{ Identity = $userObj.SamAccountName; ErrorAction = 'Stop' }
        if ($ADServer) { $groupParams.Server = $ADServer }

        $groups = Get-ADPrincipalGroupMembership @groupParams
        foreach ($group in $groups) {
            $identities.Add([string]$group.SamAccountName)
            $identities.Add([string]$group.Name)
            if ($group.SID) { $identities.Add([string]$group.SID.Value) }
        }

        # Cast to [string[]] so AddRange receives IEnumerable[string]
        # (a plain @( ... ) literal is System.Object[] and fails the generic check).
        $identities.AddRange([string[]]@(
            'Everyone',
            'Authenticated Users',
            'Domain Users',
            'BUILTIN\Users',
            'NT AUTHORITY\Authenticated Users'
        ))

        return ($identities | Select-Object -Unique)
    }
    catch {
        Write-Error "Failed to retrieve group membership for $User : $_"
        return $null
    }
}

function Get-FolderSharePermissions {
    param(
        [Parameter(Mandatory)][string]$FolderPath,
        [string[]]$UserIdentities
    )

    try {
        $acl         = Get-Acl -Path $FolderPath -ErrorAction Stop
        $permissions = [System.Collections.Generic.List[PSObject]]::new()
        $matches     = [System.Collections.Generic.List[string]]::new()

        foreach ($access in $acl.Access) {
            $rawIdentity   = $access.IdentityReference.Value
            $shortIdentity = $rawIdentity -replace '^[^\\]+\\'

            # Translate to SID when possible (NTAccount -> SID; SIDs pass through).
            $sidValue = $null
            try {
                if ($access.IdentityReference -is [System.Security.Principal.SecurityIdentifier]) {
                    $sidValue = $access.IdentityReference.Value
                }
                else {
                    $sidValue = $access.IdentityReference.Translate(
                        [System.Security.Principal.SecurityIdentifier]
                    ).Value
                }
            }
            catch { }

            $isMatch = $false
            if ($UserIdentities -contains $rawIdentity   -or
                $UserIdentities -contains $shortIdentity -or
                ($sidValue -and $UserIdentities -contains $sidValue)) {
                $isMatch = $true
                $matches.Add("$rawIdentity ($($access.FileSystemRights))")
            }

            $permissions.Add([PSCustomObject]@{
                Identity    = $rawIdentity
                SID         = $sidValue
                Rights      = $access.FileSystemRights
                AccessType  = $access.AccessControlType
                IsInherited = $access.IsInherited
                UserMatch   = $isMatch
            })
        }

        return [PSCustomObject]@{
            Permissions = $permissions
            Matches     = ($matches | Select-Object -Unique)
        }
    }
    catch {
        Write-Error "Failed to retrieve permissions for $FolderPath : $_"
        return $null
    }
}

## Execution

Write-Host "Retrieving effective identities for $username ..." -ForegroundColor Cyan
$userIdentities = Get-UserEffectiveIdentities -User $username -ADServer $adServer

if (-not $userIdentities) {
    Write-Host "Failed to load user identities. Aborting." -ForegroundColor Red
    return
}

Write-Host "`nEffective Identities & Groups for $username :" -ForegroundColor Green
$userIdentities | ForEach-Object { Write-Host "  - $_" }

Write-Host "`n--- Folder Share Access Evaluation ---" -ForegroundColor Cyan

foreach ($folder in $folderShares) {
    Write-Host "`nChecking: $folder" -ForegroundColor Cyan
    $result = Get-FolderSharePermissions -FolderPath $folder -UserIdentities $userIdentities

    if ($result) {
        $result.Permissions |
            Format-Table Identity, SID, Rights, AccessType, IsInherited, UserMatch -AutoSize

        if ($result.Matches.Count -gt 0) {
            Write-Host "RESULT: Access granted via -> $($result.Matches -join '; ')" -ForegroundColor Green
        }
        else {
            Write-Host "RESULT: No matching permissions found for this user/groups." -ForegroundColor Yellow
        }
    }
}