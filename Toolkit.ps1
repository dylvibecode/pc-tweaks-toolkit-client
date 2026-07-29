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

  OCCT, Heaven Benchmark, and MSI Afterburner (Stress Test tab) still get
  cached here, but unlike the three above they aren't self-contained
  standalone tools - Heaven and Afterburner are installers (run once per
  client PC; Afterburner also installs a driver + background service).
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

# ---------- GUI ----------

# Accent palette pulled from the logo (purple -> orange gradient on black),
# sampled at 4 even points so each check button gets its own shade.
$global:AccentPurple  = [System.Drawing.Color]::FromArgb(168, 85, 247)
$global:AccentBlend1  = [System.Drawing.Color]::FromArgb(197, 103, 173)
$global:AccentBlend2  = [System.Drawing.Color]::FromArgb(226, 122, 100)
$global:AccentOrange  = [System.Drawing.Color]::FromArgb(255, 140, 26)

$form = New-Object System.Windows.Forms.Form
$form.Text = "PC Tweaks Toolkit"
$form.Size = New-Object System.Drawing.Size(860, 900)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(8, 8, 10)
$form.ForeColor = [System.Drawing.Color]::White
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
$headerLabel.Size = New-Object System.Drawing.Size(770, 20)
$headerLabel.Location = New-Object System.Drawing.Point($textX, $headerY)
$headerLabel.ForeColor = [System.Drawing.Color]::Gray
$headerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$headerLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($headerLabel)

# gradient accent bar echoing the logo's purple -> orange ring
# (sits below the logo/header row - the logo box is 40px tall starting at
# $headerY, so this must start at or after $headerY + 40 to avoid drawing over it)
$accentBar = New-Object System.Windows.Forms.Panel
$accentBar.Location = New-Object System.Drawing.Point(15, 58)
$accentBar.Size = New-Object System.Drawing.Size(830, 4)
$accentBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$accentBar.Add_Paint({
    param($barControl, $e)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $barControl.Width, $barControl.Height)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $global:AccentPurple, $global:AccentOrange, 0.0)
    $e.Graphics.FillRectangle($brush, $rect)
    $brush.Dispose()
})
$form.Controls.Add($accentBar)

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

function Update-ToggleVisual {
    param([System.Windows.Forms.Button]$Button)
    $isOn = & $Button.Tag.GetState
    if ($isOn) {
        $Button.Text = $Button.Tag.OnLabel
        $Button.BackColor = [System.Drawing.Color]::FromArgb(20, 40, 28)
        $Button.ForeColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
        $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
    } else {
        $Button.Text = $Button.Tag.OffLabel
        $Button.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
        $Button.ForeColor = [System.Drawing.Color]::FromArgb(148, 143, 163)
        $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 78, 90)
    }
}

function New-SectionHeader {
    param([string]$Text)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text.ToUpper()
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(148, 143, 163)
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $lbl.AutoSize = $false
    # Deliberately wider than any realistic board width (rather than tracking the board's exact
    # current size) so FlowBreak reliably forces a full row-break at any window width - a Label's
    # background is transparent by default, so oversizing the bounding box draws nothing extra.
    $lbl.Size = New-Object System.Drawing.Size(2000, 20)
    $lbl.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 2)
    $lbl.Tag = 'SectionHeader'
    $lbl.FlowBreak = $true
    return $lbl
}

