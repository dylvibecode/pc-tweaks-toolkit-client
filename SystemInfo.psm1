<#
    SystemInfo.psm1
    ----------------
    Pure PowerShell system-info / checklist text for the PC Tweaks Toolkit.
    No third-party tool and no WinForms dependency - every function here just
    returns a plain string built from CIM/WMI queries and static guidance text.
#>

function Get-SystemHeaderText {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        return ("{0}  |  {1} (Build {2})  |  {3} {4}" -f $cs.Name, $os.Caption, $os.BuildNumber, $cs.Manufacturer, $cs.Model)
    } catch {
        return $env:COMPUTERNAME
    }
}

function Get-StorageCheckText {
    $lines = @()
    $lines += "=== Storage Check ==="
    Get-Volume | Where-Object { $_.DriveLetter -and $_.Size -gt 0 } | Sort-Object DriveLetter | ForEach-Object {
        $percentFree = [math]::Round(($_.SizeRemaining / $_.Size) * 100, 1)
        $freeGb = [math]::Round($_.SizeRemaining / 1GB, 1)
        $totalGb = [math]::Round($_.Size / 1GB, 1)
        $flag = if ($percentFree -lt 10) { "  <-- LOW SPACE" } else { "" }
        $lines += ("  {0}:  {1} GB free of {2} GB  ({3}% free){4}" -f $_.DriveLetter, $freeGb, $totalGb, $percentFree, $flag)
    }
    $lines += ""
    $lines += "Disk health:"
    try {
        Get-PhysicalDisk | ForEach-Object {
            $lines += ("  {0} ({1}) - Health: {2}" -f $_.FriendlyName, $_.MediaType, $_.HealthStatus)
        }
    } catch {
        $lines += "  (Disk health info unavailable on this system)"
    }
    $lines += ""
    $lines += "Guideline: keep SSDs at least 10% free for best performance."
    return $lines -join "`n"
}

function Get-RamSummaryText {
    $lines = @()
    $lines += "=== RAM Summary (Windows) ==="
    $sticks = @(Get-CimInstance Win32_PhysicalMemory)
    $i = 0
    foreach ($m in $sticks) {
        $i++
        $capGb = [math]::Round($m.Capacity / 1GB, 1)
        $lines += ("  Stick {0}: {1} GB, {2} MHz, {3} {4}" -f $i, $capGb, $m.Speed, $m.Manufacturer, $m.PartNumber.Trim())
    }
    $lines += ("  Sticks installed: {0} ({1})" -f $sticks.Count, $(if ($sticks.Count -ge 2) { "likely dual/multi-channel" } else { "single channel" }))
    $lines += ""
    $lines += "Check in CPU-Z (Memory / SPD tabs):"
    $lines += "  - XMP / DOCP / EXPO is enabled"
    $lines += "  - RAM is in the correct (motherboard-recommended) slots"
    $lines += "  - No mismatch between RAM modules"
    $lines += "  - Serial numbers, if needed for warranty/RMA"
    return $lines -join "`n"
}

function Get-GpuSummaryText {
    $lines = @()
    $lines += "=== GPU Summary (Windows) ==="
    Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic Render|Remote Display|Virtual' } | ForEach-Object {
        $lines += ("  {0}  (driver {1}, {2})" -f $_.Name, $_.DriverVersion, $_.DriverDate)
    }
    $lines += ""
    $lines += "Check in GPU-Z:"
    $lines += "  - Resizable BAR field shows Enabled"
    $lines += "  - PCIe bus is running at maximum (not downgraded, e.g. x16 3.0/4.0)"
    $lines += "  - Monitor cable is connected to the GPU, not the motherboard"
    $lines += "  - GPU is seated in the top PCIe slot"
    $lines += "  - Multiple GPUs installed is not recommended for gaming"
    $lines += ""
    $lines += "If Resizable BAR shows Disabled and the GPU/CPU support it, enable in BIOS:"
    $lines += "  - 'Above 4G Decoding' (or 'Above 4G MMIO')"
    $lines += "  - 'Re-Size BAR Support' (or 'Smart Access Memory' on AMD)"
    return $lines -join "`n"
}

function Get-DduCheckText {
    $lines = @()
    $lines += "=== GPU Driver Cleanup (DDU) ==="
    Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic Render|Remote Display|Virtual' } | ForEach-Object {
        $lines += ("  {0}  (driver {1})" -f $_.Name, $_.DriverVersion)
    }
    $lines += ""
    $lines += "Before running DDU:"
    $lines += "  - Download the new driver first (DDU removes the old one - you'll want"
    $lines += "    the replacement ready before rebooting)"
    $lines += "  - Close anything using the GPU (games, browsers with hardware accel, etc.)"
    $lines += ""
    $lines += "For the cleanest removal:"
    $lines += "  - Use 'Reboot: Safe Mode' below first, then run DDU from there - a normal-"
    $lines += "    mode run still works but won't fully unload files/services the driver"
    $lines += "    has locked while active"
    $lines += "  - Select the correct GPU vendor at the top of the DDU window before cleaning"
    $lines += "  - Use 'Reboot: Normal Mode' afterward, then install the fresh driver"
    return $lines -join "`n"
}

