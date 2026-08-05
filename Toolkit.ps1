<#
    PC Tweaks Toolkit - GUI shell
    -----------------------------
    Checklist-style companion to Debloat-Windows.ps1 / Update-GPU-Driver.ps1.
    Starts with a "PC Check" section: storage, RAM, GPU.

    Third-party utilities are never auto-downloaded from a hardcoded URL. Each
    button opens that tool's OFFICIAL vendor download page the first time it's
    needed; for the portable ones you save the .exe once into .\Tools\, and every
    future click on every client PC just launches that same verified copy.
      CPU-Z       -> https://www.cpuid.com/softwares/cpu-z.html              (CPUID, developer)
      GPU-Z       -> https://www.techpowerup.com/download/techpowerup-gpu-z/ (TechPowerUp, developer)
      HWiNFO      -> https://www.hwinfo.com/download/                        (REALiX s.r.o., developer)
      OCCT        -> https://www.ocbase.com/download                         (OCBASE, developer)
      Heaven      -> https://benchmark.unigine.com/heaven                    (Unigine, developer)
      MSI Afterburner -> https://www.msi.com/Landing/afterburner/graphics-cards (MSI, developer)

    OCCT/Heaven/Afterburner are not simple standalone exes like the first three -
    Afterburner installs a driver + background service, and the other two are
    normally full installers. The Tools-folder cache still applies if you can get
    a portable copy; otherwise these get installed like normal software.

    Branding: drop a logo file at .\Assets\logo.png (or logo.ico) and it will
    automatically be used as the window icon and header image next run.
#>

[CmdletBinding()]
param()

function Assert-Admin {
    # Elevates the WHOLE app once at launch rather than per-action. With real
    # system-modifying actions now in the app (Safe Mode toggling, more planned),
    # one UAC prompt at startup is simpler and more reliable than re-elevating on
    # every click - especially over remote-support tools (AnyDesk etc.) where each
    # extra secure-desktop UAC prompt is another chance for the prompt to not be
    # interactable. No -NoExit here - the elevated relaunch should close cleanly.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        # The heads-up below is ours to skip on repeat launches - persisted per
        # Windows user account via HKCU (never needs elevation to read/write,
        # and naturally starts fresh on every new machine/profile, client PCs
        # included). The native Windows UAC Yes/No prompt right after it is a
        # separate OS-level thing and can't be silenced the same way without a
        # scheduled-task workaround - not worth it for a one-click savings and
        # not something to bake into a tool that avoids permanent system changes.
        $noticeKey = 'HKCU:\Software\PCTweaksToolkit'
        $alreadyShown = (Get-ItemProperty -Path $noticeKey -Name 'AdminNoticeShown' -ErrorAction SilentlyContinue).AdminNoticeShown
        if (-not $alreadyShown) {
            [System.Windows.Forms.MessageBox]::Show(
                "This tool needs Administrator rights to manage system settings (Safe Mode toggling, driver cleanup, etc).`n`nClick OK, then choose Yes on the Windows prompt that follows.`n`n(This explanation only shows once - future launches go straight to the Windows prompt.)",
                "Administrator Required",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            New-Item -Path $noticeKey -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $noticeKey -Name 'AdminNoticeShown' -Value 1
        }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        exit
    }
}

# Without this, Windows applies legacy DPI virtualization to non-DPI-aware
# apps on scaled displays (125%/150%/etc) - it bitmap-stretches the whole
# window afterward, which is what makes controls look oversized/clipped/
# misaligned instead of matching the pixel sizes set below.
Add-Type @"
using System.Runtime.InteropServices;
public class DpiHelper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
"@
[DpiHelper]::SetProcessDPIAware() | Out-Null

# Lets us ask DWM to render the native title bar dark, matching the app -
# otherwise Windows draws it in the system light-theme white regardless of
# our own colors, which looks like a mismatched strip at the top.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DwmHelper {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
"@

# Hides this script's own console window regardless of how it was launched
# (double-click, right-click "Run with PowerShell", a shortcut, etc.) - without
# this, the console that hosts powershell.exe stays visible behind the GUI for
# the whole session, since Application.Run blocks until the window is closed.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ConsoleHelper {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
$consoleHandle = [ConsoleHelper]::GetConsoleWindow()
if ($consoleHandle -ne [IntPtr]::Zero) {
    [ConsoleHelper]::ShowWindow($consoleHandle, 0) | Out-Null  # SW_HIDE
}

# Mouse acceleration ("Enhance pointer precision") is stored in the registry, but Windows only
# picks up a changed value for newly-started processes/after sign-in unless the input subsystem
# is explicitly told via SystemParametersInfo(SPI_SETMOUSE) - the same call Control Panel's own
# Mouse applet makes when you click Apply. Without this, the button would need a sign-out to work.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MouseHelper {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, int[] pvParam, uint fWinIni);
}
"@
$script:SPI_SETMOUSE = 0x0004
$script:SPIF_SENDCHANGE = 0x2

# Reads the display's current default ICC profile for the Tarkov LUT toggle. GetICMProfileW is
# the only reliable read path found (confirmed live against Windows' own Color Management
# dialog) - WcsGetDefaultColorProfile and AssociateColorProfileWithDevice were both tested and
# ruled out for plain SDR displays (see PLAN.md for the full investigation). Installing the
# profile itself is a plain file copy, not InstallColorProfileW (that API rejects this specific
# file with ERROR_INVALID_PARAMETER, confirmed live both elevated and not - see the OnAction
# below). The actual default-profile write is a direct edit to the ICM ProfileAssociations
# registry list, done inline in the tile's OnAction/OffAction further down.
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class IcmHelper {
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateDCW(string pwszDriver, string pwszDevice, string pszPort, IntPtr pdm);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool GetICMProfileW(IntPtr hdc, ref uint pBufSize, StringBuilder pszFilename);
}
"@
$script:MonitorProfileAssociationsKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\ICM\ProfileAssociations\Display\{4d36e96e-e325-11ce-bfc1-08002be10318}'
$script:TarkovLutFileName = 'Filter EFT brighter.icm'
$script:ColorProfileDir = Join-Path $env:WINDIR 'System32\spool\drivers\color'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Assert-Admin

# If this folder was downloaded (e.g. extracted from a zip sent over Discord),
# every file in it carries a "Mark of the Web" flag that makes Windows show a
# SmartScreen warning the first time each one runs. Getting past that warning
# for Toolkit.ps1 itself is unavoidable (only Microsoft's reputation service
# or a paid code-signing cert prevents it, neither is realistic here) - but
# once the user is past THAT one prompt, strip the flag from every sibling
# file so none of the cached tools in Tools\ ever show that warning on their own.
try {
    Get-ChildItem -Path $PSScriptRoot -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
} catch { }

# Both modules' functions reference System.Windows.Forms/System.Drawing types
# in their param blocks, so they must be imported AFTER the Add-Type calls above.
Import-Module (Join-Path $PSScriptRoot 'SystemInfo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ExternalTools.psm1') -Force

$ToolsDir = Join-Path $PSScriptRoot 'Tools'
if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir | Out-Null }
$readmePath = Join-Path $ToolsDir 'README.txt'
if (-not (Test-Path $readmePath)) {
    @'
Drop portable tool .exe files here so the Toolkit can launch them instantly
on every client PC without redownloading. Get each one ONCE from its
official vendor site (never a third-party mirror):

  CPU-Z  -> https://www.cpuid.com/softwares/cpu-z.html
            That page has TWO options - grab the "Portable/ZIP" one, NOT
            "Setup" (Setup installs to Program Files, which is not what
            we want here). Extract the zip, save cpuz_x64.exe here.

  GPU-Z  -> https://www.techpowerup.com/download/techpowerup-gpu-z/
            Downloads as a versioned filename (e.g. GPU-Z.2.70.0.exe) -
            rename it to: GPU-Z.exe

  HWiNFO -> https://www.hwinfo.com/download/
            Download the portable ZIP, extract, save as: HWiNFO64.exe

  OCCT, Heaven Benchmark, and MSI Afterburner (Stress Test tab) follow the
  exact same manual download-and-place process as everything above. The
  only difference: they aren't self-contained standalone exes, so launching
  the cached copy runs a real installer step per client PC (Heaven and
  Afterburner) rather than opening the tool directly - Afterburner's
  installer additionally installs a driver + background service.
    OCCT             -> https://www.ocbase.com/download
                        Save as: OCCT.exe
    Heaven Benchmark -> https://benchmark.unigine.com/heaven
                        Downloads as a versioned filename (e.g.
                        Unigine_Heaven-4.0.exe) - rename to: Heaven-Setup.exe
    MSI Afterburner  -> https://www.msi.com/Landing/afterburner/graphics-cards
                        Downloads as a zip - extract the installer inside and
                        rename it to: MSIAfterburnerSetup.exe

  DDU (Graphics tab) -> https://www.wagnardsoft.com/
                        Ships as a self-extracting archive, not a single exe -
                        run the download once, extract it into a subfolder
                        here named exactly: DDU
                        (so the result is Tools\DDU\Display Driver Uninstaller.exe
                        alongside its other extracted files, which it needs).

  NVIDIA Profile Inspector (Graphics tab, "Apply/Reset NVIDIA Settings")
                     -> https://github.com/Orbmu2k/nvidiaProfileInspector/releases
                        Downloads as a zip - extract ALL of its contents
                        (nvidiaProfileInspector.exe, Reference.xml, and the
                        rest) into a subfolder here named exactly:
                        ProfileInspector
                        (so the result is Tools\ProfileInspector\nvidiaProfileInspector.exe
                        alongside its other extracted files, which it needs).

Note: each portable tool writes its own .ini settings file next to itself
the first time it runs (e.g. cpuz.ini, HWiNFO64.INI). That's normal portable-
app behavior, not client data - safe to delete before handing this folder
off, and it'll just get recreated fresh on the next PC.
'@ | Set-Content -Path $readmePath -Encoding UTF8
}

$AssetsDir = Join-Path $PSScriptRoot 'Assets'
if (-not (Test-Path $AssetsDir)) { New-Item -ItemType Directory -Path $AssetsDir | Out-Null }

# Get-SystemHeaderText, Get-StorageCheckText, Get-RamSummaryText, Get-GpuSummaryText,
# Get-TempsCheckText, Get-CpuStressCheckText, Get-GpuStressCheckText -> SystemInfo.psm1
# Invoke-ExternalTool, Write-ToolOutput, Invoke-Safe -> ExternalTools.psm1

function Get-LogoImage {
    foreach ($name in @('logo.png', 'logo.jpg', 'logo.bmp')) {
        $p = Join-Path $AssetsDir $name
        if (Test-Path $p) {
            try { return [System.Drawing.Image]::FromFile($p) } catch { return $null }
        }
    }
    return $null
}

function Get-LogoIcon {
    $icoPath = Join-Path $AssetsDir 'logo.ico'
    if (Test-Path $icoPath) {
        try { return New-Object System.Drawing.Icon($icoPath) } catch { return $null }
    }
    $img = Get-LogoImage
    if ($img) {
        try {
            $bmp = New-Object System.Drawing.Bitmap($img, 32, 32)
            return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        } catch { return $null }
    }
    return $null
}

function Get-PrimaryGpuVendor {
    # Best-effort: prefer a discrete GPU over an integrated one when both are
    # present (e.g. an AMD iGPU alongside a discrete NVIDIA card) - that's the
    # one driver updates actually matter for. Returns 'NVIDIA', 'AMD', 'Intel', or $null.
    $all = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic Render|Remote Display|Virtual' })
    if (-not $all) { return $null }
    $discrete = $all | Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX|GTX|Quadro|Radeon RX|Radeon Pro|Radeon VII|FirePro' }
    $primary = if ($discrete) { $discrete | Select-Object -First 1 } else { $all | Select-Object -First 1 }
    if ($primary.Name -match 'NVIDIA|GeForce|RTX|GTX|Quadro') { return 'NVIDIA' }
    if ($primary.Name -match 'AMD|Radeon|ATI') { return 'AMD' }
    if ($primary.Name -match 'Intel') { return 'Intel' }
    return $null
}

