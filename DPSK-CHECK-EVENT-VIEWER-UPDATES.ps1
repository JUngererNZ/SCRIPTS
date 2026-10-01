<#
.SYNOPSIS
    Enables automated logging of Windows Update availability and driver updates
    on Windows 11 via native Registry and Event Viewer mechanisms.
    Includes manual verification steps and a list of useful event IDs for searching.

.DESCRIPTION
    This script performs the following actions:
      - Verifies administrator privileges and required services.
      - Ensures the Windows Event Log service is set to Automatic.
      - Enables the WindowsUpdateClient/Operational event log.
      - Optionally enables Windows Update trace logging for verbose diagnostics.
      - Includes error handling for registry access and permission failures.
      - At the end, searches for key Windows Update event IDs to confirm logging is active.

    MANUAL VERIFICATION:
      To verify manually:
        1. Press Win+R, type eventvwr.msc, press Enter.
        2. Navigate to:
           Applications and Services Logs -> Microsoft -> Windows -> WindowsUpdateClient -> Operational
        3. Look for recent events with timestamps close to your update check.
        4. If the log is empty, right-click the "Operational" node and select "Enable Log".
        5. You can also filter by specific Event IDs (see list below).

    USEFUL EVENT IDs TO SEARCH:
        19  - Installation successful
        20  - Installation failed
        21  - Restart required
        22  - Driver installed via Windows Update
        31  - Download started
        34  - Download completed

    You can search these IDs in Event Viewer using the "Filter Current Log" action,
    or by using the Get-WinEvent PowerShell cmdlet as demonstrated at the end of this script.

.NOTES
    Run in an elevated PowerShell session (Run as Administrator).
    Windows 11 only.
#>

# ──────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ──────────────────────────────────────────────

# 1. Verify Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $currentPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    Write-Error "This script must be run as Administrator. Aborting."
    exit 1
}
Write-Host "[OK] Administrator privileges confirmed." -ForegroundColor Green

# 2. Verify Windows 11 (build 22000+)
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$build = [int]($os.BuildNumber)
if ($build -lt 22000) {
    Write-Error "This script targets Windows 11 (build 22000+). Detected build: $build. Aborting."
    exit 1
}
Write-Host "[OK] Windows 11 detected (build $build)." -ForegroundColor Green

# 3. Verify Windows Event Log service exists and is not disabled
$eventLogService = Get-Service -Name "eventlog" -ErrorAction SilentlyContinue
if (-not $eventLogService) {
    Write-Error "Windows Event Log service ('eventlog') not found. Aborting."
    exit 1
}
Write-Host "[OK] Windows Event Log service found. Current status: $($eventLogService.Status)" -ForegroundColor Green

# 4. Verify Windows Update service exists (dependency for update logging)
$wuService = Get-Service -Name "wuauserv" -ErrorAction SilentlyContinue
if (-not $wuService) {
    Write-Error "Windows Update service ('wuauserv') not found. Aborting."
    exit 1
}
Write-Host "[OK] Windows Update service found. Current status: $($wuService.Status)" -ForegroundColor Green