function New-SettingsTile {
    # -ControlType 'Toggle' needs -GetState/-OnAction/-OffAction. 'Action' and 'Check' need only
    # -RunAction. -OnLabel/-OffLabel let a toggle read as e.g. "CENTER"/"LEFT" instead of the
    # generic "ON"/"OFF" when the setting isn't a simple enabled/disabled feature.
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
    $tierColor = switch ($Tier) {
        'Adjust' { $global:AccentOrange }
        'Check'  { [System.Drawing.Color]::FromArgb(125, 211, 252) }
        'Review' { [System.Drawing.Color]::FromArgb(251, 191, 36) }
    }
    $tierLabel = switch ($Tier) {
        'Adjust' { 'ADJUST' }
        'Check'  { 'READ-ONLY' }
        'Review' { 'REVIEW FIRST' }
    }

    $tile = New-Object System.Windows.Forms.Panel
    $tile.Size = New-Object System.Drawing.Size(228, 124)
    $tile.Margin = New-Object System.Windows.Forms.Padding(4)
    $tile.BackColor = [System.Drawing.Color]::FromArgb(22, 18, 26)

    $stripe = New-Object System.Windows.Forms.Panel
    $stripe.Size = New-Object System.Drawing.Size(228, 3)
    $stripe.Location = New-Object System.Drawing.Point(0, 0)
    $stripe.BackColor = $tierColor
    $tile.Controls.Add($stripe)

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
    $lblTitle.ForeColor = [System.Drawing.Color]::White
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
    $lblTitle.AutoSize = $false
    $lblTitle.Location = New-Object System.Drawing.Point(12, 24)
    $lblTitle.Size = New-Object System.Drawing.Size(204, 18)
    $tile.Controls.Add($lblTitle)

    $lblDesc = New-Object System.Windows.Forms.Label
    $lblDesc.Text = $Description
    $lblDesc.ForeColor = [System.Drawing.Color]::FromArgb(148, 143, 163)
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

    $btn = New-Object System.Windows.Forms.Button
    $btn.Size = New-Object System.Drawing.Size(204, 26)
    $btn.Location = New-Object System.Drawing.Point(12, 92)
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 1
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)

    # Bundled on .Tag (not closed-over function parameters) so the click handler - which fires
    # long after this function call has returned - reads it via $this.Tag. PowerShell scriptblocks
    # used as .NET event delegates don't reliably keep a live closure over a finished function call's local
    # parameters, so anything the handler needs at click-time has to travel on the control itself.
    $bundle = [PSCustomObject]@{
        Tier = $Tier; GetState = $GetState; OnAction = $OnAction; OffAction = $OffAction
        RunAction = $RunAction; OnLabel = $OnLabel; OffLabel = $OffLabel
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
            $btn.BackColor = [System.Drawing.Color]::FromArgb(22, 18, 26)
            $btn.ForeColor = $tierColor
            $btn.FlatAppearance.BorderColor = $tierColor
            $btn.Add_Click({ Invoke-Safe -OutputBox $outputBox -Action { & $this.Tag.RunAction } })
        }
        'Check' {
            $btn.Text = 'Check'
            $btn.BackColor = [System.Drawing.Color]::FromArgb(22, 18, 26)
            $btn.ForeColor = $tierColor
            $btn.FlatAppearance.BorderColor = $tierColor
            $btn.Add_Click({ Invoke-Safe -OutputBox $outputBox -Action { & $this.Tag.RunAction } })
        }
    }
    $tile.Controls.Add($btn)
    return $tile
}

function Update-TileFilter {
    # Hides a section's header too when none of its tiles match the current filter, so filtering
    # to e.g. "Review First" doesn't leave empty section labels with nothing under them. Takes
    # -Board explicitly since every tab now has its own independent board (see New-TileBoard).
    param([System.Windows.Forms.FlowLayoutPanel]$Board, [string]$Filter)
    $currentHeader = $null
    $headerVisible = @{}
    foreach ($ctrl in $Board.Controls) {
        if ($ctrl.Tag -eq 'SectionHeader') {
            $currentHeader = $ctrl
            $headerVisible[$currentHeader] = $false
        } elseif ($ctrl.Tag -and $ctrl.Tag.Tier) {
            $isVisible = ($Filter -eq 'All') -or ($ctrl.Tag.Tier -eq $Filter)
            $ctrl.Visible = $isVisible
            if ($isVisible -and $currentHeader) { $headerVisible[$currentHeader] = $true }
        }
    }
    foreach ($header in $headerVisible.Keys) { $header.Visible = $headerVisible[$header] }
}