function Get-DriverUpdateCheckText {
    $lines = @()
    $lines += "=== GPU Driver Update ==="
    Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic Render|Remote Display|Virtual' } | ForEach-Object {
        $lines += ("  {0}  (driver {1}, {2})" -f $_.Name, $_.DriverVersion, $_.DriverDate)
    }
    $lines += ""
    $lines += "Opening the official driver download page for the detected GPU vendor -"
    $lines += "always grab drivers straight from NVIDIA/AMD/Intel's own site, never a"
    $lines += "third-party mirror."
    return $lines -join "`n"
}

function Get-SafeModeCheckText {
    $lines = @()
    $lines += "=== Safe Mode Reboot ==="
    try {
        $bcdOutput = & bcdedit /enum '{current}' 2>&1 | Out-String
        if ($bcdOutput -match 'safeboot\s+(\S+)') {
            $lines += "  Currently configured to boot into Safe Mode ($($Matches[1])) next restart."
        } else {
            $lines += "  Currently configured for a normal boot (no Safe Mode flag set)."
        }
    } catch {
        $lines += "  Could not read current boot configuration via bcdedit."
    }
    $lines += ""
    $lines += "Workflow for a clean GPU driver wipe:"
    $lines += "  1. Reboot: Safe Mode (this sets the flag, then restarts the PC)"
    $lines += "  2. Once back in Safe Mode, come back to this Graphics tab and run DDU"
    $lines += "  3. Reboot: Normal Mode (clears the flag, then restarts back to normal)"
    $lines += "  4. Install the fresh GPU driver"
    $lines += ""
    $lines += "Safety net: 'Reboot: Safe Mode' also registers a self-clearing RunOnce entry,"
    $lines += "so the Safe Mode flag automatically removes itself the moment any successful"
    $lines += "Windows login happens (even the Safe Mode login itself) - it cannot get stuck"
    $lines += "permanently even if you never click 'Reboot: Normal Mode' yourself."
    $lines += ""
    $lines += "The PC restarts automatically a short time after you confirm - save any"
    $lines += "open work first."
    return $lines -join "`n"
}

function Get-TempsCheckText {
    $lines = @()
    $lines += "=== Temperature Check ==="
    $lines += "Check in HWiNFO (Sensors window):"
    $lines += "  - CPU package/core temps at idle - should settle low after a minute"
    $lines += "  - CPU temps under load - compare against that CPU's rated max/throttle spec"
    $lines += "  - GPU temp under load - most cards should stay well under their thermal limit"
    $lines += "  - VRM / motherboard temps, if shown - flag anything unusually hot"
    $lines += "  - Fan RPMs actually ramp with temperature, not stuck at one speed"
    $lines += "  - For a true load reading, run a short stress test (Prime95/FurMark) first -"
    $lines += "    idle temps alone won't show a cooling problem"
    return $lines -join "`n"
}

function Get-BiosCheckText {
    $lines = @()
    $lines += "=== BIOS / Motherboard Check ==="
    try {
        $bios = Get-CimInstance Win32_BIOS
        $board = Get-CimInstance Win32_BaseBoard
        $lines += ("  Motherboard: {0} {1}" -f $board.Manufacturer, $board.Product)
        $lines += ("  Current BIOS: {0} ({1}, released {2})" -f $bios.SMBIOSBIOSVersion, $bios.Manufacturer, $bios.ReleaseDate.ToString('yyyy-MM-dd'))
    } catch {
        $lines += "  Could not read BIOS/motherboard info via WMI."
    }
    $lines += ""
    $lines += "Opening a Google search for this motherboard's support/BIOS page."
    $lines += ""
    $lines += "Before updating:"
    $lines += "  - Only update if there's a specific reason (stability/security fix, new CPU"
    $lines += "    support) - not just because a newer version exists"
    $lines += "  - Note current XMP/DOCP/EXPO and other custom BIOS settings first - some"
    $lines += "    updates reset everything to default"
    $lines += "  - Never interrupt a BIOS flash (power loss, reboot) - use USB BIOS Flashback"
    $lines += "    if the board supports it"
    $lines += "  - Confirm the download is from the motherboard's OWN manufacturer support page"
    return $lines -join "`n"
}

function Get-BiosSettingsCheckText {
    $lines = @()
    $lines += "=== BIOS Settings Checklist ==="
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $lines += ("  Detected CPU: {0}" -f $cpu.Name.Trim())
    } catch {
        $lines += "  Could not detect CPU via WMI."
    }
    $lines += ""
    $lines += "Intel:"
    $lines += "  - Enable XMP (or DOCP, depending on motherboard vendor naming)"
    $lines += "  - Disable C-States - K-series chips ONLY"
    $lines += "  - Enable Resizable BAR (ReBAR)"
    $lines += "  - Disable the integrated GPU"
    $lines += ""
    $lines += "AMD:"
    $lines += "  - Enable EXPO profile"
    $lines += "  - Enable Precision Boost Overdrive (PBO)"
    $lines += "  - 7800X3D / 9800X3D ONLY: set PBO to Advanced, with:"
    $lines += "      PBO Limits: Motherboard"
    $lines += "      Curve Optimizer: All Core, Negative, 20"
    $lines += "      Scalar: Manual, 2X"
    $lines += "      Max CPU Boost Clock Override: Enabled Positive (+200MHz)"
    $lines += "  - Disable the integrated GPU"
    $lines += "  - Disable SVM (virtualization)"
    $lines += "  - Disable IOMMU - UNLESS the client plays Faceit-anticheat CS2, where it"
    $lines += "    should stay ENABLED (Faceit's anticheat requires it)"
    return $lines -join "`n"
}

