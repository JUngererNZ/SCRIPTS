<#
    Hardware_Report.ps1
    -----------------------------------------------------------------
    Produces a "SYSTEM HARDWARE & LICENSE REPORT" in the same layout
    as Hardware_Report_<COMPUTERNAME>.txt, including installed software
    and installation dates.

    Usage:
        .\Hardware_Report.ps1
        .\Hardware_Report.ps1 -OutputPath "C:\Reports\hardware.txt"
#>

[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'SilentlyContinue'
$WIDTH = 67

# ---------------------------------------------------------------------
#  Output buffer + formatting helpers
# ---------------------------------------------------------------------
$Lines = [System.Collections.Generic.List[string]]::new()

function Add-Line { param([string]$Text = '') $Lines.Add($Text) }

function Add-Rule { param([string]$Char = '=') $Lines.Add($Char * $WIDTH) }

function Add-Centered {
    param([string]$Text)
    $pad  = [Math]::Max(0, $WIDTH - $Text.Length)
    $left = [int][Math]::Floor($pad / 2)
    $Lines.Add((' ' * $left) + $Text + (' ' * ($pad - $left)))
}

function Add-Section {
    param([string]$Title)
    Add-Line
    Add-Line "[ $Title ]"
}

function Add-Field {
    param([string]$Label, $Value)
    $Lines.Add(('{0,-17}: {1}' -f $Label, $Value))
}

# ---------------------------------------------------------------------
#  Helper: gather installed software with installation dates
# ---------------------------------------------------------------------
function Get-InstalledSoftware {
    $paths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $raw = foreach ($path in $paths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.InstallDate } |
            Select-Object @{n='Name';e={$_.DisplayName}},
                          @{n='InstallDate';e={$_.InstallDate}}
    }

    $result = foreach ($item in $raw) {
        $dateStr = $item.InstallDate
        $date = $null

        if ($dateStr -match '^\d{8}$') {
            $date = [datetime]::ParseExact($dateStr, 'yyyyMMdd', $null)
        } else {
            try { $date = [datetime]::Parse($dateStr) } catch { }
        }

        if ($date) {
            [PSCustomObject]@{
                Name        = $item.Name
                InstallDate = $date.ToString('yyyy-MM-dd')
            }
        }
    }

    $result | Sort-Object Name -Unique
}

# ---------------------------------------------------------------------
#  Collect hardware / OS data
# ---------------------------------------------------------------------
$cs    = Get-CimInstance Win32_ComputerSystem
$bios  = Get-CimInstance Win32_BIOS
$board = Get-CimInstance Win32_BaseBoard
$cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
$os    = Get-CimInstance Win32_OperatingSystem

$ram   = @(Get-CimInstance Win32_PhysicalMemory | Sort-Object DeviceLocator)

# Dedicated GPU first, integrated (Intel) last
$gpus  = @(Get-CimInstance Win32_VideoController |
           Sort-Object { if ($_.Name -match 'Intel') { 1 } else { 0 } })

$disks = @(Get-CimInstance Win32_DiskDrive | Sort-Object Index)

# Embedded OEM key lives in the ACPI MSDM table
$oemKey = (Get-CimInstance -ClassName SoftwareLicensingService -Namespace 'root\cimv2').OA3xOriginalProductKey
if ([string]::IsNullOrWhiteSpace($oemKey)) {
    $oemKey = 'Not available (no embedded OEM key found)'
}

# Installed software
$installedSoftware = @(Get-InstalledSoftware)

# ---------------------------------------------------------------------
#  Build the report
# ---------------------------------------------------------------------
Add-Rule
Add-Centered 'SYSTEM HARDWARE & LICENSE REPORT'
Add-Rule

# --- System identification -------------------------------------------
Add-Section 'SYSTEM IDENTIFICATION'
Add-Field 'Computer Name' $env:COMPUTERNAME
Add-Field 'Manufacturer'  $cs.Manufacturer
Add-Field 'Model'         $cs.Model
Add-Field 'Serial Number' $bios.SerialNumber
Add-Field 'Motherboard'   ("$($board.Manufacturer) $($board.Product)").Trim()

# --- CPU --------------------------------------------------------------
Add-Section 'PROCESSOR (CPU)'
Add-Field 'Name'            $cpu.Name
Add-Field 'Cores / Threads' ('{0} Cores / {1} Threads' -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
Add-Field 'Max Clock Speed' ('{0} MHz' -f $cpu.MaxClockSpeed)

# --- RAM --------------------------------------------------------------
Add-Section 'MEMORY (RAM)'
$ramTotalGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
Add-Field 'Total Installed'  ('{0} GB' -f $ramTotalGB)
Add-Field 'Sticks Installed' ('{0} Slot(s) Used' -f $ram.Count)
foreach ($stick in $ram) {
    $capGB = [Math]::Round($stick.Capacity / 1GB, 0)
    Add-Line ('  - Slot: {0} | Speed: {1} MHz | Capacity: {2} GB' -f
              $stick.DeviceLocator, $stick.Speed, $capGB)
}

# --- GPU --------------------------------------------------------------
Add-Section 'GRAPHICS (GPU)'
foreach ($g in $gpus) {
    Add-Line ('  - {0} (Driver Version: {1})' -f $g.Name, $g.DriverVersion)
}

# --- Storage ----------------------------------------------------------
Add-Section 'STORAGE'
foreach ($d in $disks) {
    $sizeGB = [Math]::Round($d.Size / 1GB, 2)
    Add-Line ('  - Drive: {0} | Size: {1} GB | Interface: {2}' -f
              $d.Model, $sizeGB, $d.Interface)
}

# --- Installed software ----------------------------------------------
Add-Section 'INSTALLED SOFTWARE'
if ($installedSoftware.Count -gt 0) {
    foreach ($app in $installedSoftware) {
        Add-Line ('  - {0} (Installed: {1})' -f $app.Name, $app.InstallDate)
    }
} else {
    Add-Line '  (No installed software with installation dates found)'
}

# --- OS & license -----------------------------------------------------
Add-Section 'OPERATING SYSTEM & EMBEDDED KEY'
Add-Field 'OS Name'          ('{0} ({1})' -f $os.Caption, $os.OSArchitecture)
Add-Field 'OS Version'       ('{0} (Build {1})' -f $os.Version, $os.BuildNumber)
Add-Field 'Embedded OEM Key' $oemKey

Add-Line
Add-Rule

# ---------------------------------------------------------------------
#  Emit
# ---------------------------------------------------------------------
$report = $Lines -join [Environment]::NewLine

if ($OutputPath) {
    $report | Set-Content -Path $OutputPath -Encoding UTF8
}

Write-Output $report