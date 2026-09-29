# ============================================================
# ToggleSwingScreen.ps1
#
# Swing monitor:
#   Dell S2421HS
#   Serial: GHHYS83
#
# Remaining Windows monitor:
#   Dell S2421HS
#   Serial: HTHYS83
#
# Toggle behavior:
#
#   Dual-monitor Windows mode:
#       -> switch swing monitor to HDMI
#       -> detach swing monitor from Windows
#       -> remaining monitor becomes primary
#
#   Single-monitor Windows mode:
#       -> restore saved Windows dual-monitor layout
#       -> rediscover swing monitor by EDID serial
#       -> switch swing monitor to DisplayPort
#
# No DISPLAY1/DISPLAY2/DISPLAY3 values are hard-coded.
# ============================================================


# ============================================================
# Configuration
# ============================================================

$SwingSerial     = 'GHHYS83'
$RemainingSerial = 'HTHYS83'

# Dell S2421HS MCCS VCP 0x60 input values
[uint32]$DP   = 0x0F
[uint32]$HDMI = 0x11


# ============================================================
# Windows APIs
# ============================================================

if (-not ('ToggleSwingMonitorApi' -as [type])) {

    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;


public class DisplayDeviceMapping
{
    public string DeviceName { get; set; }
    public string MonitorName { get; set; }
    public string MonitorDeviceId { get; set; }
    public bool AttachedToDesktop { get; set; }
    public bool Primary { get; set; }
}


public static class ToggleSwingMonitorApi
{
    // ========================================================
    // EnumDisplayDevices
    // ========================================================

    [StructLayout(
        LayoutKind.Sequential,
        CharSet = CharSet.Unicode
    )]
    private struct DISPLAY_DEVICE
    {
        public int cb;

        [MarshalAs(
            UnmanagedType.ByValTStr,
            SizeConst = 32
        )]
        public string DeviceName;

        [MarshalAs(
            UnmanagedType.ByValTStr,
            SizeConst = 128
        )]
        public string DeviceString;

        public uint StateFlags;

        [MarshalAs(
            UnmanagedType.ByValTStr,
            SizeConst = 128
        )]
        public string DeviceID;

        [MarshalAs(
            UnmanagedType.ByValTStr,
            SizeConst = 128
        )]
        public string DeviceKey;
    }

    private const uint
        DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x00000001;

    private const uint
        DISPLAY_DEVICE_PRIMARY_DEVICE = 0x00000004;

    private const uint
        EDD_GET_DEVICE_INTERFACE_NAME = 0x00000001;

    [DllImport(
        "user32.dll",
        CharSet = CharSet.Unicode,
        EntryPoint = "EnumDisplayDevicesW"
    )]
    private static extern bool EnumDisplayDevices(
        string lpDevice,
        uint iDevNum,
        ref DISPLAY_DEVICE lpDisplayDevice,
        uint dwFlags
    );


    public static DisplayDeviceMapping[]
        GetDisplayDeviceMappings()
    {
        List<DisplayDeviceMapping> results =
            new List<DisplayDeviceMapping>();

        uint adapterIndex = 0;

        while (true)
        {
            DISPLAY_DEVICE adapter =
                new DISPLAY_DEVICE();

            adapter.cb =
                Marshal.SizeOf(typeof(DISPLAY_DEVICE));

            if (!EnumDisplayDevices(
                null,
                adapterIndex,
                ref adapter,
                0))
            {
                break;
            }

            string adapterName =
                adapter.DeviceName;

            bool attached =
                (
                    adapter.StateFlags &
                    DISPLAY_DEVICE_ATTACHED_TO_DESKTOP
                ) != 0;

            bool primary =
                (
                    adapter.StateFlags &
                    DISPLAY_DEVICE_PRIMARY_DEVICE
                ) != 0;

            uint monitorIndex = 0;

            while (true)
            {
                DISPLAY_DEVICE monitor =
                    new DISPLAY_DEVICE();

                monitor.cb =
                    Marshal.SizeOf(
                        typeof(DISPLAY_DEVICE)
                    );

                if (!EnumDisplayDevices(
                    adapterName,
                    monitorIndex,
                    ref monitor,
                    EDD_GET_DEVICE_INTERFACE_NAME))
                {
                    break;
                }

                results.Add(
                    new DisplayDeviceMapping
                    {
                        DeviceName =
                            adapterName,

                        MonitorName =
                            monitor.DeviceString,

                        MonitorDeviceId =
                            monitor.DeviceID,

                        AttachedToDesktop =
                            attached,

                        Primary =
                            primary
                    }
                );

                monitorIndex++;
            }

            adapterIndex++;
        }

        return results.ToArray();
    }


    // ========================================================
    // DDC / CI
    // ========================================================

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }


    [StructLayout(
        LayoutKind.Sequential,
        CharSet = CharSet.Unicode
    )]
    private struct MONITORINFOEX
    {
        public int cbSize;

        public RECT rcMonitor;
        public RECT rcWork;

        public uint dwFlags;

        [MarshalAs(
            UnmanagedType.ByValTStr,
            SizeConst = 32
        )]
        public string szDevice;
    }


    [StructLayout(
        LayoutKind.Sequential,
        CharSet = CharSet.Unicode
    )]
    private struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;

        [MarshalAs(
            UnmanagedType.ByValTStr,
            SizeConst = 128
        )]
        public string szPhysicalMonitorDescription;
    }


    private delegate bool MonitorEnumProc(
        IntPtr hMonitor,
        IntPtr hdcMonitor,
        ref RECT lprcMonitor,
        IntPtr dwData
    );


    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(
        IntPtr hdc,
        IntPtr lprcClip,
        MonitorEnumProc lpfnEnum,
        IntPtr dwData
    );


    [DllImport(
        "user32.dll",
        CharSet = CharSet.Unicode,
        EntryPoint = "GetMonitorInfoW"
    )]
    private static extern bool GetMonitorInfo(
        IntPtr hMonitor,
        ref MONITORINFOEX lpmi
    );


    [DllImport(
        "dxva2.dll",
        SetLastError = true
    )]
    private static extern bool
        GetNumberOfPhysicalMonitorsFromHMONITOR(
            IntPtr hMonitor,
            out uint count
        );


    [DllImport(
        "dxva2.dll",
        SetLastError = true,
        CharSet = CharSet.Unicode
    )]
    private static extern bool
        GetPhysicalMonitorsFromHMONITOR(
            IntPtr hMonitor,
            uint count,
            [Out] PHYSICAL_MONITOR[] monitors
        );


    [DllImport(
        "dxva2.dll",
        SetLastError = true
    )]
    private static extern bool
        GetVCPFeatureAndVCPFeatureReply(
            IntPtr hMonitor,
            byte vcpCode,
            out uint type,
            out uint currentValue,
            out uint maximumValue
        );


    [DllImport(
        "dxva2.dll",
        SetLastError = true
    )]
    private static extern bool SetVCPFeature(
        IntPtr hMonitor,
        byte vcpCode,
        uint newValue
    );


    [DllImport(
        "dxva2.dll",
        SetLastError = true
    )]
    private static extern bool
        DestroyPhysicalMonitors(
            uint count,
            PHYSICAL_MONITOR[] monitors
        );


    public static bool SetInput(
        string targetDevice,
        uint targetInput,
        out uint oldInput,
        out int error)
    {
        bool found = false;
        bool success = false;

        uint capturedOldInput = 0;
        int capturedError = 0;

        MonitorEnumProc callback =
            delegate(
                IntPtr hMonitor,
                IntPtr hdcMonitor,
                ref RECT rect,
                IntPtr data)
        {
            MONITORINFOEX mi =
                new MONITORINFOEX();

            mi.cbSize =
                Marshal.SizeOf(
                    typeof(MONITORINFOEX)
                );

            if (!GetMonitorInfo(
                hMonitor,
                ref mi))
            {
                return true;
            }

            if (!String.Equals(
                mi.szDevice,
                targetDevice,
                StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            found = true;

            uint count;

            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(
                hMonitor,
                out count))
            {
                capturedError =
                    Marshal.GetLastWin32Error();

                return false;
            }

            if (count == 0)
            {
                capturedError = -2;
                return false;
            }

            PHYSICAL_MONITOR[] monitors =
                new PHYSICAL_MONITOR[count];

            if (!GetPhysicalMonitorsFromHMONITOR(
                hMonitor,
                count,
                monitors))
            {
                capturedError =
                    Marshal.GetLastWin32Error();

                return false;
            }

            try
            {
                uint type;
                uint current;
                uint maximum;

                if (
                    GetVCPFeatureAndVCPFeatureReply(
                        monitors[0].hPhysicalMonitor,
                        0x60,
                        out type,
                        out current,
                        out maximum
                    )
                )
                {
                    // Dell reports values such as
                    // 0x0F0F. Low byte is the real value.
                    capturedOldInput =
                        current & 0xFF;
                }

                success =
                    SetVCPFeature(
                        monitors[0].hPhysicalMonitor,
                        0x60,
                        targetInput
                    );

                if (!success)
                {
                    capturedError =
                        Marshal.GetLastWin32Error();
                }
            }
            finally
            {
                DestroyPhysicalMonitors(
                    count,
                    monitors
                );
            }

            return false;
        };


        EnumDisplayMonitors(
            IntPtr.Zero,
            IntPtr.Zero,
            callback,
            IntPtr.Zero
        );

        oldInput =
            capturedOldInput;

        if (!found &&
            capturedError == 0)
        {
            capturedError = -1;
        }

        error =
            capturedError;

        return found && success;
    }


    // ========================================================
    // Windows display topology
    // ========================================================

    [StructLayout(
        LayoutKind.Sequential,
        CharSet = CharSet.Unicode
    )]
    private struct DEVMODE
    {
        [MarshalAs(
            UnmanagedType.ByValTStr,
            SizeConst = 32
        )]
        public string dmDeviceName;

        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;

        public int dmFields;

        public int dmPositionX;
        public int dmPositionY;

        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;

        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;

        [MarshalAs(
            UnmanagedType.ByValTStr,
            SizeConst = 32
        )]
        public string dmFormName;

        public short dmLogPixels;

        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;

        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }


    private const int
        ENUM_CURRENT_SETTINGS = -1;

    private const int
        DM_POSITION = 0x00000020;

    private const int
        DM_PELSWIDTH = 0x00080000;

    private const int
        DM_PELSHEIGHT = 0x00100000;

    private const uint
        CDS_SET_PRIMARY = 0x00000010;


    [DllImport(
        "user32.dll",
        CharSet = CharSet.Unicode,
        EntryPoint = "EnumDisplaySettingsW"
    )]
    private static extern bool EnumDisplaySettings(
        string deviceName,
        int modeNum,
        ref DEVMODE devMode
    );


    [DllImport(
        "user32.dll",
        CharSet = CharSet.Unicode,
        EntryPoint = "ChangeDisplaySettingsExW"
    )]
    private static extern int
        ChangeDisplaySettingsEx(
            string deviceName,
            ref DEVMODE devMode,
            IntPtr hwnd,
            uint flags,
            IntPtr lParam
        );


    [DllImport(
        "user32.dll",
        CharSet = CharSet.Unicode,
        EntryPoint = "ChangeDisplaySettingsExW"
    )]
    private static extern int
        ChangeDisplaySettingsExNull(
            string deviceName,
            IntPtr devMode,
            IntPtr hwnd,
            uint flags,
            IntPtr lParam
        );


    public static int Detach(
        string deviceName)
    {
        DEVMODE mode =
            new DEVMODE();

        mode.dmSize =
            (short)Marshal.SizeOf(
                typeof(DEVMODE)
            );

        if (!EnumDisplaySettings(
            deviceName,
            ENUM_CURRENT_SETTINGS,
            ref mode))
        {
            return -100;
        }

        mode.dmPelsWidth = 0;
        mode.dmPelsHeight = 0;

        mode.dmFields =
            DM_POSITION |
            DM_PELSWIDTH |
            DM_PELSHEIGHT;

        return ChangeDisplaySettingsEx(
            deviceName,
            ref mode,
            IntPtr.Zero,
            0,
            IntPtr.Zero
        );
    }


    public static int MakePrimaryAtOrigin(
        string deviceName)
    {
        DEVMODE mode =
            new DEVMODE();

        mode.dmSize =
            (short)Marshal.SizeOf(
                typeof(DEVMODE)
            );

        if (!EnumDisplaySettings(
            deviceName,
            ENUM_CURRENT_SETTINGS,
            ref mode))
        {
            return -100;
        }

        mode.dmPositionX = 0;
        mode.dmPositionY = 0;

        mode.dmFields =
            DM_POSITION;

        return ChangeDisplaySettingsEx(
            deviceName,
            ref mode,
            IntPtr.Zero,
            CDS_SET_PRIMARY,
            IntPtr.Zero
        );
    }


    public static int RestoreSavedLayout()
    {
        return ChangeDisplaySettingsExNull(
            null,
            IntPtr.Zero,
            IntPtr.Zero,
            0,
            IntPtr.Zero
        );
    }
}
"@
}