function Get-GpuP0StateText {
    $lines = @()
    $lines += "=== Force Max GPU Performance (P0 State) ==="
    try {
        $subkeys = Get-ChildItem -Path 'Registry::HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -notlike '*Configuration*' }
        $states = foreach ($key in $subkeys) {
            $val = Get-ItemProperty -Path $key.PSPath -Name 'DisableDynamicPstate' -ErrorAction SilentlyContinue
            if ($val) { $val.DisableDynamicPstate }
        }
        if (@($states | Where-Object { $_ -eq 1 }).Count -gt 0) {
            $lines += "  Current state: FORCED to max performance (P0) at all times"
        } else {
            $lines += "  Current state: Default (dynamic power states)"
        }
    } catch {
        $lines += "  Could not read the current GPU power-state registry value."
    }
    $lines += ""
    $lines += "What this does: keeps the NVIDIA GPU at its highest power state (P0) even at"
    $lines += "idle, instead of letting it dynamically downclock. Removes the brief clock-ramp"
    $lines += "stutter/latency when a game first starts rendering - a common competitive-FPS"
    $lines += "tweak (same crowd as the Faceit/CS2 IOMMU note in BIOS Settings Notes)."
    $lines += ""
    $lines += "Trade-off: higher idle power draw, higher idle GPU temp, and the fan may spin"
    $lines += "more at idle since the core never downclocks. Fully reversible, no stability risk -"
    $lines += "takes effect immediately, no reboot needed either way."
    $lines += ""
    $lines += "NVIDIA-only - this registry value isn't read by AMD/Intel drivers."
    return $lines -join "`n"
}

function Get-GpuP0State {
    try {
        $subkeys = Get-ChildItem -Path 'Registry::HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -notlike '*Configuration*' }
        $states = foreach ($key in $subkeys) {
            $val = Get-ItemProperty -Path $key.PSPath -Name 'DisableDynamicPstate' -ErrorAction SilentlyContinue
            if ($val) { $val.DisableDynamicPstate }
        }
        return @($states | Where-Object { $_ -eq 1 }).Count -gt 0
    } catch {
        return $false
    }
}

function Get-DisplaySettingsCheckText {
    $lines = @()
    $lines += "=== Resolution & Refresh Rate ==="
    try {
        $all = @(Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution })
        # WMI reports "current" resolution/refresh rate for every video controller,
        # including an integrated GPU that isn't actually driving any display - prefer
        # a discrete GPU when one's present (same heuristic as Get-PrimaryGpuVendor),
        # so an idle iGPU's stale/copied numbers don't show up alongside the real ones.
        $discrete = @($all | Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX|GTX|Quadro|Radeon RX|Radeon Pro|Radeon VII|FirePro' })
        $shown = if ($discrete.Count -gt 0) { $discrete } else { $all }
        foreach ($gpu in $shown) {
            $lines += ("  {0}: {1}x{2} @ {3}Hz" -f $gpu.Name, $gpu.CurrentHorizontalResolution, $gpu.CurrentVerticalResolution, $gpu.CurrentRefreshRate)
        }
        if ($all.Count -gt $shown.Count) {
            $lines += "  (Integrated GPU hidden here - it reports display info via WMI even though"
            $lines += "  it isn't driving anything with a discrete GPU present)"
        }
    } catch {
        $lines += "  Could not read the current resolution/refresh rate via WMI."
    }
    $lines += ""
    $lines += "WMI's numbers above can occasionally be stale on some driver stacks - the Settings"
    $lines += "page opening below is the actual source of truth if these look off."
    $lines += ""
    $lines += "Check in Settings:"
    $lines += "  - Resolution is set to the monitor's native resolution (usually the top/recommended option)"
    $lines += "  - Refresh rate is set to the monitor's maximum - not stuck at 60Hz on a 144Hz/165Hz/240Hz"
    $lines += "    panel, a common miss after a fresh Windows install or GPU driver reset"
    $lines += "  - With multiple monitors, check each one individually (Settings lets you pick per-display)"
    return $lines -join "`n"
}

function Get-HagsCheckText {
    $lines = @()
    $lines += "=== HAGS & Windowed Game Optimizations ==="
    $lines += "Two separate settings live on this page:"
    $lines += ""
    $lines += "Hardware-Accelerated GPU Scheduling (HAGS):"
    $lines += "  - Lets the GPU manage its own scheduling queue instead of the CPU/driver"
    $lines += "  - No universal answer - some GPU/game combinations see lower latency with it OFF,"
    $lines += "    others benefit from it ON. If chasing an input-lag complaint, test both ways with"
    $lines += "    the client's actual games rather than assuming a direction"
    $lines += ""
    $lines += "Optimizations for windowed games (per-app, further down the same page):"
    $lines += "  - Reduces input lag specifically for games run in Borderless Windowed mode"
    $lines += "  - Only matters for games actually played windowed/borderless - no effect on true fullscreen"
    return $lines -join "`n"
}

