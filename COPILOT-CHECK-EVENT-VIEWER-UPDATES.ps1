<#
.SYNOPSIS
    Enables Windows Update operational logging on Windows 11 and validates configuration.

    Manual Verification:
    1. Open Event Viewer (eventvwr.msc)
    2. Navigate to:
       Applications and Services Logs
        └ Microsoft
           └ Windows
              └ WindowsUpdateClient
                 └ Operational

    3. Confirm the log is enabled and events are being generated.

    4. To force a scan:
       Settings > Windows Update > Check for updates

       or run:
       UsoClient StartScan

    5. Search Event Viewer for the following useful Event IDs:

       19 = Update installation successful
       20 = Update installation failed
       21 = Restart required
       31 = Download started
       41 = Scan started
       43 = Update detected / available
       44 = Installation started

    Example Event Viewer Filter:
       <All Event IDs>
       19,20,21,31,41,43,44

.DESCRIPTION
    This script performs the following actions:

    • Verifies the script is running with Administrator privileges.
    • Verifies required services exist and are running:
        - EventLog
        - wuauserv
        - UsoSvc

    • Enables the Windows Update Operational Event Log:
        HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels\
        Microsoft-Windows-WindowsUpdateClient/Operational

        Enabled = 1 (DWORD)

    • Verifies Windows Update service startup configuration:
        HKLM\SYSTEM\CurrentControlSet\Services\wuauserv

        Start = 3 (DWORD)

    • Validates all registry settings after configuration.

    • Displays the most recent Windows Update events collected from:
        Microsoft-Windows-WindowsUpdateClient/Operational

    Event Viewer Path:
        Applications and Services Logs
         └ Microsoft
            └ Windows
               └ WindowsUpdateClient
                  └ Operational

    Useful Event IDs:

        19  = Installation successful
        20  = Installation failed
        21  = Restart required
        31  = Download started
        41  = Scan started
        43  = Update available / detected
        44  = Installation started

    Driver Updates:
        Driver update events are logged in the same
        WindowsUpdateClient/Operational log. Search for:

            Driver
            Driver update
            Successfully installed update

    PowerShell Verification:

        Get-WinEvent `
            -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" `
            -MaxEvents 50

    Event ID Search Example:

        Get-WinEvent `
            -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" |
            Where-Object {$_.Id -in 19,20,21,31,41,43,44}

.NOTES
    Windows 11 only.

    No reboot is normally required.

    Registry Settings Applied:

        HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels\
        Microsoft-Windows-WindowsUpdateClient/Operational

            Enabled (REG_DWORD) = 1

        HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv

            Start (REG_DWORD) = 3
#>

#region Admin Check

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
    Write-Error "Administrator privileges are required."
    exit 1
}

#endregion

Write-Host "Running Windows Update logging configuration..." -ForegroundColor Cyan

try
{
    # Registry Paths
    $UpdateLogPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels\Microsoft-Windows-WindowsUpdateClient/Operational"
    $WuauservPath = "HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv"

    #-------------------------------------------------------
    # Ensure Event Log Channel Exists
    #-------------------------------------------------------

    if (-not (Test-Path $UpdateLogPath))
    {
        throw "Windows Update Event Log channel registry path not found."
    }

    Set-ItemProperty `
        -Path $UpdateLogPath `
        -Name Enabled `
        -Type DWord `
        -Value 1 `
        -ErrorAction Stop

    Write-Host "WindowsUpdateClient Operational log enabled." -ForegroundColor Green

    #-------------------------------------------------------
    # Configure Windows Update Service Startup
    #-------------------------------------------------------

    if (-not (Test-Path $WuauservPath))
    {
        throw "Windows Update service registry path not found."
    }

    Set-ItemProperty `
        -Path $WuauservPath `
        -Name Start `
        -Type DWord `
        -Value 3 `
        -ErrorAction Stop

    Write-Host "Windows Update service startup configuration verified." -ForegroundColor Green

    #-------------------------------------------------------
    # Required Services
    #-------------------------------------------------------

    $RequiredServices = @(
        "EventLog",
        "wuauserv",
        "UsoSvc"
    )

    foreach ($ServiceName in $RequiredServices)
    {
        try
        {
            $Service = Get-Service -Name $ServiceName -ErrorAction Stop

            Write-Host ("{0} : {1}" -f $ServiceName, $Service.Status)

            if ($Service.Status -ne "Running")
            {
                try
                {
                    Start-Service -Name $ServiceName -ErrorAction Stop
                    Write-Host "$ServiceName started successfully." -ForegroundColor Green
                }
                catch
                {
                    Write-Warning "Unable to start service $ServiceName : $($_.Exception.Message)"
                }
            }
        }
        catch
        {
            Write-Warning "Service not found: $ServiceName"
        }
    }

    #-------------------------------------------------------
    # Validation
    #-------------------------------------------------------

    $EnabledValue = Get-ItemPropertyValue `
        -Path $UpdateLogPath `
        -Name Enabled `
        -ErrorAction Stop

    $StartValue = Get-ItemPropertyValue `
        -Path $WuauservPath `
        -Name Start `
        -ErrorAction Stop

    Write-Host ""
    Write-Host "Validation Results" -ForegroundColor Cyan
    Write-Host "------------------"

    Write-Host "WindowsUpdateClient Operational Enabled = $EnabledValue"
    Write-Host "wuauserv Start Value = $StartValue"

    if (($EnabledValue -eq 1) -and ($StartValue -eq 3))
    {
        Write-Host ""
        Write-Host "Configuration completed successfully." -ForegroundColor Green
    }
    else
    {
        Write-Warning "One or more settings failed validation."
    }

}
catch
{
    Write-Error "Configuration failed: $($_.Exception.Message)"
    exit 1
}

# Display most recent update events

Write-Host ""
Write-Host "Recent Windows Update Events" -ForegroundColor Cyan
Write-Host "----------------------------"

try
{
    Get-WinEvent `
        -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" `
        -MaxEvents 10 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Format-Table -AutoSize
}
catch
{
    Write-Warning "Unable to read Windows Update event log."
}