# ============================================================
# PowerShell helper functions
# ============================================================

function Convert-MonitorString {
    param(
        [Parameter(Mandatory = $true)]
        $Value
    )

    return (
        $Value |
        Where-Object { $_ -ne 0 } |
        ForEach-Object { [char]$_ }
    ) -join ''
}


function Get-MonitorMappingsBySerial {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Serial
    )

    $wmiMonitor =
        Get-CimInstance `
            -Namespace root\wmi `
            -ClassName WmiMonitorID |
        Where-Object {
            (Convert-MonitorString $_.SerialNumberID) -eq $Serial
        } |
        Select-Object -First 1

    if (-not $wmiMonitor) {
        throw "Monitor serial '$Serial' was not found in WmiMonitorID."
    }

    $parts = $wmiMonitor.InstanceName -split '\\'

    if ($parts.Count -lt 3) {
        throw "Unexpected WMI monitor instance name: $($wmiMonitor.InstanceName)"
    }

    $hardwareId = $parts[1]

    $instanceId =
        $parts[2] -replace '_\d+$', ''

    $matchFragment =
        ($hardwareId + '#' + $instanceId).ToUpperInvariant()

    $matches = @(
        [ToggleSwingMonitorApi]::GetDisplayDeviceMappings() |
        Where-Object {
            $_.MonitorDeviceId -and
            $_.MonitorDeviceId.ToUpperInvariant().Contains(
                $matchFragment
            )
        }
    )

    if ($matches.Count -eq 0) {
        throw (
            "Found monitor serial '$Serial' in WMI, " +
            "but could not map it to any Windows DISPLAY device."
        )
    }

    return $matches
}