function Get-NvidiaProfileInspectorText {
    $lines = @()
    $lines += "=== NVIDIA Profile Inspector - Base Profile ==="
    Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic Render|Remote Display|Virtual' } | ForEach-Object {
        $lines += ("  {0}  (driver {1})" -f $_.Name, $_.DriverVersion)
    }
    $lines += ""
    $lines += "Applies to the driver's Base Profile (global defaults, not a per-game profile) via"
    $lines += "NVIDIA Profile Inspector's silent import - no dialogs or GUI shown. NVIDIA-only."
    $lines += ""
    $lines += "'Apply NVIDIA Settings' sets: highest available refresh rate, Prefer Maximum"
    $lines += "Performance power mode, unlimited shader cache, threaded optimization on, Ultra Low"
    $lines += "Latency Mode, 1 max pre-rendered frame, Vertical Sync off, and Fixed Refresh monitor"
    $lines += "technology."
    $lines += ""
    $lines += "'Reset NVIDIA Settings' clears the Base Profile back to driver defaults - not just"
    $lines += "undoing the 8 settings above, but any other Base Profile customization too."
    $lines += ""
    $lines += "Both auto-launch the Legacy NVIDIA Control Panel afterward so the result is visible"
    $lines += "immediately - installed via winget on first use if it isn't already present."
    return $lines -join "`n"
}

function Get-TaskbarStartText {
    $lines = @()
    $lines += "=== Taskbar & Start Menu Cleanup ==="
    $lines += "Clean applies these (all standard, documented Windows/Explorer settings):"
    $lines += "  - Hide Widgets, Search box, Task View, Chat, and Copilot buttons from the taskbar"
    $lines += "  - Show all system tray icons instead of hiding them behind the overflow arrow"
    $lines += "  - Hide the 'Recommended' section in the Start menu"
    $lines += "  - Set Start menu 'All Apps' view to List instead of Category"
    $lines += "  - Unpin all current taskbar icons (a fresh, clean layout for the client)"
    $lines += ""
    $lines += "Default reverts all of the above back to Windows' out-of-box behavior."
    $lines += ""
    $lines += "Note: unpinning taskbar icons can't be undone by 'Default' - the client will need to"
    $lines += "re-pin anything they want back manually. Some changes may need a sign-out/sign-in or"
    $lines += "an Explorer restart to fully refresh if they don't appear immediately."
    return $lines -join "`n"
}

function Get-TaskbarAlignmentText {
    $lines = @()
    $lines += "=== Taskbar Alignment ==="
    $lines += "Windows 11's default is Center. Left matches the classic Windows 10 layout."
    $lines += "Takes effect immediately, no restart needed - re-click and choose the other option"
    $lines += "to change it back."
    return $lines -join "`n"
}

function Get-TaskbarAlignmentState {
    $value = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAl' -ErrorAction SilentlyContinue).TaskbarAl
    return ($null -eq $value -or $value -eq 1)
}

function Get-ContextMenuText {
    $lines = @()
    $lines += "=== Classic Context Menu ==="
    $isClassic = Test-Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
    if ($isClassic) {
        $lines += "  Current state: Classic (full right-click menu, no 'Show more options' needed)"
    } else {
        $lines += "  Current state: Default (Windows 11's shortened menu, 'Show more options' for the rest)"
    }
    $lines += ""
    $lines += "What this does: Windows 11 ships a shortened right-click menu by design, requiring an"
    $lines += "extra 'Show more options' click (or Shift+F10) to reach the full Windows 10-style menu."
    $lines += "This flips a documented fallback switch built into Explorer itself - not a hack or a"
    $lines += "removed feature, just a supported escape hatch Microsoft left in for exactly this."
    $lines += ""
    $lines += "Takes effect immediately - no reboot, but open File Explorer windows may need to be"
    $lines += "reopened (or Explorer restarted) to pick it up right away."
    return $lines -join "`n"
}