function New-FilterChip {
    param([string]$Text, [string]$Filter, [int]$X, [System.Drawing.Color]$Color)
    $chip = New-Object System.Windows.Forms.Button
    $chip.Text = $Text
    $chip.Size = New-Object System.Drawing.Size(120, 24)
    $chip.Location = New-Object System.Drawing.Point($X, 3)
    $chip.FlatStyle = 'Flat'
    $chip.FlatAppearance.BorderSize = 1
    $chip.FlatAppearance.BorderColor = $Color
    $chip.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $chip.ForeColor = $Color
    $chip.BackColor = [System.Drawing.Color]::FromArgb(22, 18, 26)
    $chip.Tag = $Filter
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

    $chipAll = New-FilterChip -Text "All" -Filter 'All' -X 0 -Color ([System.Drawing.Color]::FromArgb(180, 176, 190))
    $chipAdjust = New-FilterChip -Text "Adjust" -Filter 'Adjust' -X 124 -Color $global:AccentOrange
    $chipCheck = New-FilterChip -Text "Read-only" -Filter 'Check' -X 248 -Color ([System.Drawing.Color]::FromArgb(125, 211, 252))
    $chipReview = New-FilterChip -Text "Review First" -Filter 'Review' -X 372 -Color ([System.Drawing.Color]::FromArgb(251, 191, 36))
    $chips = @($chipAll, $chipAdjust, $chipCheck, $chipReview)
    foreach ($chip in $chips) {
        $chip.Tag = [PSCustomObject]@{ Board = $board; Filter = $chip.Tag; Siblings = $chips }
        $chipRow.Controls.Add($chip)
    }
    foreach ($c in $chips) {
        $c.Add_Click({
            foreach ($other in $this.Tag.Siblings) {
                $other.BackColor = [System.Drawing.Color]::FromArgb(22, 18, 26)
                $other.ForeColor = $other.FlatAppearance.BorderColor
            }
            $this.BackColor = $this.FlatAppearance.BorderColor
            $this.ForeColor = [System.Drawing.Color]::FromArgb(8, 8, 10)
            Update-TileFilter -Board $this.Tag.Board -Filter $this.Tag.Filter
        })
    }
    # "All" starts selected
    $chipAll.BackColor = $chipAll.FlatAppearance.BorderColor
    $chipAll.ForeColor = [System.Drawing.Color]::FromArgb(8, 8, 10)

    return $board
}

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
$splitContainer.BackColor = [System.Drawing.Color]::FromArgb(40, 32, 46)
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
# New-TileBoard (defined further below, hoisted like every other function in this script) builds
# the shared chip-row + scrollable board plumbing now reused by every tab.
$script:WinBoard = New-TileBoard -Parent $panelWindows

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
    param([string]$Section, $Sections = $script:Sections)
    $activeBg = [System.Drawing.Color]::FromArgb(40, 32, 46)
    $inactiveBg = [System.Drawing.Color]::FromArgb(14, 14, 16)
    $activeFg = $global:AccentOrange
    $inactiveFg = [System.Drawing.Color]::FromArgb(150, 150, 155)

    foreach ($s in $Sections) {
        $isActive = $s.Name -eq $Section
        $s.Panel.Visible = $isActive
        $s.Button.BackColor = if ($isActive) { $activeBg } else { $inactiveBg }
        $s.Button.ForeColor = if ($isActive) { $activeFg } else { $inactiveFg }
    }
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
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(8, 8, 10)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Message
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $lbl.AutoSize = $false
    $lbl.Size = New-Object System.Drawing.Size(320, 40)
    $lbl.Location = New-Object System.Drawing.Point(15, 15)
    $dlg.Controls.Add($lbl)

    $btnA = New-Object System.Windows.Forms.Button
    $btnA.Text = $OptionA
    $btnA.Size = New-Object System.Drawing.Size(150, 40)
    $btnA.Location = New-Object System.Drawing.Point(15, 80)
    $btnA.FlatStyle = 'Flat'
    $btnA.FlatAppearance.BorderSize = 2
    $btnA.FlatAppearance.BorderColor = $global:AccentPurple
    $btnA.BackColor = [System.Drawing.Color]::FromArgb(22, 18, 26)
    $btnA.ForeColor = [System.Drawing.Color]::White
    $btnA.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $dlg.Controls.Add($btnA)

    $btnB = New-Object System.Windows.Forms.Button
    $btnB.Text = $OptionB
    $btnB.Size = New-Object System.Drawing.Size(150, 40)
    $btnB.Location = New-Object System.Drawing.Point(175, 80)
    $btnB.FlatStyle = 'Flat'
    $btnB.FlatAppearance.BorderSize = 2
    $btnB.FlatAppearance.BorderColor = $global:AccentOrange
    $btnB.BackColor = [System.Drawing.Color]::FromArgb(22, 18, 26)
    $btnB.ForeColor = [System.Drawing.Color]::White
    $btnB.DialogResult = [System.Windows.Forms.DialogResult]::No
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
            -InstalledNamePattern '*Heaven*' `
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

$script:WinBoard.Controls.Add((New-SectionHeader "Startup Apps"))
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Startup Apps" -Description "Lists what's currently set to launch when Windows starts, and opens Settings to change it." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-StartupAppsText)
        Start-Process "ms-settings:startupapps"
    }))

$script:WinBoard.Controls.Add((New-SectionHeader "Taskbar & Start"))
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
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
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
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
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle -OnLabel "CENTER" -OffLabel "LEFT" `
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