function Get-ActiveMonitorBySerial {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Serial
    )

    $matches = @(
        Get-MonitorMappingsBySerial $Serial
    )

    # Ignore stale/inactive Windows mappings.
    # Collapse duplicates that refer to the same DISPLAYx.
    $active = @(
        $matches |
        Where-Object {
            $_.AttachedToDesktop
        } |
        Sort-Object DeviceName -Unique
    )

    if ($active.Count -eq 0) {
        # This is expected when the swing monitor has been
        # deliberately detached from the Windows desktop.
        return $null
    }

    if ($active.Count -gt 1) {
        $names =
            ($active.DeviceName -join ', ')

        throw (
            "Monitor serial '$Serial' is active on multiple " +
            "Windows displays: $names"
        )
    }

    return $active[0]
}


function Get-DisplayChangeResult {
    param(
        [int]$Result
    )

    switch ($Result) {
         0 { "Success" }
         1 { "Restart required" }
        -1 { "Display driver failed the requested change" }
        -2 { "Invalid display mode" }
        -3 { "Unable to update registry" }
        -4 { "Invalid flags" }
        -5 { "Invalid parameter" }
        -6 { "DualView configuration error" }
        -100 { "Could not enumerate current display settings" }

        default {
            "Unknown result: $Result"
        }
    }
}