function Get-ContextMenuState {
    return (Test-Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32')
}

function Get-ThemeText {
    $lines = @()
    $lines += "=== Dark / Light Theme ==="
    try {
        $current = (Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
        $lines += "  Current state: $(if ($current -eq 0) { 'Dark' } else { 'Light' })"
    } catch {
        $lines += "  Current state: Light (Windows default - no override set yet)"
    }
    $lines += ""
    $lines += "Sets Windows' own Settings > Personalization > Colors options:"
    $lines += "  - App mode and system mode (taskbar/Start), light or dark"
    $lines += "  - Transparency effects"
    $lines += "  - 'Show accent color on Start and taskbar'"
    $lines += ""
    $lines += "Does NOT touch the desktop wallpaper or the client's chosen accent color - both"
    $lines += "stay exactly as they were either way."
    $lines += ""
    $lines += "'Light Theme' explicitly sets full light (system AND apps) rather than reverting to"
    $lines += "Windows' own out-of-box default - that default is actually asymmetric (dark taskbar,"
    $lines += "light apps, the classic Windows 10/11 look), which isn't what a 'Light Theme' button"
    $lines += "should produce. Both buttons set every value explicitly, mirroring each other exactly."
    $lines += ""
    $lines += "Both leave 'show accent color on Start/taskbar' OFF, so the taskbar renders a flat"
    $lines += "neutral dark/light color with no tint from whatever accent color happens to be set -"
    $lines += "use the separate Accent Color button if a colored taskbar is wanted."
    $lines += ""
    $lines += "Refreshes automatically (restarts Explorer and the taskbar/Start/search shell"
    $lines += "processes) - no sign-out needed, but any open File Explorer windows will briefly"
    $lines += "close during the ~3 second refresh."
    return $lines -join "`n"
}

function Get-ThemeState {
    $current = (Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction SilentlyContinue).AppsUseLightTheme
    return ($current -eq 0)
}

function Get-AccentColorText {
    $lines = @()
    $lines += "=== Accent Color ==="
    $lines += "Opens Windows' own color picker - pick any color and it's applied as the system"
    $lines += "accent (Start/taskbar/title bar accenting)."
    $lines += ""
    $lines += "Note: Windows also keeps a 10-shade preset palette for the Settings page's custom-"
    $lines += "color swatches grid - that palette isn't recalculated here, so the new color may not"
    $lines += "appear among those swatches until Windows itself regenerates it. The actual applied"
    $lines += "accent color (what you'll see on screen) is correct immediately either way."
    $lines += ""
    $lines += "Independent of Dark/Light Theme and doesn't touch the wallpaper - just the accent color."
    $lines += ""
    $lines += "Refreshes automatically (restarts Explorer and the taskbar/Start/search shell"
    $lines += "processes) - no sign-out needed, but any open File Explorer windows will briefly"
    $lines += "close during the ~3 second refresh."
    return $lines -join "`n"
}

function Get-RestartExplorerText {
    $lines = @()
    $lines += "=== Restart Explorer ==="
    $lines += "Restarts the Windows shell to pick up taskbar/Start/theme changes that don't apply"
    $lines += "live. Closes all open File Explorer windows; desktop and taskbar briefly disappear"
    $lines += "and come back (a few seconds)."
    return $lines -join "`n"
}

function Get-WidgetsText {
    $lines = @()
    $lines += "=== Widgets ==="
    $current = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -ErrorAction SilentlyContinue).AllowNewsAndInterests
    $lines += "  Current state: $(if ($current -eq 0) { 'Disabled' } else { 'Enabled (Windows default)' })"
    $lines += ""
    $lines += "Sets the documented 'Turn off widgets' policy (both the Dsh and PolicyManager"
    $lines += "registry paths Windows itself uses for this) and stops the Widgets/WidgetService"
    $lines += "processes immediately, rather than waiting for next sign-in."
    return $lines -join "`n"
}

function Get-WidgetsState {
    $current = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -ErrorAction SilentlyContinue).AllowNewsAndInterests
    return ($current -ne 0)
}

function Get-CopilotText {
    $lines = @()
    $lines += "=== Copilot ==="
    $current = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -ErrorAction SilentlyContinue).TurnOffWindowsCopilot
    $lines += "  Current state: $(if ($current -eq 1) { 'Disabled' } else { 'Enabled (Windows default)' })"
    $lines += ""
    $lines += "Sets the documented 'Turn off Windows Copilot' policy (in both HKCU and HKLM, as"
    $lines += "Windows checks either) and stops the Copilot process immediately."
    return $lines -join "`n"
}

function Get-CopilotState {
    $current = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -ErrorAction SilentlyContinue).TurnOffWindowsCopilot
    return ($current -ne 1)
}

function Get-MouseAccelText {
    $lines = @()
    $lines += "=== Mouse Acceleration (Enhance Pointer Precision) ==="
    $speed = (Get-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -ErrorAction SilentlyContinue).MouseSpeed
    $lines += "  Current state: $(if ($speed -eq '0') { 'Disabled (no acceleration)' } else { 'Enabled (Windows default)' })"
    $lines += ""
    $lines += "Mouse acceleration makes cursor movement distance depend on how fast you physically"
    $lines += "move the mouse, not just how far - competitive/FPS players almost universally want"
    $lines += "this off for consistent, predictable aim."
    $lines += ""
    $lines += "Applies immediately via the same Win32 call Control Panel's own Mouse settings use -"
    $lines += "no sign-out needed."
    return $lines -join "`n"
}

function Get-MouseAccelState {
    $speed = (Get-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -ErrorAction SilentlyContinue).MouseSpeed
    return ($speed -ne '0')
}

function Get-GameModeText {
    $lines = @()
    $lines += "=== Game Mode Check ==="
    $current = (Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -ErrorAction SilentlyContinue).AutoGameModeEnabled
    $lines += "  Current state: $(if ($null -eq $current) { 'Not set (Windows default, normally On)' } elseif ($current -eq 1) { 'On' } else { 'Off' })"
    $lines += ""
    $lines += "Game Mode prioritizes CPU/GPU scheduling for the active game and can reduce driver-"
    $lines += "related stutter - opening Settings to confirm/toggle it directly rather than writing"
    $lines += "it here, since it's a single simple switch not worth a whole button pair for."
    return $lines -join "`n"
}

