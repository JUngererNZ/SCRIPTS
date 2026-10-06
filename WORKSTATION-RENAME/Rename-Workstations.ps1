<#
.SYNOPSIS
  Renames domain-joined workstations in scheduled batches from a JSON mapping.
.DESCRIPTION
  Runs unattended within the 02:00-03:00 window. Processes max 7 devices per run.
  Verifies AD existence and remote connectivity (DCOM) before renaming.
  Persists progress after each device. Re-runs pick up remaining devices.
.NOTES
  Requires: PowerShell 5.1+, RSAT AD module, DCOM/WMI firewall rules on targets.
  WinRM is NOT required.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [string]$JsonPath    = "C:\Projects\SCRIPTS\WORKSTATION-RENAME\workstations.json",
    [string]$EnvPath     = "C:\Projects\SCRIPTS\WORKSTATION-RENAME\.env",
    [string]$LogPath     = "C:\Projects\SCRIPTS\WORKSTATION-RENAME\rename-workstations.log",
    [int]$BatchSize      = 7,
    [int]$MaxAttempts    = 3
)

# ---------- Helpers ----------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts [$Level] $Message"
    Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

function Test-InWindow {
    $now = Get-Date
    return ($now.Hour -ge 2 -and $now.Hour -lt 3)
}

function Save-Json {
    # Always writes a JSON array, even when only one element remains.
    # ConvertTo-Json in PS 5.1 collapses single-element arrays, so we
    # serialize each element and join manually.
    param($Data)
    $arr   = @($Data)
    $parts = foreach ($item in $arr) { ConvertTo-Json -InputObject $item -Depth 5 }
    $json  = if ($parts.Count -eq 0) { "[]" }
             else { "[`r`n" + ($parts -join ",`r`n") + "`r`n]" }
    Set-Content -Path $JsonPath -Value $json -Encoding UTF8
}

function Read-EnvFile {
    # Minimal .env parser. Splits on first '='. Strips surrounding quotes.
    # Does NOT strip inline comments - values may legitimately contain '#'.
    param([string]$Path)
    $vars = @{}
    Get-Content -Path $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { return }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        if ($val.Length -ge 2 -and (
            ($val.StartsWith('"') -and $val.EndsWith('"')) -or
            ($val.StartsWith("'") -and $val.EndsWith("'")))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $vars[$key] = $val
    }
    return $vars
}

function Add-Failure {
    param([hashtable]$Summary, [string]$Code)
    if (-not $Summary.Failures.ContainsKey($Code)) { $Summary.Failures[$Code] = 0 }
    $Summary.Failures[$Code]++
}