function Get-InputName {
    param(
        [uint32]$Value
    )

    switch ($Value) {
        0x0F { "DisplayPort 1" }
        0x10 { "DisplayPort 2" }
        0x11 { "HDMI 1" }
        0x12 { "HDMI 2" }

        default {
            "Unknown (0x{0:X2})" -f $Value
        }
    }
}


# ============================================================
# Discover current monitor identities
# ============================================================

try {
    $SwingMonitor =
        Get-ActiveMonitorBySerial $SwingSerial

    $RemainingMonitor =
        Get-ActiveMonitorBySerial $RemainingSerial

    if (-not $RemainingMonitor) {
        throw (
            "Remaining monitor '$RemainingSerial' " +
            "is not active in Windows."
        )
    }
}
catch {
    Write-Host "✗ Monitor discovery failed" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)"
    exit 1
}


Write-Host ""

if ($SwingMonitor) {
    Write-Host "Swing monitor:" -ForegroundColor DarkGray
    Write-Host (
        "  {0} -> {1} (attached=True, primary={2})" -f
            $SwingSerial,
            $SwingMonitor.DeviceName,
            $SwingMonitor.Primary
    ) -ForegroundColor DarkGray
}
else {
    Write-Host (
        "Swing monitor $SwingSerial is not active in Windows."
    ) -ForegroundColor DarkGray
}