function Get-BloatwareText {
    $lines = @()
    $lines += "=== Remove Bloatware ==="
    $lines += "Removes a curated list of well-known pre-installed apps for FPS/performance -"
    $lines += "Cortana, Bing News/Weather/Finance/Sports, Solitaire, the Office promo hub, Groove"
    $lines += "Music, Movies & TV, Skype, Get Help, Tips, Mobile Plans, Wallet, Feedback Hub, To Do,"
    $lines += "Power Automate Desktop, Clipchamp, consumer Teams, Phone Link, Paint 3D, 3D Viewer,"
    $lines += "Mail and Calendar, Voice Recorder, Alarms & Clock, Dev Home, Family Safety, Network"
    $lines += "Speed Test, Cross Device Experience Host, the new Outlook app, Journal, plus common"
    $lines += "OEM promo tiles (Spotify/Facebook/Instagram/TikTok/Disney/Netflix) if present - and"
    $lines += "the Xbox app, Game Bar overlay, Xbox Identity Provider, TCUI, and speech-to-text"
    $lines += "overlay (background game-recording/overlay hooking has a real FPS cost; use"
    $lines += "'Reinstall Xbox App' if a client needs Game Pass/cloud gaming back)."
    $lines += ""
    $lines += "Also uninstalls OneDrive as part of this same action (its own 'Restore OneDrive'"
    $lines += "button puts it back)."
    $lines += ""
    $lines += "Deliberately NOT included: Microsoft GameInput (breaks some controller support), the"
    $lines += "Remote Desktop client, Sticky Notes, Calculator, Camera, Snipping Tool, Store, Photos,"
    $lines += "Paint, Notepad, or anything touching shell/Start menu components - all real"
    $lines += "functionality, not bloat."
    $lines += ""
    $lines += "There's no single 'restore all' button for the app list - removed apps aren't easily"
    $lines += "un-removed in bulk. If a client wants any of them back, reinstall that one app from"
    $lines += "the Microsoft Store."
    return $lines -join "`n"
}

function Get-XboxReinstallText {
    $lines = @()
    $lines += "=== Reinstall Xbox App ==="
    $lines += "Puts back the Xbox app (Game Pass, cloud gaming, Xbox sign-in) after 'Remove"
    $lines += "Bloatware' took it out. Tries to re-register it from files still on this PC first"
    $lines += "(instant); if those are gone, opens its Microsoft Store page to reinstall fresh."
    return $lines -join "`n"
}

function Get-OneDriveText {
    $lines = @()
    $lines += "=== OneDrive ==="
    $isInstalled = [bool](Get-Process -Name OneDrive -ErrorAction SilentlyContinue) -or (Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe")
    $lines += "  Current state: $(if ($isInstalled) { 'Installed' } else { 'Not installed' })"
    $lines += ""
    $lines += "Uses Microsoft's own official uninstaller flag (OneDriveSetup.exe -uninstall) rather"
    $lines += "than deleting files directly, and cleans up its scheduled tasks. Restore re-runs the"
    $lines += "same official installer without the flag - both are Microsoft's own supported"
    $lines += "mechanism, not a custom removal."
    return $lines -join "`n"
}

function Get-ProcessCountText {
    $lines = @()
    $lines += "=== Process Count Check ==="
    $count = (Get-Process).Count
    $lines += "  Current running processes: $count"
    $lines += ""
    $lines += "Lower is better - fewer background processes generally means less CPU/RAM overhead"
    $lines += "competing with games. As a rough guide:"
    $lines += "  - Under ~150: normal for a clean gaming PC"
    $lines += "  - 150-200: still reasonable, worth a quick look at what's running"
    $lines += "  - Above 200: usually a sign of real background bloat worth investigating - try"
    $lines += "    'Disable Unneeded Services' below, or Remove Bloatware above if it hasn't been"
    $lines += "    run yet"
    $lines += ""
    $lines += "Opening Task Manager - sort the Processes tab by CPU or Memory to spot anything"
    $lines += "unexpected using resources at idle."
    return $lines -join "`n"
}

function Get-ServicesText {
    $lines = @()
    $lines += "=== Disable Unneeded Services ==="
    $lines += "Stops and disables a curated set of background Windows services most gaming PCs"
    $lines += "don't need running:"
    $lines += "  - SysMain (Superfetch) - a caching service designed for hard drives; on an SSD"
    $lines += "    (virtually all modern gaming PCs) it mostly just adds background disk/CPU"
    $lines += "    activity for little benefit"
    $lines += "  - Connected User Experiences and Telemetry (DiagTrack) - diagnostic data"
    $lines += "    collection, no effect on functionality if disabled"
    $lines += "  - Windows Error Reporting Service (WerSvc) - only affects whether crash reports"
    $lines += "    get submitted to Microsoft, not whether apps crash"
    $lines += "  - Retail Demo Service (RetailDemo) - store-kiosk demo mode, never needed on a"
    $lines += "    personal PC"
    $lines += "  - Downloaded Maps Manager (MapsBroker) - only matters for offline Maps app use"
    $lines += ""
    $lines += "Deliberately NOT touched: Print Spooler (breaks printing if the client has a"
    $lines += "printer) and Windows Search/WSearch (disabling breaks Start menu search - the"
    $lines += "process-count savings aren't worth that trade-off)."
    return $lines -join "`n"
}

function Get-ServicesState {
    # true = already trimmed (all 5 curated services currently disabled)
    $services = @('SysMain', 'DiagTrack', 'WerSvc', 'RetailDemo', 'MapsBroker')
    foreach ($svcName in $services) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.StartType -ne 'Disabled') { return $false }
    }
    return $true
}