function Invoke-LegacyNvidiaControlPanel {
    # Store app, not a Tools\-cached exe - a different acquisition path than
    # Invoke-ExternalTool's on purpose (winget/Microsoft Store, not a manual
    # download-and-place). Never blocks the UI thread on the winget install
    # itself (same class of risk as Start-Service/bulk-delete elsewhere in
    # this app) - installs in its own visible window and asks the tech to
    # click again once it finishes, matching the "click again" convention
    # every not-yet-cached tool in this app already uses.
    param([System.Windows.Forms.RichTextBox]$OutputBox)
    $aumid = 'NVIDIACorp.NVIDIAControlPanel_56jybvy8sckqj!NVIDIACorp.NVIDIAControlPanel'
    $pkg = Get-AppxPackage -Name 'NVIDIACorp.NVIDIAControlPanel' -ErrorAction SilentlyContinue
    if ($pkg) {
        Write-ToolOutput $OutputBox "Launching Legacy NVIDIA Control Panel..."
        # Start-Process "shell:appsFolder\..." directly resolves via COM activation inside
        # THIS (elevated) process, which Windows' AppModel security silently refuses for
        # packaged/UWP apps - no exception, it just never opens. Routing through explorer.exe
        # instead forwards the activation request to its own already-running, non-elevated
        # shell instance, which Store apps are allowed to activate from.
        Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:appsFolder\$aumid"
        return
    }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Write-ToolOutput $OutputBox "Legacy NVIDIA Control Panel isn't installed - installing via winget (Microsoft Store) in its own window..."
        Start-Process -FilePath 'winget.exe' -ArgumentList 'install --id 9NF8H0H7WMLT --source msstore --accept-package-agreements --accept-source-agreements'
        [System.Windows.Forms.MessageBox]::Show(
            "Installing Legacy NVIDIA Control Panel via winget in a separate window - this can take a minute depending on the connection.`n`nOnce it finishes, click this button again (or re-run Apply/Reset NVIDIA Settings) to launch it.",
            "Installing NVIDIA Control Panel",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } else {
        Write-ToolOutput $OutputBox "winget isn't available on this PC - opening the Microsoft Store listing page instead."
        Start-Process 'https://apps.microsoft.com/detail/9NF8H0H7WMLT'
        [System.Windows.Forms.MessageBox]::Show(
            "winget isn't available on this PC.`n`nThe Microsoft Store listing for Legacy NVIDIA Control Panel just opened - install it from there, then click this button again to launch it.",
            "NVIDIA Control Panel Not Found",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
}

# Tarkov LUT toggle helpers. GetICMProfileW (via a real HDC for the display) is the only
# reliable way found to read a display's current default ICC profile - confirmed live against
# Windows' own Color Management dialog. The write path is a direct edit to the ICM
# ProfileAssociations registry list (the exact list Color Management itself shows/edits under
# "Profiles associated with this device") - NOT WcsAssociateColorProfileWithDevice (fails with
# ERROR_NOT_SUPPORTED on real hardware, both elevated and not) and NOT SetICMProfileW (the write
# call reports success but doesn't persist past its own DC). The LAST entry in that REG_MULTI_SZ
# list is the default - confirmed by matching list order against what the GUI displays as
# "(default)". Whether a plain registry write alone causes a live visual change is NOT reliable
# (confirmed by direct testing: GetICMProfileW reflects the change immediately, but the screen
# does not always follow) - SetDeviceGammaRamp could force it, but Microsoft's own docs strongly
# discourage that API (silent-failure heuristics, gets reset on any display event, undefined in
# HDR), so it's deliberately not used here. See PLAN.md for the full investigation.
function Get-TarkovLutAdapterName {
    return [System.Windows.Forms.Screen]::PrimaryScreen.DeviceName
}

function Get-TarkovLutCurrentProfileLeaf {
    $hdc = [IcmHelper]::CreateDCW("DISPLAY", (Get-TarkovLutAdapterName), $null, [IntPtr]::Zero)
    if ($hdc -eq [IntPtr]::Zero) { return $null }
    [uint32]$size = 512
    $buf = New-Object System.Text.StringBuilder(512)
    $ok = [IcmHelper]::GetICMProfileW($hdc, [ref]$size, $buf)
    [IcmHelper]::DeleteDC($hdc) | Out-Null
    if (-not $ok) { return $null }
    return Split-Path $buf.ToString() -Leaf
}

function Get-TarkovLutState {
    return ((Get-TarkovLutCurrentProfileLeaf) -ieq $script:TarkovLutFileName)
}

function Find-TarkovLutInstanceKey {
    # Not hardcoded to any one numbered subkey (that number is specific to each PC's own device
    # enumeration history) - finds the right one generically by matching which key's profile list
    # currently ENDS with the live current-default filename, confirmed working across two
    # differently-numbered instances (0002 vs 0005) on the dev machine.
    param([string]$CurrentLeaf)
    if (-not $CurrentLeaf) { return $null }
    $match = $null
    Get-ChildItem $script:MonitorProfileAssociationsKey -ErrorAction SilentlyContinue | ForEach-Object {
        $val = (Get-ItemProperty -Path $_.PSPath -Name 'ICMProfile' -ErrorAction SilentlyContinue).ICMProfile
        if ($val -and $val[-1] -ieq $CurrentLeaf -and -not $match) {
            $match = [PSCustomObject]@{ Path = $_.PSPath; Value = $val }
        }
    }
    return $match
}

# ---------- GUI ----------

# Theme token tables - two flat hashtables of Color values, one active at a time via
# $script:Theme. Color is reserved exclusively for the tier system (Adjust/Check/Review
# First); every other control reads a neutral token so switching modes is one function call
# (Set-AppTheme) rather than scattered find-and-replace. See PLAN.md "Theme redesign" for
# the mockup-review history behind these exact values (tier colors were deliberately pushed
# apart in both hue AND lightness so Adjust vs Review First stays distinguishable even under
# red-green color blindness, where hue alone collapses).
$Themes = @{
    Dark = @{
        BgWindow        = [System.Drawing.Color]::FromArgb(0x13, 0x14, 0x17)
        BgSurface       = [System.Drawing.Color]::FromArgb(0x1c, 0x1d, 0x22)
        BgSurfaceRaised = [System.Drawing.Color]::FromArgb(0x24, 0x26, 0x2b)
        BorderSubtle    = [System.Drawing.Color]::FromArgb(0x2c, 0x2e, 0x35)
        TextPrimary     = [System.Drawing.Color]::FromArgb(0xec, 0xee, 0xf2)
        TextSecondary   = [System.Drawing.Color]::FromArgb(0x92, 0x98, 0xa3)
        TextTertiary    = [System.Drawing.Color]::FromArgb(0x79, 0x7f, 0x8a)
        TierAdjust      = [System.Drawing.Color]::FromArgb(0xd9, 0x9a, 0x4e)
        TierCheck       = [System.Drawing.Color]::FromArgb(0x6f, 0xad, 0xd6)
        TierReview      = [System.Drawing.Color]::FromArgb(0xe0, 0x60, 0x4a)
    }
    Light = @{
        BgWindow        = [System.Drawing.Color]::FromArgb(0xf5, 0xf5, 0xf6)
        BgSurface       = [System.Drawing.Color]::FromArgb(0xff, 0xff, 0xff)
        # BgSurfaceRaised and BorderSubtle are deliberately pushed well past what a calibrated
        # reference display needs - this app's actual audience skews toward gamers running
        # digital-vibrance/saturation boosted well above default, which compresses exactly this
        # kind of subtle near-white tonal gap (confirmed not a bug on a properly calibrated
        # screen - a real, common part of the user base, not an edge case, so light mode carries
        # extra separation headroom on purpose). Dark mode doesn't get the same treatment - its
        # deep blacks and bright accents don't have this risk the same way.
        BgSurfaceRaised = [System.Drawing.Color]::FromArgb(0xd7, 0xda, 0xe0)
        BorderSubtle    = [System.Drawing.Color]::FromArgb(0xa8, 0xad, 0xb6)
        TextPrimary     = [System.Drawing.Color]::FromArgb(0x17, 0x18, 0x1c)
        TextSecondary   = [System.Drawing.Color]::FromArgb(0x55, 0x58, 0x5f)
        TextTertiary    = [System.Drawing.Color]::FromArgb(0x7c, 0x7f, 0x87)
        TierAdjust      = [System.Drawing.Color]::FromArgb(0xa8, 0x64, 0x1c)
        TierCheck       = [System.Drawing.Color]::FromArgb(0x1f, 0x6f, 0xa0)
        TierReview      = [System.Drawing.Color]::FromArgb(0xa8, 0x38, 0x24)
    }
}
$script:ThemeModeKey = 'HKCU:\Software\PCTweaksToolkit'
$savedThemeMode = (Get-ItemProperty -Path $script:ThemeModeKey -Name 'ThemeMode' -ErrorAction SilentlyContinue).ThemeMode
$script:ThemeMode = if ($savedThemeMode -eq 'Light') { 'Light' } else { 'Dark' }
$script:Theme = $Themes[$script:ThemeMode]

# Explicit registries of already-built controls that need repainting when Set-AppTheme runs -
# preferred over recursively walking the control tree (matches this project's existing
# preference for explicit state over implicit traversal, see the .Tag-over-closures rule
# elsewhere in this file / CLAUDE.md).
$script:ThemedTiles = New-Object System.Collections.Generic.List[object]
$script:ThemedChips = New-Object System.Collections.Generic.List[object]
$script:ThemedSectionHeaders = New-Object System.Collections.Generic.List[object]
# Windows Tuning-specific: one entry per section ({ Wrapper, InnerBoard }), populated by
# New-WinBoardSection. $script:CurrentSectionInnerBoard is where subsequent New-SettingsTile
# calls land - set each time a new section starts. See New-WinBoardSection/Update-WinBoardReflow
# for why the Windows board uses this manually-positioned structure instead of a flat
# FlowLayoutPanel like every other tab (PLAN.md has the full history of what didn't work first).
$script:WinBoardSections = New-Object System.Collections.Generic.List[object]
$script:CurrentSectionInnerBoard = $null

# Fixed regardless of theme mode - the output console intentionally always stays dark
# (common terminal/log-panel convention, confirmed with the user), so its header-line color
# is a constant, never swapped by Set-AppTheme. Exposed as $global: (not $script:) because
# ExternalTools.psm1's Write-ToolOutput reads it across the module boundary - a module
# function can't see this script's $script: scope, same reason the old accent globals were
# $global: too.
$global:ConsoleHeaderColor = [System.Drawing.Color]::FromArgb(0xdf, 0xe1, 0xe5)

function Get-RoundedPath {
    # Standard WinForms rounded-corner technique - GDI+ controls are rectangular by default,
    # so any rounded look needs an explicit path built from four corner arcs. Shared by every
    # Paint handler below that fills/strokes a rounded shape.
    param([int]$Width, [int]$Height, [int]$Radius)
    $d = $Radius * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($Width - $d, 0, $d, $d, 270, 90)
    $path.AddArc($Width - $d, $Height - $d, $d, $d, 0, 90)
    $path.AddArc(0, $Height - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function Add-FlatRoundedPaint {
    # Shared by every plain flat rounded control that isn't a chip/pill-switch/tile (tabs,
    # bottom-bar buttons, dialog option buttons, tile Action/Check buttons) - reads BackColor
    # and FlatAppearance.BorderColor live off the control itself (already kept correct
    # elsewhere), so only needs -Radius and -ParentColor.
    #
    # Deliberately does NOT use Control.Region for the rounded shape - Region is a hard,
    # always-aliased pixel mask in GDI+ (confirmed via live testing: chips/pill switches already
    # had SmoothingMode = AntiAlias set in their Paint handlers and still looked jagged, because
    # the REGION boundary itself was the aliased edge, not the drawing inside it - SmoothingMode
    # only affects drawing operations, never Region clipping). Instead this erases the control's
    # full rectangle back to -ParentColor first (covering the square corners a plain BackColor
    # fill would otherwise leave showing), then fills/strokes the rounded path on top with
    # anti-aliasing - a real smooth edge, not just a smoothed stroke inside a jagged clip.
    # -ParentColor travels via Add-Member (not .Tag) since several of these controls already use
    # .Tag for other bundled state.
    param([System.Windows.Forms.Control]$Control, [int]$Radius, [scriptblock]$ParentColor)
    Add-Member -InputObject $Control -NotePropertyName RoundedRadius -NotePropertyValue $Radius -Force
    Add-Member -InputObject $Control -NotePropertyName RoundedParentColor -NotePropertyValue $ParentColor -Force
    $Control.Add_Paint({
        param($ctrl, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $eraseBrush = New-Object System.Drawing.SolidBrush((& $ctrl.RoundedParentColor))
        $g.FillRectangle($eraseBrush, 0, 0, $ctrl.Width, $ctrl.Height)
        $eraseBrush.Dispose()
        $path = Get-RoundedPath -Width $ctrl.Width -Height $ctrl.Height -Radius $ctrl.RoundedRadius
        $fillBrush = New-Object System.Drawing.SolidBrush($ctrl.BackColor)
        $g.FillPath($fillBrush, $path)
        $fillBrush.Dispose()
        if ($ctrl.FlatAppearance.BorderSize -gt 0) {
            $pen = New-Object System.Drawing.Pen($ctrl.FlatAppearance.BorderColor, 1)
            $g.DrawPath($pen, $path)
            $pen.Dispose()
        }
        $path.Dispose()
        # A Button's own default renderer draws its Text BEFORE the Paint event fires - the
        # erase-and-fill above was painting straight over that already-rendered text (confirmed
        # live: every tab/chip/button rendered as a blank shape with no visible text). Has to be
        # drawn again here, on top of the new background, or it never appears at all.
        $textFlags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
        [System.Windows.Forms.TextRenderer]::DrawText($g, $ctrl.Text, $ctrl.Font, (New-Object System.Drawing.Rectangle(0, 0, $ctrl.Width, $ctrl.Height)), $ctrl.ForeColor, $textFlags)
    })
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "PC Tweaks Toolkit"
$form.Size = New-Object System.Drawing.Size(860, 900)
$form.StartPosition = "CenterScreen"
$form.BackColor = $script:Theme.BgWindow
$form.ForeColor = $script:Theme.TextPrimary
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $true
$form.MinimumSize = New-Object System.Drawing.Size(700, 620)

$logoIcon = Get-LogoIcon
if ($logoIcon) { $form.Icon = $logoIcon }

$headerY = 12
$logoImg = Get-LogoImage
if ($logoImg) {
    $logoBox = New-Object System.Windows.Forms.PictureBox
    $logoBox.Image = $logoImg
    $logoBox.SizeMode = 'Zoom'
    $logoBox.Size = New-Object System.Drawing.Size(40, 40)
    $logoBox.Location = New-Object System.Drawing.Point(15, $headerY)
    $form.Controls.Add($logoBox)
    $textX = 65
} else {
    $textX = 15
}

$headerLabel = New-Object System.Windows.Forms.Label
$headerLabel.Text = Get-SystemHeaderText
$headerLabel.AutoSize = $false
# Width leaves room for the theme toggle (starts at X=725, see below) regardless of whether
# $textX is 65 (logo present) or 15 (no logo) - was a fixed 770 before the toggle existed,
# which overlapped it.
$headerLabel.Size = New-Object System.Drawing.Size((715 - $textX), 20)
$headerLabel.Location = New-Object System.Drawing.Point($textX, $headerY)
$headerLabel.ForeColor = $script:Theme.TextSecondary
$headerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$headerLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($headerLabel)

# Neutral hairline, replacing the old purple -> orange gradient bar - color is reserved for
# the tier system now, so this is just a flat BorderSubtle-colored rule under the header
# (sits below the logo/header row - the logo box is 40px tall starting at $headerY, so this
# must start at or after $headerY + 40 to avoid drawing over it). Reads $script:Theme live at
# paint time, so Set-AppTheme only needs to call .Invalidate() to repaint it on mode switch.
$accentBar = New-Object System.Windows.Forms.Panel
$accentBar.Location = New-Object System.Drawing.Point(15, 59)
$accentBar.Size = New-Object System.Drawing.Size(830, 1)
$accentBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$accentBar.Add_Paint({
    param($barControl, $e)
    $brush = New-Object System.Drawing.SolidBrush($script:Theme.BorderSubtle)
    $e.Graphics.FillRectangle($brush, 0, 0, $barControl.Width, $barControl.Height)
    $brush.Dispose()
})
$form.Controls.Add($accentBar)

# App-level Light/Dark toggle (goal: a real UI theme, not just the separate "Windows Dark
# Mode" feature tile). Reuses the same neutral pill-switch look as toggle tiles - Get-TierColor/
# Add-PillSwitchPaint/Set-AppTheme are defined further below (before any board/tile
# construction, same "define before call site" rule as every other helper here), so this
# control's actual wiring happens right before $splitContainer is built, later in the file,
# even though it's visually anchored in the header row.
$themeToggleLabel = New-Object System.Windows.Forms.Label
$themeToggleLabel.AutoSize = $false
$themeToggleLabel.Size = New-Object System.Drawing.Size(50, 16)
$themeToggleLabel.Location = New-Object System.Drawing.Point(725, ($headerY + 2))
$themeToggleLabel.TextAlign = 'MiddleRight'
$themeToggleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Bold)
$themeToggleLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($themeToggleLabel)

$themeToggle = New-Object System.Windows.Forms.Button
$themeToggle.Size = New-Object System.Drawing.Size(40, 20)
$themeToggle.Location = New-Object System.Drawing.Point(780, ($headerY + 1))
$themeToggle.FlatStyle = 'Flat'
$themeToggle.FlatAppearance.BorderSize = 0
$themeToggle.Text = ''
$themeToggle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($themeToggle)

# Custom "tab strip" built from two plain buttons instead of a real TabControl -
# WinForms TabControl headers fight our owner-draw and keep rendering native
# OS-themed (white) chrome underneath; buttons + panels we fully control instead.
function New-SectionButton {
    param([string]$Text, [int]$X)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Size = New-Object System.Drawing.Size(150, 28)
    $btn.Location = New-Object System.Drawing.Point($X, 68)
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    Add-FlatRoundedPaint -Control $btn -Radius 6 -ParentColor { $script:Theme.BgWindow }
    $form.Controls.Add($btn)
    return $btn
}
$btnSectionCheck = New-SectionButton -Text "PC Check" -X 15
$btnSectionStress = New-SectionButton -Text "Stress Test" -X 165
$btnSectionWindows = New-SectionButton -Text "Windows" -X 315
$btnSectionGraphics = New-SectionButton -Text "Graphics" -X 465

# --- Windows Tuning tile system -------------------------------------------------------------
# Replaces the old nested sub-tab switcher (Startup/Taskbar/Theme/etc as separate clickable
# panels) with a single scrollable board of "tiles", one per setting, color-coded by what the
# setting actually does rather than which feature group it lives in:
#   Adjust        (orange) - a fully reversible toggle or one-shot safe action
#   Check         (blue)   - read-only, changes nothing
#   Review First  (amber)  - has a permanent/irreversible side effect
# Toggle-type tiles read real current state via a -GetState scriptblock and repaint themselves
# after every click (never assume the write succeeded) - see PLAN.md for the full tier
# classification and the "Adjust always means fully reversible" rule that drove it.

function Get-TierColor {
    # The one place tier -> color is decided, so both tile construction and Set-AppTheme's
    # repaint sweep derive the exact same value from $script:Theme. Anything that isn't a real
    # tier (e.g. the "All" filter chip) falls through to a neutral tertiary text color.
    param([string]$Tier)
    switch ($Tier) {
        'Adjust' { return $script:Theme.TierAdjust }
        'Check'  { return $script:Theme.TierCheck }
        'Review' { return $script:Theme.TierReview }
        default  { return $script:Theme.TextTertiary }
    }
}

function Add-PillSwitchPaint {
    # Neutral pill switch shared by every toggle-tier tile AND the app's own theme switch -
    # state reads live from $this.Tag.GetState at paint time, so a plain .Invalidate() after a
    # state change (or a theme switch) is enough to repaint correctly. No hue anywhere: OFF is
    # an outlined track with the thumb on the left, ON is a filled track with the thumb on the
    # right (a light "cutout" thumb against the filled track) - fill and position carry the
    # state, matching the color-discipline rule the rest of this theme follows.
    # No Control.Region here - Region is a hard, always-aliased pixel mask (confirmed via live
    # testing: this already had SmoothingMode = AntiAlias and still looked jagged, because the
    # Region boundary itself was the aliased edge). Erasing to the button's own BackColor first
    # (already kept correct for whichever surface this switch sits on - a tile's BgSurface, or
    # BgWindow for the header toggle) then filling/stroking the path on top gives a real smooth
    # edge instead of an anti-aliased stroke sitting inside a jagged clip.
    param([System.Windows.Forms.Button]$Button)
    $Button.Add_Paint({
        param($btnControl, $e)
        $isOn = & $btnControl.Tag.GetState
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $w = $btnControl.Width; $h = $btnControl.Height
        $eraseBrush = New-Object System.Drawing.SolidBrush($btnControl.BackColor)
        $g.FillRectangle($eraseBrush, 0, 0, $w, $h)
        $eraseBrush.Dispose()
        $path = Get-RoundedPath -Width $w -Height $h -Radius ([Math]::Floor($h / 2))
        $thumbSize = $h - 4
        if ($isOn) {
            $trackBrush = New-Object System.Drawing.SolidBrush($script:Theme.TextPrimary)
            $g.FillPath($trackBrush, $path)
            $trackBrush.Dispose()
            $thumbBrush = New-Object System.Drawing.SolidBrush($script:Theme.BgWindow)
            $g.FillEllipse($thumbBrush, ($w - $thumbSize - 2), 2, $thumbSize, $thumbSize)
            $thumbBrush.Dispose()
        } else {
            $pen = New-Object System.Drawing.Pen($script:Theme.BorderSubtle, 1)
            $g.DrawPath($pen, $path)
            $pen.Dispose()
            $thumbBrush = New-Object System.Drawing.SolidBrush($script:Theme.TextTertiary)
            $g.FillEllipse($thumbBrush, 2, 2, $thumbSize, $thumbSize)
            $thumbBrush.Dispose()
        }
        $path.Dispose()
    })
}

function Add-ChipPaint {
    # Fills and outlines the chip manually along a rounded path, instead of trusting
    # Control.Region for the shape and FlatAppearance's built-in border renderer for the outline
    # - neither respects anti-aliasing (Region is a hard pixel mask; the built-in border is
    # always a plain rectangle, corner-clipped by a Region into flat edges and stray artifacts
    # rather than following a rounded shape). Chips always sit directly on the chip row's
    # inherited BgWindow (every tab's board chain has no explicit BackColor of its own), so that
    # erase color is safe to hardcode here rather than threading it through as a parameter.
    # Reads BackColor (fill) and FlatAppearance.BorderColor (outline) live off the chip -
    # Update-ChipVisual already keeps both in sync; BorderSize stays 0 so BorderColor is
    # otherwise inert, just reused here as where the color lives.
    param([System.Windows.Forms.Button]$Chip)
    $Chip.Add_Paint({
        param($chipControl, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $eraseBrush = New-Object System.Drawing.SolidBrush($script:Theme.BgWindow)
        $g.FillRectangle($eraseBrush, 0, 0, $chipControl.Width, $chipControl.Height)
        $eraseBrush.Dispose()
        $path = Get-RoundedPath -Width $chipControl.Width -Height $chipControl.Height -Radius 12
        $fillBrush = New-Object System.Drawing.SolidBrush($chipControl.BackColor)
        $g.FillPath($fillBrush, $path)
        $fillBrush.Dispose()
        $pen = New-Object System.Drawing.Pen($chipControl.FlatAppearance.BorderColor, 1)
        $g.DrawPath($pen, $path)
        $pen.Dispose()
        $path.Dispose()
        # Same reason as Add-FlatRoundedPaint - the erase-and-fill above paints over the chip's
        # own already-rendered text, so it has to be drawn again on top here.
        $textFlags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
        [System.Windows.Forms.TextRenderer]::DrawText($g, $chipControl.Text, $chipControl.Font, (New-Object System.Drawing.Rectangle(0, 0, $chipControl.Width, $chipControl.Height)), $chipControl.ForeColor, $textFlags)
    })
}

function Add-TilePaint {
    # Fills the tile's rounded shape manually (see Add-FlatRoundedPaint's comment for why -
    # Region-based rounding is always jagged, regardless of SmoothingMode). Tiles sit directly in
    # a tab's FlowLayoutPanel board, whose whole ancestor chain has no explicit BackColor of its
    # own, so the erase color (BgWindow) is safe to hardcode here.
    #
    # Also draws the tier-color top stripe here, clipped to the same rounded path, instead of as
    # a separate hard-cornered child Panel - a flat rectangular stripe at the very top of the
    # tile would show square corners poking past the tile's now-properly-rounded top corners,
    # which is a worse mismatch than the plain jaggedness this whole pass is fixing. Reads the
    # stripe color from a NoteProperty (StripeColor) rather than a control reference, since there
    # is no longer a separate Stripe control to point at.
    param([System.Windows.Forms.Panel]$Tile)
    $Tile.Add_Paint({
        param($tileControl, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $eraseBrush = New-Object System.Drawing.SolidBrush($script:Theme.BgWindow)
        $g.FillRectangle($eraseBrush, 0, 0, $tileControl.Width, $tileControl.Height)
        $eraseBrush.Dispose()
        $path = Get-RoundedPath -Width $tileControl.Width -Height $tileControl.Height -Radius 10
        $fillBrush = New-Object System.Drawing.SolidBrush($tileControl.BackColor)
        $g.FillPath($fillBrush, $path)
        $fillBrush.Dispose()
        $oldClip = $g.Clip
        $g.SetClip($path, [System.Drawing.Drawing2D.CombineMode]::Replace)
        $stripeBrush = New-Object System.Drawing.SolidBrush($tileControl.StripeColor)
        $g.FillRectangle($stripeBrush, 0, 0, $tileControl.Width, 3)
        $stripeBrush.Dispose()
        $g.Clip = $oldClip
        # A thin border was in the approved mockup but never made it into this Paint handler -
        # tiles were relying on fill-color contrast against BgWindow alone, which is subtle
        # enough in light mode (white tile on very-light-gray page) to read as washed out.
        $pen = New-Object System.Drawing.Pen($script:Theme.BorderSubtle, 1)
        $g.DrawPath($pen, $path)
        $pen.Dispose()
        $path.Dispose()
    })
}

function Update-ChipVisual {
    # Shared by the click handler (immediate feedback) and Set-AppTheme's repaint sweep (mode
    # switch) - both just call this rather than duplicating the active/inactive color logic.
    param([System.Windows.Forms.Button]$Chip)
    $color = Get-TierColor -Tier $Chip.Tag.Filter
    if ($Chip.Tag.IsActive) {
        $Chip.BackColor = $color
        $Chip.ForeColor = $script:Theme.BgWindow
    } else {
        $Chip.BackColor = $script:Theme.BgSurface
        $Chip.ForeColor = $color
    }
    $Chip.FlatAppearance.BorderColor = $color
}

function Update-ToggleVisual {
    param([System.Windows.Forms.Button]$Button)
    $isOn = & $Button.Tag.GetState
    $Button.Tag.StateLabel.Text = if ($isOn) { $Button.Tag.OnLabel } else { $Button.Tag.OffLabel }
    $Button.Invalidate()
}

function New-WinBoardSection {
    # Starts a new Windows Tuning section: a plain-Panel wrapper (deliberately NOT a
    # FlowLayoutPanel or AutoSize - see Update-WinBoardReflow's comment for the full history of
    # why) containing a header Label and this section's own inner tile FlowLayoutPanel, which
    # wraps tiles exactly like every other tab's board. Adds the wrapper to $script:WinBoard and
    # points $script:CurrentSectionInnerBoard at the inner board, so callers just do
    # `New-WinBoardSection "Name"` once per section and then keep adding tiles exactly as before
    # (just to $script:CurrentSectionInnerBoard instead of $script:WinBoard directly).
    param([string]$Text)

    $wrapper = New-Object System.Windows.Forms.Panel

    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Text = $Text.ToUpper()
    $hdr.ForeColor = $script:Theme.TextTertiary
    $hdr.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $hdr.AutoSize = $false
    $hdr.Location = New-Object System.Drawing.Point(4, 0)
    $hdr.Size = New-Object System.Drawing.Size(300, 20)
    $wrapper.Controls.Add($hdr)
    $script:ThemedSectionHeaders.Add($hdr) | Out-Null

    $innerBoard = New-Object System.Windows.Forms.FlowLayoutPanel
    $innerBoard.Location = New-Object System.Drawing.Point(0, 24)
    $innerBoard.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $innerBoard.WrapContents = $true
    $innerBoard.AutoSize = $true
    $innerBoard.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $wrapper.Controls.Add($innerBoard)

    $script:WinBoard.Controls.Add($wrapper)
    $script:WinBoardSections.Add([PSCustomObject]@{ Wrapper = $wrapper; InnerBoard = $innerBoard }) | Out-Null
    $script:CurrentSectionInnerBoard = $innerBoard
}

function Update-WinBoardReflow {
    # Manually Y-positions every section wrapper in $script:WinBoard and re-syncs each one's (and
    # its inner tile board's) Width to the board's current width. Called on every resize of the
    # Windows tab's boardScroll and after every filter-chip click, so hiding/showing tiles
    # correctly closes/reopens gaps between sections.
    #
    # This exists because $script:WinBoard is a plain Panel, not a FlowLayoutPanel, for the
    # Windows tab specifically - three earlier attempts at doing this with FlowLayoutPanel's own
    # wrap/FlowBreak/AutoSize machinery each fixed one bug and surfaced another (row-sharing at
    # wide widths -> a ~104px phantom gap at every section boundary once that was fixed -> the
    # same gap just relocated when height-matching was tried -> the whole board refusing to
    # shrink back down on resize once FlowBreak was dropped in favor of dynamic full-row width,
    # because AutoSize won't let a FlowLayoutPanel get narrower than its widest child, which was
    # the very thing being resized - all confirmed via direct Controls/GetFlowBreak dumps, not
    # guessed). Manual positioning sidesteps all of it: no flow algorithm to fight, so nothing to
    # get subtly wrong across resize + filter interacting at once (verified together, not just
    # separately, in an isolated test before this was applied here - see PLAN.md).
    if (-not $script:WinBoard) { return }
    $width = $script:WinBoard.Width
    $y = 0
    foreach ($s in $script:WinBoardSections) {
        if (-not $s.Wrapper.Visible) { continue }
        $s.Wrapper.Width = $width
        $s.InnerBoard.Width = $width
        $s.InnerBoard.PerformLayout()
        $s.Wrapper.Height = $s.InnerBoard.Location.Y + $s.InnerBoard.Height + 4
        $s.Wrapper.Location = New-Object System.Drawing.Point(0, $y)
        $y += $s.Wrapper.Height + 10
    }
    $script:WinBoard.Height = $y
}

function New-SettingsTile {
    # -ControlType 'Toggle' needs -GetState/-OnAction/-OffAction. 'Action' and 'Check' need only
    # -RunAction. -OnLabel/-OffLabel let a toggle read as e.g. "CENTER"/"LEFT" instead of the
    # generic "ON"/"OFF" when the setting isn't a simple enabled/disabled feature.
    #
    # Color discipline: the tier system (stripe/tag/filter chips) is the ONLY place color
    # appears anywhere in this app. Action/Check buttons render neutral even inside a tier
    # tile - the stripe and tag already say which tier it is, the button doesn't repeat it.
    param(
        [string]$Title,
        [string]$Description,
        [ValidateSet('Adjust', 'Check', 'Review')]
        [string]$Tier,
        [ValidateSet('Toggle', 'Action', 'Check')]
        [string]$ControlType,
        [scriptblock]$GetState,
        [scriptblock]$OnAction,
        [scriptblock]$OffAction,
        [scriptblock]$RunAction,
        [string]$OnLabel = 'ON',
        [string]$OffLabel = 'OFF'
    )
    $tierColor = Get-TierColor -Tier $Tier
    $tierLabel = switch ($Tier) {
        'Adjust' { 'ADJUST' }
        'Check'  { 'READ-ONLY' }
        'Review' { 'REVIEW FIRST' }
    }

    $tile = New-Object System.Windows.Forms.Panel
    $tile.Size = New-Object System.Drawing.Size(228, 124)
    $tile.Margin = New-Object System.Windows.Forms.Padding(4)
    $tile.BackColor = $script:Theme.BgSurface
    Add-Member -InputObject $tile -NotePropertyName StripeColor -NotePropertyValue $tierColor -Force
    Add-TilePaint -Tile $tile

    $lblTag = New-Object System.Windows.Forms.Label
    $lblTag.Text = $tierLabel
    $lblTag.ForeColor = $tierColor
    $lblTag.Font = New-Object System.Drawing.Font("Consolas", 7.5, [System.Drawing.FontStyle]::Bold)
    $lblTag.AutoSize = $false
    $lblTag.Location = New-Object System.Drawing.Point(12, 9)
    $lblTag.Size = New-Object System.Drawing.Size(150, 13)
    $tile.Controls.Add($lblTag)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = $Title
    $lblTitle.ForeColor = $script:Theme.TextPrimary
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
    $lblTitle.AutoSize = $false
    $lblTitle.Location = New-Object System.Drawing.Point(12, 24)
    $lblTitle.Size = New-Object System.Drawing.Size(204, 18)
    $tile.Controls.Add($lblTitle)

    $lblDesc = New-Object System.Windows.Forms.Label
    $lblDesc.Text = $Description
    $lblDesc.ForeColor = $script:Theme.TextSecondary
    $lblDesc.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblDesc.AutoSize = $false
    $lblDesc.Location = New-Object System.Drawing.Point(12, 44)
    $lblDesc.Size = New-Object System.Drawing.Size(204, 46)
    $tile.Controls.Add($lblDesc)

    # Description doubles as the hover tooltip - first-time users get the plain-language
    # explanation without needing a separate tooltip string authored per setting.
    $tooltip = New-Object System.Windows.Forms.ToolTip
    $tooltip.AutoPopDelay = 20000
    $tooltip.InitialDelay = 300
    $tooltip.SetToolTip($lblTitle, $Description)
    $tooltip.SetToolTip($lblDesc, $Description)

    $stateLabel = $null
    if ($ControlType -eq 'Toggle') {
        # Small right-aligned pill switch + a left-aligned state label, instead of one
        # full-width ON/OFF button - mirrors the approved mockup's switch-row layout.
        $btn = New-Object System.Windows.Forms.Button
        $btn.Size = New-Object System.Drawing.Size(40, 20)
        $btn.Location = New-Object System.Drawing.Point(176, 94)
        $btn.FlatStyle = 'Flat'
        $btn.FlatAppearance.BorderSize = 0
        $btn.BackColor = $script:Theme.BgSurface
        $btn.Text = ''
        Add-PillSwitchPaint -Button $btn

        $stateLabel = New-Object System.Windows.Forms.Label
        $stateLabel.AutoSize = $false
        $stateLabel.Location = New-Object System.Drawing.Point(12, 96)
        $stateLabel.Size = New-Object System.Drawing.Size(158, 16)
        $stateLabel.ForeColor = $script:Theme.TextTertiary
        $stateLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Bold)
        $tile.Controls.Add($stateLabel)
    } else {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Size = New-Object System.Drawing.Size(204, 26)
        $btn.Location = New-Object System.Drawing.Point(12, 92)
        $btn.FlatStyle = 'Flat'
        $btn.FlatAppearance.BorderSize = 1
        $btn.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
        # BgSurfaceRaised, not BgSurface - a button that shared the tile's own BgSurface fill was
        # nearly invisible in light mode (white-on-white, distinguished only by a faint border,
        # confirmed via live testing) - giving it its own step-up surface fixes that in both
        # modes without needing a heavier border.
        $btn.BackColor = $script:Theme.BgSurfaceRaised
        $btn.ForeColor = $script:Theme.TextSecondary
        $btn.FlatAppearance.BorderColor = $script:Theme.BorderSubtle
        Add-FlatRoundedPaint -Control $btn -Radius 6 -ParentColor { $script:Theme.BgSurface }
    }

    # Bundled on .Tag (not closed-over function parameters) so the click handler - which fires
    # long after this function call has returned - reads it via $this.Tag. PowerShell scriptblocks
    # used as .NET event delegates don't reliably keep a live closure over a finished function call's local
    # parameters, so anything the handler needs at click-time has to travel on the control itself.
    # Also carries direct references to every recolorable child control, so Set-AppTheme's
    # repaint sweep can address each one explicitly rather than indexing into .Controls.
    $bundle = [PSCustomObject]@{
        Tier = $Tier; GetState = $GetState; OnAction = $OnAction; OffAction = $OffAction
        RunAction = $RunAction; OnLabel = $OnLabel; OffLabel = $OffLabel; ControlType = $ControlType
        TagLabel = $lblTag; TitleLabel = $lblTitle; DescLabel = $lblDesc
        ActionButton = $btn; StateLabel = $stateLabel
    }
    $tile.Tag = $bundle
    $btn.Tag = $bundle

    switch ($ControlType) {
        'Toggle' {
            Update-ToggleVisual -Button $btn
            $btn.Add_Click({
                Invoke-Safe -OutputBox $outputBox -Action {
                    if (& $this.Tag.GetState) { & $this.Tag.OffAction } else { & $this.Tag.OnAction }
                }
                Update-ToggleVisual -Button $this
            })
        }
        'Action' {
            $btn.Text = if ($Tier -eq 'Review') { 'Run...' } else { 'Run' }
            $btn.Add_Click({ Invoke-Safe -OutputBox $outputBox -Action { & $this.Tag.RunAction } })
        }
        'Check' {
            $btn.Text = 'Check'
            $btn.Add_Click({ Invoke-Safe -OutputBox $outputBox -Action { & $this.Tag.RunAction } })
        }
    }
    $tile.Controls.Add($btn)
    $script:ThemedTiles.Add($tile) | Out-Null
    return $tile
}

function Update-TileFilter {
    # -Board is typed as the base Control class, not FlowLayoutPanel - $script:WinBoard is a
    # plain Panel (see Update-WinBoardReflow), the other three tabs' boards are still
    # FlowLayoutPanels, and this one function still has to accept either.
    #
    # $script:WinBoard needs a completely different path: its tiles live inside each section's
    # own inner board, not as direct children, and hiding a section's only-visible tiles has to
    # also hide the section wrapper (so filtering to e.g. "Review First" doesn't leave an empty
    # section label with nothing under it) and re-run the manual reflow, since nothing here wraps
    # or repositions itself automatically the way a real FlowLayoutPanel would.
    param([System.Windows.Forms.Control]$Board, [string]$Filter)
    if ($Board -eq $script:WinBoard) {
        foreach ($s in $script:WinBoardSections) {
            $anyVisible = $false
            foreach ($ctrl in $s.InnerBoard.Controls) {
                if ($ctrl.Tag -and $ctrl.Tag.Tier) {
                    $isVisible = ($Filter -eq 'All') -or ($ctrl.Tag.Tier -eq $Filter)
                    $ctrl.Visible = $isVisible
                    if ($isVisible) { $anyVisible = $true }
                }
            }
            $s.Wrapper.Visible = $anyVisible
        }
        Update-WinBoardReflow
        return
    }
    foreach ($ctrl in $Board.Controls) {
        if ($ctrl.Tag -and $ctrl.Tag.Tier) {
            $ctrl.Visible = ($Filter -eq 'All') -or ($ctrl.Tag.Tier -eq $Filter)
        }
    }
}

function New-FilterChip {
    # Color is derived from -Filter via Get-TierColor rather than passed in - the "All" chip
    # gets Get-TierColor's neutral default, the three tier chips get their tier color, and both
    # cases repaint identically on a theme switch since Update-ChipVisual re-derives from the
    # same function.
    param([string]$Text, [string]$Filter, [int]$X)
    $chip = New-Object System.Windows.Forms.Button
    $chip.Text = $Text
    $chip.Size = New-Object System.Drawing.Size(120, 24)
    $chip.Location = New-Object System.Drawing.Point($X, 3)
    $chip.FlatStyle = 'Flat'
    # BorderSize stays 0 - Add-ChipPaint draws the fill and border manually (see its own
    # comment for why), BorderColor is just where Update-ChipVisual stores the color for it.
    $chip.FlatAppearance.BorderSize = 0
    $chip.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    Add-ChipPaint -Chip $chip
    $chip.Tag = [PSCustomObject]@{ Filter = $Filter; IsActive = $false; Board = $null; Siblings = $null }
    Update-ChipVisual -Chip $chip
    $script:ThemedChips.Add($chip) | Out-Null
    return $chip
}

function New-TileBoard {
    # Builds the reusable "filter chips + scrollable, auto-wrapping tile board" now shared by
    # every tab - extracted from the Windows Tuning board once PC Check/Stress Test/Graphics
    # needed the identical setup (see PLAN.md, "Migrate PC Check, Stress Test, Graphics"). $Parent
    # must already be sized/anchored to fill its tab panel; this fills $Parent's full client area.
    # Chip click handlers read their board via $this.Tag (not a closed-over parameter) - the same
    # reason New-SettingsTile's toggles use .Tag instead of captured function parameters.
    param([System.Windows.Forms.Control]$Parent)

    $chipRow = New-Object System.Windows.Forms.Panel
    $chipRow.Location = New-Object System.Drawing.Point(0, 0)
    $chipRow.Size = New-Object System.Drawing.Size(830, 30)
    $Parent.Controls.Add($chipRow)

    # See CLAUDE.md for why this is two controls (AutoScroll Panel + AutoSize FlowLayoutPanel)
    # rather than one self-scrolling FlowLayoutPanel - confirmed via live testing that the
    # combination breaks tile wrapping specifically on window-width changes.
    $boardScroll = New-Object System.Windows.Forms.Panel
    $boardScroll.Location = New-Object System.Drawing.Point(0, 34)
    $boardScroll.Size = New-Object System.Drawing.Size(830, 386)
    $boardScroll.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $boardScroll.AutoScroll = $true
    $Parent.Controls.Add($boardScroll)

    $board = New-Object System.Windows.Forms.FlowLayoutPanel
    $board.Location = New-Object System.Drawing.Point(0, 0)
    $board.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $board.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $board.WrapContents = $true
    $board.AutoSize = $true
    $board.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $boardScroll.Controls.Add($board)

    $chipAll = New-FilterChip -Text "All" -Filter 'All' -X 0
    $chipAdjust = New-FilterChip -Text "Adjust" -Filter 'Adjust' -X 124
    $chipCheck = New-FilterChip -Text "Read-only" -Filter 'Check' -X 248
    $chipReview = New-FilterChip -Text "Review First" -Filter 'Review' -X 372
    $chips = @($chipAll, $chipAdjust, $chipCheck, $chipReview)
    foreach ($chip in $chips) {
        $chip.Tag.Board = $board
        $chip.Tag.Siblings = $chips
        $chipRow.Controls.Add($chip)
    }
    foreach ($c in $chips) {
        $c.Add_Click({
            foreach ($other in $this.Tag.Siblings) { $other.Tag.IsActive = $false; Update-ChipVisual -Chip $other }
            $this.Tag.IsActive = $true
            Update-ChipVisual -Chip $this
            Update-TileFilter -Board $this.Tag.Board -Filter $this.Tag.Filter
        })
    }
    # "All" starts selected
    $chipAll.Tag.IsActive = $true
    Update-ChipVisual -Chip $chipAll

    return $board
}

function New-SectionedTileBoard {
    # Windows Tuning-specific variant of New-TileBoard - the only tab that groups tiles under
    # named section headers. Reuses the identical chip-row + AutoScroll plumbing, but the actual
    # tile-hosting area is a plain Panel (manually Y-positioned by Update-WinBoardReflow), not a
    # FlowLayoutPanel - see that function's comment for why. A small amount of duplication with
    # New-TileBoard rather than adding a branchy switch to the one function every other tab
    # depends on and already works correctly.
    param([System.Windows.Forms.Control]$Parent)

    $chipRow = New-Object System.Windows.Forms.Panel
    $chipRow.Location = New-Object System.Drawing.Point(0, 0)
    $chipRow.Size = New-Object System.Drawing.Size(830, 30)
    $Parent.Controls.Add($chipRow)

    $boardScroll = New-Object System.Windows.Forms.Panel
    $boardScroll.Location = New-Object System.Drawing.Point(0, 34)
    $boardScroll.Size = New-Object System.Drawing.Size(830, 386)
    $boardScroll.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $boardScroll.AutoScroll = $true
    $Parent.Controls.Add($boardScroll)

    # Plain Panel, not a FlowLayoutPanel - Update-WinBoardReflow positions every section wrapper
    # manually. No AutoSize here either, for the same "nested AutoSize containers fight explicit
    # Width/Height assignments" reason documented on the section wrapper itself.
    $board = New-Object System.Windows.Forms.Panel
    $board.Location = New-Object System.Drawing.Point(0, 0)
    $board.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $boardScroll.Controls.Add($board)

    $chipAll = New-FilterChip -Text "All" -Filter 'All' -X 0
    $chipAdjust = New-FilterChip -Text "Adjust" -Filter 'Adjust' -X 124
    $chipCheck = New-FilterChip -Text "Read-only" -Filter 'Check' -X 248
    $chipReview = New-FilterChip -Text "Review First" -Filter 'Review' -X 372
    $chips = @($chipAll, $chipAdjust, $chipCheck, $chipReview)
    foreach ($chip in $chips) {
        $chip.Tag.Board = $board
        $chip.Tag.Siblings = $chips
        $chipRow.Controls.Add($chip)
    }
    foreach ($c in $chips) {
        $c.Add_Click({
            foreach ($other in $this.Tag.Siblings) { $other.Tag.IsActive = $false; Update-ChipVisual -Chip $other }
            $this.Tag.IsActive = $true
            Update-ChipVisual -Chip $this
            Update-TileFilter -Board $this.Tag.Board -Filter $this.Tag.Filter
        })
    }
    $chipAll.Tag.IsActive = $true
    Update-ChipVisual -Chip $chipAll

    # Anchor keeps $board's own Width correctly tracking $boardScroll live on every resize (the
    # same reliable pattern already proven for every other tab's board) - this just also reflows
    # the sections whenever that happens, since they can't rely on FlowLayoutPanel to do it
    # themselves anymore.
    $boardScroll.Add_SizeChanged({ Update-WinBoardReflow })

    return $board
}

function Set-AppTheme {
    # The one function that switches the app's entire visual theme - sets $script:Theme, then
    # repaints every already-built control from the explicit registries (tiles/chips/section
    # headers) plus the small set of named top-level controls, re-applies the native dark title
    # bar, and persists the choice. Called once at startup (after every board/tile/dialog control
    # below has been constructed) and again from the header toggle's click handler.
    param([ValidateSet('Dark', 'Light')][string]$Mode)
    $script:ThemeMode = $Mode
    $script:Theme = $Themes[$Mode]

    $darkFlag = if ($Mode -eq 'Dark') { 1 } else { 0 }
    try { [DwmHelper]::DwmSetWindowAttribute($form.Handle, 20, [ref]$darkFlag, 4) | Out-Null } catch { }

    $form.BackColor = $script:Theme.BgWindow
    $form.ForeColor = $script:Theme.TextPrimary
    $headerLabel.ForeColor = $script:Theme.TextSecondary
    $accentBar.Invalidate()
    $splitContainer.BackColor = $script:Theme.BgSurfaceRaised

    $themeToggle.BackColor = $script:Theme.BgWindow
    $themeToggle.Invalidate()
    $themeToggleLabel.ForeColor = $script:Theme.TextSecondary
    $themeToggleLabel.Text = $Mode.ToUpper()

    foreach ($btn in @($btnOpenTools, $btnClear, $btnRestartExplorer)) {
        $btn.BackColor = $script:Theme.BgSurface
        $btn.ForeColor = $script:Theme.TextSecondary
        $btn.Invalidate()
    }

    foreach ($chip in $script:ThemedChips) { Update-ChipVisual -Chip $chip }
    foreach ($hdr in $script:ThemedSectionHeaders) { $hdr.ForeColor = $script:Theme.TextTertiary }

    foreach ($tile in $script:ThemedTiles) {
        $b = $tile.Tag
        $tierColor = Get-TierColor -Tier $b.Tier
        $tile.BackColor = $script:Theme.BgSurface
        $tile.StripeColor = $tierColor
        $tile.Invalidate()
        $b.TagLabel.ForeColor = $tierColor
        $b.TitleLabel.ForeColor = $script:Theme.TextPrimary
        $b.DescLabel.ForeColor = $script:Theme.TextSecondary
        if ($b.ControlType -eq 'Toggle') {
            $b.ActionButton.BackColor = $script:Theme.BgSurface
            $b.ActionButton.Invalidate()
            $b.StateLabel.ForeColor = $script:Theme.TextTertiary
        } else {
            # BgSurfaceRaised, not BgSurface - see the matching comment in New-SettingsTile.
            $b.ActionButton.BackColor = $script:Theme.BgSurfaceRaised
            $b.ActionButton.ForeColor = $script:Theme.TextSecondary
            $b.ActionButton.FlatAppearance.BorderColor = $script:Theme.BorderSubtle
            $b.ActionButton.Invalidate()
        }
    }

    Show-Section -Section $script:CurrentSection

    New-Item -Path $script:ThemeModeKey -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $script:ThemeModeKey -Name 'ThemeMode' -Value $Mode -ErrorAction SilentlyContinue
}

$themeToggle.Tag = [PSCustomObject]@{ GetState = { $script:ThemeMode -eq 'Light' } }
Add-PillSwitchPaint -Button $themeToggle
$themeToggle.Add_Click({
    $newMode = if ($script:ThemeMode -eq 'Dark') { 'Light' } else { 'Dark' }
    Set-AppTheme -Mode $newMode
})

# Tab content (top) and the output console (bottom) share the window through a SplitContainer
# instead of two independently-anchored siblings - plain WinForms anchors can make ONE control
# stretch to fill new space (that's all the console was doing before), but not have two stacked
# siblings divide new space between them. SplitContainer is the native tool for exactly that,
# and gives a free draggable divider besides. Real bug found via live testing: without this, the
# Windows tab's tile board stayed pinned at its original tiny height no matter how much the
# window grew, because the console (anchored to all four sides) claimed 100% of any extra space.
$splitContainer = New-Object System.Windows.Forms.SplitContainer
$splitContainer.Location = New-Object System.Drawing.Point(15, 100)
$splitContainer.Size = New-Object System.Drawing.Size(830, 710)
$splitContainer.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$splitContainer.Orientation = [System.Windows.Forms.Orientation]::Horizontal
$splitContainer.SplitterWidth = 6
$splitContainer.BackColor = $script:Theme.BgSurfaceRaised
$splitContainer.Panel1MinSize = 150
$splitContainer.Panel2MinSize = 100
$splitContainer.FixedPanel = [System.Windows.Forms.FixedPanel]::None
$form.Controls.Add($splitContainer)
$splitContainer.SplitterDistance = 430
$panelParent = $splitContainer.Panel1

$panelCheck = New-Object System.Windows.Forms.Panel
$panelCheck.Location = New-Object System.Drawing.Point(0, 0)
$panelCheck.Size = New-Object System.Drawing.Size(830, 420)
$panelCheck.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$panelParent.Controls.Add($panelCheck)
$script:CheckBoard = New-TileBoard -Parent $panelCheck

$panelStress = New-Object System.Windows.Forms.Panel
$panelStress.Location = New-Object System.Drawing.Point(0, 0)
$panelStress.Size = New-Object System.Drawing.Size(830, 420)
$panelStress.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$panelParent.Controls.Add($panelStress)
$script:StressBoard = New-TileBoard -Parent $panelStress

$panelWindows = New-Object System.Windows.Forms.Panel
$panelWindows.Location = New-Object System.Drawing.Point(0, 0)
$panelWindows.Size = New-Object System.Drawing.Size(830, 420)
$panelWindows.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$panelParent.Controls.Add($panelWindows)

# Windows Tuning content: one scrollable board of tiles instead of the old 9-sub-tab switcher
# (see PLAN.md, "Windows Tuning Redesign") - a filter-chip row up top narrows the board by tier,
# section headers inside the board keep settings grouped without adding a second click level.
# New-SectionedTileBoard (defined further below, hoisted like every other function in this
# script) builds the Windows-tab-specific variant of the shared chip-row + scrollable board
# plumbing - see its own comment and Update-WinBoardReflow for why this tab needs a different
# structure than the other three.
$script:WinBoard = New-SectionedTileBoard -Parent $panelWindows

$panelGraphics = New-Object System.Windows.Forms.Panel
$panelGraphics.Location = New-Object System.Drawing.Point(0, 0)
$panelGraphics.Size = New-Object System.Drawing.Size(830, 420)
$panelGraphics.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$panelParent.Controls.Add($panelGraphics)
$script:GraphicsBoard = New-TileBoard -Parent $panelGraphics

# Section registry - add a {Name, Button, Panel} entry here for any future section
# instead of hand-editing Show-Section's branching logic.
$script:Sections = @(
    @{ Name = 'Check';    Button = $btnSectionCheck;    Panel = $panelCheck }
    @{ Name = 'Stress';   Button = $btnSectionStress;   Panel = $panelStress }
    @{ Name = 'Windows';  Button = $btnSectionWindows;  Panel = $panelWindows }
    @{ Name = 'Graphics'; Button = $btnSectionGraphics; Panel = $panelGraphics }
)

function Show-Section {
    # $Sections defaults to the top-level tabs. The Windows tab no longer nests its own sub-tabs
    # (see the Windows Tuning tile board below) - -Sections is kept as an optional override for
    # any future tab that needs the same highlight/switch logic against its own section list.
    # Neutral only - the active tab is a background/weight shift, not a tier or accent color -
    # tracks $script:CurrentSection so Set-AppTheme can re-run this after a mode switch.
    param([string]$Section, $Sections = $script:Sections)
    $script:CurrentSection = $Section
    foreach ($s in $Sections) {
        $isActive = $s.Name -eq $Section
        $s.Panel.Visible = $isActive
        $s.Button.BackColor = if ($isActive) { $script:Theme.BgSurfaceRaised } else { $script:Theme.BgSurface }
        $s.Button.ForeColor = if ($isActive) { $script:Theme.TextPrimary } else { $script:Theme.TextSecondary }
    }
    # Windows Tuning's board is manually reflowed (see Update-WinBoardReflow), not a
    # self-laying-out FlowLayoutPanel like the other three tabs. The Add_Shown reflow at launch
    # always runs while this tab is still hidden (Check is shown first), and a FlowLayoutPanel's
    # AutoSize PerformLayout() computes the wrong (near-zero) height for an invisible control
    # chain - confirmed live: every section wrapper collapsed to a sliver, clipping all tiles out
    # of view until the first filter-chip click forced another reflow while actually visible. Redo
    # the reflow here, now that Visible is genuinely true, so the tab is correct the first time
    # it's shown rather than only after a filter click.
    if ($Section -eq 'Windows') { Update-WinBoardReflow }
}
$btnSectionCheck.Add_Click({ Show-Section -Section 'Check' })
$btnSectionStress.Add_Click({ Show-Section -Section 'Stress' })
$btnSectionWindows.Add_Click({ Show-Section -Section 'Windows' })
$btnSectionGraphics.Add_Click({ Show-Section -Section 'Graphics' })

function Get-AccentPaletteBytes {
    # The taskbar/Start background specifically renders from this 8-shade palette, NOT from
    # DWM's AccentColor or Explorer's AccentColorMenu/StartColorMenu alone - confirmed by direct
    # testing (those three all correctly reflected a picked color, title bars updated correctly,
    # but the taskbar kept showing a stale color until this palette was also regenerated).
    # Approximates Windows' own tint/shade ramp by blending the chosen color toward white for
    # lighter entries and toward black for darker ones - self-computed from whatever color is
    # picked, not copied from any reference script.
    param([System.Drawing.Color]$BaseColor)
    $ratios = @(0.75, 0.5, 0.3, 0.15, 0.0, -0.15, -0.3, -0.5)
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($ratio in $ratios) {
        if ($ratio -ge 0) {
            $r = [byte]($BaseColor.R + ($ratio * (255 - $BaseColor.R)))
            $g = [byte]($BaseColor.G + ($ratio * (255 - $BaseColor.G)))
            $b = [byte]($BaseColor.B + ($ratio * (255 - $BaseColor.B)))
        } else {
            $factor = 1 + $ratio
            $r = [byte]($BaseColor.R * $factor)
            $g = [byte]($BaseColor.G * $factor)
            $b = [byte]($BaseColor.B * $factor)
        }
        $bytes.Add($r); $bytes.Add($g); $bytes.Add($b); $bytes.Add(0)
    }
    return $bytes.ToArray()
}

function Remove-OldFiles {
    # Deletes files one at a time (not as a single bulk pipeline call) so DoEvents can pump the
    # UI message queue periodically - every action in this app runs synchronously on the same
    # thread that draws the window, and a folder with tens of thousands of files takes long enough
    # to enumerate/delete that the window goes white/"Not Responding" for the whole duration
    # otherwise. Confirmed by testing: this isn't a hypothetical, it happened on a real ~81k-file
    # temp folder. Only deletes files older than $Cutoff, so this app's own just-started process
    # (which compiles P/Invoke helpers via Add-Type at launch, leaving temp files behind) can't
    # have one of its own active files deleted out from under it.
    param([string]$Path, [datetime]$Cutoff, [System.Windows.Forms.RichTextBox]$OutputBox)
    $files = @(Get-ChildItem -Path $Path -Recurse -ErrorAction SilentlyContinue -File | Where-Object { $_.LastWriteTime -lt $Cutoff })
    $totalSize = ($files | Measure-Object -Property Length -Sum).Sum
    $i = 0
    foreach ($file in $files) {
        Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
        $i++
        if ($i % 300 -eq 0) {
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    Get-ChildItem -Path $Path -ErrorAction SilentlyContinue -Directory | Where-Object { $_.LastWriteTime -lt $Cutoff } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    return $totalSize
}

function Restart-ShellTheme {
    # Writing theme/accent registry values alone doesn't repaint anything live - Windows' own
    # Settings app also sends a WM_SETTINGCHANGE "ImmersiveColorSet" broadcast, which alone
    # didn't work in testing either. Confirmed by direct trial on a real machine: neither
    # restarting explorer.exe alone, nor restarting just the newer shell-surface processes
    # (ShellHost / the older ShellExperienceHost, StartMenuExperienceHost, SearchHost) alone,
    # reliably repaints the taskbar - both have to go down together, with a few seconds for
    # everything to reinitialize. This does briefly close any open File Explorer windows.
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    foreach ($procName in @('ShellHost', 'ShellExperienceHost', 'StartMenuExperienceHost', 'SearchHost')) {
        Stop-Process -Name $procName -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
}

function Show-ChoiceDialog {
    # MessageBox can't show custom button labels (only fixed sets like Yes/No) -
    # this is a minimal themed stand-in for a two-option prompt, e.g. picking
    # between two named settings values rather than confirming yes/no.
    param([string]$Title, [string]$Message, [string]$OptionA, [string]$OptionB)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.Size = New-Object System.Drawing.Size(360, 170)
    $dlg.StartPosition = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $script:Theme.BgWindow

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Message
    $lbl.ForeColor = $script:Theme.TextPrimary
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $lbl.AutoSize = $false
    $lbl.Size = New-Object System.Drawing.Size(320, 40)
    $lbl.Location = New-Object System.Drawing.Point(15, 15)
    $dlg.Controls.Add($lbl)

    # Neutral, not tier-colored - this dialog isn't tied to a specific tier (e.g. Taskbar
    # Alignment's Center/Left choice), so both options render the same way.
    $btnA = New-Object System.Windows.Forms.Button
    $btnA.Text = $OptionA
    $btnA.Size = New-Object System.Drawing.Size(150, 40)
    $btnA.Location = New-Object System.Drawing.Point(15, 80)
    $btnA.FlatStyle = 'Flat'
    $btnA.FlatAppearance.BorderSize = 1
    $btnA.FlatAppearance.BorderColor = $script:Theme.BorderSubtle
    $btnA.BackColor = $script:Theme.BgSurface
    $btnA.ForeColor = $script:Theme.TextPrimary
    $btnA.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    Add-FlatRoundedPaint -Control $btnA -Radius 6 -ParentColor { $script:Theme.BgWindow }
    $dlg.Controls.Add($btnA)

    $btnB = New-Object System.Windows.Forms.Button
    $btnB.Text = $OptionB
    $btnB.Size = New-Object System.Drawing.Size(150, 40)
    $btnB.Location = New-Object System.Drawing.Point(175, 80)
    $btnB.FlatStyle = 'Flat'
    $btnB.FlatAppearance.BorderSize = 1
    $btnB.FlatAppearance.BorderColor = $script:Theme.BorderSubtle
    $btnB.BackColor = $script:Theme.BgSurface
    $btnB.ForeColor = $script:Theme.TextPrimary
    $btnB.DialogResult = [System.Windows.Forms.DialogResult]::No
    Add-FlatRoundedPaint -Control $btnB -Radius 6 -ParentColor { $script:Theme.BgWindow }
    $dlg.Controls.Add($btnB)

    $dlg.AcceptButton = $btnA
    $result = $dlg.ShowDialog()
    $dlg.Dispose()
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) { return $OptionA }
    elseif ($result -eq [System.Windows.Forms.DialogResult]::No) { return $OptionB }
    else { return $null }
}

$script:CheckBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Storage Check" -Description "Free space and disk health per drive. Opens File Explorer." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-StorageCheckText)
        Start-Process explorer.exe "shell:MyComputerFolder"
    }))
$script:CheckBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "RAM Check (CPU-Z)" -Description "Installed sticks, speed, and XMP/DOCP/EXPO status via CPU-Z." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-RamSummaryText)
        Invoke-ExternalTool -Name "CPU-Z" -Candidates @('cpuz_x64.exe', 'cpuz.exe', 'cpuz_x32.exe') `
            -DownloadUrl 'https://www.cpuid.com/softwares/cpu-z.html' -ToolsDir $ToolsDir -OutputBox $outputBox `
            -InstalledNamePattern '*CPU-Z*' `
            -Note "That page has TWO options - grab the Portable/ZIP version, NOT Setup (Setup installs to Program Files instead of giving you a standalone .exe)."
    }))
$script:CheckBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "GPU Check (GPU-Z)" -Description "Driver version and Resizable BAR status via GPU-Z." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-GpuSummaryText)
        Invoke-ExternalTool -Name "GPU-Z" -Candidates @('GPU-Z.exe', 'GPU-Z.x64.exe') `
            -DownloadUrl 'https://www.techpowerup.com/download/techpowerup-gpu-z/' -ToolsDir $ToolsDir -OutputBox $outputBox `
            -InstalledNamePattern '*GPU-Z*'
    }))
$script:CheckBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Temps Check (HWiNFO)" -Description "Live CPU/GPU temperatures and fan behavior via HWiNFO." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-TempsCheckText)
        Invoke-ExternalTool -Name "HWiNFO" -Candidates @('HWiNFO64.exe', 'HWiNFO32.exe') `
            -DownloadUrl 'https://www.hwinfo.com/download/' -ToolsDir $ToolsDir -OutputBox $outputBox `
            -InstalledNamePattern '*HWiNFO*' `
            -Note "Grab the Portable/ZIP version, not the Installer. Extract it and save HWiNFO64.exe here. On first launch, use the 'Sensors-only' mode and close the summary window to get straight to live readings."
    }))
$script:CheckBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "BIOS Check" -Description "Current BIOS version vs. the latest available, opens a search for the update page." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-BiosCheckText)
        $board = Get-CimInstance Win32_BaseBoard
        $query = "$($board.Manufacturer) $($board.Product) bios update"
        $searchUrl = "https://www.google.com/search?q=" + [Uri]::EscapeDataString($query)
        Start-Process $searchUrl
    }))
