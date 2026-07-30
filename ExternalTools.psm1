<#
    ExternalTools.psm1
    -------------------
    Launches tools cached in a Tools folder, falling back to the vendor's
    OFFICIAL download page (never a hardcoded exe URL) when a tool isn't
    cached yet. Also has the shared RichTextBox output helpers used by every
    check/tool button in the Toolkit.

    Requires System.Windows.Forms / System.Drawing to already be loaded
    (Add-Type -AssemblyName ...) BEFORE this module is imported, since these
    function signatures reference those types directly.

    Write-ToolOutput's "===...===" header-line color defaults to
    $global:ConsoleHeaderColor - the Toolkit sets that as a global (not script)
    variable specifically so it's visible here across the module boundary. The
    output console intentionally stays a fixed dark look in both Light and Dark
    app themes, so this color is a constant, never swapped by Set-AppTheme.
#>

function Write-ToolOutput {
    param(
        [System.Windows.Forms.RichTextBox]$Box,
        [string]$Text,
        [System.Drawing.Color]$HeaderColor = $global:ConsoleHeaderColor
    )
    foreach ($line in ($Text -split "`n")) {
        $Box.SelectionStart = $Box.TextLength
        $Box.SelectionLength = 0
        if ($line -match '^===.*===$') {
            $Box.SelectionColor = $HeaderColor
            $Box.SelectionFont = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
        } else {
            $Box.SelectionColor = $Box.ForeColor
            $Box.SelectionFont = $Box.Font
        }
        $Box.AppendText("$line`r`n")
    }
    $Box.AppendText("`r`n")
    $Box.SelectionStart = $Box.TextLength
    $Box.ScrollToCaret()
}

function Invoke-Safe {
    param([scriptblock]$Action, [System.Windows.Forms.RichTextBox]$OutputBox)
    try { & $Action } catch { Write-ToolOutput $OutputBox ("ERROR: " + $_.Exception.Message) }
}

function Find-InstalledTool {
    param([string]$NamePattern, [string[]]$ExeNames)
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entries = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $NamePattern }

    foreach ($entry in $entries) {
        $searchDirs = @()
        if ($entry.InstallLocation -and (Test-Path $entry.InstallLocation)) {
            $searchDirs += $entry.InstallLocation
        }
        if ($entry.DisplayIcon) {
            # DisplayIcon often points at the uninstaller itself (a common Inno
            # Setup/NSIS quirk, confirmed live with MSI Afterburner) - only use
            # it to locate the install folder, never launch that file directly.
            $iconPath = ($entry.DisplayIcon -split ',')[0].Trim('"')
            $iconDir = Split-Path $iconPath -Parent -ErrorAction SilentlyContinue
            if ($iconDir -and (Test-Path $iconDir)) { $searchDirs += $iconDir }
        }
        foreach ($dir in ($searchDirs | Select-Object -Unique)) {
            foreach ($exe in $ExeNames) {
                $exeName = Split-Path $exe -Leaf
                $match = Get-ChildItem -Path $dir -Filter $exeName -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($match) { return $match.FullName }
            }
        }
    }
    return $null
}

function Invoke-ExternalTool {
    param(
        [string]$Name,
        [string[]]$Candidates,
        [string]$DownloadUrl,
        [string]$ToolsDir,
        [System.Windows.Forms.RichTextBox]$OutputBox,
        [string]$Note = "",
        [string]$InstalledNamePattern = "",
        [string]$ArgumentList = "",
        [switch]$Wait
    )
    $found = $null
    foreach ($c in $Candidates) {
        $p = Join-Path $ToolsDir $c
        if (Test-Path $p) { $found = $p; break }
    }
    $installed = $null
    if (-not $found -and $InstalledNamePattern) {
        $installed = Find-InstalledTool -NamePattern $InstalledNamePattern -ExeNames $Candidates
    }
    if ($found) {
        Write-ToolOutput $OutputBox "Launching $Name from Tools folder ($found)..."
        if ($ArgumentList) { Start-Process -FilePath $found -ArgumentList $ArgumentList -Wait:$Wait } else { Start-Process -FilePath $found }
        return $true
    } elseif ($installed) {
        Write-ToolOutput $OutputBox "$Name is already installed on this PC - launching it directly ($installed)..."
        if ($ArgumentList) { Start-Process -FilePath $installed -ArgumentList $ArgumentList -Wait:$Wait } else { Start-Process -FilePath $installed }
        return $true
    } else {
        Write-ToolOutput $OutputBox "$Name not found in: $ToolsDir"
        Write-ToolOutput $OutputBox "Opening the official $Name download page and the Tools folder..."
        Start-Process $DownloadUrl
        Start-Process explorer.exe $ToolsDir
        $noteBlock = if ($Note) { "`n`n$Note" } else { "" }
        [System.Windows.Forms.MessageBox]::Show(
            "$Name isn't in the Tools folder yet.`n`nThe official download page just opened ($DownloadUrl), and the Tools folder is open too.`nSave the .exe there (drag it straight into that window), then click this button again.$noteBlock",
            "$Name Not Found",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return $false
    }
}

Export-ModuleMember -Function Write-ToolOutput, Invoke-Safe, Invoke-ExternalTool