function Get-GameBarText {
    $lines = @()
    $lines += "=== Game Bar ==="
    $current = (Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -ErrorAction SilentlyContinue).AppCaptureEnabled
    $lines += "  Current state: $(if ($current -eq 0) { 'Disabled' } else { 'Enabled (Windows default)' })"
    $lines += ""
    $lines += "Disables the Xbox Game Bar overlay (Win+G) and background game recording (Game DVR) -"
    $lines += "a lighter-weight alternative to fully removing the Xbox app in the Debloat tab, for"
    $lines += "when the app itself should stay (e.g. Game Pass) but the background overlay/recording"
    $lines += "shouldn't. That overlay hooking has a real measurable FPS cost."
    return $lines -join "`n"
}

function Get-GameBarState {
    $current = (Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -ErrorAction SilentlyContinue).AppCaptureEnabled
    return ($current -ne 0)
}

function Get-SoundDevicesText {
    $lines = @()
    $lines += "=== Sound Devices ==="
    $lines += "Opening the Sound control panel (Playback/Recording tabs). Check for:"
    $lines += "  - Unused playback devices (e.g. a 'Monitor'/HDMI passthrough speaker left as default"
    $lines += "    when the client actually uses separate speakers or headphones)"
    $lines += "  - Wrong default microphone (e.g. a webcam's built-in mic set as default instead of a"
    $lines += "    dedicated headset/mic)"
    $lines += "  - Leftover duplicate/disconnected devices from old hardware"
    $lines += ""
    $lines += "Right-click a device in the list to disable it or set it as default."
    return $lines -join "`n"
}

function Get-NetworkBindingsText {
    $lines = @()
    $lines += "=== Network Adapter Bindings (IPv4-only) ==="
    $lines += "Disables everything except IPv4 on physical Ethernet adapters - IPv6, File and"
    $lines += "Printer Sharing, Client for Microsoft Networks, QoS Packet Scheduler, Link-Layer"
    $lines += "Topology Discovery (Mapper/Responder), Network Adapter Multiplexor Protocol, and LLDP."
    $lines += "None of these matter for a gaming PC that's just connecting to the internet - trims a"
    $lines += "small amount of per-packet overhead and simplifies the adapter's protocol stack."
    $lines += ""
    $lines += "Only touches physical Ethernet adapters - WiFi and any virtual adapters (VPN,"
    $lines += "Hyper-V, etc.) are left alone."
    return $lines -join "`n"
}

function Get-NetworkBindingsState {
    # true = IPv4-only already applied, checked against the first physical Ethernet adapter found
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match 'Ethernet|802.3' } | Select-Object -First 1
    if (-not $adapter) { return $false }
    $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue
    return ($binding -and -not $binding.Enabled)
}

function Get-PowerPlanText {
    $lines = @()
    $lines += "=== Ultimate Performance Power Plan ==="
    try {
        $current = (& powercfg -getactivescheme) -join ' '
        $lines += "  Current: $current"
    } catch {
        $lines += "  Could not read the current power plan."
    }
    $lines += ""
    $lines += "Ultimate Performance is a hidden Windows power plan (not shown by default, even on Pro"
    $lines += "editions) that disables more aggressive power-saving/core-parking than even 'High"
    $lines += "Performance' - marginally more consistent performance at the cost of higher idle power"
    $lines += "draw and heat."
    $lines += ""
    $lines += "'Set Ultimate Power Plan' activates it, then deletes every other plan on this PC -"
    $lines += "Windows won't allow deleting the currently-active plan, so activating first is"
    $lines += "required before the others can be removed. 'Reset Power Plans' uses Windows' own"
    $lines += "'powercfg -restoredefaultschemes' to bring back the normal Balanced/Power Saver/High"
    $lines += "Performance set."
    return $lines -join "`n"
}

function Get-CleanupText {
    $lines = @()
    $lines += "=== System Cleanup ==="
    $lines += "Clears:"
    $lines += '  - User and Windows temp folders ($env:TEMP, $env:SystemRoot\Temp)'
    $lines += "  - Windows Update's downloaded installer cache (SoftwareDistribution\Download -"
    $lines += "    Windows re-downloads whatever it needs for future updates)"
    $lines += "  - Recycle Bin"
    $lines += ""
    $lines += "All standard, Windows-regenerates-as-needed cleanup - nothing here touches documents,"
    $lines += "browser data, or anything the client would notice missing besides freed disk space."
    $lines += "Some in-use files may be skipped (locked by a running app) - the freed-space total is"
    $lines += "an estimate, not an exact figure."
    return $lines -join "`n"
}