$script:CheckBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "BIOS Settings Notes" -Description "A plain-language checklist for BIOS tuning (XMP, PBO, ReBAR, etc). Purely informational." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-BiosSettingsCheckText)
    }))

$script:StressBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "CPU Stress Test (OCCT)" -Description "Runs OCCT to check for crashes or overheating under sustained load." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-CpuStressCheckText)
        Invoke-ExternalTool -Name "OCCT" -Candidates @('OCCT.exe') `
            -DownloadUrl 'https://www.ocbase.com/download' -ToolsDir $ToolsDir -OutputBox $outputBox `
            -InstalledNamePattern '*OCCT*' `
            -Note "OCCT may require the installer rather than a portable zip - if so, run it once and just launch OCCT normally from the Start Menu. Free 'Personal' license may need a quick account/email step on their site."
    }))
$script:StressBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "GPU Stress Test (Heaven)" -Description "Runs Heaven Benchmark to check GPU stability under load." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-GpuStressCheckText)
        Invoke-ExternalTool -Name "Heaven Benchmark" -Candidates @('Heaven-Setup.exe', 'Heaven.exe', 'Heaven_x64.exe') `
            -DownloadUrl 'https://benchmark.unigine.com/heaven' -ToolsDir $ToolsDir -OutputBox $outputBox `
            -InstalledNamePattern '*Heaven*' -RequiredCompanionFile 'bin\unigine.cfg' `
            -Note "Heaven is normally a full installer, not portable - run it once and launch it normally afterward. If it downloads with a version number in the filename (e.g. Unigine_Heaven-4.0.exe), rename it to Heaven-Setup.exe so future re-downloads still get found."
    }))