# ============================================================
# STATE 1:
#
# Swing monitor is active in Windows.
#
# Give it to Ubuntu:
#     DP -> HDMI
#     detach from Windows
#     remaining monitor -> primary
# ============================================================

if ($SwingMonitor) {

    Write-Host ""
    Write-Host "Giving swing monitor to Ubuntu..." `
        -ForegroundColor Cyan
    Write-Host ""


    # --------------------------------------------------------
    # Switch to HDMI while Windows still has a DDC handle.
    # --------------------------------------------------------

    [uint32]$oldInput = 0
    [int32]$ddcError = 0

    $success =
        [ToggleSwingMonitorApi]::SetInput(
            $SwingMonitor.DeviceName,
            $HDMI,
            [ref]$oldInput,
            [ref]$ddcError
        )


    if (-not $success) {
        Write-Host (
            "✗ Failed to switch {0} to HDMI" -f
                $SwingMonitor.DeviceName
        ) -ForegroundColor Red

        Write-Host "  DDC error: $ddcError"
        exit 1
    }


    Write-Host (
        "✓ Swing monitor switched to HDMI"
    ) -ForegroundColor Green

    Write-Host (
        "  Previous input: {0}" -f
            (Get-InputName $oldInput)
    )

    Start-Sleep -Milliseconds 400


    # --------------------------------------------------------
    # Detach swing monitor from Windows.
    # --------------------------------------------------------

    $result =
        [ToggleSwingMonitorApi]::Detach(
            $SwingMonitor.DeviceName
        )


    if ($result -ne 0) {
        Write-Host (
            "✗ Failed to detach swing monitor from Windows"
        ) -ForegroundColor Red

        Write-Host (
            "  {0}" -f
                (Get-DisplayChangeResult $result)
        )

        exit 1
    }


    Write-Host (
        "✓ Swing monitor detached from Windows"
    ) -ForegroundColor Green

    Start-Sleep -Milliseconds 300


    # --------------------------------------------------------
    # Re-resolve the remaining monitor by serial in case
    # Windows changed any logical display names.
    # --------------------------------------------------------

    try {
        $RemainingMonitor =
            Get-ActiveMonitorBySerial $RemainingSerial

        if (-not $RemainingMonitor) {
            throw "Remaining Windows monitor disappeared unexpectedly."
        }

    }
    catch {
        Write-Host (
            "⚠ Could not rediscover remaining monitor: {0}" -f
                $_.Exception.Message
        ) -ForegroundColor Yellow

        exit 1
    }


    # --------------------------------------------------------
    # Make the remaining monitor the temporary primary at 0,0.
    #
    # This does NOT overwrite the saved dual-monitor layout.
    # --------------------------------------------------------

    $result =
        [ToggleSwingMonitorApi]::MakePrimaryAtOrigin(
            $RemainingMonitor.DeviceName
        )


    if ($result -eq 0) {

        Write-Host (
            "✓ {0} ({1}) is now Windows primary" -f
                $RemainingSerial,
                $RemainingMonitor.DeviceName
        ) -ForegroundColor Green
    }
    else {

        Write-Host (
            "⚠ Windows could not explicitly set the remaining " +
            "monitor primary"
        ) -ForegroundColor Yellow

        Write-Host (
            "  {0}" -f
                (Get-DisplayChangeResult $result)
        )
    }


    Write-Host ""
    Write-Host (
        "Windows is now in single-monitor mode."
    ) -ForegroundColor Cyan
    Write-Host ""

    exit 0
}


# ============================================================
# STATE 2:
#
# Swing monitor is not active in Windows.
#
# Take it back:
#     restore saved Windows dual-monitor configuration
#     rediscover its current DISPLAYx name
#     HDMI -> DP
# ============================================================

Write-Host ""
Write-Host "Taking swing monitor back for Windows..." `
    -ForegroundColor Cyan
Write-Host ""


$result =
    [ToggleSwingMonitorApi]::RestoreSavedLayout()


if ($result -ne 0) {

    Write-Host (
        "✗ Failed to restore the saved Windows display layout"
    ) -ForegroundColor Red

    Write-Host (
        "  {0}" -f
            (Get-DisplayChangeResult $result)
    )

    exit 1
}


Write-Host (
    "✓ Saved Windows dual-monitor layout restored"
) -ForegroundColor Green


# ============================================================
# Wait for the swing monitor to reappear.
#
# Important: rediscover it by SERIAL on every attempt.
# We do not assume its old DISPLAYx name still exists.
# ============================================================

$SwingMonitor = $null

for ($attempt = 1; $attempt -le 20; $attempt++) {

    Start-Sleep -Milliseconds 250

    try {
        $candidate =
            Get-ActiveMonitorBySerial $SwingSerial

        if ($candidate) {
            $SwingMonitor = $candidate
            break
        }
    }
    catch {
        # Device stack may still be settling.
    }
}


if (-not $SwingMonitor) {

    Write-Host (
        "✗ Windows restored its layout, but swing monitor " +
        "$SwingSerial did not become active."
    ) -ForegroundColor Red

    exit 1
}


Write-Host (
    "✓ Swing monitor rediscovered as {0}" -f
        $SwingMonitor.DeviceName
) -ForegroundColor Green


# ============================================================
# Switch the physical monitor back to DisplayPort.
# ============================================================

$success = $false
[uint32]$oldInput = 0
[int32]$ddcError = 0


for ($attempt = 1; $attempt -le 12; $attempt++) {

    $oldInput = 0
    $ddcError = 0

    $success =
        [ToggleSwingMonitorApi]::SetInput(
            $SwingMonitor.DeviceName,
            $DP,
            [ref]$oldInput,
            [ref]$ddcError
        )


    if ($success) {
        break
    }


    # The Windows monitor topology may be restored slightly
    # before DXVA2 exposes the physical DDC monitor handle.
    Start-Sleep -Milliseconds 250

    # Resolve again in case Windows renamed DISPLAYx during
    # the topology restoration.
    try {
        $candidate =
            Get-ActiveMonitorBySerial $SwingSerial

        if ($candidate) {
            $SwingMonitor = $candidate
        }
    }
    catch {
    }
}


if (-not $success) {

    Write-Host (
        "✗ Windows restored the swing monitor, but DDC " +
        "could not switch it to DisplayPort"
    ) -ForegroundColor Red

    Write-Host "  Last DDC error: $ddcError"

    exit 1
}


Write-Host (
    "✓ Swing monitor switched to DisplayPort"
) -ForegroundColor Green

Write-Host (
    "  Previous input: {0}" -f
        (Get-InputName $oldInput)
)


Write-Host ""
Write-Host (
    "Windows is back in its saved dual-monitor configuration."
) -ForegroundColor Cyan
Write-Host ""