function Get-DiskCleanupText {
    $lines = @()
    $lines += "=== Open Disk Cleanup ==="
    $lines += "NOT a broader alternative to System Cleanup - the two genuinely overlap on temp files"
    $lines += "and the Windows Update cache, so running this right after System Cleanup won't find"
    $lines += "much there. The actual reason to open this is for categories System Cleanup doesn't"
    $lines += "touch at all:"
    $lines += "  - DirectX Shader Cache"
    $lines += "  - Delivery Optimization Files"
    $lines += "  - Device Driver Packages (old/superseded driver versions Windows kept)"
    $lines += "  - Previous Windows installation(s) (Windows.old)"
    $lines += ""
    $lines += "IMPORTANT: 'Previous Windows installation(s)' (Windows.old), if checked, removes it"
    $lines += "PERMANENTLY - that's what lets Windows roll back a recent feature update. Only check"
    $lines += "that box if there's no need to ever revert this update."
    $lines += ""
    $lines += "Everything else in this tool is safe, standard Windows-regenerates-as-needed cleanup."
    return $lines -join "`n"
}

function Get-StartupAppsText {
    $lines = @()
    $lines += "=== Startup Apps ==="
    try {
        $items = Get-CimInstance Win32_StartupCommand | Select-Object -ExpandProperty Name -Unique
        if ($items) {
            $lines += "  Currently registered to launch at boot/login:"
            foreach ($i in $items) { $lines += "    - $i" }
        } else {
            $lines += "  No startup items found via WMI."
        }
    } catch {
        $lines += "  Could not enumerate startup items via WMI."
    }
    $lines += ""
    $lines += "  (This list may be incomplete - some apps register via Task Scheduler"
    $lines += "  instead, which WMI doesn't see. The Settings page below is authoritative.)"
    $lines += ""
    $lines += "Opening Windows Settings > Apps > Startup."
    $lines += "Disable anything the client doesn't need running at every boot - fewer"
    $lines += "startup apps means a faster boot and less background resource use."
    return $lines -join "`n"
}

function Get-CpuStressCheckText {
    $lines = @()
    $lines += "=== CPU Stress Test (OCCT) ==="
    $lines += "Have HWiNFO's Sensors window open alongside this to watch temps live."
    $lines += ""
    $lines += "During the test, watch for:"
    $lines += "  - Sustained temps approaching the CPU's rated throttle point"
    $lines += "  - Thermal throttling (clock speed dropping under sustained load)"
    $lines += "  - Any crash, freeze, reboot, or BSOD - stop immediately, that's instability"
    $lines += "  - VRM / motherboard temps, if HWiNFO shows them"
    $lines += ""
    $lines += "Recommended: run at least 10-15 minutes for a meaningful stability read."
    return $lines -join "`n"
}

function Get-GpuStressCheckText {
    $lines = @()
    $lines += "=== GPU Stress Test (Heaven + MSI Afterburner) ==="
    $lines += "Use Afterburner alongside Heaven for overclocking and monitoring:"
    $lines += "  - Set a manual core/memory clock offset in Afterburner before running Heaven"
    $lines += "  - Turn on Afterburner's on-screen display (OSD) to watch clocks/temps/voltage/"
    $lines += "    fan speed live during the run"
    $lines += ""
    $lines += "During the test, watch for:"
    $lines += "  - Visual artifacts (flickering, corrupted textures) - back off the OC if seen"
    $lines += "  - Crashes, driver resets, or a black screen"
    $lines += "  - GPU temp and hotspot temp staying in a safe range"
    $lines += "  - Clock speed holding steady, not throttling unexpectedly"
    $lines += ""
    $lines += "Recommended: one full Heaven loop (~10-15 min) per OC step before pushing further."
    return $lines -join "`n"
}

Export-ModuleMember -Function Get-SystemHeaderText, Get-StorageCheckText, Get-RamSummaryText, Get-GpuSummaryText, Get-DduCheckText, Get-DriverUpdateCheckText, Get-SafeModeCheckText, Get-TempsCheckText, Get-BiosCheckText, Get-BiosSettingsCheckText, Get-GpuP0StateText, Get-GpuP0State, Get-DisplaySettingsCheckText, Get-HagsCheckText, Get-NvidiaProfileInspectorText, Get-TaskbarStartText, Get-TaskbarAlignmentText, Get-TaskbarAlignmentState, Get-ContextMenuText, Get-ContextMenuState, Get-ThemeText, Get-ThemeState, Get-AccentColorText, Get-RestartExplorerText, Get-WidgetsText, Get-WidgetsState, Get-CopilotText, Get-CopilotState, Get-MouseAccelText, Get-MouseAccelState, Get-GameModeText, Get-BloatwareText, Get-OneDriveText, Get-XboxReinstallText, Get-ProcessCountText, Get-ServicesText, Get-ServicesState, Get-GameBarText, Get-GameBarState, Get-SoundDevicesText, Get-NetworkBindingsText, Get-NetworkBindingsState, Get-PowerPlanText, Get-CleanupText, Get-DiskCleanupText, Get-StartupAppsText, Get-CpuStressCheckText, Get-GpuStressCheckText