$script:StressBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "MSI Afterburner" -Description "Opens Afterburner for overclocking and on-screen monitoring during a stress test." `
    -RunAction {
        Write-ToolOutput $outputBox "=== MSI Afterburner ==="
        Invoke-ExternalTool -Name "MSI Afterburner" -Candidates @('MSIAfterburnerSetup.exe', 'MSIAfterburner.exe') `
            -DownloadUrl 'https://www.msi.com/Landing/afterburner/graphics-cards' -ToolsDir $ToolsDir -OutputBox $outputBox `
            -InstalledNamePattern '*Afterburner*' `
            -Note "Afterburner ships as a zip containing the installer - extract it, rename the installer to MSIAfterburnerSetup.exe, and drop it here. It installs a driver + background service (not portable) - run the installer once per PC."
    }))

New-WinBoardSection "Startup Apps"
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Startup Apps" -Description "Lists what's currently set to launch when Windows starts, and opens Settings to change it." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-StartupAppsText)
        Start-Process "ms-settings:startupapps"
    }))

New-WinBoardSection "Taskbar & Start"
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
    -Title "Clean Taskbar & Start" -Description "Hides Widgets/Search/Copilot/Task View, shows all tray icons, and unpins every current taskbar icon. Unpinning can't be undone automatically." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-TaskbarStartText)
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This cleans up the taskbar and Start menu (hides Widgets/Search/Task View/Chat/Copilot, shows all tray icons, hides Start's Recommended section, sets All Apps to List view, and unpins all current taskbar icons).`n`nUnpinning can't be undone by 'Default' - re-pinning afterward is manual. Some changes may need a sign-out/sign-in to fully show.`n`nContinue?",
            "Clean Taskbar & Start",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-ToolOutput $outputBox "Cancelled - no changes made."
            return
        }
        New-Item -Path 'HKLM:\Software\Policies\Microsoft\Dsh' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\Software\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0 -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Value 0 -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowTaskViewButton' -Value 0 -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarMn' -Value 0 -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowCopilotButton' -Value 0 -Type DWord
        New-Item -Path 'HKLM:\Software\Policies\Microsoft\Windows\Windows Feeds' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\Software\Policies\Microsoft\Windows\Windows Feeds' -Name 'EnableFeeds' -Value 0 -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' -Name 'EnableAutoTray' -Value 0 -Type DWord
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' -Name 'HideRecommendedSection' -Value 1 -Type DWord
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'HideRecommendedSection' -Value 1 -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' -Name 'AllAppsViewMode' -Value 2 -Type DWord
        Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path 'HKCU:\Control Panel\NotifyIconSettings' -ErrorAction SilentlyContinue | ForEach-Object {
            Set-ItemProperty -Path $_.PSPath -Name 'IsPromoted' -Value 1 -ErrorAction SilentlyContinue
        }
        Write-ToolOutput $outputBox "Taskbar and Start menu cleaned. Sign out/in or restart Explorer if anything doesn't refresh immediately."
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
    -Title "Restore Default Taskbar & Start" -Description "Reverts the above back to Windows' default behavior. Does not restore previously-unpinned icons." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-TaskbarStartText)
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This reverts the taskbar and Start menu back to Windows' default behavior (Widgets/Search/Task View/Chat/Copilot restored, tray icons auto-hidden again, Start's Recommended section restored, All Apps back to Category view).`n`nThis does not restore previously-unpinned taskbar icons - that has to be done manually.`n`nContinue?",
            "Default Taskbar & Start",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-ToolOutput $outputBox "Cancelled - no changes made."
            return
        }
        Remove-Item -Path 'HKLM:\Software\Policies\Microsoft\Dsh' -Recurse -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowTaskViewButton' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarMn' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowCopilotButton' -ErrorAction SilentlyContinue
        Remove-Item -Path 'HKLM:\Software\Policies\Microsoft\Windows\Windows Feeds' -Recurse -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' -Name 'EnableAutoTray' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' -Name 'HideRecommendedSection' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'HideRecommendedSection' -ErrorAction SilentlyContinue
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' -Name 'AllAppsViewMode' -Value 0 -Type DWord
        Get-ChildItem -Path 'HKCU:\Control Panel\NotifyIconSettings' -ErrorAction SilentlyContinue | ForEach-Object {
            Set-ItemProperty -Path $_.PSPath -Name 'IsPromoted' -Value 0 -ErrorAction SilentlyContinue
        }
        Write-ToolOutput $outputBox "Taskbar and Start menu reverted to defaults. Sign out/in or restart Explorer if anything doesn't refresh immediately."
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle -OnLabel "CENTER" -OffLabel "LEFT" `
    -Title "Taskbar Alignment" -Description "Windows 11's default is Center. Left matches the classic Windows 10 layout. Takes effect immediately." `
    -GetState { Get-TaskbarAlignmentState } `
    -OnAction {
        Write-ToolOutput $outputBox (Get-TaskbarAlignmentText)
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAl' -Value 1 -Type DWord
        Write-ToolOutput $outputBox "Taskbar alignment set to Center."
    } `
    -OffAction {
        Write-ToolOutput $outputBox (Get-TaskbarAlignmentText)
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAl' -Value 0 -Type DWord
        Write-ToolOutput $outputBox "Taskbar alignment set to Left."
    }))