# ──────────────────────────────────────────────
# HELPER FUNCTION: Set a registry DWORD with error handling
# ──────────────────────────────────────────────
function Set-RegistryDword {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$Value
    )

    try {
        # Create the key path if it does not exist
        if (-not (Test-Path -Path $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
            Write-Host "  [CREATED] Registry path: $Path" -ForegroundColor Yellow
        }

        # Set the DWORD value
        New-ItemProperty -Path $Path -Name $Name -Value $Value `
            -PropertyType DWORD -Force -ErrorAction Stop | Out-Null

        Write-Host "  [SET] $Path\$Name = $Value" -ForegroundColor Green
    }
    catch [System.UnauthorizedAccessException] {
        Write-Error "Access denied to registry path '$Path'. Ensure you are running as Administrator and the key is not locked by policy."
        throw
    }
    catch [System.Security.SecurityException] {
        Write-Error "Security exception writing to '$Path'. The key may be protected by ACLs or Group Policy."
        throw
    }
    catch {
        Write-Error "Failed to set registry value '$Name' at '$Path'. Error: $_"
        throw
    }
}


# ──────────────────────────────────────────────
# STEP 1: Ensure Windows Event Log service Start = 2 (Automatic)
# ──────────────────────────────────────────────
Write-Host "`n[STEP 1] Configuring Windows Event Log service..." -ForegroundColor Cyan

$eventLogRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog"
Set-RegistryDword -Path $eventLogRegPath -Name "Start" -Value 2

# Also ensure the service is running now (without requiring a reboot)
if ($eventLogService.Status -ne "Running") {
    try {
        Start-Service -Name "eventlog" -ErrorAction Stop
        Write-Host "  [STARTED] Windows Event Log service started successfully." -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not start Windows Event Log service immediately. A reboot may be required. Error: $_"
    }
}


# ──────────────────────────────────────────────
# STEP 2: Enable WindowsUpdateClient/Operational log
# ──────────────────────────────────────────────
Write-Host "`n[STEP 2] Enabling WindowsUpdateClient Operational log..." -ForegroundColor Cyan

$wuClientLogPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels\Microsoft-Windows-WindowsUpdateClient/Operational"
Set-RegistryDword -Path $wuClientLogPath -Name "Enabled" -Value 1


# ──────────────────────────────────────────────
# STEP 3: (Optional) Enable Windows Update Trace Logging
# ──────────────────────────────────────────────
Write-Host "`n[STEP 3] Enabling Windows Update trace logging (verbose diagnostics)..." -ForegroundColor Cyan

$tracePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Trace"
Set-RegistryDword -Path $tracePath -Name "Flags" -Value 7
Set-RegistryDword -Path $tracePath -Name "Level" -Value 4


# ──────────────────────────────────────────────
# STEP 4: Restart Windows Update service to apply trace settings
# ──────────────────────────────────────────────
Write-Host "`n[STEP 4] Restarting Windows Update service to apply trace settings..." -ForegroundColor Cyan

try {
    Restart-Service -Name "wuauserv" -Force -ErrorAction Stop
    Write-Host "  [RESTARTED] Windows Update service restarted successfully." -ForegroundColor Green
}
catch {
    Write-Warning "Could not restart Windows Update service. A reboot may be required. Error: $_"
}


# ──────────────────────────────────────────────
# VERIFICATION: Registry values
# ──────────────────────────────────────────────
Write-Host "`n[VERIFICATION] Confirming registry values..." -ForegroundColor Cyan

$checks = @(
    @{ Path = $eventLogRegPath;   Name = "Start";   Expected = 2; Label = "EventLog Start" },
    @{ Path = $wuClientLogPath;   Name = "Enabled"; Expected = 1; Label = "WUClient/Operational Enabled" },
    @{ Path = $tracePath;         Name = "Flags";   Expected = 7; Label = "WU Trace Flags" },
    @{ Path = $tracePath;         Name = "Level";   Expected = 4; Label = "WU Trace Level" }
)

$allPassed = $true
foreach ($check in $checks) {
    try {
        $actual = (Get-ItemProperty -Path $check.Path -Name $check.Name -ErrorAction Stop).$($check.Name)
        if ($actual -eq $check.Expected) {
            Write-Host "  [PASS] $($check.Label): $actual" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] $($check.Label): expected $($check.Expected), got $actual" -ForegroundColor Red
            $allPassed = $false
        }
    }
    catch {
        Write-Host "  [FAIL] $($check.Label): could not read value. $_" -ForegroundColor Red
        $allPassed = $false
    }
}

if ($allPassed) {
    Write-Host "`nAll registry settings applied successfully." -ForegroundColor Green
} else {
    Write-Warning "`nSome registry settings could not be verified. Review the output above."
}

# Check event log is enabled
try {
    $logInfo = Get-WinEvent -ListLog "Microsoft-Windows-WindowsUpdateClient/Operational" -ErrorAction Stop
    if ($logInfo.IsEnabled) {
        Write-Host "[PASS] WindowsUpdateClient/Operational log is enabled." -ForegroundColor Green
    } else {
        Write-Warning "[WARN] WindowsUpdateClient/Operational log is not yet enabled. A reboot may be required."
    }
}
catch {
    Write-Warning "Could not query event log status: $_"
}


# ──────────────────────────────────────────────
# VERIFICATION: Search for useful Event IDs (last 7 days)
# ──────────────────────────────────────────────
Write-Host "`n[VERIFICATION] Searching for recent Windows Update events (last 7 days)..." -ForegroundColor Cyan

$usefulEventIds = @(19, 20, 21, 22, 31, 34)
$startTime = (Get-Date).AddDays(-7)

foreach ($id in $usefulEventIds) {
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-WindowsUpdateClient/Operational'
            Id        = $id
            StartTime = $startTime
        } -ErrorAction Stop

        if ($events) {
            Write-Host "  Event ID $id : $($events.Count) event(s) found" -ForegroundColor Green
            # Optionally show the most recent one
            $latest = $events | Select-Object -First 1
            Write-Host "    Latest: $($latest.TimeCreated) - $($latest.Message.Split("`n")[0])" -ForegroundColor Gray
        } else {
            Write-Host "  Event ID $id : no events found in the last 7 days" -ForegroundColor Yellow
        }
    }
    catch {
        # If no events match, Get-WinEvent throws an exception for "No events were found"
        if ($_.Exception.Message -like "*No events were found*") {
            Write-Host "  Event ID $id : no events found in the last 7 days" -ForegroundColor Yellow
        } else {
            Write-Host "  Event ID $id : error querying events - $_" -ForegroundColor Red
        }
    }
}

Write-Host "`nScript complete. A system reboot is recommended to guarantee all settings are active." -ForegroundColor Yellow
Write-Host "To verify logging, trigger a Windows Update check and then inspect Event Viewer or re-run the search above." -ForegroundColor Yellow