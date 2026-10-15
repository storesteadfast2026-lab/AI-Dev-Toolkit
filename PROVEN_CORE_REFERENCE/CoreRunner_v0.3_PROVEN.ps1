$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogsDir = Join-Path $ScriptRoot "LOGS"
$TempDir = Join-Path $ScriptRoot "TEMP"

New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Process = $null
$script:LogPath = $null
$script:WrapperPath = $null
$script:LastText = ""
$script:StartedAt = $null
$script:CompletedHandled = $false

function Get-SafeName([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return "Script" }
    return ($Value -replace '[^A-Za-z0-9_-]', '_')
}

function Read-LogText {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }

    try {
        $fs = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::Default, $true)
            try {
                return $sr.ReadToEnd()
            }
            finally {
                $sr.Dispose()
            }
        }
        finally {
            $fs.Dispose()
        }
    }
    catch {
        return $script:LastText
    }
}

function Append-LogFooter {
    param(
        [string]$Path,
        [int]$ExitCode
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    $result = if ($ExitCode -eq 0) { "PASS" } else { "FAIL" }
    $lines = @(
        ""
        "============================================================"
        "[AOM] PROCESS FINISHED - EXIT CODE: $ExitCode"
        "[AOM] RESULT: $result"
        ("[AOM] Finished: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
        "============================================================"
    )

    try {
        Add-Content -LiteralPath $Path -Value $lines -Encoding Default
    }
    catch {
    }
}

function Kill-ProcessTree {
    param([int]$Pid)

    if ($Pid -le 0) { return }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "taskkill.exe"
        $psi.Arguments = "/PID $Pid /T /F"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        $p.WaitForExit(5000) | Out-Null
        $p.Dispose()
    }
    catch {
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "AOM Core Log Runner v0.3 - PowerShell"
$form.Size = New-Object System.Drawing.Size(1040, 760)
$form.MinimumSize = New-Object System.Drawing.Size(820, 600)
$form.StartPosition = "CenterScreen"

$title = New-Object System.Windows.Forms.Label
$title.Text = "AOM Core Log Runner"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(18, 15)
$form.Controls.Add($title)

$scriptLabel = New-Object System.Windows.Forms.Label
$scriptLabel.Text = "BAT/CMD script:"
$scriptLabel.AutoSize = $true
$scriptLabel.Location = New-Object System.Drawing.Point(20, 65)
$form.Controls.Add($scriptLabel)

$scriptBox = New-Object System.Windows.Forms.TextBox
$scriptBox.Location = New-Object System.Drawing.Point(120, 61)
$scriptBox.Size = New-Object System.Drawing.Size(640, 25)
$scriptBox.Anchor = "Top,Left,Right"
$form.Controls.Add($scriptBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse..."
$browseButton.Location = New-Object System.Drawing.Point(775, 59)
$browseButton.Size = New-Object System.Drawing.Size(100, 30)
$browseButton.Anchor = "Top,Right"
$form.Controls.Add($browseButton)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "RUN"
$runButton.Location = New-Object System.Drawing.Point(885, 59)
$runButton.Size = New-Object System.Drawing.Size(115, 30)
$runButton.Anchor = "Top,Right"
$form.Controls.Add($runButton)

$preFeedCheck = New-Object System.Windows.Forms.CheckBox
$preFeedCheck.Text = "PRE-FEED ONE ENTER (only for scripts with a simple final PAUSE)"
$preFeedCheck.Checked = $true
$preFeedCheck.AutoSize = $true
$preFeedCheck.Location = New-Object System.Drawing.Point(120, 95)
$form.Controls.Add($preFeedCheck)

$statusCaption = New-Object System.Windows.Forms.Label
$statusCaption.Text = "Status:"
$statusCaption.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$statusCaption.AutoSize = $true
$statusCaption.Location = New-Object System.Drawing.Point(20, 130)
$form.Controls.Add($statusCaption)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "IDLE"
$statusLabel.AutoSize = $true
$statusLabel.Location = New-Object System.Drawing.Point(72, 130)
$form.Controls.Add($statusLabel)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = "CANCEL"
$cancelButton.Enabled = $false
$cancelButton.Location = New-Object System.Drawing.Point(885, 120)
$cancelButton.Size = New-Object System.Drawing.Size(115, 30)
$cancelButton.Anchor = "Top,Right"
$form.Controls.Add($cancelButton)

$openLogsButton = New-Object System.Windows.Forms.Button
$openLogsButton.Text = "Open Logs Folder"
$openLogsButton.Location = New-Object System.Drawing.Point(745, 120)
$openLogsButton.Size = New-Object System.Drawing.Size(130, 30)
$openLogsButton.Anchor = "Top,Right"
$form.Controls.Add($openLogsButton)

$logCaption = New-Object System.Windows.Forms.Label
$logCaption.Text = "Current log:"
$logCaption.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$logCaption.AutoSize = $true
$logCaption.Location = New-Object System.Drawing.Point(20, 165)
$form.Controls.Add($logCaption)

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = "No run yet"
$logLabel.AutoEllipsis = $true
$logLabel.Location = New-Object System.Drawing.Point(100, 165)
$logLabel.Size = New-Object System.Drawing.Size(880, 22)
$logLabel.Anchor = "Top,Left,Right"
$form.Controls.Add($logLabel)

$outputBox = New-Object System.Windows.Forms.RichTextBox
$outputBox.Location = New-Object System.Drawing.Point(20, 195)
$outputBox.Size = New-Object System.Drawing.Size(980, 460)
$outputBox.Anchor = "Top,Bottom,Left,Right"
$outputBox.Font = New-Object System.Drawing.Font("Consolas", 10)
$outputBox.ReadOnly = $true
$outputBox.WordWrap = $false
$outputBox.BackColor = [System.Drawing.Color]::White
$outputBox.Text = "Select a .bat/.cmd file and press RUN.`r`n"
$form.Controls.Add($outputBox)

$footer = New-Object System.Windows.Forms.Label
$footer.Text = "The window displays only the current .log. Windows CMD writes stdout + stderr directly to that file."
$footer.ForeColor = [System.Drawing.Color]::DimGray
$footer.AutoSize = $true
$footer.Location = New-Object System.Drawing.Point(20, 670)
$footer.Anchor = "Bottom,Left"
$form.Controls.Add($footer)

$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Filter = "Windows scripts (*.bat;*.cmd)|*.bat;*.cmd|All files (*.*)|*.*"
$dialog.Title = "Select BAT/CMD script"

$browseButton.Add_Click({
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $scriptBox.Text = $dialog.FileName
    }
})

$openLogsButton.Add_Click({
    try {
        Start-Process explorer.exe -ArgumentList "`"$LogsDir`""
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "Open Logs Folder",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$runButton.Add_Click({
    try {
        if ($script:Process -ne $null -and -not $script:Process.HasExited) {
            [System.Windows.Forms.MessageBox]::Show(
                "A process is already running.",
                "AOM Core Log Runner",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        $scriptPath = $scriptBox.Text.Trim().Trim('"')
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Select an existing .bat or .cmd file.",
                "AOM Core Log Runner",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        $ext = [System.IO.Path]::GetExtension($scriptPath).ToLowerInvariant()
        if ($ext -ne ".bat" -and $ext -ne ".cmd") {
            [System.Windows.Forms.MessageBox]::Show(
                "This core test supports only .bat/.cmd files.",
                "AOM Core Log Runner",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $stem = Get-SafeName ([System.IO.Path]::GetFileNameWithoutExtension($scriptPath))
        $script:LogPath = Join-Path $LogsDir ("CoreRunner_{0}_{1}.log" -f $stem, $stamp)
        $script:WrapperPath = Join-Path $TempDir ("__AOM_RUN_{0}.cmd" -f $stamp)
        $script:LastText = ""
        $script:StartedAt = Get-Date
        $script:CompletedHandled = $false

        $header = @(
            "============================================================"
            "AOM CORE LOG RUNNER v0.3 - POWERSHELL"
            "============================================================"
            ("Script: {0}" -f $scriptPath)
            ("Working directory: {0}" -f ([System.IO.Path]::GetDirectoryName($scriptPath)))
            ("Started: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
            ("Pre-feed one Enter: {0}" -f $(if ($preFeedCheck.Checked) { "YES" } else { "NO" }))
            "Output transport: Windows CMD stdout + stderr -> this .log"
            "============================================================"
            ""
        )
        Set-Content -LiteralPath $script:LogPath -Value $header -Encoding Default

        $escapedScript = $scriptPath.Replace('"', '""')
        $escapedLog = $script:LogPath.Replace('"', '""')

        $wrapper = New-Object System.Collections.Generic.List[string]
        $wrapper.Add("@echo off")
        $wrapper.Add("setlocal EnableExtensions")
        if ($preFeedCheck.Checked) {
            $wrapper.Add("(echo.) | call `"$escapedScript`" >> `"$escapedLog`" 2>&1")
        }
        else {
            $wrapper.Add("call `"$escapedScript`" >> `"$escapedLog`" 2>&1")
        }
        $wrapper.Add("set `"RC=%ERRORLEVEL%`"")
        $wrapper.Add("exit /b %RC%")
        Set-Content -LiteralPath $script:WrapperPath -Value $wrapper -Encoding Ascii

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/d /q /c call "' + $script:WrapperPath + '"'
        $psi.WorkingDirectory = [System.IO.Path]::GetDirectoryName($scriptPath)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $script:Process = New-Object System.Diagnostics.Process
        $script:Process.StartInfo = $psi

        if (-not $script:Process.Start()) {
            throw "Windows could not start cmd.exe."
        }

        $statusLabel.Text = "RUNNING - PID $($script:Process.Id)"
        $logLabel.Text = [System.IO.Path]::GetFileName($script:LogPath)
        $runButton.Enabled = $false
        $cancelButton.Enabled = $true
        $outputBox.Clear()
    }
    catch {
        $statusLabel.Text = "FAIL - start error"
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "AOM Core Log Runner - Start Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$cancelButton.Add_Click({
    if ($script:Process -eq $null) { return }

    try {
        if (-not $script:Process.HasExited) {
            Add-Content -LiteralPath $script:LogPath -Value "" -Encoding Default
            Add-Content -LiteralPath $script:LogPath -Value "[AOM] CANCEL REQUESTED" -Encoding Default
            Kill-ProcessTree -Pid $script:Process.Id
        }
    }
    catch {
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    try {
        if ($script:LogPath -and (Test-Path -LiteralPath $script:LogPath -PathType Leaf)) {
            $current = Read-LogText -Path $script:LogPath
            if ($current -ne $script:LastText) {
                $script:LastText = $current
                $outputBox.Text = $current
                $outputBox.SelectionStart = $outputBox.TextLength
                $outputBox.ScrollToCaret()
            }
        }

        if ($script:Process -ne $null) {
            if (-not $script:Process.HasExited) {
                if ($script:StartedAt) {
                    $elapsed = [int]((Get-Date) - $script:StartedAt).TotalSeconds
                    $statusLabel.Text = "RUNNING - ${elapsed}s"
                }
            }
            elseif (-not $script:CompletedHandled) {
                $script:CompletedHandled = $true
                $exitCode = $script:Process.ExitCode

                Append-LogFooter -Path $script:LogPath -ExitCode $exitCode

                if ($exitCode -eq 0) {
                    $statusLabel.Text = "PASS - exit code 0"
                }
                else {
                    $statusLabel.Text = "FAIL - exit code $exitCode"
                }

                $runButton.Enabled = $true
                $cancelButton.Enabled = $false

                try { $script:Process.Dispose() } catch {}
                $script:Process = $null
            }
        }
    }
    catch {
        $statusLabel.Text = "WARN - refresh error"
    }
})
$timer.Start()

$form.Add_FormClosing({
    if ($script:Process -ne $null) {
        try {
            if (-not $script:Process.HasExited) {
                Kill-ProcessTree -Pid $script:Process.Id
            }
        }
        catch {
        }
    }
})

[void]$form.ShowDialog()