New-WinBoardSection "Theme & Color"
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle -OnLabel "DARK" -OffLabel "LIGHT" `
    -Title "Dark Mode" -Description "Switches Windows and apps to a dark or light color scheme. Doesn't touch the wallpaper or accent color." `
    -GetState { Get-ThemeState } `
    -OnAction {
        Write-ToolOutput $outputBox (Get-ThemeText)
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -Value 0 -Type DWord
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme' -Value 0 -Type DWord
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency' -Value 0 -Type DWord
        # Windows' own "dark, no accent" rendering defaults to a charcoal gray, not true black -
        # forcing a near-black accent is what actually gets a genuinely black taskbar/title bar.
        # Unlike the Accent Color picker (a real hue like green needs lighter/darker variants in
        # its palette), a pure-black target shouldn't ramp up to a light gray at one end - so this
        # doesn't reuse the general tint/shade gradient generator. But an all-zero palette isn't
        # right either - confirmed by testing: toggle switches, checkboxes, and similar Windows
        # controls read their "on"/active color from an early palette entry regardless of
        # ColorPrevalence, so crushing every entry to pure black makes those controls unreadable
        # against dark backgrounds. Keeping the first two entries a visible medium gray (matching
        # how the source script's own palette wasn't actually all-zero either) and zeroing only the
        # rest keeps the taskbar/title bars pitch black while controls stay legible.
        $nearBlack = [System.Drawing.Color]::FromArgb(25, 25, 25)
        $nearBlackGlow = [System.Drawing.Color]::FromArgb(0xC4, $nearBlack)
        $blackPalette = [byte[]](100, 100, 100, 0, 110, 110, 110, 0) + ([byte[]](, 0 * 24))
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'EnableWindowColorization' -Value 1 -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -Value $nearBlack.ToArgb() -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'ColorizationColor' -Value $nearBlackGlow.ToArgb() -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'ColorizationAfterglow' -Value $nearBlackGlow.ToArgb() -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu' -Value 0 -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'StartColorMenu' -Value 0 -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentPalette' -Value $blackPalette -Type Binary
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'ColorPrevalence' -Value 1 -Type DWord
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -Value 0 -Type DWord
        Restart-ShellTheme
        Write-ToolOutput $outputBox "Dark theme applied."
    } `
    -OffAction {
        Write-ToolOutput $outputBox (Get-ThemeText)
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -Value 1 -Type DWord
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme' -Value 1 -Type DWord
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency' -Value 1 -Type DWord
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'ColorPrevalence' -Value 0 -Type DWord
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -Value 1 -Type DWord
        Restart-ShellTheme
        Write-ToolOutput $outputBox "Light theme applied (system and apps both light, matching Dark Theme's symmetric opposite)."
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Action `
    -Title "Accent Color" -Description "Opens Windows' own color picker to set the taskbar/Start/title bar accent color." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-AccentColorText)
        $colorDialog = New-Object System.Windows.Forms.ColorDialog
        $colorDialog.FullOpen = $true
        if ($colorDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            Write-ToolOutput $outputBox "Cancelled - no changes made."
            return
        }
        $color = $colorDialog.Color
        $glow = [System.Drawing.Color]::FromArgb(0xC4, $color)
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'EnableWindowColorization' -Value 1 -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -Value $color.ToArgb() -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'ColorizationColor' -Value $glow.ToArgb() -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'ColorizationAfterglow' -Value $glow.ToArgb() -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu' -Value $color.ToArgb() -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'StartColorMenu' -Value $color.ToArgb() -Type DWord
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentPalette' -Value (Get-AccentPaletteBytes -BaseColor $color) -Type Binary
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'ColorPrevalence' -Value 1 -Type DWord
        Restart-ShellTheme
        Write-ToolOutput $outputBox ("Accent color set to RGB({0}, {1}, {2})." -f $color.R, $color.G, $color.B)
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Action `
    -Title "Reset Accent Color" -Description "Removes the accent color override, reverting to Windows' own default. Doesn't touch Dark Mode." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-AccentColorText)
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'EnableWindowColorization' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'ColorizationColor' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'ColorizationAfterglow' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'StartColorMenu' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentPalette' -ErrorAction SilentlyContinue
        Restart-ShellTheme
        Write-ToolOutput $outputBox "Accent color overrides removed - reverted to Windows' own default."
    }))

