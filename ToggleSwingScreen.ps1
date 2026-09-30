# ============================================================
# ToggleSwingScreen.ps1
#
# Persistent toggle between:
#
#   SINGLE WINDOWS MODE
#       HTHYS83 = only active Windows monitor, primary
#       GHHYS83 = disabled in Windows
#       GHHYS83 physical input = HDMI (Ubuntu)
#
#   DUAL WINDOWS MODE
#       GHHYS83 = primary Windows monitor at 0,0
#       HTHYS83 = secondary Windows monitor to the right
#       GHHYS83 physical input = DisplayPort
#
# Monitors are identified by EDID serial number, not DISPLAY1/2/3.
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

if (-not ('PersistentSwingMonitorApiV2' -as [type])) {

    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class PersistentDisplayDeviceMappingV2
{
    public string DeviceName { get; set; }
    public string MonitorName { get; set; }
    public string MonitorDeviceId { get; set; }
    public bool AttachedToDesktop { get; set; }
    public bool Primary { get; set; }
}

public static class PersistentSwingMonitorApiV2
{
    // ========================================================
    // Display-device discovery
    // ========================================================

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAY_DEVICE
    {
        public int cb;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceString;

        public uint StateFlags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceID;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceKey;
    }

    private const uint DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x00000001;
    private const uint DISPLAY_DEVICE_PRIMARY_DEVICE      = 0x00000004;
    private const uint EDD_GET_DEVICE_INTERFACE_NAME      = 0x00000001;

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

    public static PersistentDisplayDeviceMappingV2[] GetPersistentDisplayDeviceMappingV2s()
    {
        List<PersistentDisplayDeviceMappingV2> results =
            new List<PersistentDisplayDeviceMappingV2>();

        uint adapterIndex = 0;

        while (true)
        {
            DISPLAY_DEVICE adapter = new DISPLAY_DEVICE();
            adapter.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));

            if (!EnumDisplayDevices(
                null,
                adapterIndex,
                ref adapter,
                0))
            {
                break;
            }

            string adapterName = adapter.DeviceName;

            bool attached =
                (adapter.StateFlags &
                 DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0;

            bool primary =
                (adapter.StateFlags &
                 DISPLAY_DEVICE_PRIMARY_DEVICE) != 0;

            uint monitorIndex = 0;

            while (true)
            {
                DISPLAY_DEVICE monitor = new DISPLAY_DEVICE();
                monitor.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));

                if (!EnumDisplayDevices(
                    adapterName,
                    monitorIndex,
                    ref monitor,
                    EDD_GET_DEVICE_INTERFACE_NAME))
                {
                    break;
                }

                results.Add(
                    new PersistentDisplayDeviceMappingV2
                    {
                        DeviceName = adapterName,
                        MonitorName = monitor.DeviceString,
                        MonitorDeviceId = monitor.DeviceID,
                        AttachedToDesktop = attached,
                        Primary = primary
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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
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

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(
        IntPtr hMonitor,
        out uint count
    );

    [DllImport(
        "dxva2.dll",
        SetLastError = true,
        CharSet = CharSet.Unicode
    )]
    private static extern bool GetPhysicalMonitorsFromHMONITOR(
        IntPtr hMonitor,
        uint count,
        [Out] PHYSICAL_MONITOR[] monitors
    );

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetVCPFeatureAndVCPFeatureReply(
        IntPtr hMonitor,
        byte vcpCode,
        out uint type,
        out uint currentValue,
        out uint maximumValue
    );

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool SetVCPFeature(
        IntPtr hMonitor,
        byte vcpCode,
        uint newValue
    );

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool DestroyPhysicalMonitors(
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
            MONITORINFOEX mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));

            if (!GetMonitorInfo(hMonitor, ref mi))
                return true;

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
                capturedError = Marshal.GetLastWin32Error();
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
                capturedError = Marshal.GetLastWin32Error();
                return false;
            }

            try
            {
                uint type;
                uint current;
                uint maximum;

                if (GetVCPFeatureAndVCPFeatureReply(
                    monitors[0].hPhysicalMonitor,
                    0x60,
                    out type,
                    out current,
                    out maximum))
                {
                    // Dell may report 0x0F0F, etc.
                    // Low byte is the actual MCCS value.
                    capturedOldInput = current & 0xFF;
                }

                success = SetVCPFeature(
                    monitors[0].hPhysicalMonitor,
                    0x60,
                    targetInput
                );

                if (!success)
                    capturedError = Marshal.GetLastWin32Error();
            }
            finally
            {
                DestroyPhysicalMonitors(count, monitors);
            }

            return false;
        };

        EnumDisplayMonitors(
            IntPtr.Zero,
            IntPtr.Zero,
            callback,
            IntPtr.Zero
        );

        oldInput = capturedOldInput;

        if (!found && capturedError == 0)
            capturedError = -1;

        error = capturedError;

        return found && success;
    }


    // ========================================================
    // Persistent Windows display topology
    // ========================================================

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
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

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
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

    private const int ENUM_CURRENT_SETTINGS = -1;

    private const int DM_POSITION   = 0x00000020;
    private const int DM_PELSWIDTH  = 0x00080000;
    private const int DM_PELSHEIGHT = 0x00100000;

    private const uint CDS_UPDATEREGISTRY = 0x00000001;
    private const uint CDS_SET_PRIMARY    = 0x00000010;
    private const uint CDS_NORESET        = 0x10000000;

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
    private static extern int ChangeDisplaySettingsEx(
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
    private static extern int ChangeDisplaySettingsExNull(
        string deviceName,
        IntPtr devMode,
        IntPtr hwnd,
        uint flags,
        IntPtr lParam
    );

    // CCD / SetDisplayConfig:
    // ask Windows for the last known EXTEND topology.
    private const uint SDC_TOPOLOGY_EXTEND         = 0x00000004;
    private const uint SDC_APPLY                   = 0x00000080;
    private const uint SDC_ALLOW_CHANGES           = 0x00000400;
    private const uint SDC_PATH_PERSIST_IF_REQUIRED = 0x00000800;

    [DllImport("user32.dll")]
    private static extern int SetDisplayConfig(
        uint numPathArrayElements,
        IntPtr pathArray,
        uint numModeInfoArrayElements,
        IntPtr modeInfoArray,
        uint flags
    );

    private static bool GetCurrentMode(
        string deviceName,
        out DEVMODE mode)
    {
        mode = new DEVMODE();
        mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));

        return EnumDisplaySettings(
            deviceName,
            ENUM_CURRENT_SETTINGS,
            ref mode
        );
    }

    // Persist:
    //   remaining monitor = primary at 0,0
    //   swing monitor     = detached
    //
    // Both changes are written to the user profile first,
    // then applied together.
    public static int PersistSingleLayout(
        string swingDevice,
        string remainingDevice)
    {
        DEVMODE swing;
        DEVMODE remaining;

        if (!GetCurrentMode(swingDevice, out swing))
            return -100;

        if (!GetCurrentMode(remainingDevice, out remaining))
            return -101;

        remaining.dmPositionX = 0;
        remaining.dmPositionY = 0;
        remaining.dmFields = DM_POSITION;

        int result = ChangeDisplaySettingsEx(
            remainingDevice,
            ref remaining,
            IntPtr.Zero,
            CDS_UPDATEREGISTRY |
            CDS_NORESET |
            CDS_SET_PRIMARY,
            IntPtr.Zero
        );

        if (result != 0 && result != 1)
            return result;

        swing.dmPositionX = 0;
        swing.dmPositionY = 0;
        swing.dmPelsWidth = 0;
        swing.dmPelsHeight = 0;

        swing.dmFields =
            DM_POSITION |
            DM_PELSWIDTH |
            DM_PELSHEIGHT;

        result = ChangeDisplaySettingsEx(
            swingDevice,
            ref swing,
            IntPtr.Zero,
            CDS_UPDATEREGISTRY |
            CDS_NORESET,
            IntPtr.Zero
        );

        if (result != 0 && result != 1)
            return result;

        return ChangeDisplaySettingsExNull(
            null,
            IntPtr.Zero,
            IntPtr.Zero,
            0,
            IntPtr.Zero
        );
    }

    // Ask Windows to reactivate its most recent EXTEND topology.
    // This gets the disabled swing path active again so we can
    // rediscover it by serial and then persist our exact layout.
    public static int RestoreExtendedTopology()
    {
        // Use the exact documented request for the last EXTEND
        // configuration from the Windows persistence database.
        //
        // Do not add SDC_ALLOW_CHANGES or
        // SDC_PATH_PERSIST_IF_REQUIRED here. We only need to
        // reactivate the extended topology; PersistDualLayout()
        // writes our exact preferred layout immediately afterward.
        return SetDisplayConfig(
            0,
            IntPtr.Zero,
            0,
            IntPtr.Zero,
            SDC_APPLY |
            SDC_TOPOLOGY_EXTEND
        );
    }

    // Persist the preferred dual-monitor layout:
    //
    //   swing     = primary at 0,0
    //   remaining = immediately to the right of swing
    //
    // Current resolution/refresh values are preserved.
    public static int PersistDualLayout(
        string swingDevice,
        string remainingDevice)
    {
        DEVMODE swing;
        DEVMODE remaining;

        if (!GetCurrentMode(swingDevice, out swing))
            return -100;

        if (!GetCurrentMode(remainingDevice, out remaining))
            return -101;

        int swingWidth = swing.dmPelsWidth;

        swing.dmPositionX = 0;
        swing.dmPositionY = 0;
        swing.dmFields = DM_POSITION;

        remaining.dmPositionX = swingWidth;
        remaining.dmPositionY = 0;
        remaining.dmFields = DM_POSITION;

        int result = ChangeDisplaySettingsEx(
            swingDevice,
            ref swing,
            IntPtr.Zero,
            CDS_UPDATEREGISTRY |
            CDS_NORESET |
            CDS_SET_PRIMARY,
            IntPtr.Zero
        );

        if (result != 0 && result != 1)
            return result;

        result = ChangeDisplaySettingsEx(
            remainingDevice,
            ref remaining,
            IntPtr.Zero,
            CDS_UPDATEREGISTRY |
            CDS_NORESET,
            IntPtr.Zero
        );

        if (result != 0 && result != 1)
            return result;

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
    $instanceId = $parts[2] -replace '_\d+$', ''

    $matchFragment =
        ($hardwareId + '#' + $instanceId).ToUpperInvariant()

    $matches = @(
        [PersistentSwingMonitorApiV2]::GetPersistentDisplayDeviceMappingV2s() |
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

    $active = @(
        $matches |
        Where-Object {
            $_.AttachedToDesktop
        } |
        Sort-Object DeviceName -Unique
    )

    if ($active.Count -eq 0) {
        return $null
    }

    if ($active.Count -gt 1) {
        $names = ($active.DeviceName -join ', ')

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
        -100 { "Could not enumerate swing display settings" }
        -101 { "Could not enumerate remaining display settings" }

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


function Wait-ForActiveMonitor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Serial,

        [int]$Attempts = 24,
        [int]$DelayMilliseconds = 250
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {

        try {
            $candidate = Get-ActiveMonitorBySerial $Serial

            if ($candidate) {
                return $candidate
            }
        }
        catch {
            # Display stack may still be settling.
        }

        Start-Sleep -Milliseconds $DelayMilliseconds
    }

    return $null
}


# ============================================================
# Discover current state
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

    Write-Host "Current state: DUAL Windows monitors" `
        -ForegroundColor DarkGray

    Write-Host (
        "  Swing:     {0} -> {1} (primary={2})" -f
            $SwingSerial,
            $SwingMonitor.DeviceName,
            $SwingMonitor.Primary
    ) -ForegroundColor DarkGray

    Write-Host (
        "  Remaining: {0} -> {1}" -f
            $RemainingSerial,
            $RemainingMonitor.DeviceName
    ) -ForegroundColor DarkGray
}
else {

    Write-Host "Current state: SINGLE Windows monitor" `
        -ForegroundColor DarkGray

    Write-Host (
        "  Swing {0} is disabled in Windows." -f
            $SwingSerial
    ) -ForegroundColor DarkGray

    Write-Host (
        "  Remaining: {0} -> {1}" -f
            $RemainingSerial,
            $RemainingMonitor.DeviceName
    ) -ForegroundColor DarkGray
}


# ============================================================
# DUAL -> SINGLE
# ============================================================

if ($SwingMonitor) {

    Write-Host ""
    Write-Host "Giving swing monitor to Ubuntu..." `
        -ForegroundColor Cyan
    Write-Host ""

    # DDC must happen while the swing monitor is still active
    # in Windows, because that is how we obtain its physical
    # monitor handle.
    [uint32]$oldInput = 0
    [int32]$ddcError = 0

    $success =
        [PersistentSwingMonitorApiV2]::SetInput(
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

    Write-Host "✓ Swing monitor switched to HDMI" `
        -ForegroundColor Green

    Write-Host (
        "  Previous input: {0}" -f
            (Get-InputName $oldInput)
    )

    Start-Sleep -Milliseconds 400

    # Persist both parts of the single-monitor topology:
    #
    #   - remaining monitor becomes primary at 0,0
    #   - swing monitor is disabled
    #
    # Because CDS_UPDATEREGISTRY is used, Windows should retain
    # this state across sleep/wake rather than automatically
    # returning to dual-monitor mode.
    $result =
        [PersistentSwingMonitorApiV2]::PersistSingleLayout(
            $SwingMonitor.DeviceName,
            $RemainingMonitor.DeviceName
        )

    if ($result -ne 0) {

        Write-Host (
            "✗ Failed to persist Windows single-monitor mode"
        ) -ForegroundColor Red

        Write-Host (
            "  {0}" -f
                (Get-DisplayChangeResult $result)
        )

        exit 1
    }

    Write-Host (
        "✓ Persistent single-monitor Windows layout saved"
    ) -ForegroundColor Green

    Write-Host (
        "✓ {0} is now the Windows primary monitor" -f
            $RemainingSerial
    ) -ForegroundColor Green

    Write-Host ""
    Write-Host (
        "Windows is now in persistent single-monitor mode."
    ) -ForegroundColor Cyan
    Write-Host ""

    exit 0
}


# ============================================================
# SINGLE -> DUAL
# ============================================================

Write-Host ""
Write-Host "Taking swing monitor back for Windows..." `
    -ForegroundColor Cyan
Write-Host ""


# Ask Windows for its most recent EXTEND topology. This
# reactivates the swing display path even though the current
# persistent state has it disabled.
$result =
    [PersistentSwingMonitorApiV2]::RestoreExtendedTopology()

if ($result -ne 0) {

    Write-Host (
        "✗ Windows could not restore an extended display topology"
    ) -ForegroundColor Red

    Write-Host (
        "  SetDisplayConfig result: $result"
    )

    exit 1
}

Write-Host "✓ Windows extended topology restored" `
    -ForegroundColor Green


# Rediscover both displays by SERIAL. Do not reuse an old
# DISPLAY1/2/3 name because Windows may renumber them here.
$SwingMonitor =
    Wait-ForActiveMonitor $SwingSerial

$RemainingMonitor =
    Wait-ForActiveMonitor $RemainingSerial


if (-not $SwingMonitor) {

    Write-Host (
        "✗ Extended mode was requested, but swing monitor " +
        "$SwingSerial did not become active."
    ) -ForegroundColor Red

    exit 1
}


if (-not $RemainingMonitor) {

    Write-Host (
        "✗ Extended mode was requested, but remaining monitor " +
        "$RemainingSerial did not become active."
    ) -ForegroundColor Red

    exit 1
}


Write-Host (
    "✓ Swing monitor rediscovered as {0}" -f
        $SwingMonitor.DeviceName
) -ForegroundColor Green

Write-Host (
    "✓ Remaining monitor rediscovered as {0}" -f
        $RemainingMonitor.DeviceName
) -ForegroundColor Green


# Explicitly persist our preferred dual layout:
#
#   swing     = primary, 0,0
#   remaining = immediately to the right
#
# This means dual mode also survives sleep/wake.
$result =
    [PersistentSwingMonitorApiV2]::PersistDualLayout(
        $SwingMonitor.DeviceName,
        $RemainingMonitor.DeviceName
    )

if ($result -ne 0) {

    Write-Host (
        "✗ Windows re-enabled both monitors, but could not " +
        "persist the preferred dual-monitor layout"
    ) -ForegroundColor Red

    Write-Host (
        "  {0}" -f
            (Get-DisplayChangeResult $result)
    )

    exit 1
}


Write-Host (
    "✓ Persistent dual-monitor Windows layout saved"
) -ForegroundColor Green

Write-Host (
    "✓ $SwingSerial is primary; $RemainingSerial is to its right"
) -ForegroundColor Green


# The monitor is active in Windows again, so DDC should now
# expose its physical handle. Retry briefly while the display
# stack settles.
$success = $false
[uint32]$oldInput = 0
[int32]$ddcError = 0


for ($attempt = 1; $attempt -le 12; $attempt++) {

    $oldInput = 0
    $ddcError = 0

    $success =
        [PersistentSwingMonitorApiV2]::SetInput(
            $SwingMonitor.DeviceName,
            $DP,
            [ref]$oldInput,
            [ref]$ddcError
        )

    if ($success) {
        break
    }

    Start-Sleep -Milliseconds 250

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
    "Windows is now in persistent dual-monitor mode."
) -ForegroundColor Cyan
Write-Host ""
