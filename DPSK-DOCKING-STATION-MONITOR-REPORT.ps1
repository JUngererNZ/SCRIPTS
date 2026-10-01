<#
.SYNOPSIS
    Reports monitors and docking stations attached to the local workstation.
.DESCRIPTION
    Monitors:  Vendor, model, serial, connection type, manufacture date.
    Docks:     Tries vendor-specific WMI namespaces (Surface, Dell, Lenovo, HP)
               and falls back to generic USB/PnP detection.

    Fix history:
      - 2024-xx: Handle VideoOutputTechnology values > Int32.MaxValue
                 (e.g. 0x80000000 = 2147483648 for internal/embedded panels)
                 by casting to UInt32 and using safe hashtable lookup.
#>

[CmdletBinding()]
param(
    [switch]$AsObject,          # Return raw objects instead of formatted tables
    [switch]$ExternalOnly       # Exclude internal/embedded panels (laptop screens)
)

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
function Convert-ByteArrayToStr {
    param([byte[]]$Bytes)
    if (-not $Bytes) { return $null }
    ($Bytes | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join ''
}

$script:OutputTechMap = @{
    0  = 'Other'; 1  = 'HD15'; 2  = 'SVIDEO'; 3  = 'Composite'
    4  = 'Component'; 5 = 'DVI'; 6 = 'HDMI'; 7 = 'LVDS'
    8  = 'D_JPN'; 9 = 'SDI'
    10 = 'DisplayPort External'
    11 = 'DisplayPort Embedded'
    12 = 'UDI External'
    13 = 'UDI Embedded'
    14 = 'SDTV Dongle'
    15 = 'Miracast'
    16 = 'Indirect Wired'
    17 = 'Internal'
}

# ------------------------------------------------------------------
# 1. MONITORS
# ------------------------------------------------------------------
function Get-MonitorInfo {
    [CmdletBinding()]
    param(
        [switch]$ExternalOnly
    )

    $results = @()

    try {
        $monitors = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop
    } catch {
        Write-Warning "Could not query WmiMonitorID (are you running as Administrator?). $_"
        return $results
    }

    # --- Connection technology lookup (safe for UInt32 values) -----
    $connections = @{}
    try {
        Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction SilentlyContinue |
            ForEach-Object {
                # Use UInt32 — some values (e.g. 0x80000000 = 2147483648) exceed Int32.MaxValue
                $connections[$_.InstanceName] = [uint32]$_.VideoOutputTechnology
            }
    } catch { }

    # --- Optional: filter out internal / embedded panels -----------
    $internalInstances = @()
    if ($ExternalOnly) {
        $internalInstances = $connections.GetEnumerator() |
            Where-Object { $_.Value -eq 0x80000000 -or $_.Value -in 7,11,13,17 } |
            ForEach-Object { $_.Key }
    }
    # ---------------------------------------------------------------

    foreach ($m in $monitors) {

        if ($ExternalOnly -and ($m.InstanceName -in $internalInstances)) {
            continue
        }

        # --- Safe lookup of the output technology ------------------
        if ($connections.ContainsKey($m.InstanceName)) {
            $tech = [uint32]$connections[$m.InstanceName]

            if ($tech -eq 0x80000000) {
                # 2147483648 — internal / embedded display (e.g. laptop panel)
                $connTech = 'Internal'
            }
            elseif ($script:OutputTechMap.ContainsKey([int]$tech)) {
                $connTech = $script:OutputTechMap[[int]$tech]
            }
            else {
                $connTech = ('Unknown (0x{0:X8})' -f $tech)
            }
        }
        else {
            $connTech = 'Unknown'
        }
        # -----------------------------------------------------------

        $results += [PSCustomObject]@{
            DeviceType        = 'Monitor'
            Vendor            = Convert-ByteArrayToStr $m.ManufacturerName
            Model             = Convert-ByteArrayToStr $m.UserFriendlyName
            ProductCode       = Convert-ByteArrayToStr $m.ProductCodeID
            SerialNumber      = Convert-ByteArrayToStr $m.SerialNumberID
            YearOfManufacture = $m.YearOfManufacture
            WeekOfManufacture = $m.WeekOfManufacture
            Connection        = $connTech
            Source            = 'WmiMonitorID'
        }
    }

    return $results
}

# ------------------------------------------------------------------
# 2. DOCKING STATIONS
# ------------------------------------------------------------------

# --- 2a. Surface docks -------------------------------------------------
function Get-SurfaceDock {
    try {
        Get-CimInstance -Namespace root\wmi -ClassName SurfaceDock_Info -ErrorAction Stop |
            ForEach-Object {
                [PSCustomObject]@{
                    DeviceType   = 'Docking Station'
                    Vendor       = 'Microsoft'
                    Model        = $_.DeviceName
                    SerialNumber = $_.DockSerialNumber
                    Firmware     = $_.FirmwareVersion
                    Source       = 'SurfaceDock_Info'
                }
            }
    } catch { return @() }
}

# --- 2b. Dell docks (Dell Command | Monitor required) ------------------
function Get-DellDock {
    try {
        Get-CimInstance -Namespace root\dcim\sysman -ClassName DCIM_Chassis -ErrorAction Stop |
            Where-Object { $_.CreationClassName -eq 'DCIM_DockingStation' } |
            ForEach-Object {
                [PSCustomObject]@{
                    DeviceType   = 'Docking Station'
                    Vendor       = 'Dell'
                    Model        = $_.Name
                    SerialNumber = $_.SerialNumber
                    ServiceTag   = $_.Tag
                    Firmware     = $_.Version
                    ModuleType   = $_.Model
                    Source       = 'DCIM_Chassis'
                }
            }
    } catch { return @() }
}

# --- 2c. Lenovo docks (Lenovo Dock Manager required) -------------------
function Get-LenovoDock {
    try {
        Get-CimInstance -Namespace root\Lenovo\Dock_Manager -ClassName DockDevice -ErrorAction Stop |
            ForEach-Object {
                [PSCustomObject]@{
                    DeviceType   = 'Docking Station'
                    Vendor       = 'Lenovo'
                    Model        = $_.MachineType
                    SerialNumber = $_.SerialNumber
                    MACAddress   = $_.MacAddress
                    Firmware     = $_.FWVersion
                    Source       = 'DockDevice'
                }
            }
    } catch { return @() }
}

# --- 2d. HP docks (HP client management / HP Dock accessory) -----------
function Get-HPDock {
    $results = @()
    $namespaces = @(
        'root\HP\InstrumentedServices\v1',
        'root\HP\InstrumentedServices'
    )
    foreach ($ns in $namespaces) {
        try {
            Get-CimInstance -Namespace $ns -ClassName HP_DockAccessory -ErrorAction Stop |
                ForEach-Object {
                    $results += [PSCustomObject]@{
                        DeviceType   = 'Docking Station'
                        Vendor       = 'HP'
                        Model        = $_.Name
                        SerialNumber = $_.SerialNumber
                        Firmware     = $_.FirmwareVersion
                        Source       = "HP_DockAccessory ($ns)"
                    }
                }
            if ($results.Count -gt 0) { break }
        } catch { }
    }
    return $results
}

# --- 2e. Generic fallback: USB / PnP docking-station-like devices ------
function Get-GenericDock {
    $dockPatterns = @(
        'Dock', 'Docking', 'ThinkPad USB', 'DisplayLink',
        'WD15', 'WD19', 'WD22', 'WD25', 'SD25',
        'TB16', 'TB19', 'Thunderbolt Dock',
        'HP Thunderbolt', 'HP USB-C', 'HP Dock',
        'Surface Dock', 'Lenovo Dock', 'Dell Dock'
    )

    $pattern = ($dockPatterns | ForEach-Object { [regex]::Escape($_) }) -join '|'

    try {
        Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
            Where-Object {
                $_.Name -match $pattern -or $_.Description -match $pattern
            } |
            ForEach-Object {
                $serial = $null
                if ($_.PNPDeviceID -match '\\\\([^\\]+)$') { $serial = $matches[1] }

                [PSCustomObject]@{
                    DeviceType   = 'Docking Station (generic)'
                    Vendor       = $_.Manufacturer
                    Model        = $_.Name
                    SerialNumber = $serial
                    DeviceID     = $_.PNPDeviceID
                    Status       = $_.Status
                    Source       = 'Win32_PnPEntity'
                }
            }
    } catch { return @() }
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
$monitors = Get-MonitorInfo -ExternalOnly:$ExternalOnly

$docks = @()
$docks += Get-SurfaceDock
$docks += Get-DellDock
$docks += Get-LenovoDock
$docks += Get-HPDock

# If no vendor-specific dock was found, try the generic fallback
if (($docks | Measure-Object).Count -eq 0) {
    $docks += Get-GenericDock
}

$all = @($monitors) + @($docks)

if ($AsObject) {
    $all
}
else {
    Write-Host "`n================ MONITORS ================" -ForegroundColor Cyan
    if (($monitors | Measure-Object).Count -eq 0) {
        Write-Host "No monitors detected." -ForegroundColor Yellow
    } else {
        $monitors |
            Format-Table Vendor, Model, SerialNumber, Connection, YearOfManufacture, WeekOfManufacture -AutoSize
    }

    Write-Host "`n============ DOCKING STATIONS ============" -ForegroundColor Cyan
    if (($docks | Measure-Object).Count -eq 0) {
        Write-Host "No docking station detected." -ForegroundColor Yellow
    } else {
        $docks | Format-Table Vendor, Model, SerialNumber, Firmware, Source -AutoSize
    }
}