New-WinBoardSection "Context Menu"
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle -OnLabel "CLASSIC" -OffLabel "DEFAULT" `
    -Title "Right-Click Menu" -Description "Classic shows the full Windows 10-style menu immediately, instead of Windows 11's shortened one." `
    -GetState { Get-ContextMenuState } `
    -OnAction {
        Write-ToolOutput $outputBox (Get-ContextMenuText)
        New-Item -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' -Force | Out-Null
        Set-Item -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' -Value ''
        Write-ToolOutput $outputBox "Classic context menu enabled. Reopen File Explorer windows (or restart Explorer) if it doesn't show up immediately."
    } `
    -OffAction {
        Write-ToolOutput $outputBox (Get-ContextMenuText)
        Remove-Item -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -Recurse -Force -ErrorAction SilentlyContinue
        Write-ToolOutput $outputBox "Reverted to Windows 11's default context menu. Reopen File Explorer windows (or restart Explorer) if it doesn't show up immediately."
    }))

New-WinBoardSection "Windows Features"
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle `
    -Title "Widgets" -Description "The news/weather panel on the taskbar. Disabling stops the Widgets process immediately." `
    -GetState { Get-WidgetsState } `
    -OnAction {
        Write-ToolOutput $outputBox (Get-WidgetsText)
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests' -Name 'value' -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -ErrorAction SilentlyContinue
        Write-ToolOutput $outputBox "Widgets restored (may need a sign-out to fully reappear)."
    } `
    -OffAction {
        Write-ToolOutput $outputBox (Get-WidgetsText)
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests' -Name 'value' -Value 0 -Type DWord
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0 -Type DWord
        Stop-Process -Name Widgets -Force -ErrorAction SilentlyContinue
        Stop-Process -Name WidgetService -Force -ErrorAction SilentlyContinue
        Write-ToolOutput $outputBox "Widgets disabled."
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle `
    -Title "Copilot" -Description "Microsoft's built-in AI assistant panel. Disabling stops the Copilot process immediately." `
    -GetState { Get-CopilotState } `
    -OnAction {
        Write-ToolOutput $outputBox (Get-CopilotText)
        Remove-ItemProperty -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -ErrorAction SilentlyContinue
        Write-ToolOutput $outputBox "Copilot restored (may need a sign-out to fully reappear)."
    } `
    -OffAction {
        Write-ToolOutput $outputBox (Get-CopilotText)
        New-Item -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1 -Type DWord
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1 -Type DWord
        Stop-Process -Name Copilot -Force -ErrorAction SilentlyContinue
        Write-ToolOutput $outputBox "Copilot disabled."
    }))

New-WinBoardSection "Gaming Tweaks"
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle `
    -Title "Mouse Acceleration" -Description "Cursor speed depends on how fast you physically move the mouse. Most competitive/FPS players want this OFF." `
    -GetState { Get-MouseAccelState } `
    -OnAction {
        Write-ToolOutput $outputBox (Get-MouseAccelText)
        Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -Value '1' -Type String
        Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold1' -Value '6' -Type String
        Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold2' -Value '10' -Type String
        [MouseHelper]::SystemParametersInfo($script:SPI_SETMOUSE, 0, [int[]]@(6, 10, 1), $script:SPIF_SENDCHANGE) | Out-Null
        Write-ToolOutput $outputBox "Mouse acceleration restored to Windows default - takes effect immediately."
    } `
    -OffAction {
        Write-ToolOutput $outputBox (Get-MouseAccelText)
        Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -Value '0' -Type String
        Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold1' -Value '0' -Type String
        Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold2' -Value '0' -Type String
        [MouseHelper]::SystemParametersInfo($script:SPI_SETMOUSE, 0, [int[]]@(0, 0, 0), $script:SPIF_SENDCHANGE) | Out-Null
        Write-ToolOutput $outputBox "Mouse acceleration disabled - takes effect immediately."
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle `
    -Title "Game Bar" -Description "Xbox's background recording/overlay (Win+G). The overlay hooking has a real measurable FPS cost while active." `
    -GetState { Get-GameBarState } `
    -OnAction {
        Write-ToolOutput $outputBox (Get-GameBarText)
        New-Item -Path 'HKCU:\System\GameConfigStore' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 1 -Type DWord
        New-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 1 -Type DWord
        New-Item -Path 'HKCU:\SOFTWARE\Microsoft\GameBar' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\GameBar' -Name 'UseNexusForGameBarEnabled' -Value 1 -Type DWord
        Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -ErrorAction SilentlyContinue
        Write-ToolOutput $outputBox "Game Bar and background game recording re-enabled."
    } `
    -OffAction {
        Write-ToolOutput $outputBox (Get-GameBarText)
        New-Item -Path 'HKCU:\System\GameConfigStore' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0 -Type DWord
        New-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 0 -Type DWord
        New-Item -Path 'HKCU:\SOFTWARE\Microsoft\GameBar' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\GameBar' -Name 'UseNexusForGameBarEnabled' -Value 0 -Type DWord
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -Value 0 -Type DWord
        Write-ToolOutput $outputBox "Game Bar and background game recording disabled."
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Game Mode Check" -Description "Shows whether Windows' Game Mode is currently on and opens Settings to change it." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-GameModeText)
        Start-Process "ms-settings:gaming-gamemode"
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Sound Devices" -Description "Opens the Sound panel to check for the wrong default mic/speaker (e.g. a webcam mic or HDMI passthrough)." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-SoundDevicesText)
        Start-Process "control.exe" -ArgumentList "mmsys.cpl"
    }))

New-WinBoardSection "Debloat"
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Action `
    -Title "Restore OneDrive" -Description "Reinstalls OneDrive using Microsoft's own official installer." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-OneDriveText)
        $setup64 = "$env:SystemRoot\System32\OneDriveSetup.exe"
        $setup32 = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
        if (Test-Path $setup64) { Start-Process $setup64 -ErrorAction SilentlyContinue }
        elseif (Test-Path $setup32) { Start-Process $setup32 -ErrorAction SilentlyContinue }
        else { Write-ToolOutput $outputBox "OneDriveSetup.exe not found - OneDrive may need to be downloaded fresh from microsoft.com." ; return }
        Write-ToolOutput $outputBox "OneDrive reinstall started."
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Action `
    -Title "Reinstall Xbox App" -Description "Puts back the Xbox app (Game Pass, cloud gaming) after Remove Bloatware took it out." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-XboxReinstallText)
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Microsoft.GamingApp' }
        if ($provisioned) {
            Add-AppxPackage -DisableDevelopmentMode -RegisterByFamilyName -MainPackageName $provisioned.PackageName -ErrorAction SilentlyContinue
            Write-ToolOutput $outputBox "Xbox app re-registered from the files still on this PC."
        } else {
            Write-ToolOutput $outputBox "Xbox app files no longer present on this PC - opening its Microsoft Store page to reinstall fresh."
            Start-Process "ms-windows-store://pdp/?productid=9MV0B5HZVK9Z"
        }
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle -OnLabel "TRIMMED" -OffLabel "DEFAULT" `
    -Title "Background Services" -Description "Disables SysMain, DiagTrack, Windows Error Reporting, Retail Demo, and Downloaded Maps Manager. Doesn't affect printing or Start menu search." `
    -GetState { Get-ServicesState } `
    -OnAction {
        Write-ToolOutput $outputBox (Get-ServicesText)
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This stops and disables SysMain, DiagTrack, Windows Error Reporting, Retail Demo, and Downloaded Maps Manager.`n`nAll are safe and reversible - toggle back to restore their normal startup type and start them again.`n`nContinue?",
            "Disable Unneeded Services",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-ToolOutput $outputBox "Cancelled - no changes made."
            return
        }
        $services = @('SysMain', 'DiagTrack', 'WerSvc', 'RetailDemo', 'MapsBroker')
        foreach ($svcName in $services) {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc) {
                Write-ToolOutput $outputBox "  Found - stopping and disabling: $svcName"
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
                Set-Service -Name $svcName -StartupType Disabled -ErrorAction SilentlyContinue
            } else {
                Write-ToolOutput $outputBox "  Not present on this PC: $svcName"
            }
        }
        Write-ToolOutput $outputBox "Done."
    } `
    -OffAction {
        Write-ToolOutput $outputBox (Get-ServicesText)
        # Real Windows-default startup types verified directly on a live machine rather than
        # guessed - they aren't all the same (SysMain/DiagTrack/MapsBroker default to Automatic,
        # WerSvc/RetailDemo default to Manual/start-on-demand).
        $defaults = [ordered]@{
            'SysMain'    = 'Automatic'
            'DiagTrack'  = 'Automatic'
            'WerSvc'     = 'Manual'
            'RetailDemo' = 'Manual'
            'MapsBroker' = 'Automatic'
        }
        foreach ($svcName in $defaults.Keys) {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc) {
                # Setting StartupType is enough to resume normal behavior (Windows starts it on
                # next boot, or via its own trigger) - deliberately NOT calling Start-Service here.
                # It's a blocking call that runs on the same thread as the UI, and starting a
                # service right after flipping it off Disabled can stall long enough to freeze
                # the whole window - confirmed by testing, not a hypothetical risk.
                Set-Service -Name $svcName -StartupType $defaults[$svcName] -ErrorAction SilentlyContinue
                Write-ToolOutput $outputBox "  Restored: $svcName ($($defaults[$svcName]) - will start normally on next boot)"
            } else {
                Write-ToolOutput $outputBox "  Not present on this PC: $svcName"
            }
        }
        Write-ToolOutput $outputBox "Services restored."
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Process Count Check" -Description "Shows how many processes are currently running and opens Task Manager." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-ProcessCountText)
        Start-Process taskmgr.exe
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
    -Title "Remove Bloatware" -Description "Removes ~40 pre-installed apps (Xbox, Cortana, OneDrive, etc). No bulk restore - reinstall individual apps from the Store if wanted back." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-BloatwareText)
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This removes the curated bloatware list shown above (including Xbox app/Game Bar overlay components) and uninstalls OneDrive, for every user on this PC.`n`nThere's no bulk 'restore' for the app list - reinstall a specific app from the Microsoft Store if a client wants it back. OneDrive and the Xbox app each have their own dedicated restore button.`n`nContinue?",
            "Remove Bloatware",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-ToolOutput $outputBox "Cancelled - no changes made."
            return
        }
        # Exact names for well-known first-party apps (AppX Name values are stable, unversioned
        # identifiers - no wildcard needed or wanted here, since a broad wildcard like '*People*'
        # can accidentally catch an unrelated component like Microsoft.Windows.PeopleExperienceHost,
        # confirmed by testing). Wildcards are reserved for OEM-bundled promo tiles, where the exact
        # publisher-prefixed package name varies too much across different PC builds to predict.
        $bloatExactNames = @(
            'Microsoft.549981C3F5F10', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingFinance',
            'Microsoft.BingSports', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MicrosoftOfficeHub',
            'Microsoft.People', 'Microsoft.WindowsMaps', 'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo',
            'Microsoft.MixedReality.Portal', 'Microsoft.SkypeApp', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
            'Microsoft.Messaging', 'Microsoft.OneConnect', 'Microsoft.Wallet', 'Microsoft.WindowsFeedbackHub',
            'Microsoft.Todos', 'Microsoft.PowerAutomateDesktop', 'Clipchamp.Clipchamp', 'MicrosoftTeams',
            'Microsoft.YourPhone', 'Microsoft.Paint3D', 'Microsoft.Microsoft3DViewer',
            'microsoft.windowscommunicationsapps', 'Microsoft.WindowsSoundRecorder', 'Microsoft.WindowsAlarms',
            'Microsoft.Windows.DevHome', 'MicrosoftCorporationII.MicrosoftFamily', 'Microsoft.NetworkSpeedTest',
            'MicrosoftWindows.CrossDevice', 'Microsoft.OutlookForWindows', 'Microsoft.MicrosoftJournal',
            'Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.Xbox.TCUI',
            'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay'
        )
        $bloatWildcardPatterns = @('*SpotifyMusic*', '*Facebook*', '*Instagram*', '*TikTok*', '*Disney*', '*Netflix*')

        # Report per-item status (found-and-removing vs not-installed) for every entry, rather than
        # one bulk pass with a single summary line - so the tech can see exactly what this PC had.
        $installedPackages = Get-AppxPackage -AllUsers
        $toRemove = New-Object System.Collections.Generic.List[object]
        foreach ($name in $bloatExactNames) {
            $match = $installedPackages | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($match) {
                Write-ToolOutput $outputBox "  Found - removing: $name"
                $toRemove.Add($match)
            } else {
                Write-ToolOutput $outputBox "  Not installed: $name"
            }
        }
        foreach ($pattern in $bloatWildcardPatterns) {
            $patternMatches = @($installedPackages | Where-Object { $_.Name -like $pattern })
            if ($patternMatches.Count -gt 0) {
                foreach ($m in $patternMatches) {
                    Write-ToolOutput $outputBox "  Found - removing: $($m.Name) (matched $pattern)"
                    $toRemove.Add($m)
                }
            } else {
                Write-ToolOutput $outputBox "  Not installed: $pattern"
            }
        }
        if ($toRemove.Count -gt 0) {
            $toRemove | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        }

        if (Get-Process -Name OneDrive -ErrorAction SilentlyContinue) {
            Write-ToolOutput $outputBox "  Found - removing: OneDrive"
            Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
            $setup64 = "$env:SystemRoot\System32\OneDriveSetup.exe"
            $setup32 = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
            if (Test-Path $setup64) { Start-Process $setup64 -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue }
            if (Test-Path $setup32) { Start-Process $setup32 -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue }
            Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'OneDrive' } | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
        } else {
            Write-ToolOutput $outputBox "  Not installed: OneDrive"
        }
        Write-ToolOutput $outputBox "Bloatware removal complete."
    }))