$script:WinBoard.Controls.Add((New-SectionHeader "Theme & Color"))
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle -OnLabel "DARK" -OffLabel "LIGHT" `
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
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Action `
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
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Action `
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

$script:WinBoard.Controls.Add((New-SectionHeader "Context Menu"))
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle -OnLabel "CLASSIC" -OffLabel "DEFAULT" `
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

$script:WinBoard.Controls.Add((New-SectionHeader "Windows Features"))
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle `
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
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle `
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

$script:WinBoard.Controls.Add((New-SectionHeader "Gaming Tweaks"))
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle `
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
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle `
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
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Game Mode Check" -Description "Shows whether Windows' Game Mode is currently on and opens Settings to change it." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-GameModeText)
        Start-Process "ms-settings:gaming-gamemode"
    }))
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Sound Devices" -Description "Opens the Sound panel to check for the wrong default mic/speaker (e.g. a webcam mic or HDMI passthrough)." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-SoundDevicesText)
        Start-Process "control.exe" -ArgumentList "mmsys.cpl"
    }))

$script:WinBoard.Controls.Add((New-SectionHeader "Debloat"))
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Action `
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
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Action `
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
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle -OnLabel "TRIMMED" -OffLabel "DEFAULT" `
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
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
    -Title "Process Count Check" -Description "Shows how many processes are currently running and opens Task Manager." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-ProcessCountText)
        Start-Process taskmgr.exe
    }))
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
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

$script:WinBoard.Controls.Add((New-SectionHeader "Performance"))
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Adjust -ControlType Toggle -OnLabel "IPV4-ONLY" -OffLabel "DEFAULT" `
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
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
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
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
    -Title "Reset Power Plans" -Description "Restores Windows' normal Balanced/Power Saver/High Performance set. Doesn't recreate any custom plans that were previously deleted." `
    -RunAction {
        Write-ToolOutput $outputBox (Get-PowerPlanText)
        & powercfg -restoredefaultschemes
        Write-ToolOutput $outputBox "Power plans reset to Windows' default set (Balanced active)."
    }))
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Review -ControlType Action `
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
$script:WinBoard.Controls.Add((New-SettingsTile -Tier Check -ControlType Check `
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
$btnOpenTools.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
$btnOpenTools.ForeColor = [System.Drawing.Color]::White
$btnOpenTools.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($btnOpenTools)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = "Clear Output"
$btnClear.Size = New-Object System.Drawing.Size(150, 30)
$btnClear.Location = New-Object System.Drawing.Point(175, 822)
$btnClear.FlatStyle = 'Flat'
$btnClear.FlatAppearance.BorderSize = 0
$btnClear.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
$btnClear.ForeColor = [System.Drawing.Color]::White
$btnClear.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($btnClear)

$btnRestartExplorer = New-Object System.Windows.Forms.Button
$btnRestartExplorer.Text = "Restart Explorer"
$btnRestartExplorer.Size = New-Object System.Drawing.Size(150, 30)
$btnRestartExplorer.Location = New-Object System.Drawing.Point(335, 822)
$btnRestartExplorer.FlatStyle = 'Flat'
$btnRestartExplorer.FlatAppearance.BorderSize = 0
$btnRestartExplorer.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
$btnRestartExplorer.ForeColor = [System.Drawing.Color]::White
$btnRestartExplorer.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
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
})

try {
    $darkMode = 1
    # attribute 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (Windows 10 20H1+ / Windows 11).
    # Accessing .Handle forces the window handle to exist before the app loop starts.
    [DwmHelper]::DwmSetWindowAttribute($form.Handle, 20, [ref]$darkMode, 4) | Out-Null
} catch { }

[System.Windows.Forms.Application]::Run($form)