# ---------- Main ----------
try {
    $logDir = Split-Path -Path $LogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    if (-not (Test-InWindow)) {
        Write-Log "Outside 02:00-03:00 window. Exiting."
        exit 0
    }

    # ---- Credentials ----
    if (-not (Test-Path $EnvPath)) { throw ".env not found: $EnvPath" }
    $envVars   = Read-EnvFile -Path $EnvPath
    $adminUser = $envVars["ADMIN_USER"]
    $adminPass = $envVars["ADMIN_PASSWORD"]
    if (-not $adminUser -or -not $adminPass) {
        throw "ADMIN_USER and ADMIN_PASSWORD required in .env"
    }
    $secPass = ConvertTo-SecureString $adminPass -AsPlainText -Force
    $cred    = New-Object System.Management.Automation.PSCredential($adminUser, $secPass)

    # ---- Mapping ----
    if (-not (Test-Path $JsonPath)) { throw "JSON not found: $JsonPath" }
    $json = @(Get-Content $JsonPath -Raw | ConvertFrom-Json)
    if ($json.Count -eq 0) { throw "JSON empty" }

    # Pending = not already renamed AND still under the retry ceiling.
    $pending = $json | Where-Object {
        $_.SuccessCode -ne "RENAMED" -and ([int]($_.Attempts) -lt $MaxAttempts)
    }
    $batch = @($pending | Select-Object -First $BatchSize)

    if ($batch.Count -eq 0) {
        Write-Log "Nothing to do. All entries renamed or at retry ceiling."
        exit 0
    }

    $summary = @{ Total = 0; Success = 0; Failures = @{} }

    foreach ($item in $batch) {
        if (-not (Test-InWindow)) {
            Write-Log "Window closed mid-run. Stopping before next device."
            break
        }

        $summary.Total++
        $oldName = $item.OldName
        $newName = $item.NewName

        if ($null -eq $item.PSObject.Properties['Attempts']) {
            $item | Add-Member -NotePropertyName Attempts -NotePropertyValue 0
        }
        $item.Attempts = [int]$item.Attempts + 1
        Write-Log "Processing $oldName -> $newName (attempt $($item.Attempts)/$MaxAttempts)"

        # 1. Verify old name exists in AD.
        try {
            Get-ADComputer -Identity $oldName -ErrorAction Stop | Out-Null
        } catch {
            $item.SuccessCode = "NOT_FOUND"
            $item.Message     = "Old computer not found in AD"
            Write-Log "AD not found: $oldName" -Level ERROR
            Add-Failure $summary "NOT_FOUND"
            Save-Json $json
            continue
        }

        # 2. Verify new name is free.
        try {
            $existing = Get-ADComputer -Filter "Name -eq '$newName'" -ErrorAction Stop
            if ($existing -and $existing.Name -ne $oldName) {
                $item.SuccessCode = "NAME_CONFLICT"
                $item.Message     = "New name $newName already exists in AD"
                Write-Log "Name conflict: $newName" -Level ERROR
                Add-Failure $summary "NAME_CONFLICT"
                Save-Json $json
                continue
            }
        } catch {
            # Filter errors are non-fatal; treat as "not found".
        }

        # 3. Connectivity check via CIM/DCOM (explicit timeout, up to 2 attempts).
        $cimSession = $null
        $connected  = $false
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            try {
                $opt = New-CimSessionOption -Protocol Dcom
                $cimSession = New-CimSession -ComputerName $oldName -Credential $cred `
                    -SessionOption $opt -OperationTimeoutSec 15 -ErrorAction Stop
                $connected = $true
                break
            } catch {
                Write-Log "Connect attempt $attempt to $oldName failed: $($_.Exception.Message)" -Level WARN
                if ($cimSession) { Remove-CimSession $cimSession -ErrorAction SilentlyContinue; $cimSession = $null }
                if ($attempt -lt 2) { Start-Sleep -Seconds 5 }
            }
        }
        if (-not $connected) {
            $item.SuccessCode = "UNREACHABLE"
            $item.Message     = "Failed to connect after retries"
            Write-Log "Unreachable: $oldName" -Level ERROR
            Add-Failure $summary "UNREACHABLE"
            Save-Json $json
            continue
        }

        # 4. Dry-run.
        if (-not $PSCmdlet.ShouldProcess($oldName, "Rename to $newName and restart")) {
            Write-Log "WhatIf: would rename $oldName to $newName and restart."
            if ($cimSession) { Remove-CimSession $cimSession -ErrorAction SilentlyContinue }
            continue
        }

        # 5. Rename. Rename-Computer is the correct mechanism for a domain-joined
        #    machine: it performs the local rename and the AD object rename as one
        #    operation, keeping the computer account intact. -Protocol DCOM is
        #    forced because this environment does not enable WinRM on targets.
        try {
            Write-Log "Renaming $oldName to $newName"
            Rename-Computer -ComputerName $oldName -NewName $newName `
                -DomainCredential $cred -Protocol DCOM -Force -ErrorAction Stop
            Write-Log "Rename command completed for $oldName"
        } catch {
            $item.SuccessCode = "RENAME_FAILED"
            $item.Message     = $_.Exception.Message
            Write-Log "Rename failed for $oldName: $($_.Exception.Message)" -Level ERROR
            Add-Failure $summary "RENAME_FAILED"
            if ($cimSession) { Remove-CimSession $cimSession -ErrorAction SilentlyContinue }
            Save-Json $json
            continue
        }

        # The pre-check CIM session was bound to the old name; drop it - it is
        # no longer a trustworthy handle on the renamed machine.
        if ($cimSession) { Remove-CimSession $cimSession -ErrorAction SilentlyContinue; $cimSession = $null }

        # 6. Grace period for the target to settle before reboot.
        Start-Sleep -Seconds 5

        # 7. Restart the (now renamed) host via a fresh DCOM connection to the
        #    new name. Retries tolerate DNS/Netlogon propagation delay.
        $restartOk = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Restart-Computer -ComputerName $newName -Protocol DCOM `
                    -Credential $cred -Force -ErrorAction Stop
                $restartOk = $true
                break
            } catch {
                Write-Log "Restart attempt $attempt for $newName failed: $($_.Exception.Message)" -Level WARN
                if ($attempt -lt 3) { Start-Sleep -Seconds 10 }
            }
        }
        if (-not $restartOk) {
            $item.SuccessCode = "RESTART_FAILED"
            $item.Message     = "Rename succeeded but restart failed"
            Write-Log "Restart failed for $newName after retries" -Level ERROR
            Add-Failure $summary "RESTART_FAILED"
            Save-Json $json
            continue
        }
        Write-Log "Restart initiated for $newName"

        # 8. Success.
        $item.SuccessCode = "RENAMED"
        $item.Message     = "Renamed and restarted"
        $summary.Success++
        Write-Log "Successfully renamed $oldName to $newName"
        Save-Json $json
    }

    # ---- End-of-run summary ----
    Write-Log "Run complete. Processed: $($summary.Total), Success: $($summary.Success)"
    foreach ($code in $summary.Failures.Keys) {
        Write-Log "Failure $code: $($summary.Failures[$code])"
    }
} catch {
    Write-Log "Fatal error: $($_.Exception.Message)" -Level ERROR
    exit 1
}