New-WinBoardSection "Performance"
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle -OnLabel "IPV4-ONLY" -OffLabel "DEFAULT" `
    -Title "Network Bindings" -Description "Disables everything except IPv4 (IPv6, File Sharing, QoS, LLDP, etc) on physical Ethernet adapters. WiFi/virtual adapters are untouched." `
    -GetState { Get-NetworkBindingsState } `
    -OnAction {
        Write-ToolOutput $outputBox (Get-NetworkBindingsText)
        $bindingsToDisable = @('ms_tcpip6', 'ms_server', 'ms_msclient', 'ms_pacer', 'ms_lltdio', 'ms_rspndr', 'ms_implat', 'ms_lldp')
        $ethAdapters = @(Get-NetAdapter | Where-Object { $_.PhysicalMediaType -match 'Ethernet|802.3' })
        if ($ethAdapters.Count -eq 0) {
            Write-ToolOutput $outputBox "  No Ethernet adapter found on this PC."
            return
        }
        foreach ($adapter in $ethAdapters) {
            Write-ToolOutput $outputBox "  Adapter: $($adapter.Name)"
            foreach ($componentId in $bindingsToDisable) {
                Disable-NetAdapterBinding -Name $adapter.Name -ComponentID $componentId -ErrorAction SilentlyContinue
            }
        }
        Write-ToolOutput $outputBox "IPv4-only bindings applied."
    } `
    -OffAction {
        Write-ToolOutput $outputBox (Get-NetworkBindingsText)
        $bindingsToRestore = @('ms_tcpip6', 'ms_server', 'ms_msclient', 'ms_pacer', 'ms_lltdio', 'ms_rspndr', 'ms_implat', 'ms_lldp')
        $ethAdapters = @(Get-NetAdapter | Where-Object { $_.PhysicalMediaType -match 'Ethernet|802.3' })
        if ($ethAdapters.Count -eq 0) {
            Write-ToolOutput $outputBox "  No Ethernet adapter found on this PC."
            return
        }
        foreach ($adapter in $ethAdapters) {
            Write-ToolOutput $outputBox "  Adapter: $($adapter.Name)"
            foreach ($componentId in $bindingsToRestore) {
                Enable-NetAdapterBinding -Name $adapter.Name -ComponentID $componentId -ErrorAction SilentlyContinue
            }
        }
        Write-ToolOutput $outputBox "Network bindings restored."
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle `
    -Title "Prioritize Foreground Apps" -Description "Reduces the CPU Windows always reserves for background/multimedia tasks (SystemResponsiveness 20 -> 10), leaving more headroom for whatever's actively in the foreground. Modest but real effect, safe and reversible." `
    -GetState { Get-SystemResponsivenessState } `
    -OnAction {
        Write-ToolOutput $outputBox (Get-SystemResponsivenessText)
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'SystemResponsiveness' -Value 10 -Type DWord
        Write-ToolOutput $outputBox "SystemResponsiveness set to 10."
    } `
    -OffAction {
        Write-ToolOutput $outputBox (Get-SystemResponsivenessText)
        Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'SystemResponsiveness' -ErrorAction SilentlyContinue
        Write-ToolOutput $outputBox "SystemResponsiveness key removed - reverted to Windows' default (20)."
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Core Isolation / Memory Integrity" -Description "Opens Windows Security's Device Security page and explains the Memory Integrity performance-vs-security tradeoff. This app never toggles it - the tech/client decides in the actual Windows UI." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-CoreIsolationText)
        Start-Process 'windowsdefender://devicesecurity'
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Visual Effects" -Description "Opens Windows' Performance Options dialog. Recommends 'Adjust for best performance' as a starting point, then lists 5 specific effects worth re-checking afterward." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-VisualEffectsText)
        Start-Process 'SystemPropertiesPerformance.exe'
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle `
    -Title "Apply Tarkov LUT" -Description "Installs a bundled color profile and sets it as the default for this display - a known Escape from Tarkov community technique for brightening its very dark scenes. Opens Color Management afterward in case a manual 'Set as Default Profile' click is needed to finish applying it live." `
    -GetState { Get-TarkovLutState } `
    -OnAction {
        Write-ToolOutput $outputBox (Get-TarkovLutText)
        $lutPath = Join-Path $AssetsDir $script:TarkovLutFileName
        if (-not (Test-Path $lutPath)) {
            Write-ToolOutput $outputBox "ERROR: bundled LUT file not found at $lutPath"
            return
        }
        # InstallColorProfileW rejects this file with ERROR_INVALID_PARAMETER (confirmed live,
        # both elevated and not) - its ICC validation is apparently stricter than what a plain
        # copy needs. A direct file copy into the color directory works instead (same result
        # Color Management's own "Add..." dialog produces - confirmed by diffing this file
        # against the user's own manually-added copy, byte-identical, both read back fine).
        try {
            Copy-Item -Path $lutPath -Destination (Join-Path $script:ColorProfileDir $script:TarkovLutFileName) -Force -ErrorAction Stop
        } catch {
            Write-ToolOutput $outputBox "ERROR: could not copy the profile into the color directory - $_"
            return
        }
        Write-ToolOutput $outputBox "Profile installed to the Windows color directory."
        $currentLeaf = Get-TarkovLutCurrentProfileLeaf
        $key = Find-TarkovLutInstanceKey -CurrentLeaf $currentLeaf
        if (-not $key) {
            Write-ToolOutput $outputBox "Couldn't find this display's profile list in the registry - opening Color Management so you can add it manually (Add... -> select '$($script:TarkovLutFileName)' -> Set as Default Profile)."
            Start-Process 'colorcpl.exe'
            return
        }
        $newList = @($key.Value | Where-Object { $_ -ine $script:TarkovLutFileName }) + $script:TarkovLutFileName
        Set-ItemProperty -Path $key.Path -Name 'ICMProfile' -Value $newList -Type MultiString
        Write-ToolOutput $outputBox "Registry association updated - '$($script:TarkovLutFileName)' is now the default profile for this display."
        Write-ToolOutput $outputBox "If your screen doesn't look brighter yet, Color Management just opened - click it in the list, then 'Set as Default Profile' once to finish applying it live."
        Start-Process 'colorcpl.exe'
    } `
    -OffAction {
        Write-ToolOutput $outputBox (Get-TarkovLutText)
        $currentLeaf = Get-TarkovLutCurrentProfileLeaf
        $key = Find-TarkovLutInstanceKey -CurrentLeaf $currentLeaf
        if (-not $key) {
            Write-ToolOutput $outputBox "Couldn't find this display's profile list in the registry - opening Color Management so you can pick a different default manually."
            Start-Process 'colorcpl.exe'
            return
        }
        $trimmedList = @($key.Value | Where-Object { $_ -ine $script:TarkovLutFileName })
        if ($trimmedList.Count -eq 0) {
            $trimmedList = @('sRGB Color Space Profile.icm')
            Write-ToolOutput $outputBox "No other profile was associated with this display - falling back to Windows' stock sRGB profile."
        }
        Set-ItemProperty -Path $key.Path -Name 'ICMProfile' -Value $trimmedList -Type MultiString
        Write-ToolOutput $outputBox "Registry association reverted - default is now '$($trimmedList[-1])'."
        Write-ToolOutput $outputBox "If your screen still looks like the LUT, Color Management just opened - click '$($trimmedList[-1])' in the list, then 'Set as Default Profile' once to finish reverting it live."
        Start-Process 'colorcpl.exe'
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
    -Title "Set Ultimate Power Plan" -Description "Activates Windows' hidden max-performance plan and permanently deletes every other power plan, including any custom ones." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-PowerPlanText)
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This activates the hidden Ultimate Performance power plan and deletes every other power plan on this PC (Balanced, Power Saver, High Performance, any custom ones).`n`nUse 'Reset Power Plans' afterward if you ever want the normal set back.`n`nContinue?",
            "Set Ultimate Power Plan",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-ToolOutput $outputBox "Cancelled - no changes made."
            return
        }
        $dupOutput = & powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
        if ($dupOutput -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $newGuid = $Matches[1]
            & powercfg -setactive $newGuid
            Write-ToolOutput $outputBox "  Ultimate Performance activated ($newGuid)"
            $listOutput = & powercfg -list | Out-String
            $otherGuids = [regex]::Matches($listOutput, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') |
                ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne $newGuid } | Select-Object -Unique
            foreach ($guid in $otherGuids) {
                & powercfg -delete $guid
                Write-ToolOutput $outputBox "  Removed other plan: $guid"
            }
            Write-ToolOutput $outputBox "Done - Ultimate Performance is now the only power plan."
        } else {
            Write-ToolOutput $outputBox "Could not create the Ultimate Performance plan."
        }
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
    -Title "Reset Power Plans" -Description "Restores Windows' normal Balanced/Power Saver/High Performance set. Doesn't recreate any custom plans that were previously deleted." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-PowerPlanText)
        & powercfg -restoredefaultschemes
        Write-ToolOutput $outputBox "Power plans reset to Windows' default set (Balanced active)."
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
    -Title "System Cleanup" -Description "Clears temp folders, the Windows Update cache, and empties the Recycle Bin. Deletes files permanently." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-CleanupText)
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This clears user/Windows temp folders, the Windows Update download cache, and empties the Recycle Bin.`n`nAll standard, safe cleanup - nothing here touches documents or personal files.`n`nContinue?",
            "System Cleanup",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-ToolOutput $outputBox "Cancelled - no changes made."
            return
        }
        $totalFreed = 0
        $cutoff = (Get-Date).AddHours(-1)

        Write-ToolOutput $outputBox "  Clearing user temp (this can take a bit on a large folder)..."
        $userTempSize = Remove-OldFiles -Path $env:TEMP -Cutoff $cutoff -OutputBox $outputBox
        $totalFreed += $userTempSize
        Write-ToolOutput $outputBox ("  User temp: {0:N1} MB cleared" -f ($userTempSize / 1MB))

        Write-ToolOutput $outputBox "  Clearing system temp..."
        $sysTempSize = Remove-OldFiles -Path "$env:SystemRoot\Temp" -Cutoff $cutoff -OutputBox $outputBox
        $totalFreed += $sysTempSize
        Write-ToolOutput $outputBox ("  System temp: {0:N1} MB cleared" -f ($sysTempSize / 1MB))

        $wuWasRunning = (Get-Service -Name wuauserv -ErrorAction SilentlyContinue).Status -eq 'Running'
        $bitsWasRunning = (Get-Service -Name bits -ErrorAction SilentlyContinue).Status -eq 'Running'
        Stop-Service -Name wuauserv, bits -Force -ErrorAction SilentlyContinue
        $wuSize = Remove-OldFiles -Path "$env:SystemRoot\SoftwareDistribution\Download" -Cutoff $cutoff -OutputBox $outputBox
        if ($wuWasRunning) { Start-Service -Name wuauserv -ErrorAction SilentlyContinue }
        if ($bitsWasRunning) { Start-Service -Name bits -ErrorAction SilentlyContinue }
        $totalFreed += $wuSize
        Write-ToolOutput $outputBox ("  Windows Update cache: {0:N1} MB cleared" -f ($wuSize / 1MB))

        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-ToolOutput $outputBox "  Recycle Bin emptied"

        Write-ToolOutput $outputBox ("Cleanup complete - approximately {0:N1} MB freed." -f ($totalFreed / 1MB))
    }))
$script:CurrentSectionInnerBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Open Disk Cleanup" -Description "Additional cleanup for shader cache, Windows Update leftovers, old driver packages, and old Windows installs - not a broader alternative to System Cleanup, which already covers temp files/WU cache/Recycle Bin. Windows.old removal is permanent." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-DiskCleanupText)
        Start-Process cleanmgr.exe -ArgumentList "/d $env:SystemDrive"
    }))

$script:GraphicsBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Clean GPU Drivers (DDU)" -Description "Detected GPU + pre-cleanup checklist, then launches DDU (Display Driver Uninstaller)." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-DduCheckText)
        Invoke-ExternalTool -Name "DDU" -Candidates @('DDU\Display Driver Uninstaller.exe', 'DDU\DisplayDriverUninstaller.exe') `
            -DownloadUrl 'https://www.wagnardsoft.com/' -ToolsDir $ToolsDir -OutputBox $outputBox `
            -Note "DDU ships as a self-extracting archive, not a single portable exe - run the downloaded file once, extract it into a 'DDU' subfolder inside Tools (so it keeps its accompanying files together), then this button will find it there."
    }))
