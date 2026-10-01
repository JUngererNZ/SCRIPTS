<#
.SYNOPSIS
    Inventories attached monitors and docking stations.
#>

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "      CONNECTED MONITORS & DOCKS          " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Helper function to convert arrays of US-ASCII bytes to text
function ConvertFrom-AsciiBytes {
    param([byte[]]$Bytes)
    if ($Bytes) {
        ([System.Text.Encoding]::ASCII.GetString($Bytes) -replace '\0', '').Trim()
    } else {
        "N/A"
    }
}

# --- 1. MONITORS ---
Write-Host "`n[+] MONITORS" -ForegroundColor Yellow

$monitors = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue

if ($monitors) {
    foreach ($mon in $monitors) {
        $manufacturer = ConvertFrom-AsciiBytes -Bytes $mon.ManufacturerName
        $model        = ConvertFrom-AsciiBytes -Bytes $mon.UserFriendlyName
        $serial       = ConvertFrom-AsciiBytes -Bytes $mon.SerialNumberID

        $type = if ($model -match "Internal|Built-in|Integrated") {
            "Integrated/Laptop Display"
        } else {
            "External Monitor"
        }

        [PSCustomObject]@{
            "Vendor"        = $manufacturer
            "Model"         = $model
            "Type"          = $type
            "Serial Number" = $serial
        } | Format-List
    }
} else {
    Write-Host "No monitors detected or WMI access restricted." -ForegroundColor Red
}

# --- 2. DOCKING STATIONS ---
Write-Host "`n[+] DOCKING STATIONS" -ForegroundColor Yellow

$docks = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FriendlyName -like "*Dock*" -or
        $_.FriendlyName -like "*Thunderbolt*" -or
        $_.Manufacturer -match "DisplayLink|CalDigit|Plugable"
    } |
    Select-Object -Unique -Property FriendlyName, Manufacturer, InstanceId

if ($docks) {
    foreach ($dock in $docks) {
        $serial = if ($dock.InstanceId -match '\\([A-Za-z0-9_-]+)$') {
            $matches[1]
        } else {
            "N/A"
        }

        $dockType = if ($dock.FriendlyName -match "Thunderbolt") {
            "Thunderbolt Dock"
        } elseif ($dock.FriendlyName -match "USB-C") {
            "USB-C Dock"
        } else {
            "USB / Universal Dock"
        }

        [PSCustomObject]@{
            "Vendor/Manufacturer" = $dock.Manufacturer
            "Model / Name"        = $dock.FriendlyName
            "Type"                = $dockType
            "Device ID / Serial"  = $serial
        } | Format-List
    }
} else {
    # Fallback to WMI System Enclosure / Docking Station check
    $wmiDock = Get-CimInstance -ClassName Win32_SystemEnclosure |
        Where-Object { $_.ChassisTypes -contains 12 }

    if ($wmiDock) {
        foreach ($d in $wmiDock) {
            [PSCustomObject]@{
                "Vendor"        = $d.Manufacturer
                "Model"         = "Generic WMI Docking Station"
                "Serial Number" = $d.SerialNumber
            } | Format-List
        }
    } else {
        Write-Host "No dedicated docking station recognized." -ForegroundColor Gray
    }
}