$script:GraphicsBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Get Latest Driver" -Description "Detects NVIDIA/AMD/Intel and opens that vendor's official driver download page." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-DriverUpdateCheckText)
        $vendor = Get-PrimaryGpuVendor
        $url = switch ($vendor) {
            'NVIDIA' { 'https://www.nvidia.com/Download/index.aspx' }
            'AMD'    { 'https://www.amd.com/en/support/download/drivers.html' }
            'Intel'  { 'https://www.intel.com/content/www/us/en/download-center/home.html' }
            default  { $null }
        }
        if ($url) {
            Write-ToolOutput $outputBox "Detected vendor: $vendor - opening official driver page."
            Start-Process $url
        } else {
            Write-ToolOutput $outputBox "Could not confidently detect NVIDIA/AMD/Intel - opening a general search instead."
            $gpuName = (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic Render|Remote Display|Virtual' } | Select-Object -First 1).Name
            Start-Process ("https://www.google.com/search?q=" + [Uri]::EscapeDataString("$gpuName driver download"))
        }
    }))
$script:GraphicsBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle `
    -Title "Max GPU Performance" -Description "Keeps the NVIDIA GPU at full power (P0) instead of slowing at idle - removes clock-ramp stutter, costs some idle power/heat/fan noise. NVIDIA-only." `
    -GetState { Get-GpuP0State } `
    -OnAction {
        Write-ToolOutput $outputBox (Get-GpuP0StateText)
        $vendor = Get-PrimaryGpuVendor
        if ($vendor -ne 'NVIDIA') {
            $reason = if ($vendor) { "$vendor GPU detected" } else { "No GPU vendor confidently detected" }
            Write-ToolOutput $outputBox "$reason - this registry value only affects NVIDIA's driver, skipping to avoid a no-op."
            return
        }
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This forces the NVIDIA GPU to stay at its highest power state (P0) at all times, even at idle.`n`nThis raises idle power draw, idle temps, and fan noise - traded for eliminating the clock-ramp stutter when a game first starts rendering. Takes effect immediately, no reboot needed, and is fully reversible with 'Revert GPU Perf'.`n`nContinue?",
            "Force Max GPU Performance",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $subkeys = (Get-ChildItem -Path 'Registry::HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -Force -ErrorAction SilentlyContinue).Name
            foreach ($key in $subkeys) {
                if ($key -notlike '*Configuration') {
                    reg add "$key" /v "DisableDynamicPstate" /t REG_DWORD /d "1" /f | Out-Null
                }
            }
            Write-ToolOutput $outputBox "GPU forced to max performance state (P0)."
        } else {
            Write-ToolOutput $outputBox "Cancelled - no changes made."
        }
    } `
    -OffAction {
        Write-ToolOutput $outputBox (Get-GpuP0StateText)
        $subkeys = (Get-ChildItem -Path 'Registry::HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -Force -ErrorAction SilentlyContinue).Name
        foreach ($key in $subkeys) {
            if ($key -notlike '*Configuration') {
                reg add "$key" /v "DisableDynamicPstate" /t REG_DWORD /d "0" /f | Out-Null
            }
        }
        Write-ToolOutput $outputBox "GPU power state reverted to default (dynamic switching)."
    }))
$script:GraphicsBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Action `
    -Title "Apply NVIDIA Settings" -Description "Applies a curated NVIDIA Base Profile via NVIDIA Profile Inspector: highest available refresh rate, Prefer Maximum Performance power mode, unlimited shader cache, threaded optimization on, Ultra Low Latency Mode, 1 max pre-rendered frame, Vertical Sync off, Fixed Refresh monitor technology. Heads-up: Vertical Sync off can cause screen tearing on monitors without G-Sync/FreeSync. Auto-launches the Legacy NVIDIA Control Panel afterward. NVIDIA-only, fully reversible with 'Reset NVIDIA Settings'." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-NvidiaProfileInspectorText)
        $vendor = Get-PrimaryGpuVendor
        if ($vendor -ne 'NVIDIA') {
            $reason = if ($vendor) { "$vendor GPU detected" } else { "No GPU vendor confidently detected" }
            Write-ToolOutput $outputBox "$reason - NVIDIA Profile Inspector only affects NVIDIA's driver, skipping."
            return
        }
        # SettingID/SettingValue pairs sourced directly from the user's own Profile Inspector
        # export - not re-derived or copied from any third-party sample.
        $nip = @'
<?xml version="1.0" encoding="utf-16"?>
<ArrayOfProfile>
  <Profile>
    <ProfileName>Base Profile</ProfileName>
    <Executeables />
    <Settings>
      <ProfileSetting>
        <SettingNameInfo>Preferred refresh rate</SettingNameInfo>
        <SettingID>6600001</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Power management mode</SettingNameInfo>
        <SettingID>274197361</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Shader disk cache maximum size</SettingNameInfo>
        <SettingID>11306135</SettingID>
        <SettingValue>4294967295</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Threaded optimization</SettingNameInfo>
        <SettingID>549528094</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>FRL Low Latency</SettingNameInfo>
        <SettingID>277041152</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Maximum pre-rendered frames</SettingNameInfo>
        <SettingID>8102046</SettingID>
        <SettingValue>1</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <SettingNameInfo>Vertical Sync</SettingNameInfo>
        <SettingID>11041231</SettingID>
        <SettingValue>138504007</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
      <ProfileSetting>
        <!-- Profile Inspector's internal SettingNameInfo for this ID is "GSYNC - Application
             State" - a misleading label confirmed against the live UI, which calls it "Monitor
             Technology". Not gated behind having G-Sync hardware; SettingValue=4 is "Fixed
             Refresh Rate", the correct universal default for a client PC of unknown monitor. -->
        <SettingNameInfo>Monitor Technology - Fixed Refresh</SettingNameInfo>
        <SettingID>279476687</SettingID>
        <SettingValue>4</SettingValue>
        <ValueType>Dword</ValueType>
      </ProfileSetting>
    </Settings>
  </Profile>
</ArrayOfProfile>
'@
        $tempPath = Join-Path $env:TEMP 'PCTweaksToolkit_ApplyBase.nip'
        [System.IO.File]::WriteAllText($tempPath, $nip, [System.Text.Encoding]::Unicode)
        $applied = Invoke-ExternalTool -Name "NVIDIA Profile Inspector" -Candidates @('ProfileInspector\nvidiaProfileInspector.exe') `
            -DownloadUrl 'https://github.com/Orbmu2k/nvidiaProfileInspector/releases' -ToolsDir $ToolsDir -OutputBox $outputBox `
            -ArgumentList "-silentImport -silent `"$tempPath`"" -Wait `
            -Note "Downloads as a zip - extract ALL of its contents (nvidiaProfileInspector.exe, Reference.xml, and the rest) into a subfolder here named exactly: ProfileInspector"
        Remove-Item -Path $tempPath -ErrorAction SilentlyContinue
        if ($applied) {
            Write-ToolOutput $outputBox "NVIDIA Base Profile settings applied. Heads-up: Vertical Sync is now off, which can cause screen tearing on monitors without G-Sync/FreeSync."
            Invoke-LegacyNvidiaControlPanel -OutputBox $outputBox
        }
    }))
$script:GraphicsBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Action `
    -Title "Reset NVIDIA Settings" -Description "Clears the NVIDIA Base Profile back to driver defaults via NVIDIA Profile Inspector - reverts 'Apply NVIDIA Settings' and any other Base Profile customization. Auto-launches the Legacy NVIDIA Control Panel afterward. NVIDIA-only." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-NvidiaProfileInspectorText)
        $vendor = Get-PrimaryGpuVendor
        if ($vendor -ne 'NVIDIA') {
            $reason = if ($vendor) { "$vendor GPU detected" } else { "No GPU vendor confidently detected" }
            Write-ToolOutput $outputBox "$reason - NVIDIA Profile Inspector only affects NVIDIA's driver, skipping."
            return
        }
        $nip = @'
<?xml version="1.0" encoding="utf-16"?>
<ArrayOfProfile>
  <Profile>
    <ProfileName>Base Profile</ProfileName>
    <Executeables />
    <Settings />
  </Profile>
</ArrayOfProfile>
'@
        $tempPath = Join-Path $env:TEMP 'PCTweaksToolkit_ResetBase.nip'
        [System.IO.File]::WriteAllText($tempPath, $nip, [System.Text.Encoding]::Unicode)
        $applied = Invoke-ExternalTool -Name "NVIDIA Profile Inspector" -Candidates @('ProfileInspector\nvidiaProfileInspector.exe') `
            -DownloadUrl 'https://github.com/Orbmu2k/nvidiaProfileInspector/releases' -ToolsDir $ToolsDir -OutputBox $outputBox `
            -ArgumentList "-silentImport -silent `"$tempPath`"" -Wait `
            -Note "Downloads as a zip - extract ALL of its contents (nvidiaProfileInspector.exe, Reference.xml, and the rest) into a subfolder here named exactly: ProfileInspector"
        Remove-Item -Path $tempPath -ErrorAction SilentlyContinue
        if ($applied) {
            Write-ToolOutput $outputBox "NVIDIA Base Profile settings reset to driver defaults."
            Invoke-LegacyNvidiaControlPanel -OutputBox $outputBox
        }
    }))
$script:GraphicsBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Legacy NVIDIA Control Panel" -Description "Launches the classic NVIDIA Control Panel (via its Microsoft Store app). Installs it first via winget if it isn't already present - click again once the install finishes." `
    -RunAction {
        Invoke-LegacyNvidiaControlPanel -OutputBox $outputBox
    }))
$script:GraphicsBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Resolution & Refresh Rate" -Description "Shows each display's current resolution/refresh rate and opens Settings." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-DisplaySettingsCheckText)
        Start-Process "ms-settings:display"
    }))
$script:GraphicsBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "HAGS / Windowed Opts" -Description "Opens Settings with a checklist covering Hardware-Accelerated GPU Scheduling and per-app windowed optimizations." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-HagsCheckText)
        Start-Process "ms-settings:display-advancedgraphics"
    }))
$script:GraphicsBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
    -Title "Reboot: Safe Mode" -Description "Sets the Safe Mode boot flag and restarts the PC automatically in 15 seconds. Self-clearing on next login." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-SafeModeCheckText)
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This sets the Safe Mode boot flag and restarts this PC in 15 seconds.`n`nThis is self-clearing - it automatically reverts to a normal boot the moment any successful Windows login happens (even the Safe Mode login itself), so it cannot get stuck permanently even if this session disconnects.`n`nSave any open work now. To cancel within the 15 seconds, open a Command Prompt and run: shutdown /a`n`nContinue?",
            "Reboot to Safe Mode",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-ToolOutput $outputBox "Setting Safe Mode boot flag (self-clearing after next login) - restarting in 15 seconds (run 'shutdown /a' to cancel)."
            & bcdedit /set '{current}' safeboot minimal | Out-Null
            & reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' /v '*PCTweaksExitSafeMode' /t REG_SZ /d 'cmd /c bcdedit /deletevalue {current} safeboot' /f | Out-Null
            Start-Process shutdown.exe -ArgumentList '/r /t 15 /c "Rebooting into Safe Mode - this auto-reverts to normal boot after your next login"'
        } else {
            Write-ToolOutput $outputBox "Cancelled - no changes made."
        }
    }))
$script:GraphicsBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
    -Title "Reboot: Normal Mode" -Description "Clears the Safe Mode boot flag and restarts the PC automatically in 15 seconds, back to normal Windows." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-SafeModeCheckText)
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This clears the Safe Mode boot flag and restarts this PC in 15 seconds, back into normal Windows.`n`nSave any open work now. To cancel within that window, open a Command Prompt and run: shutdown /a`n`nContinue?",
            "Reboot to Normal Mode",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-ToolOutput $outputBox "Clearing Safe Mode boot flag - restarting in 15 seconds (run 'shutdown /a' to cancel)."
            & bcdedit /deletevalue '{current}' safeboot | Out-Null
            & reg delete 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' /v '*PCTweaksExitSafeMode' /f | Out-Null
            Start-Process shutdown.exe -ArgumentList '/r /t 15 /c "Rebooting back into normal Windows"'
        } else {
            Write-ToolOutput $outputBox "Cancelled - no changes made."
        }
    }))

$outputBox = New-Object System.Windows.Forms.RichTextBox
$outputBox.Location = New-Object System.Drawing.Point(0, 0)
$outputBox.Size = New-Object System.Drawing.Size(830, 270)
$outputBox.BackColor = [System.Drawing.Color]::FromArgb(6, 6, 8)
$outputBox.ForeColor = [System.Drawing.Color]::FromArgb(230, 227, 235)
$outputBox.Font = New-Object System.Drawing.Font("Consolas", 10)
$outputBox.ReadOnly = $true
$outputBox.BorderStyle = 'FixedSingle'
$outputBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$splitContainer.Panel2.Controls.Add($outputBox)

$btnOpenTools = New-Object System.Windows.Forms.Button
$btnOpenTools.Text = "Open Tools Folder"
$btnOpenTools.Size = New-Object System.Drawing.Size(150, 30)
$btnOpenTools.Location = New-Object System.Drawing.Point(15, 822)
$btnOpenTools.FlatStyle = 'Flat'
$btnOpenTools.FlatAppearance.BorderSize = 0
$btnOpenTools.BackColor = $script:Theme.BgSurface
$btnOpenTools.ForeColor = $script:Theme.TextSecondary
$btnOpenTools.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
Add-FlatRoundedPaint -Control $btnOpenTools -Radius 6 -ParentColor { $script:Theme.BgWindow }
$form.Controls.Add($btnOpenTools)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = "Clear Output"
$btnClear.Size = New-Object System.Drawing.Size(150, 30)
$btnClear.Location = New-Object System.Drawing.Point(175, 822)
$btnClear.FlatStyle = 'Flat'
$btnClear.FlatAppearance.BorderSize = 0
$btnClear.BackColor = $script:Theme.BgSurface
$btnClear.ForeColor = $script:Theme.TextSecondary
$btnClear.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
Add-FlatRoundedPaint -Control $btnClear -Radius 6 -ParentColor { $script:Theme.BgWindow }
$form.Controls.Add($btnClear)

$btnRestartExplorer = New-Object System.Windows.Forms.Button
$btnRestartExplorer.Text = "Restart Explorer"
$btnRestartExplorer.Size = New-Object System.Drawing.Size(150, 30)
$btnRestartExplorer.Location = New-Object System.Drawing.Point(335, 822)
$btnRestartExplorer.FlatStyle = 'Flat'
$btnRestartExplorer.FlatAppearance.BorderSize = 0
$btnRestartExplorer.BackColor = $script:Theme.BgSurface
$btnRestartExplorer.ForeColor = $script:Theme.TextSecondary
$btnRestartExplorer.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
Add-FlatRoundedPaint -Control $btnRestartExplorer -Radius 6 -ParentColor { $script:Theme.BgWindow }
$form.Controls.Add($btnRestartExplorer)

$btnOpenTools.Add_Click({ Start-Process explorer.exe $ToolsDir })
$btnClear.Add_Click({ $outputBox.Clear() })

Show-Section -Section 'Check'

# WinForms quirk: an Anchor-sized control several levels deep (SplitContainer > Panel1 >
# panelCheck > boardScroll > board) doesn't always have its Width correctly resolved before the
# very first paint - confirmed by live testing: PC Check/Stress Test/Graphics's tile boards
# rendered as a single column at launch, correcting instantly the moment the window was resized
# (a real resize event forces WinForms to re-resolve every anchor in the chain; the initial paint
# doesn't reliably get the same treatment). Calling PerformLayout() alone wasn't enough - it
# re-wraps a board's children using whatever Width the board currently has, without first
# re-deriving that Width from its own Anchor, so it can just re-wrap using the still-wrong value.
# Fixed by explicitly setting each board's Width from its immediate parent's resolved
# ClientSize.Width before laying it out, rather than trusting the Anchor to have already done so.
$form.Add_Shown({
    foreach ($b in @($script:CheckBoard, $script:StressBoard, $script:WinBoard, $script:GraphicsBoard)) {
        $b.Width = $b.Parent.ClientSize.Width
        $b.PerformLayout()
    }
    Update-WinBoardReflow
})

# Applies the persisted (or default Dark) theme to every already-built control, including the
# native title bar (DWMWA_USE_IMMERSIVE_DARK_MODE, attribute 20) - accessing .Handle inside
# Set-AppTheme forces the window handle to exist before the app loop starts. Must run after
# Show-Section above so $script:CurrentSection is already set to 'Check', not $null.
Set-AppTheme -Mode $script:ThemeMode

[System.Windows.Forms.Application]::Run($form)
