param([switch]$SmokeTest)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppHome = Join-Path $env:LOCALAPPDATA "ApplicationOperationsManagerPS"
$StateDir = Join-Path $AppHome "STATE"
$VerifiedRoot = Join-Path $AppHome "Packages"
$ConfigPath = Join-Path $AppHome "config.json"
$DefaultConfigPath = Join-Path $ScriptRoot "config.default.json"
$PackageStatePath = Join-Path $StateDir "package_states.json"
$ExecutionStatePath = Join-Path $StateDir "execution_states.json"
$InstalledStatePath = Join-Path $StateDir "installed_states.json"
$SelectedApplicationStatePath = Join-Path $StateDir "selected_application.txt"
$ArchiveNoConfirmStatePath = Join-Path $StateDir "archive_no_confirm.txt"
$PromptLibraryDir = Join-Path $AppHome "PROMPT_LIBRARY"
$PromptIndexPath = Join-Path $PromptLibraryDir "prompts_index.json"

# Manager-wide storage defaults. These may be overridden by config.json.
$TempRoot = Join-Path $AppHome "TEMP"
$OutputRoot = Join-Path $AppHome "OUTPUT"
$LogsDir = Join-Path $AppHome "LOGS"

New-Item -ItemType Directory -Force -Path $AppHome | Out-Null
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf) -and
    (Test-Path -LiteralPath $DefaultConfigPath -PathType Leaf)) {
    Copy-Item -LiteralPath $DefaultConfigPath -Destination $ConfigPath -Force
}

# Bootstrap storage paths early because logs/TEMP are required before the UI loads.
try {
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $bootstrapConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $storageProp = $bootstrapConfig.PSObject.Properties['storage']
        if ($null -ne $storageProp -and $null -ne $storageProp.Value) {
            $bootstrapStorage = $storageProp.Value
            foreach ($def in @(
                @('temp_folder','TempRoot'),
                @('output_folder','OutputRoot'),
                @('logs_folder','LogsDir')
            )) {
                $prop = $bootstrapStorage.PSObject.Properties[[string]$def[0]]
                if ($null -ne $prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
                    $resolved = [Environment]::ExpandEnvironmentVariables([string]$prop.Value)
                    $resolved = $resolved.Replace("%APP_HOME%", $AppHome)
                    Set-Variable -Scope Script -Name ([string]$def[1]) -Value $resolved
                }
            }
        }
    }
}
catch {
    # Fall back to the default AppHome folders. Full config validation occurs later.
}

foreach ($p in @($AppHome,$LogsDir,$TempRoot,$OutputRoot,$StateDir,$VerifiedRoot,$PromptLibraryDir)) {
    New-Item -ItemType Directory -Force -Path $p | Out-Null
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName Microsoft.VisualBasic

if (-not ("AomNativeMethods" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AomNativeMethods {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
}
"@
}

$script:Config = $null
$script:SelectedApp = $null
$script:PackagePaths = @()
$script:CurrentPackagePath = $null
$script:CurrentPackageInspection = $null
$script:Process = $null
$script:RunContext = $null
$script:LastLogText = ""
$script:SessionAttempts = New-Object 'System.Collections.Generic.HashSet[string]'
$script:RecentLogPaths = @()
$script:RecentHandoffPaths = @()
$script:LastActionExecutionKey = ""
$script:LastObservedLogLength = -1
$script:MaxLiveLogChars = 200000
$script:LatestGeneratedOutputPath = $null
$script:DrQuickScriptsPanel = $null
$script:ArchivePackageBtn = $null
$script:PromptRecords = @()
$script:PromptCurrentId = ''
$script:PromptDirty = $false
$script:PromptIsNew = $false
$script:PromptSuppressEvents = $false
$script:PromptSuppressSelection = $false
$script:PromptAutoSaveTimer = $null

function Expand-ConfigPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    $expanded = $expanded.Replace("%APP_HOME%", $AppHome)
    return $expanded
}

function Get-DisplayDateTime([datetime]$Value) {
    return $Value.ToString('dd/MM/yyyy HH:mm:ss')
}

function Get-SafeName([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return "Application" }
    return (($Value -replace '[^A-Za-z0-9]+','_').Trim('_'))
}

function Read-TextShared([string]$Path) {
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
            try { return $sr.ReadToEnd() }
            finally { $sr.Dispose() }
        }
        finally { $fs.Dispose() }
    }
    catch { return $script:LastLogText }
}

function Scroll-RichTextBoxToBottom([System.Windows.Forms.RichTextBox]$Box) {
    if ($null -eq $Box) { return }
    try {
        $Box.SelectionStart = $Box.TextLength
        $Box.SelectionLength = 0
        $Box.ScrollToCaret()
        # Force the vertical scrollbar to the bottom without stealing keyboard focus.
        [void][AomNativeMethods]::SendMessage($Box.Handle, 0x0115, [IntPtr]7, [IntPtr]::Zero)
    }
    catch {}
}

function Get-LogLineColor([string]$Line) {
    if ($null -eq $Line) { return [System.Drawing.SystemColors]::WindowText }
    if ($Line -match '(?i)\[FAIL\]|RESULT\s*:\s*FAIL|SCRIPT RESULT\s*:\s*FAIL|\[ERROR\]|\bERROR\b|EXIT CODE\s*:\s*[1-9][0-9]*') {
        return [System.Drawing.Color]::Red
    }
    if ($Line -match '(?i)\[WARN\]|\bWARNING\b|RESULT\s*:\s*CANCELLED') {
        return [System.Drawing.Color]::Goldenrod
    }
    if ($Line -match '(?i)\[PASS\]|RESULT\s*:\s*PASS|SCRIPT RESULT\s*:\s*PASS|EXIT CODE\s*:\s*0') {
        return [System.Drawing.Color]::Green
    }
    return [System.Drawing.SystemColors]::WindowText
}

function Add-DisplayTimestamps(
    [string]$Text,
    [datetime]$Timestamp,
    [bool]$PrefixFirstLine=$true
) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $stamp = Get-DisplayDateTime $Timestamp
    $parts = [System.Text.RegularExpressions.Regex]::Split($Text, '(\r\n|\n|\r)')
    $sb = New-Object System.Text.StringBuilder
    $atLineStart = $PrefixFirstLine

    foreach ($part in $parts) {
        if ($part -eq "`r`n" -or $part -eq "`n" -or $part -eq "`r") {
            [void]$sb.Append($part)
            $atLineStart = $true
            continue
        }

        if ($part.Length -eq 0) { continue }

        if ($atLineStart) {
            # Do not double-prefix lines that already begin with the standard timestamp.
            if ($part -match '^\d{2}/\d{2}/\d{4}\s+\d{2}:\d{2}:\d{2}\s') {
                [void]$sb.Append($part)
            }
            else {
                [void]$sb.Append($stamp)
                [void]$sb.Append(' ')
                [void]$sb.Append($part)
            }
        }
        else {
            [void]$sb.Append($part)
        }

        $atLineStart = $false
    }

    return $sb.ToString()
}

function Append-ColouredLogText([System.Windows.Forms.RichTextBox]$Box, [string]$Text) {
    if ($null -eq $Box -or [string]::IsNullOrEmpty($Text)) { return }
    $parts = [System.Text.RegularExpressions.Regex]::Split($Text, '(?<=\n)')
    foreach ($part in $parts) {
        if ($part.Length -eq 0) { continue }
        $Box.SelectionStart = $Box.TextLength
        $Box.SelectionLength = 0
        $Box.SelectionColor = Get-LogLineColor $part
        $Box.AppendText($part)
    }
    $Box.SelectionColor = [System.Drawing.SystemColors]::WindowText
}

function Set-ColouredLogText([System.Windows.Forms.RichTextBox]$Box, [string]$Text) {
    if ($null -eq $Box) { return }
    $Box.Clear()
    Append-ColouredLogText $Box $Text
}

function Copy-DisplayedExecutionLog(
    [System.Windows.Forms.RichTextBox]$LogViewer,
    [System.Windows.Forms.Button]$CopyButton
) {
    if ($null -eq $LogViewer -or $null -eq $CopyButton) { return }

    # Copy the entire in-memory RichTextBox content, not merely selected text
    # or the current viewport. This also works if the underlying .log file is
    # missing or unreadable after it was displayed.
    $displayedText = [string]$LogViewer.Text
    if ([string]::IsNullOrEmpty($displayedText)) {
        $CopyButton.Text = 'NO LOG'
        return
    }

    try {
        [System.Windows.Forms.Clipboard]::SetText(
            $displayedText,
            [System.Windows.Forms.TextDataFormat]::UnicodeText
        )
        $CopyButton.Text = 'COPIED'
    }
    catch {
        $CopyButton.Text = 'COPY FAILED'
        [void][System.Windows.Forms.MessageBox]::Show(
            ('The displayed log could not be copied to the clipboard: ' + $_.Exception.Message),
            'Copy Log',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

function Update-LiveLogBox([System.Windows.Forms.RichTextBox]$Box, [string]$Text) {
    if ($null -eq $Box) { return }
    if ($null -eq $Text) { $Text = '' }
    if ($Text -eq $script:LastLogText) { return }

    # Keep the physical .log complete, but cap the WinForms viewer to prevent
    # large/fast logs from progressively freezing the UI.
    $visibleText = $Text
    $truncated = $false
    if ($Text.Length -gt $script:MaxLiveLogChars) {
        $visibleText = $Text.Substring($Text.Length - $script:MaxLiveLogChars)
        $truncated = $true
    }

    try {
        if (-not $truncated -and $Text.StartsWith($script:LastLogText)) {
            $previousRaw = $script:LastLogText
            $delta = $Text.Substring($previousRaw.Length)

            if ($delta.Length -gt 0) {
                # Timestamp every line as it arrives in the on-screen viewer.
                # If a polling cycle starts in the middle of a line, do not
                # insert another timestamp into that same line.
                $prefixFirst = (
                    [string]::IsNullOrEmpty($previousRaw) -or
                    $previousRaw.EndsWith("`r`n") -or
                    $previousRaw.EndsWith("`n") -or
                    $previousRaw.EndsWith("`r")
                )
                $displayDelta = Add-DisplayTimestamps $delta (Get-Date) $prefixFirst
                Append-ColouredLogText $Box $displayDelta
            }
        }
        else {
            $displayVisible = Add-DisplayTimestamps $visibleText (Get-Date) $true
            if ($truncated) {
                $notice = "$(Get-DisplayDateTime (Get-Date)) [AOM VIEW] Live display limited to the latest $($script:MaxLiveLogChars) characters. The physical log file remains complete.`r`n`r`n"
                Set-ColouredLogText $Box ($notice + $displayVisible)
            }
            else {
                Set-ColouredLogText $Box $displayVisible
            }
        }

        $script:LastLogText = $Text
        Scroll-RichTextBoxToBottom $Box
    }
    catch {
        try {
            $displayVisible = Add-DisplayTimestamps $visibleText (Get-Date) $true
            if ($truncated) {
                $notice = "$(Get-DisplayDateTime (Get-Date)) [AOM VIEW] Live display limited to the latest $($script:MaxLiveLogChars) characters. The physical log file remains complete.`r`n`r`n"
                Set-ColouredLogText $Box ($notice + $displayVisible)
            }
            else {
                Set-ColouredLogText $Box $displayVisible
            }
            $script:LastLogText = $Text
            Scroll-RichTextBoxToBottom $Box
        }
        catch {}
    }
}

function Write-JsonFile([string]$Path, $Object) {
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $Object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Load-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Copy-Item -LiteralPath $DefaultConfigPath -Destination $ConfigPath -Force
    }
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

        # Backward-compatible migration for configs created before v1.0.21.
        $storageProp = $cfg.PSObject.Properties['storage']
        if ($null -eq $storageProp -or $null -eq $storageProp.Value) {
            $storage = [pscustomobject]@{
                temp_folder = '%APP_HOME%\TEMP'
                output_folder = '%APP_HOME%\OUTPUT'
                logs_folder = '%APP_HOME%\LOGS'
                archive_folder = '%USERPROFILE%\Downloads\AOM_Archive'
                auto_clean_temp_after_success = $false
            }
            $cfg | Add-Member -NotePropertyName 'storage' -NotePropertyValue $storage
        }
        else {
            $storage = $storageProp.Value
            foreach ($def in @(
                @('temp_folder','%APP_HOME%\TEMP'),
                @('output_folder','%APP_HOME%\OUTPUT'),
                @('logs_folder','%APP_HOME%\LOGS'),
                @('archive_folder','%USERPROFILE%\Downloads\AOM_Archive'),
                @('auto_clean_temp_after_success',$false)
            )) {
                $p = $storage.PSObject.Properties[[string]$def[0]]
                if ($null -eq $p) {
                    $storage | Add-Member -NotePropertyName ([string]$def[0]) -NotePropertyValue $def[1]
                }
            }
        }

        # Backward-compatible Manager-wide installation path added in v1.0.46.
        $installProp = $cfg.PSObject.Properties['toolkit_install_folder']
        if ($null -eq $installProp -or [string]::IsNullOrWhiteSpace([string]$installProp.Value)) {
            if ($null -eq $installProp) {
                $cfg | Add-Member -NotePropertyName 'toolkit_install_folder' -NotePropertyValue 'C:\PythonProjects\APP AI DevToolkit'
            }
            else {
                $installProp.Value = 'C:\PythonProjects\APP AI DevToolkit'
            }
        }

        # Backward-compatible migration for DR Continuity Snapshot added in v1.0.31.
        foreach ($app in @($cfg.applications)) {
            $appId = [string](Get-PropertyValue $app 'id')
            $drScripts = Get-PropertyValue $app 'dr_scripts'
            if ($null -eq $drScripts) { continue }

            if ($null -eq $drScripts.PSObject.Properties['continuity_snapshot']) {
                $continuityScript = switch ($appId.ToUpperInvariant()) {
                    'PON'  { '07_Create_Continuity_Snapshot_PON.bat' }
                    'CALC' { '07_Create_Continuity_Snapshot_CALC.bat' }
                    default { '' }
                }
                if (-not [string]::IsNullOrWhiteSpace($continuityScript)) {
                    $drScripts | Add-Member -NotePropertyName 'continuity_snapshot' -NotePropertyValue $continuityScript
                }
            }
        }

        return $cfg
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not read configuration:`r`n$ConfigPath`r`n`r`n$($_.Exception.Message)",
            "Configuration error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        throw
    }
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}


function Apply-StorageConfig {
    if ($null -eq $script:Config) { return }

    $storage = Get-PropertyValue $script:Config 'storage'
    if ($null -eq $storage) { return }

    $tempRaw = [string](Get-PropertyValue $storage 'temp_folder')
    $outputRaw = [string](Get-PropertyValue $storage 'output_folder')
    $logsRaw = [string](Get-PropertyValue $storage 'logs_folder')

    $newTemp = Expand-ConfigPath $tempRaw
    $newOutput = Expand-ConfigPath $outputRaw
    $newLogs = Expand-ConfigPath $logsRaw

    if ([string]::IsNullOrWhiteSpace($newTemp)) { $newTemp = Join-Path $AppHome 'TEMP' }
    if ([string]::IsNullOrWhiteSpace($newOutput)) { $newOutput = Join-Path $AppHome 'OUTPUT' }
    if ([string]::IsNullOrWhiteSpace($newLogs)) { $newLogs = Join-Path $AppHome 'LOGS' }

    foreach ($p in @($newTemp,$newOutput,$newLogs)) {
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }

    $script:TempRoot = $newTemp
    $script:OutputRoot = $newOutput
    $script:LogsDir = $newLogs
}

function Get-AutoCleanTempAfterSuccess {
    $storage = Get-PropertyValue $script:Config 'storage'
    if ($null -eq $storage) { return $false }
    $value = Get-PropertyValue $storage 'auto_clean_temp_after_success'
    if ($null -eq $value) { return $false }
    return [System.Convert]::ToBoolean($value)
}

function Open-FolderSafe([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $resolved = Expand-ConfigPath $Path
    if ([string]::IsNullOrWhiteSpace($resolved)) { return }
    try {
        New-Item -ItemType Directory -Force -Path $resolved | Out-Null
        Start-Process explorer.exe -ArgumentList ('"' + $resolved + '"')
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not open folder:`r`n$resolved`r`n`r`n$($_.Exception.Message)",
            "Open folder failed"
        ) | Out-Null
    }
}

function Browse-FolderIntoTextBox([System.Windows.Forms.TextBox]$TextBox) {
    if ($null -eq $TextBox) { return }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select folder'
    $current = Expand-ConfigPath $TextBox.Text
    if (-not [string]::IsNullOrWhiteSpace($current) -and (Test-Path -LiteralPath $current -PathType Container)) {
        $dlg.SelectedPath = $current
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $TextBox.Text = $dlg.SelectedPath
    }
    $dlg.Dispose()
}

function Read-ZipEntryText($Zip, [string]$EntryName) {
    foreach ($entry in $Zip.Entries) {
        if ([System.IO.Path]::GetFileName($entry.FullName) -ieq $EntryName) {
            $stream = $entry.Open()
            try {
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
                try { return $reader.ReadToEnd() }
                finally { $reader.Dispose() }
            }
            finally { $stream.Dispose() }
        }
    }
    return $null
}

function Get-ScriptRank([string]$Name) {
    $norm = $Name.Replace('/','\')
    $parts = @($norm.Split('\'))
    $depth = $parts.Count
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()
    $rootRank = if ($depth -eq 1) { 0 } else { 1 }
    $extRank = if ($ext -eq '.bat' -or $ext -eq '.cmd') { 0 } else { 1 }
    $internalPenalty = 0
    if ($depth -gt 1) {
        for ($i=0; $i -lt $depth-1; $i++) {
            $p = $parts[$i].ToLowerInvariant()
            if ($p -eq '_internal' -or $p -eq 'internal' -or $p -eq 'support' -or $p -eq '_support') {
                $internalPenalty = 1
            }
        }
    }
    return [pscustomobject]@{ Name=$Name; Internal=$internalPenalty; Root=$rootRank; Ext=$extRank; Depth=$depth; Length=$Name.Length }
}

function Choose-Script($Candidates) {
    $list = @($Candidates)
    if ($list.Count -eq 0) { return $null }
    $ranked = foreach ($n in $list) { Get-ScriptRank $n }
    $selected = $ranked | Sort-Object Internal,Root,Ext,Depth,Length | Select-Object -First 1
    return $selected.Name
}

function Inspect-Package([string]$PackagePath) {
    $result = [ordered]@{
        Info = $null
        Operations = @{}
        Scripts = @()
        Release = $null
        Error = $null
    }
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
        try {
            $infoText = Read-ZipEntryText $zip "PACKAGE_INFO.json"
            if (-not [string]::IsNullOrWhiteSpace($infoText)) {
                try { $result.Info = $infoText | ConvertFrom-Json }
                catch { $result.Info = $null }
            }
            $releaseText = Read-ZipEntryText $zip "RELEASE_VERSION.txt"
            if (-not [string]::IsNullOrWhiteSpace($releaseText)) { $result.Release = $releaseText.Trim() }
            $scripts = @()
            foreach ($entry in $zip.Entries) {
                $ext = [System.IO.Path]::GetExtension($entry.FullName).ToLowerInvariant()
                if ($ext -eq '.bat' -or $ext -eq '.cmd' -or $ext -eq '.ps1') {
                    $scripts += $entry.FullName
                }
            }
            $result.Scripts = $scripts

            $metaOps = Get-PropertyValue $result.Info "operations"
            foreach ($key in @('apply','verify','rollback','continuity')) {
                $metaKey = if ($key -eq 'continuity') { 'continuity_snapshot' } else { $key }
                $target = Get-PropertyValue $metaOps $metaKey
                if (-not [string]::IsNullOrWhiteSpace([string]$target)) {
                    $result.Operations[$key] = [string]$target
                    continue
                }
                $words = switch ($key) {
                    'apply' { @('apply','install') }
                    'verify' { @('verify','validation','validate','check') }
                    'rollback' { @('rollback') }
                    'continuity' { @('continuity','snapshot') }
                }
                $candidates = @()
                foreach ($s in $scripts) {
                    $stem = [System.IO.Path]::GetFileNameWithoutExtension($s).ToLowerInvariant()
                    $match = $false
                    foreach ($w in $words) { if ($stem.Contains($w)) { $match = $true } }
                    if ($key -eq 'continuity' -and $stem.Contains('recovery')) { $match = $false }
                    if ($match) { $candidates += $s }
                }
                $chosen = Choose-Script $candidates
                if ($chosen) { $result.Operations[$key] = $chosen; continue }

                $prefixes = switch ($key) {
                    'apply' { @('02_apply','01_apply') }
                    'verify' { @('04_verify','02_verify') }
                    'rollback' { @('03_rollback') }
                    'continuity' { @('05_create_continuity','04_continuity') }
                }
                $fallback = @()
                foreach ($s in $scripts) {
                    $stem = [System.IO.Path]::GetFileNameWithoutExtension($s).ToLowerInvariant()
                    foreach ($prefix in $prefixes) {
                        if ($stem.StartsWith($prefix)) { $fallback += $s }
                    }
                }
                $chosen = Choose-Script $fallback
                if ($chosen) { $result.Operations[$key] = $chosen }
            }

            # Disaster Recovery operations are also discovered ONLY from the selected ZIP.
            # There is intentionally no fallback to the configured production DR Toolkit.
            $drDefs = @(
                @('dr_backup', @('backup'), @('01_backup')),
                @('dr_verify_backup', @('verify','backup'), @('02_verify_latest','02_verify')),
                @('dr_test_restore', @('test','restore'), @('03_test_restore')),
                @('dr_destroy_test', @('destroy','test'), @('04_destroy_test')),
                @('dr_list_snapshots', @('list','snapshot'), @('05_list_snapshots')),
                @('dr_full_recovery', @('full','recovery'), @('06_create_full_recovery'))
            )
            foreach ($def in $drDefs) {
                $opKey=[string]$def[0]; $words=@($def[1]); $prefixes=@($def[2]); $candidates=@()
                foreach ($s in $scripts) {
                    $stem=[System.IO.Path]::GetFileNameWithoutExtension($s).ToLowerInvariant()
                    $all=$true; foreach($w in $words){ if(-not $stem.Contains([string]$w)){ $all=$false } }
                    if($all){ $candidates += $s }
                }
                if($candidates.Count -eq 0){
                    foreach($s in $scripts){
                        $stem=[System.IO.Path]::GetFileNameWithoutExtension($s).ToLowerInvariant()
                        foreach($prefix in $prefixes){ if($stem.StartsWith([string]$prefix)){ $candidates += $s } }
                    }
                }
                $chosen=Choose-Script $candidates
                if($chosen){ $result.Operations[$opKey]=$chosen }
            }
        }
        finally { $zip.Dispose() }
    }
    catch { $result.Error = $_.Exception.Message }
    return [pscustomobject]$result
}

function Get-PackageSha([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Load-PackageStates {
    if (-not (Test-Path -LiteralPath $PackageStatePath)) { return @() }
    try {
        $data = Get-Content -LiteralPath $PackageStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $data) { return @() }
        return @($data)
    }
    catch { return @() }
}

function Save-PackageStates($States) {
    Write-JsonFile $PackageStatePath @($States)
}

function Get-StateKey([string]$AppId,[string]$Sha) { return "$AppId`:$($Sha.ToLowerInvariant())" }

function Get-PackageState([string]$AppId,[string]$Sha) {
    $key = Get-StateKey $AppId $Sha
    $states = Load-PackageStates
    foreach ($s in $states) {
        if ((Get-PropertyValue $s 'key') -eq $key) { return $s }
    }
    return $null
}

function Update-PackageState([string]$AppId,[string]$Sha,[hashtable]$Changes) {
    $key = Get-StateKey $AppId $Sha
    $states = New-Object System.Collections.ArrayList
    foreach ($s in (Load-PackageStates)) { [void]$states.Add($s) }
    $target = $null
    foreach ($s in $states) { if ((Get-PropertyValue $s 'key') -eq $key) { $target = $s } }
    if ($null -eq $target) {
        $target = [pscustomobject]@{ key=$key; app_id=$AppId; sha256=$Sha }
        [void]$states.Add($target)
    }
    foreach ($k in $Changes.Keys) {
        $prop = $target.PSObject.Properties[$k]
        if ($prop) { $prop.Value = $Changes[$k] }
        else { $target | Add-Member -NotePropertyName $k -NotePropertyValue $Changes[$k] }
    }
    Save-PackageStates @($states)
    return $target
}


function Load-ExecutionStates {
    if (-not (Test-Path -LiteralPath $ExecutionStatePath -PathType Leaf)) { return @() }
    try {
        $data = Get-Content -LiteralPath $ExecutionStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $data) { return @() }
        return @($data)
    }
    catch { return @() }
}

function Save-ExecutionStates($States) {
    Write-JsonFile $ExecutionStatePath @($States)
}

function Get-ExecutionState([string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    foreach ($state in (Load-ExecutionStates)) {
        if ([string](Get-PropertyValue $state 'key') -eq $Key) { return $state }
    }
    return $null
}

function Update-ExecutionState([string]$Key,[hashtable]$Changes) {
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }

    $states = New-Object System.Collections.ArrayList
    foreach ($state in (Load-ExecutionStates)) { [void]$states.Add($state) }

    $target = $null
    foreach ($state in $states) {
        if ([string](Get-PropertyValue $state 'key') -eq $Key) {
            $target = $state
            break
        }
    }

    if ($null -eq $target) {
        $target = [pscustomobject]@{ key = $Key }
        [void]$states.Add($target)
    }

    foreach ($name in $Changes.Keys) {
        $prop = $target.PSObject.Properties[$name]
        if ($null -ne $prop) { $prop.Value = $Changes[$name] }
        else { $target | Add-Member -NotePropertyName $name -NotePropertyValue $Changes[$name] }
    }

    Save-ExecutionStates @($states)
    return $target
}

function Get-PackageStableIdentity([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $parts = New-Object System.Collections.Generic.List[string]
            foreach ($entry in @($zip.Entries | Sort-Object FullName)) {
                if ([string]::IsNullOrWhiteSpace($entry.Name)) { continue }

                $normalised = $entry.FullName.Replace('\','/')
                if ($normalised.StartsWith('EXECUTION_LOGS/',[System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                [void]$parts.Add(
                    ("{0}|{1}|{2}" -f $normalised,$entry.Length,$entry.CompressedLength)
                )
            }

            $payload = [string]::Join("`n",$parts.ToArray())
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $hash = $sha.ComputeHash($bytes)
                return ([System.BitConverter]::ToString($hash)).Replace('-','').ToLowerInvariant()
            }
            finally { $sha.Dispose() }
        }
        finally { $zip.Dispose() }
    }
    catch {
        # Fallback is path-specific rather than silently claiming two packages are identical.
        return ("PATH_" + (Get-SafeName ([System.IO.Path]::GetFullPath($Path))))
    }
}

function Get-PackageVersionText([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'unknown' }

    if ($null -ne $script:CurrentPackageInspection -and
        -not [string]::IsNullOrWhiteSpace([string]$script:CurrentPackagePath) -and
        [string]::Equals(
            [System.IO.Path]::GetFullPath($script:CurrentPackagePath),
            [System.IO.Path]::GetFullPath($Path),
            [System.StringComparison]::OrdinalIgnoreCase
        )) {

        $release = [string](Get-PropertyValue $script:CurrentPackageInspection.Info 'release')
        if ([string]::IsNullOrWhiteSpace($release)) {
            $release = [string]$script:CurrentPackageInspection.Release
        }

        if (-not [string]::IsNullOrWhiteSpace($release) -and
            $release -ne 'not declared') {
            return $release.Trim()
        }
    }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Path)

    # Prefer release-like tokens such as 1012.1615 / 1012_1615 / 1012-1615.
    $matches = [System.Text.RegularExpressions.Regex]::Matches(
        $stem,
        '(?<!\d)(\d{4}[._-]\d{4})(?!\d)'
    )
    if ($matches.Count -gt 0) {
        return $matches[$matches.Count - 1].Groups[1].Value
    }

    # Fallback for conventional semantic versions.
    $semver = [System.Text.RegularExpressions.Regex]::Matches(
        $stem,
        '(?i)(?:^|[_-])v?(\d+\.\d+\.\d+)(?:[_-]|$)'
    )
    if ($semver.Count -gt 0) {
        return $semver[$semver.Count - 1].Groups[1].Value
    }

    return 'not declared'
}

function Get-PackageExecutionKey(
    [string]$PackagePath,
    [string]$TargetName
) {
    $stableId = Get-PackageStableIdentity $PackagePath
    $target = ([string]$TargetName).Replace('\','/').ToLowerInvariant()
    return "PKG:$stableId`:$target"
}

function Get-DrExecutionKey(
    [string]$Operation,
    [string]$ScriptPath
) {
    $appId = [string](Get-PropertyValue $script:SelectedApp 'id')
    return ("DR:{0}:{1}:{2}" -f $appId.ToUpperInvariant(),$Operation.ToUpperInvariant(),[System.IO.Path]::GetFullPath($ScriptPath).ToUpperInvariant())
}

function Get-LatestPackageExecutionState([string]$StableId) {
    if ([string]::IsNullOrWhiteSpace($StableId)) { return $null }

    $matches = @(
        Load-ExecutionStates |
        Where-Object { [string](Get-PropertyValue $_ 'package_id') -eq $StableId } |
        Sort-Object { [string](Get-PropertyValue $_ 'finished') } -Descending
    )

    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Set-RunButtonVisual(
    [System.Windows.Forms.Button]$Button,
    [string]$State
) {
    if ($null -eq $Button) { return }

    $baseText = [string]$Button.AccessibleDescription
    if ([string]::IsNullOrWhiteSpace($baseText)) {
        $baseText = $Button.Text
        $Button.AccessibleDescription = $baseText
    }

    $stateUpper = if ([string]::IsNullOrWhiteSpace($State)) { '' } else { $State.ToUpperInvariant() }

    switch ($stateUpper) {
        'RUNNING' {
            $Button.Text = "… $baseText"
            $Button.UseVisualStyleBackColor = $false
            $Button.BackColor = [System.Drawing.Color]::Khaki
            $Button.ForeColor = [System.Drawing.Color]::Black
        }
        'PASS' {
            $Button.Text = "✓ $baseText"
            $Button.UseVisualStyleBackColor = $false
            $Button.BackColor = [System.Drawing.Color]::LightGreen
            $Button.ForeColor = [System.Drawing.Color]::Black
        }
        'FAIL' {
            $Button.Text = "✕ $baseText"
            $Button.UseVisualStyleBackColor = $false
            $Button.BackColor = [System.Drawing.Color]::LightCoral
            $Button.ForeColor = [System.Drawing.Color]::Black
        }
        'CANCELLED' {
            $Button.Text = "✕ $baseText"
            $Button.UseVisualStyleBackColor = $false
            $Button.BackColor = [System.Drawing.Color]::LightCoral
            $Button.ForeColor = [System.Drawing.Color]::Black
        }
        default {
            $Button.Text = $baseText
            if ($script:ThemeMode -eq 'NIGHT') {
                $Button.UseVisualStyleBackColor = $false
                $Button.BackColor = [System.Drawing.Color]::FromArgb(45,45,45)
                $Button.ForeColor = [System.Drawing.Color]::FromArgb(235,235,235)
            }
            else {
                $Button.UseVisualStyleBackColor = $true
                $Button.BackColor = [System.Drawing.SystemColors]::Control
                $Button.ForeColor = [System.Drawing.SystemColors]::ControlText
            }
        }
    }
}

function Refresh-QuickScriptExecutionVisuals {
    if ($null -eq $script:QuickScriptsPanel -or
        $null -eq $script:CurrentPackagePath -or
        -not (Test-Path -LiteralPath $script:CurrentPackagePath -PathType Leaf)) {
        return
    }

    foreach ($control in $script:QuickScriptsPanel.Controls) {
        if (-not ($control -is [System.Windows.Forms.Button])) { continue }

        $key = [string]$control.AccessibleName
        if ([string]::IsNullOrWhiteSpace($key)) {
            $key = Get-PackageExecutionKey $script:CurrentPackagePath ([string]$control.Tag)
            $control.AccessibleName = $key
        }

        $visualState = ''
        if ([string]::Equals($script:LastActionExecutionKey,$key,[System.StringComparison]::OrdinalIgnoreCase)) {
            if ($null -ne $script:RunContext -and
                [string](Get-PropertyValue $script:RunContext 'ExecutionKey') -eq $key) {
                $visualState = 'RUNNING'
            }
            else {
                $stored = Get-ExecutionState $key
                if ($null -ne $stored) {
                    $visualState = [string](Get-PropertyValue $stored 'result')
                }
            }
        }

        Set-RunButtonVisual $control $visualState
        if ($visualState -eq 'RUNNING') {
            $control.Enabled = $true
        }
    }
}

function Refresh-DrExecutionVisuals {
    if ($null -eq $script:SelectedApp) { return }

    $toolkitRaw = [string](Get-PropertyValue $script:SelectedApp 'dr_toolkit')
    $toolkit = Expand-ConfigPath $toolkitRaw
    $drScripts = Get-PropertyValue $script:SelectedApp 'dr_scripts'

    if ([string]::IsNullOrWhiteSpace($toolkit) -or $null -eq $drScripts) { return }

    foreach ($def in @(
        @('backup','backup',$script:DrBackupBtn,'Backup'),
        @('verify_backup','verify_backup',$script:DrVerifyBtn,'Verify Latest Backup'),
        @('full_recovery','full_recovery',$script:DrFullBtn,'Create FULL Recovery Folder'),
        @('continuity_snapshot','continuity_snapshot',$script:DrContinuityBtn,'Continuity Snapshot'),
        @('test_restore','test_restore',$script:DrRestoreBtn,'Test Restore Latest'),
        @('destroy_test','destroy_test',$script:DrDestroyBtn,'Destroy Isolated Test'),
        @('list_snapshots','list_snapshots',$script:DrListBtn,'List Snapshots')
    )) {
        $operation = [string]$def[0]
        $propertyName = [string]$def[1]
        $button = $def[2]
        $baseText = [string]$def[3]

        if ($null -eq $button) { continue }
        $button.AccessibleDescription = $baseText

        $scriptName = [string](Get-PropertyValue $drScripts $propertyName)
        if ([string]::IsNullOrWhiteSpace($scriptName)) {
            Set-RunButtonVisual $button ''
            continue
        }

        $scriptPath = Join-Path $toolkit $scriptName
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            Set-RunButtonVisual $button ''
            continue
        }

        $key = Get-DrExecutionKey $operation $scriptPath
        $button.AccessibleName = $key

        $visualState = ''
        if ([string]::Equals($script:LastActionExecutionKey,$key,[System.StringComparison]::OrdinalIgnoreCase)) {
            if ($null -ne $script:RunContext -and
                [string](Get-PropertyValue $script:RunContext 'ExecutionKey') -eq $key) {
                $visualState = 'RUNNING'
            }
            else {
                $stored = Get-ExecutionState $key
                if ($null -ne $stored) {
                    $visualState = [string](Get-PropertyValue $stored 'result')
                }
            }
        }

        Set-RunButtonVisual $button $visualState
        if ($visualState -eq 'RUNNING') {
            $button.Enabled = $true
        }
    }
}

function Refresh-PackageExecutionBadge {
    if ($null -eq $script:PackageVersionLabel -or
        $null -eq $script:PackageExecutionLabel) {
        return
    }

    # v1.0.35: package status text is always black and bold.
    # Execution state remains visible in the text itself and through button colours.
    $script:PackageVersionLabel.ForeColor = [System.Drawing.Color]::Black
    $script:PackageExecutionLabel.ForeColor = [System.Drawing.Color]::Black
    $script:PackageVersionLabel.Font = New-Object System.Drawing.Font(
        'Segoe UI',11,[System.Drawing.FontStyle]::Bold
    )
    $script:PackageExecutionLabel.Font = New-Object System.Drawing.Font(
        'Segoe UI',11,[System.Drawing.FontStyle]::Bold
    )

    if ($null -eq $script:CurrentPackagePath -or
        -not (Test-Path -LiteralPath $script:CurrentPackagePath -PathType Leaf)) {
        $script:PackageVersionLabel.Text = 'VERSION: —'
        $script:PackageExecutionLabel.Text = 'NOT EXECUTED'
        return
    }

    $version = Get-PackageVersionText $script:CurrentPackagePath
    $stableId = Get-PackageStableIdentity $script:CurrentPackagePath
    $script:PackageVersionLabel.Text = "VERSION: $version"

    $visualState = ''
    $detail = ''

    if ($null -ne $script:RunContext -and
        [string](Get-PropertyValue $script:RunContext 'PackageStableId') -eq $stableId) {
        $visualState = 'RUNNING'
        $detail = [string](Get-PropertyValue $script:RunContext 'ExecutionTarget')
    }
    else {
        $latest = Get-LatestPackageExecutionState $stableId
        if ($null -ne $latest) {
            $visualState = [string](Get-PropertyValue $latest 'result')
            $detail = [string](Get-PropertyValue $latest 'script_name')
        }
    }

    switch ($visualState.ToUpperInvariant()) {
        'RUNNING' {
            $script:PackageExecutionLabel.Text = "RUNNING — $detail"
        }
        'PASS' {
            $script:PackageExecutionLabel.Text = "✓ EXECUTED / PASS — $detail"
        }
        'FAIL' {
            $script:PackageExecutionLabel.Text = "✕ EXECUTED / FAIL — $detail"
        }
        'CANCELLED' {
            $script:PackageExecutionLabel.Text = "✕ EXECUTION CANCELLED — $detail"
        }
        default {
            $script:PackageExecutionLabel.Text = 'NOT EXECUTED'
        }
    }
}

function Refresh-ExecutionVisuals {
    Refresh-QuickScriptExecutionVisuals
    Refresh-DrExecutionVisuals
    Refresh-PackageExecutionBadge
}

function Save-RunExecutionResult($Context,[string]$Result) {
    if ($null -eq $Context) { return }

    $key = [string](Get-PropertyValue $Context 'ExecutionKey')
    if ([string]::IsNullOrWhiteSpace($key)) { return }

    $appId = [string](Get-PropertyValue $script:SelectedApp 'id')
    $packageStableId = [string](Get-PropertyValue $Context 'PackageStableId')
    $packageVersion = [string](Get-PropertyValue $Context 'PackageVersion')
    $scriptName = [string](Get-PropertyValue $Context 'ExecutionTarget')

    [void](Update-ExecutionState $key @{
        app_id = $appId
        category = [string](Get-PropertyValue $Context 'Category')
        operation = [string](Get-PropertyValue $Context 'Operation')
        script_name = $scriptName
        package_id = $packageStableId
        package_path = [string](Get-PropertyValue $Context 'PackagePath')
        package_version = $packageVersion
        result = $Result
        finished = (Get-Date).ToString('o')
    })
}


function Load-InstalledStates {
    if (-not (Test-Path -LiteralPath $InstalledStatePath -PathType Leaf)) { return @() }
    try {
        $data = Get-Content -LiteralPath $InstalledStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $data) { return @() }
        return @($data)
    }
    catch { return @() }
}

function Save-InstalledStates($States) {
    Write-JsonFile $InstalledStatePath @($States)
}

function Get-InstalledState([string]$AppId) {
    if ([string]::IsNullOrWhiteSpace($AppId)) { return $null }
    foreach ($state in (Load-InstalledStates)) {
        if ([string](Get-PropertyValue $state 'app_id') -eq $AppId) { return $state }
    }
    return $null
}

function Update-InstalledState([string]$AppId,[hashtable]$Changes) {
    if ([string]::IsNullOrWhiteSpace($AppId)) { return $null }

    $states = New-Object System.Collections.ArrayList
    foreach ($state in (Load-InstalledStates)) { [void]$states.Add($state) }

    $target = $null
    foreach ($state in $states) {
        if ([string](Get-PropertyValue $state 'app_id') -eq $AppId) {
            $target = $state
            break
        }
    }

    if ($null -eq $target) {
        $target = [pscustomobject]@{ app_id = $AppId }
        [void]$states.Add($target)
    }

    foreach ($name in $Changes.Keys) {
        $prop = $target.PSObject.Properties[$name]
        if ($null -ne $prop) { $prop.Value = $Changes[$name] }
        else { $target | Add-Member -NotePropertyName $name -NotePropertyValue $Changes[$name] }
    }

    Save-InstalledStates @($states)
    return $target
}

function Test-RunIsApply($Context) {
    if ($null -eq $Context) { return $false }

    $category = [string](Get-PropertyValue $Context 'Category')
    $operation = [string](Get-PropertyValue $Context 'Operation')

    if ($category -eq 'UPDATE' -and $operation -eq 'APPLY') {
        return $true
    }

    if ($category -ne 'SCRIPT') { return $false }

    $packagePath = [string](Get-PropertyValue $Context 'PackagePath')
    $target = ([string](Get-PropertyValue $Context 'ExecutionTarget')).Replace('\','/')

    if ([string]::IsNullOrWhiteSpace($packagePath) -or
        -not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        return $false
    }

    try {
        $inspection = Inspect-Package $packagePath
        if ($inspection.Error) { return $false }

        $ops = $inspection.Operations
        if ($null -eq $ops -or -not $ops.ContainsKey('apply')) { return $false }

        $applyEntry = ([string]$ops['apply']).Replace('\','/')
        return [string]::Equals(
            $applyEntry,
            $target,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}

function Record-InstalledStateFromRun($Context,[string]$Result) {
    if ($null -eq $Context -or -not (Test-RunIsApply $Context)) { return }

    $appId = [string](Get-PropertyValue $script:SelectedApp 'id')
    if ([string]::IsNullOrWhiteSpace($appId)) { return }

    $version = [string](Get-PropertyValue $Context 'PackageVersion')
    if ([string]::IsNullOrWhiteSpace($version)) { $version = 'not declared' }

    $scriptName = [System.IO.Path]::GetFileName(
        [string](Get-PropertyValue $Context 'ExecutionTarget')
    )
    $packagePath = [string](Get-PropertyValue $Context 'PackagePath')
    $finished = (Get-Date).ToString('o')

    if ($Result -eq 'PASS') {
        # A successful APPLY becomes the known-good installed version.
        # It also clears any older failed-apply warning.
        [void](Update-InstalledState $appId @{
            installed_version = $version
            installed_script = $scriptName
            installed_package = $packagePath
            installed_finished = $finished
            installed_result = 'PASS'
            last_apply_result = 'PASS'
            last_apply_version = $version
            last_apply_script = $scriptName
            last_apply_finished = $finished
        })
    }
    else {
        # A failed/cancelled APPLY must NEVER replace the known-good installed version.
        [void](Update-InstalledState $appId @{
            last_apply_result = $Result
            last_apply_version = $version
            last_apply_script = $scriptName
            last_apply_finished = $finished
        })
    }
}

function Format-InstalledTimestamp([string]$IsoValue) {
    if ([string]::IsNullOrWhiteSpace($IsoValue)) { return '' }
    try {
        return ([datetime]::Parse($IsoValue)).ToString('dd MMM yyyy HH:mm')
    }
    catch {
        return $IsoValue
    }
}

function Refresh-InstalledStatusStrip {
    if ($null -eq $script:InstalledStatusLabel -or
        $null -eq $script:LastApplyWarningLabel) {
        return
    }

    if ($null -eq $script:SelectedApp) {
        $script:InstalledStatusLabel.Text = 'INSTALLED: UNKNOWN'
        $script:LastApplyWarningLabel.Visible = $false
        return
    }

    $appId = [string](Get-PropertyValue $script:SelectedApp 'id')
    $state = Get-InstalledState $appId

    if ($null -eq $state -or
        [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $state 'installed_version'))) {

        $script:InstalledStatusLabel.Text = 'INSTALLED: UNKNOWN — no successful APPLY recorded by AOM'
        if ($script:ThemeMode -eq 'NIGHT') {
            $script:InstalledStatusLabel.ForeColor = [System.Drawing.Color]::Silver
        }
        else {
            $script:InstalledStatusLabel.ForeColor = [System.Drawing.Color]::DimGray
        }

        $lastResult = [string](Get-PropertyValue $state 'last_apply_result')
        if ($null -ne $state -and
            -not [string]::IsNullOrWhiteSpace($lastResult) -and
            $lastResult -ne 'PASS') {

            $failedVersion = [string](Get-PropertyValue $state 'last_apply_version')
            $script:LastApplyWarningLabel.Text = "LAST APPLY ${lastResult}: $failedVersion"
            $script:LastApplyWarningLabel.ForeColor = [System.Drawing.Color]::Firebrick
            $script:LastApplyWarningLabel.Visible = $true
        }
        else {
            $script:LastApplyWarningLabel.Visible = $false
        }
        return
    }

    $version = [string](Get-PropertyValue $state 'installed_version')
    $applyScript = [string](Get-PropertyValue $state 'installed_script')
    $finished = Format-InstalledTimestamp ([string](Get-PropertyValue $state 'installed_finished'))

    $script:InstalledStatusLabel.Text = (
        "INSTALLED: {0}  ✓ PASS   |   {1}   |   {2}" -f
        $version,$applyScript,$finished
    )
    $script:InstalledStatusLabel.ForeColor = [System.Drawing.Color]::ForestGreen

    $lastResult = [string](Get-PropertyValue $state 'last_apply_result')
    if (-not [string]::IsNullOrWhiteSpace($lastResult) -and
        $lastResult -ne 'PASS') {

        $failedVersion = [string](Get-PropertyValue $state 'last_apply_version')
        $failedScript = [string](Get-PropertyValue $state 'last_apply_script')
        $script:LastApplyWarningLabel.Text = (
            "LAST APPLY {0}: {1} | {2}" -f
            $lastResult,$failedVersion,$failedScript
        )
        $script:LastApplyWarningLabel.ForeColor = [System.Drawing.Color]::Firebrick
        $script:LastApplyWarningLabel.Visible = $true
    }
    else {
        $script:LastApplyWarningLabel.Visible = $false
    }
}

function Test-PatternMatch([string]$Name, $Patterns) {
    foreach ($p in @($Patterns)) { if ($Name -like [string]$p) { return $true } }
    return $false
}

function Find-ExtractedScript([string]$Root,[string]$Basename) {
    $matches = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Name -ieq $Basename })
    if ($matches.Count -eq 0) { return $null }
    return ($matches | Sort-Object { $_.FullName.Split('\').Count }, { $_.FullName.Length } | Select-Object -First 1).FullName
}

function Get-NewRunLogPath([string]$Category,[string]$Operation,[string]$PackagePath) {
    $safeApp = Get-SafeName ([string](Get-PropertyValue $script:SelectedApp 'name'))
    $safeCat = Get-SafeName $Category
    $safeOp = Get-SafeName $Operation
    $pkgTag = 'NO_PACKAGE'
    if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
        $pkgTag = Get-SafeName ([System.IO.Path]::GetFileNameWithoutExtension($PackagePath))
        if ($pkgTag.Length -gt 36) { $pkgTag = $pkgTag.Substring(0,36) }
    }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $base = "{0}_{1}_{2}_{3}_{4}" -f $safeApp,$safeCat,$safeOp,$pkgTag,$stamp
    $candidate = Join-Path $LogsDir ($base + '.log')
    $n = 2
    while (Test-Path -LiteralPath $candidate) { $candidate=Join-Path $LogsDir ("{0}_{1}.log" -f $base,$n); $n++ }
    return $candidate
}

function Append-RunFooter([string]$Path,[int]$ExitCode,[string]$Result,[datetime]$Started) {
    $finished = Get-Date
    $duration = $finished - $Started
    $durationText = ('{0:00}:{1:00}:{2:00}' -f [int]$duration.TotalHours,$duration.Minutes,$duration.Seconds)
    $lines = @(
        "",
        "============================================================",
        "[AOM] PROCESS FINISHED",
        "[AOM] EXIT CODE: $ExitCode",
        "[AOM] RESULT: $Result",
        ("[AOM] Finished: {0}" -f $finished.ToString("yyyy-MM-dd HH:mm:ss")),
        ("[AOM] Duration: {0}" -f $durationText),
        "============================================================"
    )
    try { Add-Content -LiteralPath $Path -Value $lines -Encoding Default } catch {}
}

function Kill-ProcessTree([int]$Pid) {
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
    } catch {}
}

function Get-OperationCommand([string]$ScriptPath) {
    $ext = [System.IO.Path]::GetExtension($ScriptPath).ToLowerInvariant()
    if ($ext -eq '.bat' -or $ext -eq '.cmd') { return ('call "{0}"' -f $ScriptPath) }
    if ($ext -eq '.ps1') { return ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath) }
    throw "Unsupported script type: $ext"
}

function Start-ManagedOperation {
    param(
        [string]$ScriptPath,
        [string]$Category,
        [string]$Operation,
        [string]$PackagePath,
        [string]$PackageSha,
        [string]$WorkRoot,
        [string[]]$PrefeedLines,
        [System.Windows.Forms.RichTextBox]$OutputBox,
        [System.Windows.Forms.Label]$StatusLabel
    )

    if ($script:Process -ne $null -and -not $script:Process.HasExited) {
        [System.Windows.Forms.MessageBox]::Show("Another operation is already running.","Busy") | Out-Null
        return $false
    }

    $workingDir = [System.IO.Path]::GetDirectoryName($ScriptPath)

    $executionTarget = [System.IO.Path]::GetFileName($ScriptPath)
    if (-not [string]::IsNullOrWhiteSpace($WorkRoot)) {
        try {
            $workFull = [System.IO.Path]::GetFullPath($WorkRoot).TrimEnd('\') + '\'
            $scriptFull = [System.IO.Path]::GetFullPath($ScriptPath)
            if ($scriptFull.StartsWith($workFull,[System.StringComparison]::OrdinalIgnoreCase)) {
                $executionTarget = $scriptFull.Substring($workFull.Length).Replace('\','/')
            }
        }
        catch {}
    }

    $packageStableId = ''
    $packageVersion = ''
    $executionKey = ''

    if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
        $packageStableId = Get-PackageStableIdentity $PackagePath
        $packageVersion = Get-PackageVersionText $PackagePath
        $executionKey = Get-PackageExecutionKey $PackagePath $executionTarget
    }
    else {
        $executionKey = Get-DrExecutionKey $Operation $ScriptPath
    }

    $logPath = Get-NewRunLogPath $Category $Operation $PackagePath
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $rand = Get-Random -Minimum 100000 -Maximum 999999
    $wrapper = Join-Path $TempRoot ("__AOM_RUN_{0}_{1}.cmd" -f $stamp,$rand)
    $inputFile = Join-Path $TempRoot ("__AOM_INPUT_{0}_{1}.txt" -f $stamp,$rand)
    $command = Get-OperationCommand $ScriptPath

    $header = @(
        "[INFO] Application: $([string](Get-PropertyValue $script:SelectedApp 'name'))",
        "[INFO] Operation: $Category / $Operation",
        "[INFO] Script: $ScriptPath",
        "[INFO] Working directory: $workingDir",
        "[INFO] Run log: $logPath",
        "[INFO] Execution engine: PowerShell/.NET ProcessStartInfo - Windows-proven Core Runner v0.3",
        "[INFO] Output transport: Windows CMD stdout+stderr -> this .log; UI tails this file.",
        "",
        "============================================================",
        "[AOM] PROCESS STARTED",
        "[AOM] STATUS: RUNNING",
        ("[AOM] Started: {0}" -f (Get-Date -Format "dd/MM/yyyy HH:mm:ss")),
        "============================================================",
        ""
    )
    if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
        $pkgName=[System.IO.Path]::GetFileName($PackagePath)
        $safety=if($pkgName -match '(?i)test'){ 'TEST / NON-PRODUCTION PACKAGE' } else { 'PACKAGE-CONTROLLED EXECUTION' }
        $identity=@("[AOM] PACKAGE: $pkgName","[AOM] SCRIPT: $([System.IO.Path]::GetFileName($ScriptPath))","[AOM] SAFETY: $safety")
        $header = @($header[0..1]) + "[INFO] Package: $PackagePath" + $identity + @($header[2..($header.Count-1)])
    }
    Set-Content -LiteralPath $logPath -Value $header -Encoding Default

    $runLine = $null
    if ($null -ne $PrefeedLines -and $PrefeedLines.Count -gt 0) {
        if ($PrefeedLines.Count -eq 1 -and [string]::IsNullOrEmpty($PrefeedLines[0])) {
            $runLine = '(echo.) | ' + $command + ' >> "' + $logPath + '" 2>&1'
        }
        else {
            $content = @($PrefeedLines) + @('')
            Set-Content -LiteralPath $inputFile -Value $content -Encoding Default
            $runLine = 'type "' + $inputFile + '" | ' + $command + ' >> "' + $logPath + '" 2>&1'
        }
    }
    else {
        $runLine = $command + ' >> "' + $logPath + '" 2>&1'
    }

    $wrapperLines = @(
        '@echo off',
        'setlocal EnableExtensions',
        $runLine,
        'set "RC=%ERRORLEVEL%"',
        'exit /b %RC%'
    )
    Set-Content -LiteralPath $wrapper -Value $wrapperLines -Encoding Ascii

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/d /q /c call "' + $wrapper + '"'
    $psi.WorkingDirectory = $workingDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    if (-not $p.Start()) { throw "Windows could not start cmd.exe." }

    $script:Process = $p
    $script:LastLogText = ""
    $script:LastObservedLogLength = -1
    $script:LastActionExecutionKey = $executionKey
    $script:RunContext = [pscustomobject]@{
        ScriptPath = $ScriptPath
        Category = $Category
        Operation = $Operation
        PackagePath = $PackagePath
        PackageSha = $PackageSha
        WorkRoot = $WorkRoot
        ExecutionKey = $executionKey
        ExecutionTarget = $executionTarget
        PackageStableId = $packageStableId
        PackageVersion = $packageVersion
        LogPath = $logPath
        WrapperPath = $wrapper
        InputFile = $inputFile
        OutputBox = $OutputBox
        StatusLabel = $StatusLabel
        Started = Get-Date
        Finalized = $false
        CancelRequested = $false
    }
    $OutputBox.Clear()
    $StatusLabel.Text = "RUNNING - $Operation | started $(Get-DisplayDateTime $script:RunContext.Started) | process active"
    Set-BusyState $true
    Refresh-ExecutionVisuals
    Refresh-LogHandoff
    return $true
}



function Copy-GeneratedRunOutputs {
    param(
        [string]$WorkRoot,
        [string]$PackagePath,
        [string]$Operation,
        [string]$Result,
        [datetime]$Started
    )

    $summary = [pscustomobject]@{
        Count = 0
        Destination = $null
        Files = @()
    }

    if ([string]::IsNullOrWhiteSpace($WorkRoot) -or
        -not (Test-Path -LiteralPath $WorkRoot -PathType Container)) {
        return $summary
    }

    # Only collect files created/updated by the run from folders named OUTPUT.
    $threshold = $Started.AddSeconds(-2)
    $outputDirs = @(Get-ChildItem -LiteralPath $WorkRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq 'OUTPUT' })

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($dir in $outputDirs) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir.FullName -File -Recurse -ErrorAction SilentlyContinue)) {
            if ($file.LastWriteTime -ge $threshold) {
                [void]$files.Add($file)
            }
        }
    }

    if ($files.Count -eq 0) { return $summary }

    $appId = Get-SafeName ([string](Get-PropertyValue $script:SelectedApp 'id'))
    if ([string]::IsNullOrWhiteSpace($appId)) { $appId = 'Application' }

    $packageStem = 'NO_PACKAGE'
    if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
        $packageStem = Get-SafeName ([System.IO.Path]::GetFileNameWithoutExtension($PackagePath))
    }

    $safeOperation = Get-SafeName $Operation
    $runStamp = $Started.ToString('yyyyMMdd_HHmmss')
    $runFolderName = "{0}_{1}_{2}" -f $runStamp,$safeOperation,$Result
    $destination = Join-Path $OutputRoot (Join-Path $appId (Join-Path $packageStem $runFolderName))
    New-Item -ItemType Directory -Force -Path $destination | Out-Null

    $copied = 0
    $copiedPaths = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($WorkRoot.Length).TrimStart('\','/')
        $target = Join-Path $destination $relative
        $parent = Split-Path -Parent $target
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        $copied++
        [void]$copiedPaths.Add($target)
    }

    $info = @(
        "AI Dev Toolkit - generated output archive",
        "Application: $([string](Get-PropertyValue $script:SelectedApp 'name'))",
        "Package: $PackagePath",
        "Operation: $Operation",
        "Result: $Result",
        "Started: $($Started.ToString('yyyy-MM-dd HH:mm:ss'))",
        "Temporary work root: $WorkRoot",
        "Permanent output folder: $destination",
        "Files copied: $copied"
    )
    Set-Content -LiteralPath (Join-Path $destination '_AOM_RUN_INFO.txt') -Value $info -Encoding UTF8

    $summary.Count = $copied
    $summary.Destination = $destination
    $summary.Files = @($copiedPaths.ToArray())
    return $summary
}


function Get-DirectGeneratedOutputFiles {
    param(
        [string]$SearchRoot,
        [datetime]$Started
    )

    if ([string]::IsNullOrWhiteSpace($SearchRoot) -or
        -not (Test-Path -LiteralPath $SearchRoot -PathType Container)) {
        return @()
    }

    $threshold = $Started.AddSeconds(-2)
    $found = New-Object System.Collections.Generic.List[string]

    # Only inspect directories named OUTPUT under the execution root.
    # This avoids treating arbitrary project/source changes as generated artefacts.
    $outputDirs = @(Get-ChildItem -LiteralPath $SearchRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq 'OUTPUT' })

    try {
        if ((Split-Path -Leaf $SearchRoot) -ieq 'OUTPUT') {
            $outputDirs = @((Get-Item -LiteralPath $SearchRoot)) + $outputDirs
        }
    }
    catch {}

    foreach ($dir in $outputDirs) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir.FullName -File -Recurse -ErrorAction SilentlyContinue)) {
            if ($file.LastWriteTime -ge $threshold -and
                -not $found.Contains($file.FullName)) {
                [void]$found.Add($file.FullName)
            }
        }
    }

    return @($found.ToArray())
}

function Write-GeneratedOutputDetails {
    param(
        [string]$LogPath,
        [string[]]$Files,
        [string]$Result
    )

    $validFiles = @(
        $Files |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_) -and
            (Test-Path -LiteralPath ([string]$_) -PathType Leaf)
        } |
        Select-Object -Unique
    )

    if ($validFiles.Count -eq 0) { return }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("")
    [void]$lines.Add("============================================================")
    [void]$lines.Add("[AOM] GENERATED OUTPUT FILES")
    [void]$lines.Add("============================================================")

    foreach ($path in $validFiles) {
        try {
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            $sizeMb = [Math]::Round($item.Length / 1MB, 2)
            $ext = [System.IO.Path]::GetExtension($item.FullName)

            if ($ext -ieq '.zip') {
                $sha = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                [void]$lines.Add("[PASS] ZIP READY FOR AI: $($item.FullName)")
                [void]$lines.Add("[AOM] GENERATED ZIP: $($item.FullName)")
                [void]$lines.Add("[AOM] ZIP SIZE: $sizeMb MB")
                [void]$lines.Add("[AOM] ZIP SHA256: $sha")
            }
            else {
                [void]$lines.Add("[AOM] GENERATED FILE: $($item.FullName)")
                [void]$lines.Add("[AOM] FILE SIZE: $sizeMb MB")
            }
        }
        catch {
            [void]$lines.Add("[WARN] Could not inspect generated output: $path")
        }
    }

    [void]$lines.Add("[AOM] OUTPUT RESULT: $Result")
    [void]$lines.Add("============================================================")

    try {
        Add-Content -LiteralPath $LogPath -Value $lines.ToArray() -Encoding Default
    }
    catch {}
}

function Save-ExecutionLogIntoPackage {
    param(
        [string]$PackagePath,
        [string]$LogPath,
        [string]$Operation,
        [string]$Result
    )

    if ([string]::IsNullOrWhiteSpace($PackagePath) -or
        [string]::IsNullOrWhiteSpace($LogPath)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return $null
    }

    if ([System.IO.Path]::GetExtension($PackagePath) -ine '.zip') {
        return $null
    }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $safeOperation = Get-SafeName $Operation
        if ([string]::IsNullOrWhiteSpace($safeOperation)) { $safeOperation = 'Script' }

        $entryName = "EXECUTION_LOGS/{0}/{1}_{2}.log" -f $safeOperation,$stamp,$Result

        $zip = [System.IO.Compression.ZipFile]::Open(
            $PackagePath,
            [System.IO.Compression.ZipArchiveMode]::Update
        )
        try {
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip,
                $LogPath,
                $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal
            )
        }
        finally {
            $zip.Dispose()
        }

        return $entryName
    }
    catch {
        try {
            Add-Content -LiteralPath $LogPath -Value (
                "[WARN] AOM could not save this execution log inside the selected ZIP: {0}" -f $_.Exception.Message
            ) -Encoding Default
        }
        catch {}
        return $null
    }
}

function Finalize-ManagedOperation {
    if ($null -eq $script:RunContext) { return }

    $ctx = $script:RunContext
    if ([bool](Get-PropertyValue $ctx 'Finalized')) { return }

    $exitCode = -1
    $result = 'FAIL'
    $finalizationWarnings = New-Object System.Collections.Generic.List[string]

    # Mark as finalizing immediately so the timer cannot enter this routine twice.
    # Cleanup itself is guaranteed by finally below.
    $ctx.Finalized = $true

    try {
        try {
            if ($null -ne $script:Process) {
                $script:Process.Refresh()
                $exitCode = [int]$script:Process.ExitCode
            }
        }
        catch {
            [void]$finalizationWarnings.Add("Could not read process exit code: $($_.Exception.Message)")
            $exitCode = -1
        }

        $result = if ($ctx.CancelRequested) {
            'CANCELLED'
        }
        elseif ($exitCode -eq 0) {
            'PASS'
        }
        else {
            'FAIL'
        }

        try {
            Append-RunFooter $ctx.LogPath $exitCode $result $ctx.Started
        }
        catch {
            [void]$finalizationWarnings.Add("Could not append run footer: $($_.Exception.Message)")
        }

        try {
            Save-RunExecutionResult $ctx $result
        }
        catch {
            [void]$finalizationWarnings.Add("Could not save execution state: $($_.Exception.Message)")
        }

        try {
            Record-InstalledStateFromRun $ctx $result
        }
        catch {
            [void]$finalizationWarnings.Add("Could not update installed state: $($_.Exception.Message)")
        }

        # Preserve script-generated OUTPUT files outside the temporary extraction folder.
        $outputArchive = $null
        try {
            $outputArchive = Copy-GeneratedRunOutputs `
                -WorkRoot $ctx.WorkRoot `
                -PackagePath $ctx.PackagePath `
                -Operation $ctx.Operation `
                -Result $result `
                -Started $ctx.Started
        }
        catch {
            [void]$finalizationWarnings.Add("Generated-output preservation failed: $($_.Exception.Message)")
        }

        $generatedFiles = @()

        if ($null -ne $outputArchive -and $outputArchive.Count -gt 0) {
            try {
                Add-Content -LiteralPath $ctx.LogPath -Value @(
                    "[AOM] GENERATED OUTPUTS: $($outputArchive.Count) file(s)",
                    "[AOM] PERMANENT OUTPUT: $($outputArchive.Destination)"
                ) -Encoding Default
            }
            catch {
                [void]$finalizationWarnings.Add("Could not record generated-output destination: $($_.Exception.Message)")
            }
            $generatedFiles = @($outputArchive.Files)
        }
        elseif ($ctx.Category -eq 'DR') {
            try {
                $drSearchRoot = [System.IO.Path]::GetDirectoryName([string]$ctx.ScriptPath)
                $generatedFiles = @(Get-DirectGeneratedOutputFiles -SearchRoot $drSearchRoot -Started $ctx.Started)

                if ($generatedFiles.Count -gt 0) {
                    Add-Content -LiteralPath $ctx.LogPath -Value (
                        "[AOM] GENERATED OUTPUTS: {0} file(s) detected in fixed DR toolkit OUTPUT" -f $generatedFiles.Count
                    ) -Encoding Default
                }
                else {
                    Add-Content -LiteralPath $ctx.LogPath -Value "[AOM] GENERATED OUTPUTS: none detected under the fixed DR toolkit OUTPUT folder" -Encoding Default
                }
            }
            catch {
                [void]$finalizationWarnings.Add("DR generated-output discovery failed: $($_.Exception.Message)")
            }
        }
        else {
            try {
                Add-Content -LiteralPath $ctx.LogPath -Value "[AOM] GENERATED OUTPUTS: none detected under an OUTPUT folder" -Encoding Default
            }
            catch {}
        }

        try {
            Write-GeneratedOutputDetails `
                -LogPath $ctx.LogPath `
                -Files $generatedFiles `
                -Result $result
        }
        catch {
            [void]$finalizationWarnings.Add("Could not write generated-output details: $($_.Exception.Message)")
        }

        # Keep a copy of this completed execution inside the selected ZIP itself.
        try {
            $packageLogEntry = Save-ExecutionLogIntoPackage `
                -PackagePath $ctx.PackagePath `
                -LogPath $ctx.LogPath `
                -Operation $ctx.Operation `
                -Result $result

            if (-not [string]::IsNullOrWhiteSpace([string]$packageLogEntry)) {
                try {
                    Add-Content -LiteralPath $ctx.LogPath -Value (
                        "{0} [AOM] PACKAGE LOG: saved inside ZIP as {1}" -f (Get-DisplayDateTime (Get-Date)),$packageLogEntry
                    ) -Encoding Default
                }
                catch {}
            }
        }
        catch {
            [void]$finalizationWarnings.Add("Could not embed execution log into package ZIP: $($_.Exception.Message)")
        }

        if ($ctx.Category -eq 'UPDATE' -and -not [string]::IsNullOrWhiteSpace($ctx.PackageSha)) {
            try {
                $appId = [string](Get-PropertyValue $script:SelectedApp 'id')
                if ($ctx.Operation -eq 'APPLY') {
                    [void](Update-PackageState $appId $ctx.PackageSha @{
                        apply_attempted=$true
                        apply_result=$result
                        apply_finished=(Get-Date).ToString('o')
                        package_name=[System.IO.Path]::GetFileName($ctx.PackagePath)
                    })
                }
                elseif ($ctx.Operation -eq 'VERIFY') {
                    [void](Update-PackageState $appId $ctx.PackageSha @{
                        verify_result=$result
                        verify_finished=(Get-Date).ToString('o')
                    })
                    $postState = Get-PackageState $appId $ctx.PackageSha
                    if ($result -eq 'PASS' -and $postState -and (Get-PropertyValue $postState 'apply_attempted')) {
                        Try-ArchiveVerifiedPackage $ctx.PackagePath $ctx.PackageSha
                    }
                }
            }
            catch {
                [void]$finalizationWarnings.Add("Could not update package execution state: $($_.Exception.Message)")
            }
        }

        if ($result -eq 'PASS' -and (Get-AutoCleanTempAfterSuccess) -and
            -not [string]::IsNullOrWhiteSpace([string]$ctx.WorkRoot) -and
            (Test-Path -LiteralPath $ctx.WorkRoot -PathType Container)) {
            try {
                Remove-Item -LiteralPath $ctx.WorkRoot -Recurse -Force -ErrorAction Stop
                Add-Content -LiteralPath $ctx.LogPath -Value "[AOM] TEMP CLEANUP: PASS - $($ctx.WorkRoot)" -Encoding Default
            }
            catch {
                [void]$finalizationWarnings.Add("TEMP cleanup failed: $($_.Exception.Message)")
            }
        }

        if ($finalizationWarnings.Count -gt 0) {
            try {
                Add-Content -LiteralPath $ctx.LogPath -Value "" -Encoding Default
                Add-Content -LiteralPath $ctx.LogPath -Value "[AOM] FINALIZATION WARNINGS" -Encoding Default
                foreach ($warning in $finalizationWarnings) {
                    Add-Content -LiteralPath $ctx.LogPath -Value "[WARN] $warning" -Encoding Default
                }
            }
            catch {}
        }

        # One final viewer refresh. Failure here must never keep the UI locked.
        try {
            $finalText = Read-TextShared $ctx.LogPath
            Update-LiveLogBox $ctx.OutputBox $finalText
        }
        catch {}

        try {
            $ctx.StatusLabel.Text = "$result - $($ctx.Operation) | finished $(Get-DisplayDateTime (Get-Date)) | exit code $exitCode"
        }
        catch {}
    }
    catch {
        # A previously unexpected finalisation exception is recorded but is not
        # allowed to strand the Toolkit in RUNNING state.
        try {
            Add-Content -LiteralPath $ctx.LogPath -Value (
                "[WARN] AOM finalisation exception: {0}" -f $_.Exception.Message
            ) -Encoding Default
        }
        catch {}
    }
    finally {
        # CRITICAL: never leave Process/RunContext/Busy state latched after the
        # child process has ended. This block must execute regardless of any
        # post-processing, output-copying, ZIP, state or UI error above.
        try {
            if ($null -ne $script:Process) {
                $script:Process.Dispose()
            }
        }
        catch {}
        $script:Process = $null

        foreach ($f in @($ctx.WrapperPath,$ctx.InputFile)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$f)) {
                try {
                    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
                }
                catch {}
            }
        }

        $script:RunContext = $null

        try {
            Set-BusyState $false
        }
        catch {
            # Direct fallback for the controls whose disabled state was visible
            # in the reported stuck-RUNNING defect.
            foreach ($control in @(
                $script:RefreshPackagesBtn,
                $script:BrowsePackageBtn,
                $script:ArchivePackageBtn,
                $script:AppCombo,
                $script:MultipleRunsCheck
            )) {
                if ($null -ne $control) {
                    try { $control.Enabled = $true } catch {}
                }
            }
        }

        try { Refresh-LogHandoff } catch {}

        try {
            if ($ctx.Category -eq 'DR') {
                Update-OperationButtons
                Refresh-ExecutionVisuals
            }
            else {
                Refresh-Packages
                Refresh-ExecutionVisuals
            }
        }
        catch {
            try { Update-OperationButtons } catch {}
        }

        try { Refresh-InstalledStatusStrip } catch {}
    }
}

function Try-ArchiveVerifiedPackage([string]$PackagePath,[string]$Sha) {
    if ([string]::IsNullOrWhiteSpace($PackagePath)) { return }
    if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) { return }
    $appId = [string](Get-PropertyValue $script:SelectedApp 'id')
    $raw = [string](Get-PropertyValue $script:SelectedApp 'verified_package_folder')
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = "%APP_HOME%\Packages\$appId\Verified" }
    $targetDir = Expand-ConfigPath $raw
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    $target = Join-Path $targetDir ([System.IO.Path]::GetFileName($PackagePath))
    if (Test-Path -LiteralPath $target) {
        try {
            if ((Get-PackageSha $target) -eq $Sha) { Remove-Item -LiteralPath $PackagePath -Force; return }
        } catch {}
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($PackagePath)
        $ext = [System.IO.Path]::GetExtension($PackagePath)
        $target = Join-Path $targetDir ("{0}_{1}{2}" -f $stem,(Get-Date -Format 'yyyyMMdd_HHmmss'),$ext)
    }
    try { Move-Item -LiteralPath $PackagePath -Destination $target -Force } catch {}
}

function Get-SessionKey([string]$Category,[string]$Operation,[string]$Sha) {
    $appId = [string](Get-PropertyValue $script:SelectedApp 'id')
    return "$appId`:$Category`:$Sha`:$Operation"
}

function Set-BusyState([bool]$Busy) {
    foreach ($b in @($script:ApplyBtn,$script:VerifyBtn,$script:RollbackBtn,$script:ContinuityBtn,$script:DrBackupBtn,$script:DrVerifyBtn,$script:DrFullBtn,$script:DrContinuityBtn,$script:DrRestoreBtn,$script:DrDestroyBtn,$script:DrListBtn,$script:RefreshPackagesBtn,$script:BrowsePackageBtn,$script:ArchivePackageBtn,$script:AppCombo)) {
        if ($null -ne $b) { $b.Enabled = -not $Busy }
    }
    $script:CancelBtn.Enabled = $Busy
    $script:DrCancelBtn.Enabled = $Busy
    $script:MultipleRunsCheck.Enabled = -not $Busy
    if (-not $Busy) { Update-OperationButtons }

    if ($null -ne $script:QuickScriptsPanel) {
        foreach ($control in $script:QuickScriptsPanel.Controls) {
            if ($control -is [System.Windows.Forms.Button]) {
                $control.Enabled = -not $Busy
            }
        }
    }

    if ($null -ne $script:DrQuickScriptsPanel) {
        foreach ($control in $script:DrQuickScriptsPanel.Controls) {
            if ($control -is [System.Windows.Forms.Button]) {
                $control.Enabled = -not $Busy
            }
        }
    }
}


function Load-LatestOperationView {
    if ($null -eq $script:SelectedApp -or $null -eq $script:OperationOutput) { return }

    $prefix = (Get-SafeName ([string](Get-PropertyValue $script:SelectedApp 'name'))) + '_'
    $latest = Get-ChildItem -LiteralPath $LogsDir -Filter "$prefix*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        if ($script:OperationOutput.TextLength -eq 0) {
            $script:OperationStatus.Text = 'READY - no previous run log'
        }
        return
    }

    try {
        $content = Get-Content -LiteralPath $latest.FullName -Raw -ErrorAction Stop
        $script:OperationOutput.Clear()
        $displayContent = Add-DisplayTimestamps $content $latest.CreationTime $true
        Append-ColouredLogText -Box $script:OperationOutput -Text $displayContent
        Scroll-RichTextBoxToBottom $script:OperationOutput

        $result = 'LAST RUN'
        if ($content -match '\[AOM\]\s+RESULT:\s+([A-Z]+)') {
            $result = "LAST RUN: $($matches[1])"
        }
        $script:OperationStatus.Text = "$result | $(Get-DisplayDateTime $latest.CreationTime) | $($latest.Name)"
        $script:LastViewedLogPath = $latest.FullName
    }
    catch {
        $script:OperationStatus.Text = "READY - latest log could not be loaded"
    }
}

function Refresh-LogHandoff {
    if ($null -eq $script:SelectedApp) { return }

    $prefix = (Get-SafeName ([string](Get-PropertyValue $script:SelectedApp 'name'))) + '_'
    $logs = @(Get-ChildItem -LiteralPath $LogsDir -Filter "$prefix*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 20)

    $script:RecentLogPaths = @($logs | ForEach-Object { $_.FullName })

    $records = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($log in $logs) {
        if ($seen.Add($log.FullName)) {
            [void]$records.Add([pscustomobject]@{
                Path = $log.FullName
                Type = 'LOG'
                Name = $log.Name
                Created = $log.CreationTime
            })
        }

        # Discover generated ZIP/files referenced by each completed run log.
        # The actual file CreationTime is shown, not a timestamp parsed from its name.
        try {
            $content = Get-Content -LiteralPath $log.FullName -Raw -ErrorAction Stop

            foreach ($pattern in @(
                '(?m)^\[PASS\]\s+ZIP READY FOR AI:\s*(.+?)\s*$',
                '(?m)^\[AOM\]\s+GENERATED ZIP:\s*(.+?)\s*$',
                '(?m)^\[AOM\]\s+GENERATED FILE:\s*(.+?)\s*$'
            )) {
                foreach ($match in [regex]::Matches($content,$pattern)) {
                    $candidate = $match.Groups[1].Value.Trim()
                    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
                    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
                    if (-not $seen.Add($candidate)) { continue }

                    $fileItem = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
                    if ($null -eq $fileItem) { continue }

                    $ext = [System.IO.Path]::GetExtension($candidate)
                    $type = if ($ext -ieq '.zip') { 'ZIP' } else { 'FILE' }

                    [void]$records.Add([pscustomobject]@{
                        Path = $candidate
                        Type = $type
                        Name = $fileItem.Name
                        Created = $fileItem.CreationTime
                    })
                }
            }
        }
        catch {}
    }

    $ordered = @($records | Sort-Object Created -Descending)
    $script:RecentHandoffPaths = @($ordered | ForEach-Object { $_.Path })

    $script:LogList.Items.Clear()
    $script:DrLogList.Items.Clear()

    foreach ($record in $ordered) {
        $createdText = ([datetime]$record.Created).ToString('dd/MM/yyyy HH:mm:ss')
        $fileText = "[{0}] {1}" -f $record.Type,$record.Name

        $opItem = New-Object System.Windows.Forms.ListViewItem($createdText)
        [void]$opItem.SubItems.Add($fileText)
        $opItem.Tag = [string]$record.Path
        [void]$script:LogList.Items.Add($opItem)

        $drItem = New-Object System.Windows.Forms.ListViewItem($createdText)
        [void]$drItem.SubItems.Add($fileText)
        $drItem.Tag = [string]$record.Path
        [void]$script:DrLogList.Items.Add($drItem)
    }

    # Legacy individual drag labels remain hidden.
    foreach ($control in @(
        $script:CurrentLogLabel,
        $script:CurrentOutputLabel,
        $script:DrCurrentLogLabel,
        $script:DrCurrentOutputLabel
    )) {
        if ($null -ne $control) {
            $control.Visible = $false
            $control.Tag = $null
        }
    }
}

function Open-SelectedHandoffFolder([System.Windows.Forms.ListView]$ListView) {
    if ($null -eq $ListView -or $ListView.SelectedItems.Count -lt 1) { return }

    $path = [string]$ListView.SelectedItems[0].Tag
    if ([string]::IsNullOrWhiteSpace($path) -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return
    }

    try {
        Start-Process explorer.exe -ArgumentList ('/select,"' + $path + '"')
    }
    catch {}
}

function Start-FileDrag($Control,[string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $data = New-Object System.Windows.Forms.DataObject
    $data.SetData([System.Windows.Forms.DataFormats]::FileDrop, [string[]]@($Path))
    [void]$Control.DoDragDrop($data,[System.Windows.Forms.DragDropEffects]::Copy)
}

function Start-HandoffSelectionDrag(
    [System.Windows.Forms.ListView]$ListView,
    [System.Windows.Forms.ListViewItem]$DraggedItem
) {
    if ($null -eq $ListView -or $null -eq $DraggedItem) { return }

    # Standard Windows behaviour: Ctrl-click selects individual files and
    # Shift-click selects a range. Dragging any selected row drags the entire
    # current selection as one FileDrop operation.
    if (-not $DraggedItem.Selected) {
        foreach ($item in $ListView.Items) { $item.Selected = $false }
        $DraggedItem.Selected = $true
    }

    $paths = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in $ListView.SelectedItems) {
        $path = [string]$item.Tag
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        if ($seen.Add($path)) { [void]$paths.Add($path) }
    }

    if ($paths.Count -lt 1) { return }

    $data = New-Object System.Windows.Forms.DataObject
    $data.SetData(
        [System.Windows.Forms.DataFormats]::FileDrop,
        [string[]]$paths.ToArray()
    )
    [void]$ListView.DoDragDrop($data,[System.Windows.Forms.DragDropEffects]::Copy)
}


function Get-PackageArchiveRoot {
    $storage = Get-PropertyValue $script:Config 'storage'
    $raw = if ($null -ne $storage) { [string](Get-PropertyValue $storage 'archive_folder') } else { '' }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $raw = '%USERPROFILE%\Downloads\AOM_Archive'
    }
    return (Expand-ConfigPath $raw)
}

function Get-ArchiveNoConfirmPreference {
    if (-not (Test-Path -LiteralPath $ArchiveNoConfirmStatePath -PathType Leaf)) {
        return $false
    }

    try {
        $raw = (Get-Content -LiteralPath $ArchiveNoConfirmStatePath -Raw -ErrorAction Stop).Trim()
        return ($raw -eq '1')
    }
    catch {
        return $false
    }
}

function Set-ArchiveNoConfirmPreference([bool]$Enabled) {
    try {
        $parent = Split-Path -Parent $ArchiveNoConfirmStatePath
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Set-Content -LiteralPath $ArchiveNoConfirmStatePath -Value ($(if ($Enabled) { '1' } else { '0' })) -Encoding Ascii
    }
    catch {}
}

function Show-ArchiveConfirmation(
    [string]$Source,
    [string]$Destination
) {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Archive selected ZIP'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.ClientSize = [System.Drawing.Size]::new(650,270)
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI',9)

    $message = New-Object System.Windows.Forms.Label
    $message.Text = "Move this package to the archive?"
    $message.Font = New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Bold)
    $message.Location = [System.Drawing.Point]::new(18,18)
    $message.Size = [System.Drawing.Size]::new(610,28)
    $dialog.Controls.Add($message)

    $fromLabel = New-Object System.Windows.Forms.Label
    $fromLabel.Text = "FROM:`r`n$Source"
    $fromLabel.Location = [System.Drawing.Point]::new(18,58)
    $fromLabel.Size = [System.Drawing.Size]::new(610,58)
    $fromLabel.AutoEllipsis = $true
    $dialog.Controls.Add($fromLabel)

    $toLabel = New-Object System.Windows.Forms.Label
    $toLabel.Text = "TO:`r`n$Destination"
    $toLabel.Location = [System.Drawing.Point]::new(18,122)
    $toLabel.Size = [System.Drawing.Size]::new(610,58)
    $toLabel.AutoEllipsis = $true
    $dialog.Controls.Add($toLabel)

    $dontAsk = New-Object System.Windows.Forms.CheckBox
    $dontAsk.Text = "Don't ask me again for ARCHIVE ZIP"
    $dontAsk.Location = [System.Drawing.Point]::new(18,190)
    $dontAsk.Size = [System.Drawing.Size]::new(330,26)
    $dialog.Controls.Add($dontAsk)

    $archiveButton = New-Object System.Windows.Forms.Button
    $archiveButton.Text = 'ARCHIVE ZIP'
    $archiveButton.Location = [System.Drawing.Point]::new(488,222)
    $archiveButton.Size = [System.Drawing.Size]::new(140,34)
    $archiveButton.Add_Click({
        $dialog.Tag = [pscustomobject]@{
            Confirmed = $true
            DontAskAgain = [bool]$dontAsk.Checked
        }
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })
    $dialog.Controls.Add($archiveButton)

    $dialog.AcceptButton = $archiveButton

    # The window X is the cancel path; there is intentionally no second action
    # button so the confirmation remains visually simple.
    $dialog.Tag = [pscustomobject]@{
        Confirmed = $false
        DontAskAgain = $false
    }

    [void]$dialog.ShowDialog($form)
    $result = $dialog.Tag
    try { $dialog.Dispose() } catch {}
    return $result
}


function Archive-SelectedPackage {
    if ($script:Process -ne $null -and -not $script:Process.HasExited) {
        [System.Windows.Forms.MessageBox]::Show(
            "A script is currently running. Wait for it to finish before archiving the package.",
            "Package busy"
        ) | Out-Null
        return
    }

    $source = [string]$script:CurrentPackagePath
    if ([string]::IsNullOrWhiteSpace($source) -or
        -not (Test-Path -LiteralPath $source -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show(
            "There is no valid selected ZIP package to archive.",
            "No package selected"
        ) | Out-Null
        return
    }

    if ([System.IO.Path]::GetExtension($source) -ine '.zip') {
        [System.Windows.Forms.MessageBox]::Show(
            "Only ZIP packages can be archived.",
            "Unsupported file"
        ) | Out-Null
        return
    }

    $archiveRoot = Get-PackageArchiveRoot
    if ([string]::IsNullOrWhiteSpace($archiveRoot)) { return }

    $sourceFull = [System.IO.Path]::GetFullPath($source)
    $archiveFull = [System.IO.Path]::GetFullPath($archiveRoot).TrimEnd('\') + '\'
    if ($sourceFull.StartsWith($archiveFull,[System.StringComparison]::OrdinalIgnoreCase)) {
        [System.Windows.Forms.MessageBox]::Show(
            "This package is already inside the archive folder:`r`n$archiveRoot",
            "Already archived"
        ) | Out-Null
        return
    }

    $appId = Get-SafeName ([string](Get-PropertyValue $script:SelectedApp 'id'))
    if ([string]::IsNullOrWhiteSpace($appId)) { $appId = 'Application' }
    $monthFolder = Get-Date -Format 'yyyy-MM'
    $destinationDir = Join-Path $archiveRoot (Join-Path $appId $monthFolder)
    New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null

    $fileName = [System.IO.Path]::GetFileName($source)
    $destination = Join-Path $destinationDir $fileName

    if (Test-Path -LiteralPath $destination) {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $destination = Join-Path $destinationDir (
            "{0}_{1}.zip" -f $stem,(Get-Date -Format 'yyyyMMdd_HHmmss')
        )
    }

    if (-not (Get-ArchiveNoConfirmPreference)) {
        $confirmation = Show-ArchiveConfirmation -Source $source -Destination $destination
        if ($null -eq $confirmation -or -not [bool](Get-PropertyValue $confirmation 'Confirmed')) {
            return
        }

        if ([bool](Get-PropertyValue $confirmation 'DontAskAgain')) {
            Set-ArchiveNoConfirmPreference $true
        }
    }

    try {
        Move-Item -LiteralPath $source -Destination $destination -Force

        # Clear the old explicit selection so Refresh cannot retain the moved package.
        $script:CurrentPackagePath = $null
        $script:CurrentPackageInspection = $null

        # No second success popup. The archive action completes silently
        # and the package list refreshes immediately.
        Refresh-Packages
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not archive the selected package:`r`n`r`n$($_.Exception.Message)",
            "Archive failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Refresh-Packages {
    # Refresh means: rescan packages and select the newest ZIP by LastWriteTime.
    # A manual Browse selection remains active only until the next Refresh.
    $discovered = New-Object System.Collections.Generic.List[object]

    if ($null -ne $script:SelectedApp) {
        $folder = Expand-ConfigPath ([string](Get-PropertyValue $script:SelectedApp 'package_folder'))
        if (Test-Path -LiteralPath $folder -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $folder -File -Filter '*.zip' |
                Sort-Object LastWriteTime -Descending)

            foreach ($f in $files) {
                [void]$discovered.Add($f)
            }
        }
    }

    # Keep an explicitly browsed ZIP in the list if it exists outside the configured folder.
    # It participates in the same newest-first ordering.
    if (-not [string]::IsNullOrWhiteSpace([string]$script:CurrentPackagePath) -and
        (Test-Path -LiteralPath $script:CurrentPackagePath -PathType Leaf) -and
        ([System.IO.Path]::GetExtension($script:CurrentPackagePath) -ieq '.zip')) {

        $already = $false
        foreach ($item in $discovered) {
            if ([string]::Equals($item.FullName,$script:CurrentPackagePath,[System.StringComparison]::OrdinalIgnoreCase)) {
                $already = $true
                break
            }
        }

        if (-not $already) {
            $extra = Get-Item -LiteralPath $script:CurrentPackagePath
            [void]$discovered.Add($extra)
        }
    }

    $ordered = @($discovered | Sort-Object LastWriteTime -Descending)
    $script:PackagePaths = @($ordered | ForEach-Object { $_.FullName })

    $script:PackageCombo.Items.Clear()
    foreach ($path in $script:PackagePaths) {
        [void]$script:PackageCombo.Items.Add([System.IO.Path]::GetFileName($path))
    }

    if ($script:PackagePaths.Count -eq 0) {
        $script:CurrentPackagePath = $null
        $script:CurrentPackageInspection = $null
        $script:PackageInfoBox.Text = "No ZIP package detected. Use Browse..."
        Refresh-PackageExecutionBadge
        Rebuild-QuickScriptButtons
        Rebuild-DrQuickScriptButtons
        Update-OperationButtons
        return
    }

    # Always select the newest ZIP after Refresh.
    $script:PackageCombo.SelectedIndex = 0
    Refresh-PackageInfo
}

function Refresh-PackageInfo {
    $idx = $script:PackageCombo.SelectedIndex
    if ($idx -lt 0 -or $idx -ge $script:PackagePaths.Count) {
        $script:CurrentPackagePath = $null
        $script:CurrentPackageInspection = $null
        $script:PackageInfoBox.Text = "No package selected."
        Refresh-PackageExecutionBadge
        Rebuild-QuickScriptButtons
        Update-OperationButtons
        return
    }
    $path = $script:PackagePaths[$idx]
    $script:CurrentPackagePath = $path
    $inspection = Inspect-Package $path
    $script:CurrentPackageInspection = $inspection
    if ($inspection.Error) { $script:PackageInfoBox.Text = "Package inspection failed:`r`n$($inspection.Error)"; Refresh-PackageExecutionBadge; Rebuild-QuickScriptButtons; Rebuild-DrQuickScriptButtons; Update-OperationButtons; return }
    $info = $inspection.Info
    $release = Get-PropertyValue $info 'release'
    if ([string]::IsNullOrWhiteSpace([string]$release)) { $release = $inspection.Release }
    if ([string]::IsNullOrWhiteSpace([string]$release)) { $release = 'not declared' }
    $ptype = Get-PropertyValue $info 'type'
    if ([string]::IsNullOrWhiteSpace([string]$ptype)) { $ptype = 'SCRIPT-DISCOVERY PACKAGE' }
    $appId = [string](Get-PropertyValue $script:SelectedApp 'id')
    $pkgApp = [string](Get-PropertyValue $info 'application_id')
    $compat = if ([string]::IsNullOrWhiteSpace($pkgApp)) { 'SCRIPT DISCOVERY / no application metadata' } elseif ($pkgApp -eq $appId) { 'PASS - explicit application metadata' } else { 'FAIL - explicit application mismatch' }
    $sha = Get-PackageSha $path
    $state = Get-PackageState $appId $sha
    $safety = 'NEW - Apply has not been attempted'
    if ($state) {
        $vr = Get-PropertyValue $state 'verify_result'
        $aa = Get-PropertyValue $state 'apply_attempted'
        $ar = Get-PropertyValue $state 'apply_result'
        if ($vr -eq 'PASS') { $safety = 'VERIFIED PASS - package completed' }
        elseif ($aa) { $safety = "APPLY ATTEMPTED ($ar)" }
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Target application: $([string](Get-PropertyValue $script:SelectedApp 'name'))")
    $lines.Add("Selected script package: $([System.IO.Path]::GetFileName($path))")
    $lines.Add("ZIP: $path")
    $lines.Add("Release: $release")
    $lines.Add("Type: $ptype")
    $lines.Add("Compatibility: $compat")
    $lines.Add("Safety: $safety")
    $lines.Add("Execution mode: $(if ($script:MultipleRunsCheck.Checked) {'MULTIPLE RUNS'} else {'SINGLE RUN'})")
    $lines.Add("SHA256: $sha")
    $lines.Add("")
    $lines.Add("Detected operations:")
    foreach ($k in @('apply','verify','rollback','continuity','dr_backup','dr_verify_backup','dr_test_restore','dr_destroy_test','dr_list_snapshots','dr_full_recovery')) {
        if ($inspection.Operations.ContainsKey($k)) { $lines.Add("  $k : READY -> $([System.IO.Path]::GetFileName([string]$inspection.Operations[$k]))") }
        else { $lines.Add("  $k : Not available") }
    }
    $lines.Add("")
    $lines.Add("Scripts inside selected ZIP ($($inspection.Scripts.Count)):")
    foreach($sc in @($inspection.Scripts)){ $lines.Add("  - $sc") }
    $script:PackageInfoBox.Text = ($lines -join "`r`n")
    Refresh-PackageExecutionBadge
    Rebuild-QuickScriptButtons
    Rebuild-DrQuickScriptButtons
    Update-OperationScriptLabels
    Update-OperationButtons
}


function Get-OperationDisplayScript {
    param([string]$Operation)

    if ($null -eq $script:CurrentPackageInspection) { return 'Not available' }

    $op = $Operation.ToLowerInvariant()
    $mapping = $script:CurrentPackageInspection.Operations
    if ($null -eq $mapping) { return 'Not available' }

    $value = Get-PropertyValue $mapping $op
    if ([string]::IsNullOrWhiteSpace([string]$value)) { return 'Not available' }

    return [System.IO.Path]::GetFileName([string]$value)
}

function Get-OtherPackageScripts {
    if ($null -eq $script:CurrentPackageInspection) { return @() }

    $all = @($script:CurrentPackageInspection.Scripts)
    if ($all.Count -eq 0) { return @() }

    $standard = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($op in @('apply','verify','rollback','continuity')) {
        $mapped = Get-PropertyValue $script:CurrentPackageInspection.Operations $op
        if (-not [string]::IsNullOrWhiteSpace([string]$mapped)) {
            [void]$standard.Add([System.IO.Path]::GetFileName([string]$mapped))
        }
    }

    $other = @()
    foreach ($sc in $all) {
        $name = [System.IO.Path]::GetFileName([string]$sc)
        if (-not $standard.Contains($name)) {
            $other += [string]$sc
        }
    }
    return $other
}

function Update-OperationScriptLabels {
    if ($null -ne $script:ApplyScriptLabel) {
        $script:ApplyScriptLabel.Text = Get-OperationDisplayScript 'apply'
    }
    if ($null -ne $script:VerifyScriptLabel) {
        $script:VerifyScriptLabel.Text = Get-OperationDisplayScript 'verify'
    }
    if ($null -ne $script:RollbackScriptLabel) {
        $script:RollbackScriptLabel.Text = Get-OperationDisplayScript 'rollback'
    }
    if ($null -ne $script:ContinuityScriptLabel) {
        $script:ContinuityScriptLabel.Text = Get-OperationDisplayScript 'continuity'
    }

    if ($null -ne $script:OtherScriptsCombo) {
        $selectedBefore = [string]$script:OtherScriptsCombo.SelectedItem
        $script:OtherScriptsCombo.Items.Clear()

        foreach ($sc in @(Get-OtherPackageScripts)) {
            [void]$script:OtherScriptsCombo.Items.Add([string]$sc)
        }

        if ($script:OtherScriptsCombo.Items.Count -gt 0) {
            $restoreIndex = -1
            if (-not [string]::IsNullOrWhiteSpace($selectedBefore)) {
                for ($i=0; $i -lt $script:OtherScriptsCombo.Items.Count; $i++) {
                    if ([string]$script:OtherScriptsCombo.Items[$i] -eq $selectedBefore) {
                        $restoreIndex = $i
                        break
                    }
                }
            }
            if ($restoreIndex -ge 0) { $script:OtherScriptsCombo.SelectedIndex = $restoreIndex }
            else { $script:OtherScriptsCombo.SelectedIndex = 0 }
        }
    }

    foreach ($label in @(
        $script:ApplyScriptLabel,
        $script:VerifyScriptLabel,
        $script:RollbackScriptLabel,
        $script:ContinuityScriptLabel
    )) {
        if ($null -eq $label) { continue }
        if ($label.Text -eq 'Not available') {
            $label.ForeColor = [System.Drawing.Color]::DimGray
        } else {
            $label.ForeColor = [System.Drawing.Color]::ForestGreen
        }
    }
}


function Invoke-PackageScriptDirect {
    param([string]$ScriptEntry)

    if ($script:Process -ne $null -and -not $script:Process.HasExited) {
        [System.Windows.Forms.MessageBox]::Show("Another operation is already running.","Operation in progress") | Out-Null
        return
    }
    if ($null -eq $script:CurrentPackagePath -or -not (Test-Path -LiteralPath $script:CurrentPackagePath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show("Select a ZIP package first.","Package required") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($ScriptEntry)) { return }

    $entryName = [System.IO.Path]::GetFileName($ScriptEntry)
    $ext = [System.IO.Path]::GetExtension($entryName).ToLowerInvariant()
    if ($ext -notin @('.bat','.cmd','.ps1')) {
        [System.Windows.Forms.MessageBox]::Show("Unsupported script type: $ext","Cannot execute script") | Out-Null
        return
    }

    if (-not (Test-PackageCompatibility)) { return }

    $sha = Get-PackageSha $script:CurrentPackagePath
    $sessionOperation = "QUICK_" + (Get-SafeName $ScriptEntry)
    $packageIdentity = [System.IO.Path]::GetFullPath($script:CurrentPackagePath).ToUpperInvariant()
    $key = "SCRIPT_PATH:$packageIdentity`:$sessionOperation"

    if (-not $script:MultipleRunsCheck.Checked -and $script:SessionAttempts.Contains($key)) {
        [System.Windows.Forms.MessageBox]::Show(
            "This exact script has already been launched once in this session. Enable ALLOW MULTIPLE RUNS to repeat it.",
            "Single-run mode"
        ) | Out-Null
        return
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $appId = [string](Get-PropertyValue $script:SelectedApp 'id')
    $workDir = Join-Path $TempRoot ("{0}_QUICK_{1}" -f $appId,$stamp)
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null

    try {
        Expand-Archive -LiteralPath $script:CurrentPackagePath -DestinationPath $workDir -Force
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Package extraction failed:`r`n$($_.Exception.Message)","Package error") | Out-Null
        return
    }

    $relative = ([string]$ScriptEntry) -replace '/', '\'
    $scriptPath = Join-Path $workDir $relative
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show(
            "The selected script was not found after extraction:`r`n$ScriptEntry",
            "Script not found"
        ) | Out-Null
        return
    }

    [void]$script:SessionAttempts.Add($key)

    $started = Start-ManagedOperation `
        -ScriptPath $scriptPath `
        -Category 'SCRIPT' `
        -Operation $entryName `
        -PackagePath $script:CurrentPackagePath `
        -PackageSha $sha `
        -WorkRoot $workDir `
        -PrefeedLines @('') `
        -OutputBox $script:OperationOutput `
        -StatusLabel $script:OperationStatus

    if ($started) {
        $script:MultipleRunsCheck.Checked = $false
        Update-OperationButtons
    }
}

function Rebuild-QuickScriptButtons {
    if ($null -eq $script:QuickScriptsPanel) { return }
    $script:QuickScriptsPanel.Controls.Clear()

    if ($null -eq $script:CurrentPackageInspection) {
        $empty = New-Object System.Windows.Forms.Label
        $empty.Text = 'No package selected.'
        $empty.AutoSize = $true
        $empty.Location = [System.Drawing.Point]::new(4,4)
        $script:QuickScriptsPanel.Controls.Add($empty)
        return
    }

    $scripts = @($script:CurrentPackageInspection.Scripts)
    if ($scripts.Count -eq 0) {
        $empty = New-Object System.Windows.Forms.Label
        $empty.Text = 'No executable scripts detected in this ZIP.'
        $empty.AutoSize = $true
        $empty.Location = [System.Drawing.Point]::new(4,4)
        $script:QuickScriptsPanel.Controls.Add($empty)
        return
    }

    $ordered = @($scripts | Sort-Object { [System.IO.Path]::GetFileName([string]$_) })

    # Preserve established 4-row columns:
    # 1..4 first column, 5..8 second column, etc.
    $rowsPerColumn = 4
    $leftPad = 4
    $topPad = 4
    $buttonH = 28
    $colGap = 8
    $rowGap = 4

    # v1.0.44: compact automatic button sizing.
    # Do NOT stretch buttons to fill the whole panel.
    $minButtonW = 260
    $maxButtonW = 460
    $textPadding = 34

    $measureFont = New-Object System.Drawing.Font('Segoe UI',9)

    # Calculate a practical width for each column independently.
    $columnWidths = @{}
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $columnIndex = [int][Math]::Floor($i / $rowsPerColumn)
        $displayName = [System.IO.Path]::GetFileName([string]$ordered[$i])
        $text = ("{0}.  {1}" -f ($i + 1),$displayName)
        $measured = [System.Windows.Forms.TextRenderer]::MeasureText($text,$measureFont)
        $required = [Math]::Max($minButtonW,($measured.Width + $textPadding))
        $required = [Math]::Min($maxButtonW,$required)

        if (-not $columnWidths.ContainsKey($columnIndex) -or
            $required -gt [int]$columnWidths[$columnIndex]) {
            $columnWidths[$columnIndex] = [int]$required
        }
    }

    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 20000
    $toolTip.InitialDelay = 300
    $toolTip.ReshowDelay = 100
    $script:QuickScriptsToolTip = $toolTip

    # Pre-calculate X position of each column because widths can differ.
    $columnX = @{}
    $runningX = $leftPad
    $columnCount = [int][Math]::Ceiling(($ordered.Count * 1.0) / $rowsPerColumn)
    for ($col = 0; $col -lt $columnCount; $col++) {
        $columnX[$col] = $runningX
        $runningX += [int]$columnWidths[$col] + $colGap
    }

    $n = 1
    foreach ($entry in $ordered) {
        $scriptEntry = [string]$entry
        $displayName = [System.IO.Path]::GetFileName($scriptEntry)

        $zeroIndex = $n - 1
        $columnIndex = [int][Math]::Floor($zeroIndex / $rowsPerColumn)
        $rowIndex = $zeroIndex % $rowsPerColumn

        $x = [int]$columnX[$columnIndex]
        $y = $topPad + ($rowIndex * ($buttonH + $rowGap))
        $buttonW = [int]$columnWidths[$columnIndex]

        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = ("{0}.  {1}" -f $n,$displayName)
        $btn.AccessibleDescription = $btn.Text
        $btn.Tag = $scriptEntry
        $btn.AccessibleName = Get-PackageExecutionKey $script:CurrentPackagePath $scriptEntry
        $btn.Location = [System.Drawing.Point]::new($x,$y)
        $btn.Size = [System.Drawing.Size]::new($buttonW,$buttonH)
        $btn.TextAlign = 'MiddleLeft'
        $btn.Anchor = 'Top,Left'
        $btn.AutoEllipsis = $true

        # Always expose the exact script path/name on hover.
        $toolTip.SetToolTip($btn,$scriptEntry)

        $btn.Add_Click({
            param($sender,$eventArgs)
            Invoke-PackageScriptDirect -ScriptEntry ([string]$sender.Tag)
        })
        $script:QuickScriptsPanel.Controls.Add($btn)

        $storedState = Get-ExecutionState ([string]$btn.AccessibleName)
        $visualState = ''
        if ($null -ne $script:RunContext -and
            [string](Get-PropertyValue $script:RunContext 'ExecutionKey') -eq [string]$btn.AccessibleName) {
            $visualState = 'RUNNING'
        }
        elseif ($null -ne $storedState) {
            $visualState = [string](Get-PropertyValue $storedState 'result')
        }
        Set-RunButtonVisual $btn $visualState

        $n++
    }

    $contentW = $runningX
    $contentH = $topPad + ($rowsPerColumn * ($buttonH + $rowGap))

    # Horizontal scrolling appears only when the total compact columns exceed
    # the visible panel width.
    $script:QuickScriptsPanel.AutoScrollMinSize = [System.Drawing.Size]::new($contentW,$contentH)

    try { $measureFont.Dispose() } catch {}
}


function Rebuild-DrQuickScriptButtons {
    # Retained as a compatibility no-op. DR is fixed-toolkit driven from v1.0.27.
    return
}

function Update-OperationButtons {
    foreach ($b in @(
        $script:ApplyBtn,
        $script:VerifyBtn,
        $script:RollbackBtn,
        $script:ContinuityBtn,
        $script:DrBackupBtn,
        $script:DrVerifyBtn,
        $script:DrFullBtn,
        $script:DrContinuityBtn,
        $script:DrRestoreBtn,
        $script:DrDestroyBtn,
        $script:DrListBtn
    )) {
        if ($b) { $b.Enabled = $false }
    }

    if ($script:Process -ne $null -and -not $script:Process.HasExited) { return }
    if ($null -eq $script:SelectedApp) { return }

    $repeat = $script:MultipleRunsCheck.Checked

    # ---------------------------------------------------------------
    # Disaster Recovery is NOT package/ZIP driven.
    # It executes the fixed toolkit configured for the selected app.
    # ---------------------------------------------------------------
    $toolkitRaw = [string](Get-PropertyValue $script:SelectedApp 'dr_toolkit')
    $toolkit = Expand-ConfigPath $toolkitRaw
    $drScripts = Get-PropertyValue $script:SelectedApp 'dr_scripts'

    if (-not [string]::IsNullOrWhiteSpace($toolkit) -and
        (Test-Path -LiteralPath $toolkit -PathType Container) -and
        $null -ne $drScripts) {

        foreach ($pair in @(
            @('backup',              'backup',              $script:DrBackupBtn),
            @('verify_backup',       'verify_backup',       $script:DrVerifyBtn),
            @('full_recovery',       'full_recovery',       $script:DrFullBtn),
            @('continuity_snapshot', 'continuity_snapshot', $script:DrContinuityBtn),
            @('test_restore',        'test_restore',        $script:DrRestoreBtn),
            @('destroy_test',        'destroy_test',        $script:DrDestroyBtn),
            @('list_snapshots',      'list_snapshots',      $script:DrListBtn)
        )) {
            $operation = [string]$pair[0]
            $propertyName = [string]$pair[1]
            $button = $pair[2]

            $scriptName = [string](Get-PropertyValue $drScripts $propertyName)
            if ([string]::IsNullOrWhiteSpace($scriptName)) { continue }

            $scriptPath = Join-Path $toolkit $scriptName
            if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { continue }

            # Keep the button enabled so its PASS/FAIL colour remains visible.
            # Execute-DrOperation still enforces single-run protection.
            $button.Enabled = $true
        }
    }

    # ---------------------------------------------------------------
    # Operations remains selected-ZIP driven.
    # ---------------------------------------------------------------
    if ($null -eq $script:CurrentPackageInspection -or
        $null -eq $script:CurrentPackagePath) {
        Refresh-ExecutionVisuals
        return
    }

    $ops = $script:CurrentPackageInspection.Operations
    $sha = Get-PackageSha $script:CurrentPackagePath
    $appId = [string](Get-PropertyValue $script:SelectedApp 'id')
    $state = Get-PackageState $appId $sha

    foreach ($pair in @(
        @('apply',$script:ApplyBtn),
        @('verify',$script:VerifyBtn),
        @('rollback',$script:RollbackBtn),
        @('continuity',$script:ContinuityBtn)
    )) {
        $key = [string]$pair[0]
        $btn = $pair[1]

        if ($ops.ContainsKey($key)) {
            $sessionKey = Get-SessionKey 'UPDATE' $key $sha
            $already = $script:SessionAttempts.Contains($sessionKey)
            $btn.Enabled = $repeat -or -not $already
        }
    }

    if ($ops.ContainsKey('apply') -and
        $state -and
        (Get-PropertyValue $state 'apply_attempted') -and
        -not $repeat) {
        $script:ApplyBtn.Enabled = $false
    }

    Refresh-ExecutionVisuals
}

function Test-PackageCompatibility {
    # A package without PACKAGE_INFO.json is valid when the requested script was
    # actually discovered inside the selected ZIP. Only explicit contradictory
    # application metadata is grounds for blocking execution.
    $info = $script:CurrentPackageInspection.Info
    $pkgApp = [string](Get-PropertyValue $info 'application_id')
    $appId = [string](Get-PropertyValue $script:SelectedApp 'id')
    if (-not [string]::IsNullOrWhiteSpace($pkgApp) -and $pkgApp -ne $appId) {
        [System.Windows.Forms.MessageBox]::Show(
            "This package explicitly declares application '$pkgApp', not '$appId'. Execution is blocked.",
            "Wrong target application",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return $false
    }
    return $true
}

function Execute-PackageOperation([string]$Operation) {
    if ($null -eq $script:CurrentPackagePath -or -not (Test-Path -LiteralPath $script:CurrentPackagePath)) { return }
    if (-not (Test-PackageCompatibility)) { return }
    $ops = $script:CurrentPackageInspection.Operations
    if (-not $ops.ContainsKey($Operation)) { return }
    $sha = Get-PackageSha $script:CurrentPackagePath
    $key = Get-SessionKey 'UPDATE' $Operation $sha
    if (-not $script:MultipleRunsCheck.Checked -and $script:SessionAttempts.Contains($key)) {
        [System.Windows.Forms.MessageBox]::Show("This operation has already been launched once in this session. Enable ALLOW MULTIPLE RUNS to repeat it.","Single-run mode") | Out-Null
        return
    }
    $appId = [string](Get-PropertyValue $script:SelectedApp 'id')
    $state = Get-PackageState $appId $sha
    if ($Operation -eq 'apply' -and $state -and (Get-PropertyValue $state 'apply_attempted')) {
        if (-not $script:MultipleRunsCheck.Checked) { return }
        $ans = [System.Windows.Forms.MessageBox]::Show("This exact ZIP has already had an Apply attempt. Repeat APPLY?","Repeat Apply",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning,[System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    [void]$script:SessionAttempts.Add($key)
    if ($Operation -eq 'apply') {
        [void](Update-PackageState $appId $sha @{apply_attempted=$true;apply_result='RUNNING';apply_started=(Get-Date).ToString('o');package_name=[System.IO.Path]::GetFileName($script:CurrentPackagePath)})
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $workDir = Join-Path $TempRoot ("{0}_{1}" -f $appId,$stamp)
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    try { Expand-Archive -LiteralPath $script:CurrentPackagePath -DestinationPath $workDir -Force }
    catch { [System.Windows.Forms.MessageBox]::Show("Extraction failed:`r`n$($_.Exception.Message)","Package error") | Out-Null; return }
    $entryName = [System.IO.Path]::GetFileName([string]$ops[$Operation])
    $scriptPath = Find-ExtractedScript $workDir $entryName
    if (-not $scriptPath) { [System.Windows.Forms.MessageBox]::Show("Could not locate $entryName after extraction.","Script not found") | Out-Null; return }
    $started=Start-ManagedOperation -ScriptPath $scriptPath -Category 'UPDATE' -Operation $Operation.ToUpperInvariant() -PackagePath $script:CurrentPackagePath -PackageSha $sha -WorkRoot $workDir -PrefeedLines @('') -OutputBox $script:OperationOutput -StatusLabel $script:OperationStatus
    if($started){ $script:MultipleRunsCheck.Checked=$false; Refresh-PackageInfo; Rebuild-DrQuickScriptButtons }
}

function Execute-DrOperation([string]$Operation) {
    if ($null -eq $script:SelectedApp) { return }

    $appId = [string](Get-PropertyValue $script:SelectedApp 'id')
    $toolkitRaw = [string](Get-PropertyValue $script:SelectedApp 'dr_toolkit')
    $toolkit = Expand-ConfigPath $toolkitRaw

    if ([string]::IsNullOrWhiteSpace($toolkit) -or
        -not (Test-Path -LiteralPath $toolkit -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show(
            "The Disaster Recovery toolkit folder is not available:`r`n$toolkit`r`n`r`nCheck Settings > Disaster Recovery Toolkit Folder.",
            "DR toolkit not found",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    $drScripts = Get-PropertyValue $script:SelectedApp 'dr_scripts'
    if ($null -eq $drScripts) {
        [System.Windows.Forms.MessageBox]::Show(
            "No Disaster Recovery script mapping is configured for $appId.",
            "DR configuration missing"
        ) | Out-Null
        return
    }

    $propertyName = switch ($Operation) {
        'backup'              { 'backup' }
        'verify_backup'       { 'verify_backup' }
        'test_restore'        { 'test_restore' }
        'destroy_test'        { 'destroy_test' }
        'list_snapshots'      { 'list_snapshots' }
        'full_recovery'       { 'full_recovery' }
        'continuity_snapshot' { 'continuity_snapshot' }
        default          { $null }
    }

    if ([string]::IsNullOrWhiteSpace([string]$propertyName)) { return }

    $scriptName = [string](Get-PropertyValue $drScripts $propertyName)
    if ([string]::IsNullOrWhiteSpace($scriptName)) {
        [System.Windows.Forms.MessageBox]::Show(
            "No script is configured for DR operation '$Operation'.",
            "DR script not configured"
        ) | Out-Null
        return
    }

    $scriptPath = Join-Path $toolkit $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show(
            "The configured DR script was not found:`r`n$scriptPath",
            "DR script not found",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    # Single-run protection is keyed to the fixed toolkit script path,
    # not to the currently selected Operations ZIP.
    $identity = $scriptPath.ToUpperInvariant()
    $key = Get-SessionKey 'DR' $Operation $identity

    if (-not $script:MultipleRunsCheck.Checked -and
        $script:SessionAttempts.Contains($key)) {
        [System.Windows.Forms.MessageBox]::Show(
            "This DR operation already ran once in this session. Enable ALLOW MULTIPLE RUNS to repeat it.",
            "Single-run mode"
        ) | Out-Null
        return
    }

    $prefeed = @('')

    # Existing destructive/sensitive DR confirmations are retained.
    if ($Operation -eq 'destroy_test') {
        $expected = "DESTROY $appId"
        $answer = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Type exactly:`r`n$expected",
            "Destroy isolated test",
            ""
        )
        if ($answer -ne $expected) { return }
        $prefeed = @($expected,'')
    }
    elseif ($Operation -eq 'full_recovery') {
        $default = "LATEST $appId"
        $answer = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Enter snapshot folder/ZIP path, or use:",
            "Create FULL Recovery",
            $default
        )
        if ([string]::IsNullOrWhiteSpace($answer)) { return }
        $prefeed = @($answer,'')
    }

    [void]$script:SessionAttempts.Add($key)

    # DR executes directly from the permanent toolkit folder.
    # WorkRoot is intentionally blank so TEMP cleanup can never remove or
    # alter the toolkit directory.
    $started = Start-ManagedOperation `
        -ScriptPath $scriptPath `
        -Category 'DR' `
        -Operation $Operation.ToUpperInvariant() `
        -PackagePath '' `
        -PackageSha '' `
        -WorkRoot '' `
        -PrefeedLines $prefeed `
        -OutputBox $script:DrOutput `
        -StatusLabel $script:DrStatus

    if ($started) {
        $script:MultipleRunsCheck.Checked = $false
        Update-OperationButtons
    }
}

function Refresh-Applications {
    $script:AppCombo.Items.Clear()

    $apps = @($script:Config.applications)
    foreach ($app in $apps) {
        [void]$script:AppCombo.Items.Add([string]$app.name)
    }

    if ($script:AppCombo.Items.Count -eq 0) { return }

    $savedAppId = ''
    if (Test-Path -LiteralPath $SelectedApplicationStatePath -PathType Leaf) {
        try {
            $savedAppId = (Get-Content -LiteralPath $SelectedApplicationStatePath -Raw -ErrorAction Stop).Trim()
        }
        catch {}
    }

    $selectedIndex = 0
    if (-not [string]::IsNullOrWhiteSpace($savedAppId)) {
        for ($i = 0; $i -lt $apps.Count; $i++) {
            $candidateId = [string](Get-PropertyValue $apps[$i] 'id')
            if ([string]::Equals($candidateId,$savedAppId,[System.StringComparison]::OrdinalIgnoreCase)) {
                $selectedIndex = $i
                break
            }
        }
    }

    $script:AppCombo.SelectedIndex = $selectedIndex
}

function On-ApplicationChanged {
    $idx = $script:AppCombo.SelectedIndex
    if ($idx -lt 0) { return }
    $script:SelectedApp = @($script:Config.applications)[$idx]
    $script:LastActionExecutionKey = ""

    # Remember the selected target application for the next AOM session.
    try {
        $selectedAppId = [string](Get-PropertyValue $script:SelectedApp 'id')
        if (-not [string]::IsNullOrWhiteSpace($selectedAppId)) {
            Set-Content -LiteralPath $SelectedApplicationStatePath -Value $selectedAppId -Encoding ASCII
        }
    }
    catch {}

    Refresh-Packages
    Refresh-LogHandoff
    Load-LatestOperationView
    Load-SettingsForApp
    Refresh-InstalledStatusStrip
}

function Load-SettingsForApp {
    if ($null -eq $script:SelectedApp) { return }
    $script:SetName.Text = [string](Get-PropertyValue $script:SelectedApp 'name')
    $script:SetAppPath.Text = [string](Get-PropertyValue $script:SelectedApp 'application_path')
    $script:SetPackageFolder.Text = [string](Get-PropertyValue $script:SelectedApp 'package_folder')
    $script:SetVerifiedFolder.Text = [string](Get-PropertyValue $script:SelectedApp 'verified_package_folder')
    $script:SetHttpUrl.Text = [string](Get-PropertyValue $script:SelectedApp 'http_url')
    $script:SetDrToolkit.Text = [string](Get-PropertyValue $script:SelectedApp 'dr_toolkit')
    $patterns = @(Get-PropertyValue $script:SelectedApp 'package_patterns')
    $script:SetPatterns.Text = ($patterns -join "`r`n")

    if ($null -ne $script:SetTempFolder) { $script:SetTempFolder.Text = $TempRoot }
    if ($null -ne $script:SetOutputFolder) { $script:SetOutputFolder.Text = $OutputRoot }
    if ($null -ne $script:SetLogsFolder) { $script:SetLogsFolder.Text = $LogsDir }
    if ($null -ne $script:SetArchiveFolder) { $script:SetArchiveFolder.Text = Get-PackageArchiveRoot }
    if ($null -ne $script:SetInstallFolder) {
        $configuredInstall = [string](Get-PropertyValue $script:Config 'toolkit_install_folder')
        if ([string]::IsNullOrWhiteSpace($configuredInstall)) { $configuredInstall = 'C:\PythonProjects\APP AI DevToolkit' }
        $script:SetInstallFolder.Text = $configuredInstall
    }
    if ($null -ne $script:SetAutoCleanTemp) { $script:SetAutoCleanTemp.Checked = Get-AutoCleanTempAfterSuccess }
}

function Save-SelectedSettings {
    if ($null -eq $script:SelectedApp) { return }
    foreach ($kv in @(
        @('name',$script:SetName.Text),
        @('application_path',$script:SetAppPath.Text),
        @('package_folder',$script:SetPackageFolder.Text),
        @('verified_package_folder',$script:SetVerifiedFolder.Text),
        @('http_url',$script:SetHttpUrl.Text),
        @('dr_toolkit',$script:SetDrToolkit.Text)
    )) {
        $prop = $script:SelectedApp.PSObject.Properties[$kv[0]]
        if ($prop) { $prop.Value = $kv[1].Trim() } else { $script:SelectedApp | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1].Trim() }
    }
    $patterns = @($script:SetPatterns.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    $prop = $script:SelectedApp.PSObject.Properties['package_patterns']
    if ($prop) { $prop.Value = $patterns } else { $script:SelectedApp | Add-Member -NotePropertyName 'package_patterns' -NotePropertyValue $patterns }

    # Manager-wide Storage & Paths settings.
    $storage = Get-PropertyValue $script:Config 'storage'
    if ($null -eq $storage) {
        $storage = [pscustomobject]@{}
        $script:Config | Add-Member -NotePropertyName 'storage' -NotePropertyValue $storage
    }

    foreach ($kv in @(
        @('temp_folder',$script:SetTempFolder.Text),
        @('output_folder',$script:SetOutputFolder.Text),
        @('logs_folder',$script:SetLogsFolder.Text),
        @('archive_folder',$script:SetArchiveFolder.Text)
    )) {
        $sp = $storage.PSObject.Properties[[string]$kv[0]]
        if ($null -ne $sp) { $sp.Value = ([string]$kv[1]).Trim() }
        else { $storage | Add-Member -NotePropertyName ([string]$kv[0]) -NotePropertyValue ([string]$kv[1]).Trim() }
    }
    # Manager-wide AI Dev Toolkit installation folder used by future incremental patches.
    $installFolder = ([string]$script:SetInstallFolder.Text).Trim()
    if ([string]::IsNullOrWhiteSpace($installFolder)) {
        $installFolder = 'C:\PythonProjects\APP AI DevToolkit'
    }
    $installProp = $script:Config.PSObject.Properties['toolkit_install_folder']
    if ($null -ne $installProp) { $installProp.Value = $installFolder }
    else { $script:Config | Add-Member -NotePropertyName 'toolkit_install_folder' -NotePropertyValue $installFolder }

    $cleanProp = $storage.PSObject.Properties['auto_clean_temp_after_success']
    if ($null -ne $cleanProp) { $cleanProp.Value = [bool]$script:SetAutoCleanTemp.Checked }
    else { $storage | Add-Member -NotePropertyName 'auto_clean_temp_after_success' -NotePropertyValue ([bool]$script:SetAutoCleanTemp.Checked) }

    Write-JsonFile $ConfigPath $script:Config
    Apply-StorageConfig

    [System.Windows.Forms.MessageBox]::Show(
        "Settings saved:`r`n$ConfigPath`r`n`r`nAI Dev Toolkit: $installFolder`r`nTEMP: $TempRoot`r`nOUTPUT: $OutputRoot`r`nLOGS: $LogsDir",
        "Saved"
    ) | Out-Null
    Refresh-Applications
    Refresh-LogHandoff
}



# ---------- AI PROMPT LIBRARY ----------
# Persistent storage: editable HTML prompt files + JSON metadata. Legacy .rtf/.md stay readable.
function Get-PromptSafeFileName([string]$Identifier) {
    $safe = ([string]$Identifier -replace '[^A-Za-z0-9._-]+','_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'PROMPT' }
    return ($safe + '.html')
}

function Read-PromptIndex {
    if (-not (Test-Path -LiteralPath $PromptIndexPath -PathType Leaf)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $PromptIndexPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj) { return @() }
        $p = $obj.PSObject.Properties['prompts']
        if ($null -ne $p) { return @($p.Value) }
        return @($obj)
    }
    catch { return @() }
}

function Write-PromptIndex([object[]]$Records) {
    New-Item -ItemType Directory -Force -Path $PromptLibraryDir | Out-Null
    $payload = [pscustomobject]@{
        version = 1
        prompts = @($Records)
    }
    $json = $payload | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $PromptIndexPath -Value $json -Encoding UTF8
}

function Get-PromptRecordById([string]$Identifier) {
    if ([string]::IsNullOrWhiteSpace($Identifier)) { return $null }
    foreach ($record in @($script:PromptRecords)) {
        if ([string]::Equals([string]$record.id,$Identifier,[System.StringComparison]::OrdinalIgnoreCase)) {
            return $record
        }
    }
    return $null
}

function Get-PromptFilePath($Record) {
    if ($null -eq $Record) { return '' }
    $fileName = [string]$Record.file
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $fileName = Get-PromptSafeFileName ([string]$Record.id)
    }
    $fileName = [System.IO.Path]::GetFileName($fileName)
    return (Join-Path $PromptLibraryDir $fileName)
}

function Format-PromptDate([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    [datetime]$dt = [datetime]::MinValue
    if ([datetime]::TryParse($Value,[ref]$dt)) {
        return $dt.ToString('dd/MM/yyyy HH:mm:ss')
    }
    return $Value
}

function Initialize-PromptLibrary {
    New-Item -ItemType Directory -Force -Path $PromptLibraryDir | Out-Null
    if (Test-Path -LiteralPath $PromptIndexPath -PathType Leaf) { return }

    # One editable starter prompt makes the feature immediately usable.
    $id = 'BACKUP_MD_001'
    $fileName = 'BACKUP_MD_001.md'
    $content = @'
# Objective

Use the attached Markdown file as the authoritative continuity source and preserve the important project context.

## Instructions

- **Read the complete Markdown file before proposing changes.**
- Preserve confirmed decisions, architecture, procedures, paths, versions and unresolved work.
- **Do not invent missing facts or silently replace project-specific information with general knowledge.**
- Identify contradictions, obsolete information and decisions that supersede older ones.
- Keep operational details that are required to continue the work safely.

## Output required

1. Produce a clear, structured continuity update in Markdown.
2. Keep the most important facts easy to find.
3. Separate confirmed facts from assumptions or open questions.
4. List any missing information that must be confirmed before the document can be treated as authoritative.
'@
    Set-Content -LiteralPath (Join-Path $PromptLibraryDir $fileName) -Value $content -Encoding UTF8
    $now = (Get-Date).ToString('o')
    $record = [pscustomobject]@{
        id = $id
        purpose = 'Backup Markdown continuity file'
        tags = 'backup, documentation, continuity, ai'
        file = $fileName
        created = $now
        updated = $now
    }
    Write-PromptIndex @($record)
}

function Set-PromptRecordProperty($Record,[string]$Name,$Value) {
    $prop = $Record.PSObject.Properties[$Name]
    if ($null -ne $prop) { $prop.Value = $Value }
    else { $Record | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Set-PromptUiStatus([string]$Text) {
    if ($null -ne $script:PromptStatusLabel) { $script:PromptStatusLabel.Text = $Text }
}

function Append-PromptPreviewStyled(
    [System.Windows.Forms.RichTextBox]$Box,
    [string]$Text,
    [System.Drawing.FontStyle]$Style,
    [single]$Size,
    [string]$FontName='Segoe UI'
) {
    if ($null -eq $Box -or $null -eq $Text) { return }
    $Box.SelectionStart = $Box.TextLength
    $Box.SelectionLength = 0
    $Box.SelectionFont = New-Object System.Drawing.Font($FontName,$Size,$Style)
    $Box.AppendText($Text)
}

function Append-PromptPreviewInline(
    [System.Windows.Forms.RichTextBox]$Box,
    [string]$Text,
    [single]$BaseSize=9
) {
    if ($null -eq $Text) { return }
    $pattern = '(\*\*.+?\*\*|`[^`]+`|\*[^*]+\*)'
    $matches = [regex]::Matches($Text,$pattern)
    $pos = 0
    foreach ($m in $matches) {
        if ($m.Index -gt $pos) {
            Append-PromptPreviewStyled $Box $Text.Substring($pos,$m.Index-$pos) ([System.Drawing.FontStyle]::Regular) $BaseSize
        }
        $token = $m.Value
        if ($token.StartsWith('**') -and $token.EndsWith('**') -and $token.Length -ge 4) {
            Append-PromptPreviewStyled $Box $token.Substring(2,$token.Length-4) ([System.Drawing.FontStyle]::Bold) $BaseSize
        }
        elseif ($token.StartsWith('`') -and $token.EndsWith('`') -and $token.Length -ge 2) {
            Append-PromptPreviewStyled $Box $token.Substring(1,$token.Length-2) ([System.Drawing.FontStyle]::Regular) $BaseSize 'Consolas'
        }
        elseif ($token.StartsWith('*') -and $token.EndsWith('*') -and $token.Length -ge 2) {
            Append-PromptPreviewStyled $Box $token.Substring(1,$token.Length-2) ([System.Drawing.FontStyle]::Italic) $BaseSize
        }
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $Text.Length) {
        Append-PromptPreviewStyled $Box $Text.Substring($pos) ([System.Drawing.FontStyle]::Regular) $BaseSize
    }
}

function Convert-LegacyPromptMarkdownToRichText([string]$markdown) {
    if ($null -eq $script:PromptEditor) { return }
    $box = $script:PromptEditor
    $box.Clear()

    $inCode = $false
    foreach ($line in [regex]::Split($markdown,'\r\n|\n|\r')) {
        if ($line -match '^\s*```') {
            $inCode = -not $inCode
            continue
        }

        if ($inCode) {
            Append-PromptPreviewStyled $box ($line + "`r`n") ([System.Drawing.FontStyle]::Regular) 9 'Consolas'
            continue
        }

        if ($line -match '^(#{1,6})\s+(.+)$') {
            $level = $matches[1].Length
            $size = switch ($level) { 1 { 15 } 2 { 13 } 3 { 11 } default { 10 } }
            Append-PromptPreviewStyled $box ($matches[2] + "`r`n") ([System.Drawing.FontStyle]::Bold) $size
            continue
        }

        if ($line -match '^\s*[-*+]\s+(.+)$') {
            Append-PromptPreviewStyled $box '• ' ([System.Drawing.FontStyle]::Bold) 9
            Append-PromptPreviewInline $box $matches[1] 9
            Append-PromptPreviewStyled $box "`r`n" ([System.Drawing.FontStyle]::Regular) 9
            continue
        }

        if ($line -match '^\s*(\d+)\.\s+(.+)$') {
            Append-PromptPreviewStyled $box ($matches[1] + '. ') ([System.Drawing.FontStyle]::Bold) 9
            Append-PromptPreviewInline $box $matches[2] 9
            Append-PromptPreviewStyled $box "`r`n" ([System.Drawing.FontStyle]::Regular) 9
            continue
        }

        if ($line -match '^\s*>\s?(.*)$') {
            Append-PromptPreviewStyled $box ($matches[1] + "`r`n") ([System.Drawing.FontStyle]::Italic) 9
            continue
        }

        if ($line -match '^\s*---+\s*$') {
            Append-PromptPreviewStyled $box ("────────────────────────────────────────`r`n") ([System.Drawing.FontStyle]::Regular) 9
            continue
        }

        Append-PromptPreviewInline $box $line 9
        Append-PromptPreviewStyled $box "`r`n" ([System.Drawing.FontStyle]::Regular) 9
    }

    $box.SelectionStart = 0
    $box.SelectionLength = 0
}

function Mark-PromptDirty {
    if ($script:PromptSuppressEvents) { return }
    $script:PromptDirty = $true
    if ($script:PromptIsNew -or [string]::IsNullOrWhiteSpace($script:PromptCurrentId)) {
        Set-PromptUiStatus 'NEW / UNSAVED — enter Purpose, paste content, click Save. Identifier is automatic.'
        return
    }
    Set-PromptUiStatus 'Unsaved changes — auto-save pending...'
    if ($null -ne $script:PromptAutoSaveTimer) {
        $script:PromptAutoSaveTimer.Stop()
        $script:PromptAutoSaveTimer.Start()
    }
}

function Load-PromptIntoEditor([string]$Identifier) {
    $record = Get-PromptRecordById $Identifier
    if ($null -eq $record) { return }

    $script:PromptSuppressEvents = $true
    try {
        $script:PromptCurrentId = [string]$record.id
        $script:PromptIsNew = $false
        $script:PromptDirty = $false
        $script:PromptIdBox.Text = [string]$record.id
        $script:PromptPurposeBox.Text = [string]$record.purpose
        $script:PromptTagsBox.Text = [string]$record.tags
        $script:PromptUpdatedBox.Text = Format-PromptDate ([string]$record.updated)
        $path = Get-PromptFilePath $record
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $html = Get-PromptHtmlFromLegacyRecord $path
            Set-PromptHtmlDocument $html
        }
        else { Set-PromptHtmlDocument (Get-PromptHtmlTemplate '') }
        Set-PromptUiStatus ("LOADING — {0}" -f [System.IO.Path]::GetFileName($path))
    }
    catch {
        Set-PromptUiStatus ('LOAD FAILED — ' + $_.Exception.Message)
        # Leave current file intact; do not auto-save an empty replacement.
        $script:PromptBrowserReady = $false
    }
    finally { $script:PromptSuppressEvents = $false }
}


function Refresh-PromptLibrary(
    [string]$SelectId='',
    [switch]$SkipEditorLoad
) {
    if ($null -eq $script:PromptList) { return }
    $script:PromptRecords = @(Read-PromptIndex)
    $query = ''
    if ($null -ne $script:PromptSearchBox) { $query = ([string]$script:PromptSearchBox.Text).Trim() }

    $script:PromptSuppressSelection = $true
    try {
        $script:PromptList.Items.Clear()
        foreach ($record in @($script:PromptRecords | Sort-Object @{Expression={
            [datetime]$d=[datetime]::MinValue
            if ([datetime]::TryParse([string]$_.updated,[ref]$d)) { $d } else { [datetime]::MinValue }
        };Descending=$true})) {
            $haystack = ("{0} {1} {2}" -f [string]$record.id,[string]$record.purpose,[string]$record.tags)
            if (-not [string]::IsNullOrWhiteSpace($query) -and
                $haystack.IndexOf($query,[System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                continue
            }

            $item = New-Object System.Windows.Forms.ListViewItem([string]$record.id)
            [void]$item.SubItems.Add([string]$record.purpose)
            [void]$item.SubItems.Add((Format-PromptDate ([string]$record.updated)))
            $item.Tag = [string]$record.id
            [void]$script:PromptList.Items.Add($item)
        }

        $target = $SelectId
        if ([string]::IsNullOrWhiteSpace($target)) { $target = $script:PromptCurrentId }
        $selectedItem = $null
        foreach ($item in $script:PromptList.Items) {
            if (-not [string]::IsNullOrWhiteSpace($target) -and
                [string]::Equals([string]$item.Tag,$target,[System.StringComparison]::OrdinalIgnoreCase)) {
                $selectedItem = $item
                break
            }
        }
        if ($null -eq $selectedItem -and $script:PromptList.Items.Count -gt 0) {
            $selectedItem = $script:PromptList.Items[0]
        }
        if ($null -ne $selectedItem) {
            $selectedItem.Selected = $true
            $selectedItem.Focused = $true
            $selectedItem.EnsureVisible()
        }
    }
    finally {
        $script:PromptSuppressSelection = $false
    }

    if (-not $SkipEditorLoad -and $script:PromptList.SelectedItems.Count -gt 0) {
        Load-PromptIntoEditor ([string]$script:PromptList.SelectedItems[0].Tag)
    }

    if ($null -ne $script:PromptCountLabel) {
        $script:PromptCountLabel.Text = ("Prompts: {0} | Stored locally | {1}" -f $script:PromptRecords.Count,$PromptLibraryDir)
    }
}

function Get-PromptAutomaticIdentifier([string]$Purpose) {
    $normal = [string]$Purpose
    if (-not [string]::IsNullOrWhiteSpace($normal)) {
        $normal = $normal.Normalize([System.Text.NormalizationForm]::FormD)
        $normal = [regex]::Replace($normal,'\p{Mn}','')
    }
    $baseId = ([regex]::Replace($normal,'[^A-Za-z0-9]+','_')).Trim('_').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($baseId)) { $baseId = 'PROMPT' }
    if ($baseId.Length -gt 48) { $baseId = $baseId.Substring(0,48).Trim('_') }
    $records = @(Read-PromptIndex)
    $candidate = $baseId
    $n = 2
    while (@($records | Where-Object {
        [string]::Equals([string]$_.id,$candidate,[System.StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0) {
        $candidate = '{0}_{1:000}' -f $baseId,$n
        $n++
    }
    return $candidate
}

function Save-CurrentPrompt(
    [switch]$Silent,
    [switch]$SkipRefresh
) {
    if ($null -eq $script:PromptIdBox -or $null -eq $script:PromptBrowser) { return $false }
    if (-not $script:PromptBrowserReady -and -not (Confirm-PromptBrowserReady)) {
        if (-not $Silent) {
            Set-PromptUiStatus ('SAVE BLOCKED — ' + $script:PromptReadyReason + ' Keep editor open; copy unsaved text to OneNote.')
        }
        return $false
    }

    $newId = ([string]$script:PromptIdBox.Text).Trim()
    if ([string]::IsNullOrWhiteSpace($newId)) {
        $newId = Get-PromptAutomaticIdentifier ([string]$script:PromptPurposeBox.Text)
        $script:PromptSuppressEvents = $true
        try { $script:PromptIdBox.Text = $newId }
        finally { $script:PromptSuppressEvents = $false }
    }
    if ($newId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show(
                'Identifier is required and may contain letters, numbers, dot, underscore and dash only.',
                'AI Prompt'
            ) | Out-Null
        }
        return $false
    }

    $records = @(Read-PromptIndex)
    $oldId = [string]$script:PromptCurrentId
    $existing = $null
    foreach ($r in $records) {
        if (-not [string]::IsNullOrWhiteSpace($oldId) -and
            [string]::Equals([string]$r.id,$oldId,[System.StringComparison]::OrdinalIgnoreCase)) {
            $existing = $r
            break
        }
    }

    foreach ($r in $records) {
        if ([string]::Equals([string]$r.id,$newId,[System.StringComparison]::OrdinalIgnoreCase) -and
            ($null -eq $existing -or $r -ne $existing)) {
            if (-not $Silent) {
                [System.Windows.Forms.MessageBox]::Show(
                    "A prompt with Identifier '$newId' already exists.",
                    'AI Prompt'
                ) | Out-Null
            }
            return $false
        }
    }

    $now = (Get-Date).ToString('o')
    $newFileName = Get-PromptSafeFileName $newId
    $newPath = Join-Path $PromptLibraryDir $newFileName
    New-Item -ItemType Directory -Force -Path $PromptLibraryDir | Out-Null
    $stagePath = $newPath + '.tmp'
    try {
        $htmlContent = Get-PromptHtmlContent
        [System.IO.File]::WriteAllText($stagePath,$htmlContent,(New-Object System.Text.UTF8Encoding($false)))
        if (-not (Test-Path -LiteralPath $stagePath -PathType Leaf)) {
            throw 'HTML SaveFile did not produce a file.'
        }
        Copy-Item -LiteralPath $stagePath -Destination $newPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $stagePath -PathType Leaf) {
            Remove-Item -LiteralPath $stagePath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($null -eq $existing) {
        $existing = [pscustomobject]@{
            id = $newId
            purpose = ([string]$script:PromptPurposeBox.Text).Trim()
            tags = ([string]$script:PromptTagsBox.Text).Trim()
            file = $newFileName
            created = $now
            updated = $now
        }
        $records += $existing
    }
    else {
        $oldPath = Get-PromptFilePath $existing
        Set-PromptRecordProperty $existing 'id' $newId
        Set-PromptRecordProperty $existing 'purpose' (([string]$script:PromptPurposeBox.Text).Trim())
        Set-PromptRecordProperty $existing 'tags' (([string]$script:PromptTagsBox.Text).Trim())
        Set-PromptRecordProperty $existing 'file' $newFileName
        Set-PromptRecordProperty $existing 'updated' $now
        if (-not [string]::Equals($oldPath,$newPath,[System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $oldPath -PathType Leaf)) {
            # Migration preserves the old .rtf/.md source. Only renamed HTML files are archived.
            if ([System.IO.Path]::GetExtension($oldPath) -ieq '.html') {
                $archiveDir = Join-Path $PromptLibraryDir 'ARCHIVE'
                New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null
                $archiveName = ('{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'),[System.IO.Path]::GetFileName($oldPath))
                Move-Item -LiteralPath $oldPath -Destination (Join-Path $archiveDir $archiveName) -Force
            }
        }
    }

    Write-PromptIndex $records
    $script:PromptCurrentId = $newId
    $script:PromptIsNew = $false
    $script:PromptDirty = $false
    $script:PromptBrowserBaseline = $htmlContent
    $script:PromptUpdatedBox.Text = Format-PromptDate $now
    Set-PromptUiStatus ("SAVED — {0}" -f (Format-PromptDate $now))

    if (-not $SkipRefresh) {
        Refresh-PromptLibrary -SelectId $newId
    }
    return $true
}

function New-Prompt {
    Watch-PromptHtmlChanges
    if ($script:PromptDirty -and -not [string]::IsNullOrWhiteSpace($script:PromptCurrentId)) {
        [void](Save-CurrentPrompt -Silent -SkipRefresh)
    }
    $script:PromptSuppressEvents = $true
    try {
        $script:PromptCurrentId = ''
        $script:PromptIsNew = $true
        $script:PromptDirty = $false
        $script:PromptIdBox.Text = ''
        $script:PromptPurposeBox.Text = ''
        $script:PromptTagsBox.Text = ''
        $script:PromptUpdatedBox.Text = ''
        $intro = '<p>Describe what the AI should do.</p><p>Include the requirements, context and expected result.</p>'
        Set-PromptHtmlDocument (Get-PromptHtmlTemplate $intro)
        Set-PromptUiStatus 'NEW / UNSAVED — enter Purpose, paste content, click Save. Identifier is automatic.'
        $script:PromptIdBox.Focus()
    }
    finally {
        $script:PromptSuppressEvents = $false
    }
}

function Duplicate-Prompt {
    if ($null -eq $script:PromptBrowser) { return }
    $baseId = ([string]$script:PromptIdBox.Text).Trim()
    if ([string]::IsNullOrWhiteSpace($baseId)) { $baseId = 'PROMPT' }
    $candidate = $baseId + '_COPY'
    $n = 2
    $records = @(Read-PromptIndex)
    while (@($records | Where-Object { [string]::Equals([string]$_.id,$candidate,[System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        $candidate = $baseId + '_COPY' + $n
        $n++
    }

    $script:PromptSuppressEvents = $true
    try {
        $script:PromptCurrentId = ''
        $script:PromptIsNew = $true
        $script:PromptIdBox.Text = $candidate
        $script:PromptUpdatedBox.Text = ''
        $script:PromptDirty = $true
        Set-PromptUiStatus 'DUPLICATE / UNSAVED — review it and click Save.'
    }
    finally {
        $script:PromptSuppressEvents = $false
    }
}

function Delete-CurrentPrompt {
    $id = [string]$script:PromptCurrentId
    if ([string]::IsNullOrWhiteSpace($id)) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Archive and remove prompt '$id' from the active library?",
        'Delete AI Prompt',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $records = @(Read-PromptIndex)
    $record = $null
    foreach ($r in $records) {
        if ([string]::Equals([string]$r.id,$id,[System.StringComparison]::OrdinalIgnoreCase)) {
            $record = $r
            break
        }
    }

    if ($null -ne $record) {
        $path = Get-PromptFilePath $record
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $archive = Join-Path $PromptLibraryDir 'ARCHIVE'
            New-Item -ItemType Directory -Force -Path $archive | Out-Null
            $dest = Join-Path $archive (("{0}_{1}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'),[System.IO.Path]::GetFileName($path)))
            Move-Item -LiteralPath $path -Destination $dest -Force
        }
    }

    $remaining = @($records | Where-Object {
        -not [string]::Equals([string]$_.id,$id,[System.StringComparison]::OrdinalIgnoreCase)
    })
    Write-PromptIndex $remaining
    $script:PromptCurrentId = ''
    $script:PromptDirty = $false
    $script:PromptIsNew = $false
    Refresh-PromptLibrary
    Set-PromptUiStatus "DELETED FROM ACTIVE LIBRARY — archived copy retained."
}

function Convert-PromptHtmlFragmentToRichText([string]$Html) {
    if ([string]::IsNullOrWhiteSpace($Html) -or $null -eq $script:PromptEditor) { return $false }
    # Browser clipboard's HTML Format has optional StartFragment/EndFragment markers.
    $fragmentMatch = [regex]::Match($Html,'(?is)<!--StartFragment-->(.*?)<!--EndFragment-->')
    if ($fragmentMatch.Success) { $Html = $fragmentMatch.Groups[1].Value }
    elseif ($Html -match '(?is)<body[^>]*>(.*?)</body>') { $Html = $matches[1] }
    $Html = [regex]::Replace($Html,'(?is)<(script|style)[^>]*>.*?</\1>','')

    $box = $script:PromptEditor
    $baseFont = New-Object System.Drawing.Font('Segoe UI',10)
    $boldLevel = 0; $italicLevel = 0; $underlineLevel = 0
    $headingLevel = 0
    $colourStack = New-Object System.Collections.Generic.Stack[System.Drawing.Color]
    $currentColour = $box.ForeColor
    $listDepth = 0

    foreach ($tokenMatch in [regex]::Matches($Html,'(?s)<[^>]+>|[^<]+')) {
        $token = $tokenMatch.Value
        if ($token.StartsWith('<')) {
            if ($token -match '^</?\s*(?:br|hr)\b') {
                $box.SelectedText = "`r`n"
                continue
            }
            if ($token -match '^<\s*(p|div|h[1-6]|li)\b') {
                if ($box.SelectionStart -gt 0 -and -not $box.Text.EndsWith("`n")) { $box.SelectedText = "`r`n" }
                if ($matches[1] -eq 'li') { $box.SelectedText = '• ' }
            }
            if ($token -match '^</\s*(p|div|h[1-6]|li|ul|ol)\b') {
                if ($box.SelectionStart -gt 0 -and -not $box.Text.EndsWith("`n")) { $box.SelectedText = "`r`n" }
            }
            if ($token -match '^<\s*(b|strong)\b') { $boldLevel++; continue }
            if ($token -match '^</\s*(b|strong)\b') { $boldLevel=[Math]::Max(0,$boldLevel-1); continue }
            if ($token -match '^<\s*(i|em)\b') { $italicLevel++; continue }
            if ($token -match '^</\s*(i|em)\b') { $italicLevel=[Math]::Max(0,$italicLevel-1); continue }
            if ($token -match '^<\s*u\b') { $underlineLevel++; continue }
            if ($token -match '^</\s*u\b') { $underlineLevel=[Math]::Max(0,$underlineLevel-1); continue }
            if ($token -match '^<\s*h([1-6])\b') { $headingLevel=[int]$matches[1]; continue }
            if ($token -match '^</\s*h[1-6]\b') { $headingLevel=0; continue }
            if ($token -match '^<\s*(span|font)\b') {
                $colourStack.Push($currentColour)
                $hexMatch = [regex]::Match($token,'#[0-9A-Fa-f]{6}')
                if ($hexMatch.Success) {
                    try { $currentColour = [System.Drawing.ColorTranslator]::FromHtml($hexMatch.Value) } catch {}
                }
                continue
            }
            if ($token -match '^</\s*(span|font)\b') {
                if ($colourStack.Count -gt 0) { $currentColour = $colourStack.Pop() }
                continue
            }
            continue
        }
        $value = [System.Net.WebUtility]::HtmlDecode($token)
        if ([string]::IsNullOrEmpty($value)) { continue }
        $value = [regex]::Replace($value,'[\r\n\t]+',' ')
        $style = [System.Drawing.FontStyle]::Regular
        if ($boldLevel -gt 0 -or $headingLevel -gt 0) { $style = $style -bor [System.Drawing.FontStyle]::Bold }
        if ($italicLevel -gt 0) { $style = $style -bor [System.Drawing.FontStyle]::Italic }
        if ($underlineLevel -gt 0) { $style = $style -bor [System.Drawing.FontStyle]::Underline }
        $size = if ($headingLevel -gt 0) { [single][Math]::Max(11,20-(2*$headingLevel)) } else { [single]10 }
        $box.SelectionFont = New-Object System.Drawing.Font('Segoe UI',$size,$style)
        $box.SelectionColor = $currentColour
        $box.SelectedText = $value
    }
    return $true
}

# ---------- HTML PROMPT EDITOR ----------
# Windows MSHTML WebBrowser is used as an editable HTML surface. This preserves
# Word/OneNote HTML clipboard lists, styled spans, headings, indents and colours
# better than the old hand-written HTML-to-RTF token parser.
# No network navigation is needed; prompts are local HTML documents only.
function Get-PromptHtmlTemplate([string]$Body) {
    if ($null -eq $Body) { $Body = '' }
    return ('<!DOCTYPE html><html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8">' +
        '<style>body{font-family:Segoe UI,Calibri,Arial,sans-serif;font-size:11pt;margin:12px;' +
        'color:#151515;background:white}p{margin:0 0 0.55em 0}ol,ul{padding-left:1.6em}</style>' +
        '</head><body contenteditable="true">' + $Body + '</body></html>')
}

function Remove-PromptActiveHtml([string]$Html) {
    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }
    $safe = $Html
    # Protect the local editor against active content in pasted/stored HTML.
    $safe = [regex]::Replace($safe,'(?is)<\s*(script|iframe|object|embed|form|base|meta)[^>]*>.*?<\s*/\s*\1\s*>','')
    $safe = [regex]::Replace($safe,'(?is)<\s*(script|iframe|object|embed|form|base)[^>]*?/?>','')
    $safe = [regex]::Replace($safe,'(?i)\s+on[a-z]+\s*=\s*(?:"[^"]*"|''[^'']*''|[^\s>]+)','')
    $safe = [regex]::Replace($safe,'(?i)\bjavascript\s*:','blocked:')
    $safe = [regex]::Replace($safe,'(?i)expression\s*\x28','blocked-')
    return $safe
}

function Set-PromptHtmlDocument([string]$Html) {
    if ($null -eq $script:PromptBrowser) { return }
    $script:PromptBrowserReady = $false
    $script:PromptBrowserBaseline = ''
    $script:PromptReadyReason = 'Waiting for the editor document to load.'
    $script:PromptLoadToken = [guid]::NewGuid().ToString('N')
    $script:PromptOriginalBodyId = ''
    if ([string]::IsNullOrWhiteSpace($Html)) {
        $Html = Get-PromptHtmlTemplate ''
    }
    elseif ($Html -notmatch '(?is)<html\b') {
        $Html = Get-PromptHtmlTemplate $Html
    }
    $sanitised = Remove-PromptActiveHtml $Html
    # Remove legacy v1.0.56 custom load attributes. Some versions of MSHTML
    # discard data-* attributes, which left Save blocked even when text was visible.
    $sanitised = [regex]::Replace($sanitised,
        '(?i)\s+data-aom-load-token\s*=\s*(?:"[^"]*"|''[^'']*''|[^\s>]+)','')
    $bodyMatch = [regex]::Match($sanitised,'(?is)<body\b[^>]*>')
    if (-not $bodyMatch.Success) {
        throw 'Prompt HTML has no BODY element. Loading cancelled to protect saved content.'
    }

    $opening = [string]$bodyMatch.Value
    $oldIdMatch = [regex]::Match($opening,
        '(?i)\s+id\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>]+))')
    if ($oldIdMatch.Success) {
        foreach ($g in @(1,2,3)) {
            if ($oldIdMatch.Groups[$g].Success) {
                $script:PromptOriginalBodyId = [string]$oldIdMatch.Groups[$g].Value
                break
            }
        }
        $opening = $opening.Remove($oldIdMatch.Index,$oldIdMatch.Length)
    }
    # BODY.id is a first-class, durable DOM property. Unlike data-* custom
    # attributes, it is recognised by the legacy Windows WebBrowser control.
    $marker = 'aom-prompt-' + $script:PromptLoadToken
    $opening = [regex]::Replace($opening,'(?i)^<body\b',('<body id="' + $marker + '"'),1)
    $script:PromptPendingHtml = $sanitised.Substring(0,$bodyMatch.Index) +
        $opening + $sanitised.Substring($bodyMatch.Index + $bodyMatch.Length)
    Set-PromptUiStatus 'LOADING — opening selected prompt content.'
    $script:PromptBrowser.DocumentText = $script:PromptPendingHtml
}

function Confirm-PromptBrowserReady {
    if ($null -eq $script:PromptBrowser) {
        $script:PromptReadyReason = 'The editor control is missing.'
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($script:PromptLoadToken)) {
        $script:PromptReadyReason = 'No prompt document has been selected.'
        return $false
    }
    try {
        $doc = $script:PromptBrowser.Document
        if ($null -eq $doc -or $null -eq $doc.Body) {
            $script:PromptReadyReason = 'The HTML document or its BODY is unavailable.'
            return $false
        }
        $marker = 'aom-prompt-' + $script:PromptLoadToken
        $actualId = [string]$doc.Body.Id
        if (-not [string]::Equals($actualId,$marker,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            # GetElementById is the alternate standard MSHTML identity check.
            $element = $doc.GetElementById($marker)
            if ($null -eq $element -or
                -not [object]::ReferenceEquals($element.DomElement,$doc.Body.DomElement)) {
                # BODY.Id is the primary check, and GetElementById handles
                # unusual legacy DOM implementations. Never accept a stale
                # document belonging to a previously selected prompt.
                $script:PromptReadyReason = 'Document identity mismatch (loaded: ' + $actualId + ').'
                return $false
            }
        }

        $doc.Body.SetAttribute('contentEditable','true')
        try { $doc.DomDocument.designMode = 'On' } catch {}
        $script:PromptBrowserReady = $true
        if ([string]::IsNullOrWhiteSpace([string]$script:PromptBrowserBaseline)) {
            try { $script:PromptBrowserBaseline = Get-PromptHtmlContent }
            catch {
                $script:PromptBrowserReady = $false
                $script:PromptReadyReason = 'Could not read the full HTML document: ' + $_.Exception.Message
                return $false
            }
        }
        $script:PromptReadyReason = ''
        if (-not $script:PromptDirty) {
            Set-PromptUiStatus 'READY — content is loaded. Save is available.'
        }
        return $true
    }
    catch {
        $script:PromptReadyReason = 'DOM readiness check failed: ' + $_.Exception.Message
        return $false
    }
}

function Get-PromptHtmlContent {
    if ($null -eq $script:PromptBrowser -or -not $script:PromptBrowserReady) {
        throw 'Prompt editor is still loading. Try again after the content appears.'
    }
    $doc = $script:PromptBrowser.Document
    if ($null -eq $doc -or $null -eq $doc.Body) { throw 'HTML prompt editor is not ready.' }
    $nodes = $doc.GetElementsByTagName('html')
    $html = ''
    if ($null -ne $nodes -and $nodes.Count -ge 1) {
        $html = [string]$nodes[0].OuterHtml
    }
    if ([string]::IsNullOrWhiteSpace($html)) {
        try { $html = [string]$doc.DomDocument.documentElement.outerHTML } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($html)) {
        # Never silently save body-only content; its linked styles could be lost.
        throw 'HTML root element is not accessible yet; cannot save without preserving formatting.'
    }
    # Remove internal BODY identity from persisted prompts, and reinstate the
    # original BODY id if the imported HTML had one. Preserves CSS selectors.
    $bodyOpen = [regex]::Match($html,'(?is)<body\b[^>]*>')
    if ($bodyOpen.Success) {
        $opening = [string]$bodyOpen.Value
        # BODY id belongs to the temporary editor load marker here.
        $opening = [regex]::Replace($opening,
            '(?i)\s+id\s*=\s*(?:"[^"]*"|''[^'']*''|[^\s>]+)','')
        if (-not [string]::IsNullOrWhiteSpace($script:PromptOriginalBodyId)) {
            $safeOldId = [System.Net.WebUtility]::HtmlEncode($script:PromptOriginalBodyId)
            $opening = [regex]::Replace($opening,'(?i)^<body\b',('<body id="' + $safeOldId + '"'),1)
        }
        $html = $html.Substring(0,$bodyOpen.Index) + $opening +
            $html.Substring($bodyOpen.Index + $bodyOpen.Length)
    }
    $html = [regex]::Replace($html,
        '(?i)\s+data-aom-load-token\s*=\s*(?:"[^"]*"|''[^'']*''|[^\s>]+)','')
    return (Remove-PromptActiveHtml $html)
}

function Get-PromptHtmlFragment {
    if ($null -eq $script:PromptBrowser -or -not $script:PromptBrowserReady) { return '' }
    $doc = $script:PromptBrowser.Document
    if ($null -eq $doc -or $null -eq $doc.Body) { return '' }
    return (Remove-PromptActiveHtml ([string]$doc.Body.InnerHtml))
}

function Get-PromptPlainText {
    if ($null -eq $script:PromptBrowser -or -not $script:PromptBrowserReady) { return '' }
    $doc = $script:PromptBrowser.Document
    if ($null -eq $doc -or $null -eq $doc.Body) { return '' }
    return [string]$doc.Body.InnerText
}

function Get-PromptHtmlFromLegacyRecord([string]$Path) {
    if ([System.IO.Path]::GetExtension($Path) -ieq '.html' -or
        [System.IO.Path]::GetExtension($Path) -ieq '.htm') {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop)
    }
    if ([System.IO.Path]::GetExtension($Path) -ieq '.rtf') {
        # Read-only legacy migration into HTML. Do not overwrite the source RTF.
        $script:PromptEditor.LoadFile($Path,[System.Windows.Forms.RichTextBoxStreamType]::RichText)
    }
    else {
        $legacy = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        Convert-LegacyPromptMarkdownToRichText $legacy
    }
    $fragment = Convert-PromptRichTextToHtml
    return (Get-PromptHtmlTemplate $fragment)
}

function Watch-PromptHtmlChanges {
    if (-not $script:PromptBrowserReady) { [void](Confirm-PromptBrowserReady) }
    if ($script:PromptSuppressEvents -or -not $script:PromptBrowserReady -or
        $null -eq $script:PromptBrowser) { return }
    try {
        $current = Get-PromptHtmlContent
        if ($current -ne $script:PromptBrowserBaseline) {
            # Only report edits; never change the currently stored HTML on a read.
            if (-not $script:PromptDirty) { Mark-PromptDirty }
        }
    }
    catch {}
}


function Convert-PromptRichTextToHtml {
    # Generate HTML in addition to RTF so web-based AI chats can keep the styling
    # when they accept a rich HTML clipboard/drop payload.
    if ($null -eq $script:PromptEditor) { return '' }
    $box = $script:PromptEditor
    $text = [string]$box.Text
    $oldStart = $box.SelectionStart
    $oldLength = $box.SelectionLength
    $sb = New-Object System.Text.StringBuilder
    try {
        [void]$sb.Append('<div style="font-family:Segoe UI,Arial,sans-serif;white-space:pre-wrap">')
        $lastStyle = ''
        for ($i=0;$i -lt $text.Length;$i++) {
            $c = $text[$i]
            if ($c -eq "`r") { continue }
            if ($c -eq "`n") {
                if ($lastStyle.Length -gt 0) { [void]$sb.Append('</span>'); $lastStyle='' }
                [void]$sb.Append('<br>')
                continue
            }
            $box.Select($i,1)
            $font = $box.SelectionFont
            if ($null -eq $font) { $font = $box.Font }
            $color = $box.SelectionColor
            $css = 'font-weight:{0};font-style:{1};text-decoration:{2};font-size:{3}pt;color:#{4:X2}{5:X2}{6:X2};' -f (
                $(if ($font.Bold) {'bold'} else {'normal'}),
                $(if ($font.Italic) {'italic'} else {'normal'}),
                $(if ($font.Underline) {'underline'} else {'none'}),
                [Math]::Round($font.SizeInPoints,1),$color.R,$color.G,$color.B)
            if ($css -ne $lastStyle) {
                if ($lastStyle.Length -gt 0) { [void]$sb.Append('</span>') }
                [void]$sb.Append('<span style="'); [void]$sb.Append($css); [void]$sb.Append('">')
                $lastStyle = $css
            }
            [void]$sb.Append([System.Net.WebUtility]::HtmlEncode([string]$c))
        }
        if ($lastStyle.Length -gt 0) { [void]$sb.Append('</span>') }
        [void]$sb.Append('</div>')
        return $sb.ToString()
    }
    finally { $box.Select($oldStart,$oldLength) }
}

function New-PromptClipboardHtml([string]$Fragment) {
    $doc = '<html><body><!--StartFragment-->' + $Fragment + '<!--EndFragment--></body></html>'
    $head = "Version:1.0`r`nStartHTML:0000000000`r`nEndHTML:0000000000`r`nStartFragment:0000000000`r`nEndFragment:0000000000`r`n"
    $startHtml = [System.Text.Encoding]::UTF8.GetByteCount($head)
    $startFragment = $startHtml + [System.Text.Encoding]::UTF8.GetByteCount('<html><body><!--StartFragment-->')
    $endFragment = $startFragment + [System.Text.Encoding]::UTF8.GetByteCount($Fragment)
    $endHtml = $startHtml + [System.Text.Encoding]::UTF8.GetByteCount($doc)
    return ('Version:1.0' + "`r`n" +
        ('StartHTML:{0:D10}' -f $startHtml) + "`r`n" +
        ('EndHTML:{0:D10}' -f $endHtml) + "`r`n" +
        ('StartFragment:{0:D10}' -f $startFragment) + "`r`n" +
        ('EndFragment:{0:D10}' -f $endFragment) + "`r`n" + $doc)
}

function New-PromptTransferData {
    if ($null -eq $script:PromptBrowser -or -not $script:PromptBrowserReady) { return $null }
    $plain = Get-PromptPlainText
    $fragment = Get-PromptHtmlFragment
    if ([string]::IsNullOrWhiteSpace($plain) -and [string]::IsNullOrWhiteSpace($fragment)) { return $null }
    $data = New-Object System.Windows.Forms.DataObject
    $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText,$plain)
    $data.SetData([System.Windows.Forms.DataFormats]::Text,$plain)
    if (-not [string]::IsNullOrWhiteSpace($fragment)) {
        $data.SetData([System.Windows.Forms.DataFormats]::Html,(New-PromptClipboardHtml $fragment))
    }
    return $data
}


function Copy-CurrentPrompt {
    try {
        $data = New-PromptTransferData
        if ($null -eq $data) { return }
        [System.Windows.Forms.Clipboard]::SetDataObject($data,$true)
        Set-PromptUiStatus 'COPIED — HTML formatted prompt + plain text on clipboard.'
    }
    catch { Set-PromptUiStatus ('COPY FAILED — ' + $_.Exception.Message) }
}

function Start-PromptTextDrag($Control) {
    $data = New-PromptTransferData
    if ($null -eq $data -or $null -eq $Control) { return }
    [void]$Control.DoDragDrop($data,[System.Windows.Forms.DragDropEffects]::Copy)
}


# ---------- DAY / NIGHT THEME ----------
$script:ThemeStatePath = Join-Path $StateDir 'theme.txt'
$script:ThemeMode = 'DAY'
if (Test-Path -LiteralPath $script:ThemeStatePath) {
    try {
        $saved=(Get-Content -LiteralPath $script:ThemeStatePath -Raw).Trim().ToUpperInvariant()
        if($saved -eq 'NIGHT'){$script:ThemeMode='NIGHT'}
    } catch {}
}
function Set-ThemeRecursive([System.Windows.Forms.Control]$c,[string]$mode){
    if($null -eq $c){return}
    $night=($mode -eq 'NIGHT')
    $bg=if($night){[System.Drawing.Color]::FromArgb(24,24,24)}else{[System.Drawing.SystemColors]::Control}
    $panel=if($night){[System.Drawing.Color]::FromArgb(30,30,30)}else{[System.Drawing.SystemColors]::Control}
    $input=if($night){[System.Drawing.Color]::FromArgb(16,16,16)}else{[System.Drawing.SystemColors]::Window}
    $fg=if($night){[System.Drawing.Color]::FromArgb(238,238,238)}else{[System.Drawing.SystemColors]::ControlText}
    if($c -is [System.Windows.Forms.TextBox] -or $c -is [System.Windows.Forms.RichTextBox] -or $c -is [System.Windows.Forms.ListBox] -or $c -is [System.Windows.Forms.ListView] -or $c -is [System.Windows.Forms.ComboBox]){
        $c.BackColor=$input; $c.ForeColor=$fg
    } elseif($c -is [System.Windows.Forms.TabControl]) {
        $c.BackColor=$panel; $c.ForeColor=$fg
    } elseif($c -is [System.Windows.Forms.CheckBox] -or $c -is [System.Windows.Forms.Label]) {
        $c.BackColor=$panel; $c.ForeColor=$fg
    } elseif($c -is [System.Windows.Forms.Button]){
        $c.UseVisualStyleBackColor=$false; $c.BackColor=if($night){[System.Drawing.Color]::FromArgb(52,52,52)}else{[System.Drawing.SystemColors]::Control}; $c.ForeColor=$fg
    } elseif($c -is [System.Windows.Forms.Form]){
        $c.BackColor=$bg; $c.ForeColor=$fg
    } else {$c.BackColor=$panel; $c.ForeColor=$fg}
    foreach($child in $c.Controls){Set-ThemeRecursive $child $mode}
}
function Apply-Theme([string]$mode){
    if($mode -ne 'NIGHT'){$mode='DAY'}
    $script:ThemeMode=$mode
    Set-ThemeRecursive $form $mode
    # Base log colours only. PASS/WARN/FAIL line colours remain controlled by the existing colour renderer.
    foreach($box in @($script:OperationOutput,$script:DrOutput)){
        if($null -ne $box){
            if($mode -eq 'NIGHT'){$box.BackColor=[System.Drawing.Color]::FromArgb(10,10,10);$box.ForeColor=[System.Drawing.Color]::FromArgb(235,235,235)}
            else{$box.BackColor=[System.Drawing.SystemColors]::Window;$box.ForeColor=[System.Drawing.SystemColors]::WindowText}
        }
    }
    if($null -ne $script:ThemeButton){$script:ThemeButton.Text=if($mode -eq 'NIGHT'){'DAY MODE'}else{'NIGHT MODE'}}
    try{Set-Content -LiteralPath $script:ThemeStatePath -Value $mode -Encoding ASCII}catch{}
    Refresh-ExecutionVisuals
    Refresh-InstalledStatusStrip
    $form.Refresh()
}
function Toggle-Theme {if($script:ThemeMode -eq 'NIGHT'){Apply-Theme 'DAY'}else{Apply-Theme 'NIGHT'}}


# Optional UI references used by responsive layout.
# Explicit initialization avoids Set-StrictMode failures before control creation.
$script:OpenLogsBtn = $null
$script:RefreshLogsBtn = $null
$script:DrOpenLogsBtn = $null
$script:DrRefreshLogsBtn = $null
$script:PromptList = $null
$script:PromptSearchBox = $null
$script:PromptIdBox = $null
$script:PromptPurposeBox = $null
$script:PromptTagsBox = $null
$script:PromptUpdatedBox = $null
$script:PromptEditor = $null # Hidden legacy RTF import helper; HTML is edited in PromptBrowser.
$script:PromptBrowser = $null
$script:PromptBrowserReady = $false
$script:PromptLoadToken = ''
$script:PromptOriginalBodyId = ''
$script:PromptReadyReason = ''
$script:PromptBrowserBaseline = ''
$script:PromptPendingHtml = ''
$script:PromptBrowserPollTimer = $null
$script:PromptStatusLabel = $null
$script:PromptCountLabel = $null

# ---------- UI ----------
$script:Config = Load-Config
Apply-StorageConfig
$form = New-Object System.Windows.Forms.Form
$form.Text = "AI Dev Toolkit v1.0.57"
$form.Size = [System.Drawing.Size]::new(1220, 920)
$form.MinimumSize = [System.Drawing.Size]::new(980, 720)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI',9)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'AI Dev Toolkit'
$title.Font = New-Object System.Drawing.Font('Segoe UI',18,[System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = [System.Drawing.Point]::new(18,15)
$form.Controls.Add($title)

$appLbl = New-Object System.Windows.Forms.Label
$appLbl.Text = 'TARGET APPLICATION'
$appLbl.AutoSize = $true
$appLbl.Location = [System.Drawing.Point]::new(575,26)
$form.Controls.Add($appLbl)

$script:AppCombo = New-Object System.Windows.Forms.ComboBox
$script:AppCombo.DropDownStyle = 'DropDownList'
$script:AppCombo.Location = [System.Drawing.Point]::new(725,21)
$script:AppCombo.Size = [System.Drawing.Size]::new(270,27)
$script:AppCombo.Anchor = 'Top,Left'
$form.Controls.Add($script:AppCombo)

$script:ThemeButton = New-Object System.Windows.Forms.Button
$script:ThemeButton.Text = 'NIGHT MODE'
$script:ThemeButton.Location = [System.Drawing.Point]::new(1010,20)
$script:ThemeButton.Size = [System.Drawing.Size]::new(165,30)
$script:ThemeButton.Anchor = 'Top,Left'
$script:ThemeButton.Add_Click({ Toggle-Theme })
$form.Controls.Add($script:ThemeButton)


$script:MultipleRunsCheck = New-Object System.Windows.Forms.CheckBox
$script:MultipleRunsCheck.Text = 'ALLOW MULTIPLE RUNS'
$script:MultipleRunsCheck.AutoSize = $true
$script:MultipleRunsCheck.Location = [System.Drawing.Point]::new(18,62)
$script:MultipleRunsCheck.Anchor = 'Top,Left'
$form.Controls.Add($script:MultipleRunsCheck)

$script:InstalledStatusLabel = New-Object System.Windows.Forms.Label
$script:InstalledStatusLabel.Text = 'INSTALLED: UNKNOWN — no successful APPLY recorded by AOM'
$script:InstalledStatusLabel.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$script:InstalledStatusLabel.Location = [System.Drawing.Point]::new(220,61)
$script:InstalledStatusLabel.Size = [System.Drawing.Size]::new(650,24)
$script:InstalledStatusLabel.AutoEllipsis = $true
$form.Controls.Add($script:InstalledStatusLabel)

$script:LastApplyWarningLabel = New-Object System.Windows.Forms.Label
$script:LastApplyWarningLabel.Text = ''
$script:LastApplyWarningLabel.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$script:LastApplyWarningLabel.Location = [System.Drawing.Point]::new(875,61)
$script:LastApplyWarningLabel.Size = [System.Drawing.Size]::new(320,24)
$script:LastApplyWarningLabel.TextAlign = 'MiddleRight'
$script:LastApplyWarningLabel.AutoEllipsis = $true
$script:LastApplyWarningLabel.Visible = $false
$form.Controls.Add($script:LastApplyWarningLabel)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = [System.Drawing.Point]::new(15,90)
$tabs.Size = [System.Drawing.Size]::new(1175,790)
$tabs.Anchor = 'Top,Left'
$form.Controls.Add($tabs)

# Operations tab
$opTab = New-Object System.Windows.Forms.TabPage
$opTab.Text = 'Operations'
$opTab.AutoScroll = $true
$opTab.AutoScrollMinSize = [System.Drawing.Size]::new(1120,1040)
$tabs.TabPages.Add($opTab)

$pkgLabel = New-Object System.Windows.Forms.Label
$pkgLabel.Text = 'SELECTED SCRIPT PACKAGE'
$pkgLabel.Location = [System.Drawing.Point]::new(18,18)
$pkgLabel.AutoSize = $true
$opTab.Controls.Add($pkgLabel)

$script:PackageCombo = New-Object System.Windows.Forms.ComboBox
$script:PackageCombo.DropDownStyle = 'DropDownList'
$script:PackageCombo.Location = [System.Drawing.Point]::new(18,42)
$script:PackageCombo.Size = [System.Drawing.Size]::new(720,27)
$script:PackageCombo.Anchor = 'Top,Left,Right'
$opTab.Controls.Add($script:PackageCombo)

$script:RefreshPackagesBtn = New-Object System.Windows.Forms.Button
$script:RefreshPackagesBtn.Text = 'Refresh'
$script:RefreshPackagesBtn.Location = [System.Drawing.Point]::new(750,40)
$script:RefreshPackagesBtn.Size = [System.Drawing.Size]::new(120,30)
$script:RefreshPackagesBtn.Anchor = 'Top,Right'
$opTab.Controls.Add($script:RefreshPackagesBtn)

$script:BrowsePackageBtn = New-Object System.Windows.Forms.Button
$script:BrowsePackageBtn.Text = 'Browse...'
$script:BrowsePackageBtn.Location = [System.Drawing.Point]::new(880,40)
$script:BrowsePackageBtn.Size = [System.Drawing.Size]::new(120,30)
$script:BrowsePackageBtn.Anchor = 'Top,Right'
$opTab.Controls.Add($script:BrowsePackageBtn)

$script:ArchivePackageBtn = New-Object System.Windows.Forms.Button
$script:ArchivePackageBtn.Text = 'ARCHIVE ZIP'
$script:ArchivePackageBtn.Location = [System.Drawing.Point]::new(1010,40)
$script:ArchivePackageBtn.Size = [System.Drawing.Size]::new(120,30)
$script:ArchivePackageBtn.Anchor = 'Top,Right'
$opTab.Controls.Add($script:ArchivePackageBtn)

$script:PackageVersionLabel = New-Object System.Windows.Forms.Label
$script:PackageVersionLabel.Text = 'VERSION: —'
$script:PackageVersionLabel.Font = New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Bold)
$script:PackageVersionLabel.Location = [System.Drawing.Point]::new(18,80)
$script:PackageVersionLabel.Size = [System.Drawing.Size]::new(240,32)
$script:PackageVersionLabel.TextAlign = 'MiddleLeft'
$opTab.Controls.Add($script:PackageVersionLabel)

$script:PackageExecutionLabel = New-Object System.Windows.Forms.Label
$script:PackageExecutionLabel.Text = 'NOT EXECUTED'
$script:PackageExecutionLabel.Font = New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Bold)
$script:PackageExecutionLabel.Location = [System.Drawing.Point]::new(235,80)
$script:PackageExecutionLabel.Size = [System.Drawing.Size]::new(700,32)
$script:PackageExecutionLabel.TextAlign = 'MiddleLeft'
$script:PackageExecutionLabel.AutoEllipsis = $true
$opTab.Controls.Add($script:PackageExecutionLabel)

$script:PackageInfoBox = New-Object System.Windows.Forms.TextBox
$script:PackageInfoBox.Multiline = $true
$script:PackageInfoBox.ReadOnly = $true
$script:PackageInfoBox.ScrollBars = 'Vertical'
$script:PackageInfoBox.Location = [System.Drawing.Point]::new(18,80)
$script:PackageInfoBox.Size = [System.Drawing.Size]::new(520,155)
$script:PackageInfoBox.Anchor = 'Top,Left'
$opTab.Controls.Add($script:PackageInfoBox)

$quickScriptsTitle = New-Object System.Windows.Forms.Label
$quickScriptsTitle.Text = 'QUICK SCRIPT BUTTONS - one click runs the exact script'
$quickScriptsTitle.Location = [System.Drawing.Point]::new(555,80)
$quickScriptsTitle.AutoSize = $true
$opTab.Controls.Add($quickScriptsTitle)

$script:QuickScriptsPanel = New-Object System.Windows.Forms.Panel
$script:QuickScriptsPanel.Location = [System.Drawing.Point]::new(555,104)
$script:QuickScriptsPanel.Size = [System.Drawing.Size]::new(543,131)
$script:QuickScriptsPanel.Anchor = 'Top,Left'
$script:QuickScriptsPanel.AutoScroll = $true
$script:QuickScriptsPanel.BorderStyle = 'FixedSingle'
$opTab.Controls.Add($script:QuickScriptsPanel)




# Exact script names resolved from the selected package.
$script:ApplyScriptLabel = New-Object System.Windows.Forms.Label
$script:ApplyScriptLabel.Text = 'Not available'
$script:ApplyScriptLabel.Location = [System.Drawing.Point]::new(18,458)
$script:ApplyScriptLabel.Size = [System.Drawing.Size]::new(190,18)
$script:ApplyScriptLabel.TextAlign = 'MiddleCenter'
$script:ApplyScriptLabel.Visible = $false

$script:VerifyScriptLabel = New-Object System.Windows.Forms.Label
$script:VerifyScriptLabel.Text = 'Not available'
$script:VerifyScriptLabel.Location = [System.Drawing.Point]::new(218,458)
$script:VerifyScriptLabel.Size = [System.Drawing.Size]::new(190,18)
$script:VerifyScriptLabel.TextAlign = 'MiddleCenter'
$script:VerifyScriptLabel.Visible = $false

$script:RollbackScriptLabel = New-Object System.Windows.Forms.Label
$script:RollbackScriptLabel.Text = 'Not available'
$script:RollbackScriptLabel.Location = [System.Drawing.Point]::new(418,458)
$script:RollbackScriptLabel.Size = [System.Drawing.Size]::new(190,18)
$script:RollbackScriptLabel.TextAlign = 'MiddleCenter'
$script:RollbackScriptLabel.Visible = $false

$script:ContinuityScriptLabel = New-Object System.Windows.Forms.Label
$script:ContinuityScriptLabel.Text = 'Not available'
$script:ContinuityScriptLabel.Location = [System.Drawing.Point]::new(618,458)
$script:ContinuityScriptLabel.Size = [System.Drawing.Size]::new(230,18)
$script:ContinuityScriptLabel.TextAlign = 'MiddleCenter'
$script:ContinuityScriptLabel.Visible = $false

$script:ApplyBtn = New-Object System.Windows.Forms.Button; $script:ApplyBtn.Text='APPLY'; $script:ApplyBtn.Location=[System.Drawing.Point]::new(18,250); $script:ApplyBtn.Size=[System.Drawing.Size]::new(190,36); $script:ApplyBtn.Visible = $false
$script:VerifyBtn = New-Object System.Windows.Forms.Button; $script:VerifyBtn.Text='VERIFY'; $script:VerifyBtn.Location=[System.Drawing.Point]::new(208,250); $script:VerifyBtn.Size=[System.Drawing.Size]::new(190,36); $script:VerifyBtn.Visible = $false
$script:RollbackBtn = New-Object System.Windows.Forms.Button; $script:RollbackBtn.Text='ROLLBACK'; $script:RollbackBtn.Location=[System.Drawing.Point]::new(398,250); $script:RollbackBtn.Size=[System.Drawing.Size]::new(190,36); $script:RollbackBtn.Visible = $false
$script:ContinuityBtn = New-Object System.Windows.Forms.Button; $script:ContinuityBtn.Text='CONTINUITY SNAPSHOT'; $script:ContinuityBtn.Location=[System.Drawing.Point]::new(588,250); $script:ContinuityBtn.Size=[System.Drawing.Size]::new(250,36); $script:ContinuityBtn.Visible = $false
$script:CancelBtn = New-Object System.Windows.Forms.Button; $script:CancelBtn.Text='CANCEL'; $script:CancelBtn.Location=[System.Drawing.Point]::new(848,250); $script:CancelBtn.Size=[System.Drawing.Size]::new(200,36); $script:CancelBtn.Enabled=$false; $opTab.Controls.Add($script:CancelBtn)


$otherScriptsLabel = New-Object System.Windows.Forms.Label
$otherScriptsLabel.Text = 'OTHER PACKAGE SCRIPTS'
$otherScriptsLabel.Location = [System.Drawing.Point]::new(18,530)
$otherScriptsLabel.AutoSize = $true
$otherScriptsLabel.Visible = $false

$script:OtherScriptsCombo = New-Object System.Windows.Forms.ComboBox
$script:OtherScriptsCombo.DropDownStyle = 'DropDownList'
$script:OtherScriptsCombo.Location = [System.Drawing.Point]::new(18,554)
$script:OtherScriptsCombo.Size = [System.Drawing.Size]::new(810,27)
$script:OtherScriptsCombo.Anchor = 'Top,Left,Right'
$script:OtherScriptsCombo.Visible = $false

$otherScriptsHint = New-Object System.Windows.Forms.Label
$otherScriptsHint.Text = 'Scripts not mapped to APPLY / VERIFY / ROLLBACK / CONTINUITY are shown here.'
$otherScriptsHint.Location = [System.Drawing.Point]::new(18,584)
$otherScriptsHint.AutoSize = $true
$otherScriptsHint.Visible = $false

$script:OperationStatus = New-Object System.Windows.Forms.Label
$script:OperationStatus.Text='READY'
$script:OperationStatus.Location=[System.Drawing.Point]::new(18,295)
$script:OperationStatus.Size=[System.Drawing.Size]::new(1080,24)
$opTab.Controls.Add($script:OperationStatus)

$script:CopyOperationLogBtn = New-Object System.Windows.Forms.Button
$script:CopyOperationLogBtn.Text = 'Copy Log'
$script:CopyOperationLogBtn.Location = [System.Drawing.Point]::new(720,295)
$script:CopyOperationLogBtn.Size = [System.Drawing.Size]::new(110,34)
$opTab.Controls.Add($script:CopyOperationLogBtn)

$script:OperationOutput = New-Object System.Windows.Forms.RichTextBox
$script:OperationOutput.ReadOnly=$true
$script:OperationOutput.WordWrap=$false
$script:OperationOutput.Font=New-Object System.Drawing.Font('Consolas',9)
$script:OperationOutput.Location=[System.Drawing.Point]::new(18,322)
$script:OperationOutput.Size=[System.Drawing.Size]::new(1080,505)
$script:OperationOutput.Anchor='Top,Left'
$script:OperationOutput.HideSelection=$false
$opTab.Controls.Add($script:OperationOutput)

$handoffGroup = New-Object System.Windows.Forms.GroupBox
$handoffGroup.Text='AI / Support Files - Ctrl/Shift-click multiple files, then drag selection to ChatGPT'
$handoffGroup.Location=[System.Drawing.Point]::new(18,842)
$handoffGroup.Size=[System.Drawing.Size]::new(1080,170)
$handoffGroup.Anchor='Top,Left,Right'
$opTab.Controls.Add($handoffGroup)

$script:CurrentLogLabel = New-Object System.Windows.Forms.Label
$script:CurrentLogLabel.Text='No run logs yet'
$script:CurrentLogLabel.TextAlign='MiddleCenter'
$script:CurrentLogLabel.BorderStyle='FixedSingle'
$script:CurrentLogLabel.Location=[System.Drawing.Point]::new(12,25)
$script:CurrentLogLabel.Size=[System.Drawing.Size]::new(430,60)
$script:CurrentLogLabel.Cursor='Hand'
$script:CurrentLogLabel.Visible=$false; $handoffGroup.Controls.Add($script:CurrentLogLabel)

$script:CurrentOutputLabel = New-Object System.Windows.Forms.Label
$script:CurrentOutputLabel.Text='No generated file detected for latest run'
$script:CurrentOutputLabel.TextAlign='MiddleCenter'
$script:CurrentOutputLabel.BorderStyle='FixedSingle'
$script:CurrentOutputLabel.Location=[System.Drawing.Point]::new(12,91)
$script:CurrentOutputLabel.Size=[System.Drawing.Size]::new(430,64)
$script:CurrentOutputLabel.Cursor='Hand'
$script:CurrentOutputLabel.Enabled=$false
$script:CurrentOutputLabel.Visible=$false; $handoffGroup.Controls.Add($script:CurrentOutputLabel)

$script:LogList = New-Object System.Windows.Forms.ListView
$script:LogList.Location=[System.Drawing.Point]::new(12,25)
$script:LogList.Size=[System.Drawing.Size]::new(888,130)
$script:LogList.View=[System.Windows.Forms.View]::Details
$script:LogList.FullRowSelect=$true
$script:LogList.MultiSelect=$true
$script:LogList.HideSelection=$false
$script:LogList.GridLines=$false
[void]$script:LogList.Columns.Add('Created',155)
[void]$script:LogList.Columns.Add('File',700)
$handoffGroup.Controls.Add($script:LogList)

$script:OpenLogsBtn = New-Object System.Windows.Forms.Button
$script:OpenLogsBtn.Text='Open Selected'
$script:OpenLogsBtn.Location=[System.Drawing.Point]::new(910,25)
$script:OpenLogsBtn.Size=[System.Drawing.Size]::new(150,36)
$handoffGroup.Controls.Add($script:OpenLogsBtn)

$script:RefreshLogsBtn = New-Object System.Windows.Forms.Button
$script:RefreshLogsBtn.Text='Refresh Files'
$script:RefreshLogsBtn.Location=[System.Drawing.Point]::new(910,70)
$script:RefreshLogsBtn.Size=[System.Drawing.Size]::new(150,36)
$handoffGroup.Controls.Add($script:RefreshLogsBtn)

# DR tab
$drTab = New-Object System.Windows.Forms.TabPage
$drTab.Text='Disaster Recovery'
$drTab.AutoScroll = $true
$drTab.AutoScrollMinSize = [System.Drawing.Size]::new(1120,820)
$tabs.TabPages.Add($drTab)

$drNote = New-Object System.Windows.Forms.Label
$drNote.Text='DR executes the fixed toolkit configured for the selected application. It does not depend on the Operations ZIP.'
$drNote.Location=[System.Drawing.Point]::new(18,18)
$drNote.Size=[System.Drawing.Size]::new(1000,28)
$drTab.Controls.Add($drNote)

$script:DrBackupBtn=New-Object System.Windows.Forms.Button; $script:DrBackupBtn.Text='Backup'; $script:DrBackupBtn.Location=[System.Drawing.Point]::new(18,55); $script:DrBackupBtn.Size=[System.Drawing.Size]::new(260,38); $drTab.Controls.Add($script:DrBackupBtn)
$script:DrVerifyBtn=New-Object System.Windows.Forms.Button; $script:DrVerifyBtn.Text='Verify Latest Backup'; $script:DrVerifyBtn.Location=[System.Drawing.Point]::new(290,55); $script:DrVerifyBtn.Size=[System.Drawing.Size]::new(260,38); $drTab.Controls.Add($script:DrVerifyBtn)
$script:DrFullBtn=New-Object System.Windows.Forms.Button; $script:DrFullBtn.Text='Create FULL Recovery Folder'; $script:DrFullBtn.Location=[System.Drawing.Point]::new(562,55); $script:DrFullBtn.Size=[System.Drawing.Size]::new(260,38); $drTab.Controls.Add($script:DrFullBtn)
$script:DrContinuityBtn=New-Object System.Windows.Forms.Button; $script:DrContinuityBtn.Text='Continuity Snapshot'; $script:DrContinuityBtn.Location=[System.Drawing.Point]::new(834,55); $script:DrContinuityBtn.Size=[System.Drawing.Size]::new(260,38); $drTab.Controls.Add($script:DrContinuityBtn)
$script:DrRestoreBtn=New-Object System.Windows.Forms.Button; $script:DrRestoreBtn.Text='Test Restore Latest'; $script:DrRestoreBtn.Location=[System.Drawing.Point]::new(18,103); $script:DrRestoreBtn.Size=[System.Drawing.Size]::new(260,38); $drTab.Controls.Add($script:DrRestoreBtn)
$script:DrDestroyBtn=New-Object System.Windows.Forms.Button; $script:DrDestroyBtn.Text='Destroy Isolated Test'; $script:DrDestroyBtn.Location=[System.Drawing.Point]::new(290,103); $script:DrDestroyBtn.Size=[System.Drawing.Size]::new(260,38); $drTab.Controls.Add($script:DrDestroyBtn)
$script:DrListBtn=New-Object System.Windows.Forms.Button; $script:DrListBtn.Text='List Snapshots'; $script:DrListBtn.Location=[System.Drawing.Point]::new(562,103); $script:DrListBtn.Size=[System.Drawing.Size]::new(260,38); $drTab.Controls.Add($script:DrListBtn)
$script:DrCancelBtn=New-Object System.Windows.Forms.Button; $script:DrCancelBtn.Text='CANCEL'; $script:DrCancelBtn.Location=[System.Drawing.Point]::new(840,79); $script:DrCancelBtn.Size=[System.Drawing.Size]::new(190,38); $script:DrCancelBtn.Enabled=$false; $drTab.Controls.Add($script:DrCancelBtn)


$drQuickTitle = New-Object System.Windows.Forms.Label
$drQuickTitle.Text = 'DR QUICK SCRIPT BUTTONS - exact scripts detected in selected ZIP'
$drQuickTitle.Location = [System.Drawing.Point]::new(18,52)
$drQuickTitle.AutoSize = $true
$drQuickTitle.Visible = $false
$drTab.Controls.Add($drQuickTitle)

$script:DrQuickScriptsPanel = New-Object System.Windows.Forms.Panel
$script:DrQuickScriptsPanel.Location = [System.Drawing.Point]::new(18,76)
$script:DrQuickScriptsPanel.Size = [System.Drawing.Size]::new(1080,126)
$script:DrQuickScriptsPanel.AutoScroll = $true
$script:DrQuickScriptsPanel.BorderStyle = 'FixedSingle'
$script:DrQuickScriptsPanel.Visible = $false
$drTab.Controls.Add($script:DrQuickScriptsPanel)

$script:DrStatus=New-Object System.Windows.Forms.Label; $script:DrStatus.Text='READY'; $script:DrStatus.Location=[System.Drawing.Point]::new(18,155); $script:DrStatus.Size=[System.Drawing.Size]::new(1000,24); $drTab.Controls.Add($script:DrStatus)
$script:CopyDrLogBtn = New-Object System.Windows.Forms.Button
$script:CopyDrLogBtn.Text = 'Copy Log'
$script:CopyDrLogBtn.Location = [System.Drawing.Point]::new(978,152)
$script:CopyDrLogBtn.Size = [System.Drawing.Size]::new(110,29)
$drTab.Controls.Add($script:CopyDrLogBtn)
$script:DrOutput=New-Object System.Windows.Forms.RichTextBox; $script:DrOutput.ReadOnly=$true; $script:DrOutput.WordWrap=$false; $script:DrOutput.Font=New-Object System.Drawing.Font('Consolas',9); $script:DrOutput.Location=[System.Drawing.Point]::new(18,185); $script:DrOutput.Size=[System.Drawing.Size]::new(1080,390); $script:DrOutput.Anchor='Top,Left,Right'; $script:DrOutput.HideSelection=$false; $drTab.Controls.Add($script:DrOutput)

$drHandoff=New-Object System.Windows.Forms.GroupBox; $drHandoff.Text='AI / Support Files - Ctrl/Shift-click multiple files, then drag selection to ChatGPT'; $drHandoff.Location=[System.Drawing.Point]::new(18,680); $drHandoff.Size=[System.Drawing.Size]::new(1080,170); $drHandoff.Anchor='Top,Left,Right'; $drTab.Controls.Add($drHandoff)
$script:DrCurrentLogLabel=New-Object System.Windows.Forms.Label; $script:DrCurrentLogLabel.Text='No run logs yet'; $script:DrCurrentLogLabel.TextAlign='MiddleCenter'; $script:DrCurrentLogLabel.BorderStyle='FixedSingle'; $script:DrCurrentLogLabel.Location=[System.Drawing.Point]::new(12,25); $script:DrCurrentLogLabel.Size=[System.Drawing.Size]::new(430,60); $script:DrCurrentLogLabel.Cursor='Hand'; $script:DrCurrentLogLabel.Visible=$false; $drHandoff.Controls.Add($script:DrCurrentLogLabel)
$script:DrCurrentOutputLabel=New-Object System.Windows.Forms.Label; $script:DrCurrentOutputLabel.Text='No generated file detected for latest run'; $script:DrCurrentOutputLabel.TextAlign='MiddleCenter'; $script:DrCurrentOutputLabel.BorderStyle='FixedSingle'; $script:DrCurrentOutputLabel.Location=[System.Drawing.Point]::new(12,91); $script:DrCurrentOutputLabel.Size=[System.Drawing.Size]::new(430,64); $script:DrCurrentOutputLabel.Cursor='Hand'; $script:DrCurrentOutputLabel.Enabled=$false; $script:DrCurrentOutputLabel.Visible=$false; $drHandoff.Controls.Add($script:DrCurrentOutputLabel)
$script:DrLogList=New-Object System.Windows.Forms.ListView; $script:DrLogList.Location=[System.Drawing.Point]::new(12,25); $script:DrLogList.Size=[System.Drawing.Size]::new(888,130); $script:DrLogList.View=[System.Windows.Forms.View]::Details; $script:DrLogList.FullRowSelect=$true; $script:DrLogList.MultiSelect=$true; $script:DrLogList.HideSelection=$false; $script:DrLogList.GridLines=$false; [void]$script:DrLogList.Columns.Add('Created',155); [void]$script:DrLogList.Columns.Add('File',700); $drHandoff.Controls.Add($script:DrLogList)
$script:DrOpenLogsBtn=New-Object System.Windows.Forms.Button; $script:DrOpenLogsBtn.Text='Open Selected'; $script:DrOpenLogsBtn.Location=[System.Drawing.Point]::new(910,25); $script:DrOpenLogsBtn.Size=[System.Drawing.Size]::new(150,36); $drHandoff.Controls.Add($script:DrOpenLogsBtn)
$script:DrRefreshLogsBtn=New-Object System.Windows.Forms.Button; $script:DrRefreshLogsBtn.Text='Refresh Files'; $script:DrRefreshLogsBtn.Location=[System.Drawing.Point]::new(910,70); $script:DrRefreshLogsBtn.Size=[System.Drawing.Size]::new(150,36); $drHandoff.Controls.Add($script:DrRefreshLogsBtn)


# AI Prompt tab
$promptTab = New-Object System.Windows.Forms.TabPage
$promptTab.Text = 'AI Prompt'
$promptTab.AutoScroll = $true
$promptTab.AutoScrollMinSize = [System.Drawing.Size]::new(1120,760)
$tabs.TabPages.Add($promptTab)

$promptTitle = New-Object System.Windows.Forms.Label
$promptTitle.Text = 'AI Prompt Library'
$promptTitle.Font = New-Object System.Drawing.Font('Segoe UI',15,[System.Drawing.FontStyle]::Bold)
$promptTitle.Location = [System.Drawing.Point]::new(18,16)
$promptTitle.AutoSize = $true
$promptTab.Controls.Add($promptTitle)

$promptSubtitle = New-Object System.Windows.Forms.Label
$promptSubtitle.Text = 'Select a prompt, then drag it to AI or edit it.'
$promptSubtitle.Location = [System.Drawing.Point]::new(18,48)
$promptSubtitle.Size = [System.Drawing.Size]::new(420,26)
$promptTab.Controls.Add($promptSubtitle)

$script:PromptSearchBox = New-Object System.Windows.Forms.TextBox
$script:PromptSearchBox.Location = [System.Drawing.Point]::new(18,78)
$script:PromptSearchBox.Size = [System.Drawing.Size]::new(300,25)
$promptTab.Controls.Add($script:PromptSearchBox)

$promptSearchHint = New-Object System.Windows.Forms.Label
$promptSearchHint.Text = 'Search'
$promptSearchHint.Location = [System.Drawing.Point]::new(324,82)
$promptSearchHint.AutoSize = $true
$promptTab.Controls.Add($promptSearchHint)

$script:PromptList = New-Object System.Windows.Forms.ListView
$script:PromptList.Location = [System.Drawing.Point]::new(18,110)
$script:PromptList.Size = [System.Drawing.Size]::new(420,540)
$script:PromptList.View = [System.Windows.Forms.View]::Details
$script:PromptList.FullRowSelect = $true
$script:PromptList.MultiSelect = $false
$script:PromptList.HideSelection = $false
$script:PromptList.GridLines = $true
[void]$script:PromptList.Columns.Add('Identifier',135)
[void]$script:PromptList.Columns.Add('Purpose / Use',180)
[void]$script:PromptList.Columns.Add('Last Updated',145)
$promptTab.Controls.Add($script:PromptList)

$script:PromptCountLabel = New-Object System.Windows.Forms.Label
$script:PromptCountLabel.Location = [System.Drawing.Point]::new(18,658)
$script:PromptCountLabel.Size = [System.Drawing.Size]::new(420,46)
$promptTab.Controls.Add($script:PromptCountLabel)

# Prompt action toolbar
$script:PromptNewBtn = New-Object System.Windows.Forms.Button
$script:PromptNewBtn.Text = 'New'
$script:PromptNewBtn.Location = [System.Drawing.Point]::new(458,18)
$script:PromptNewBtn.Size = [System.Drawing.Size]::new(72,32)
$promptTab.Controls.Add($script:PromptNewBtn)

$script:PromptSaveBtn = New-Object System.Windows.Forms.Button
$script:PromptSaveBtn.Text = 'Save'
$script:PromptSaveBtn.Location = [System.Drawing.Point]::new(536,18)
$script:PromptSaveBtn.Size = [System.Drawing.Size]::new(72,32)
$promptTab.Controls.Add($script:PromptSaveBtn)

$script:PromptDuplicateBtn = New-Object System.Windows.Forms.Button
$script:PromptDuplicateBtn.Text = 'Duplicate'
$script:PromptDuplicateBtn.Location = [System.Drawing.Point]::new(614,18)
$script:PromptDuplicateBtn.Size = [System.Drawing.Size]::new(86,32)
$promptTab.Controls.Add($script:PromptDuplicateBtn)

$script:PromptDeleteBtn = New-Object System.Windows.Forms.Button
$script:PromptDeleteBtn.Text = 'Delete'
$script:PromptDeleteBtn.Location = [System.Drawing.Point]::new(706,18)
$script:PromptDeleteBtn.Size = [System.Drawing.Size]::new(72,32)
$promptTab.Controls.Add($script:PromptDeleteBtn)

$script:PromptRefreshBtn = New-Object System.Windows.Forms.Button
$script:PromptRefreshBtn.Text = 'Refresh'
$script:PromptRefreshBtn.Location = [System.Drawing.Point]::new(784,18)
$script:PromptRefreshBtn.Size = [System.Drawing.Size]::new(78,32)
$promptTab.Controls.Add($script:PromptRefreshBtn)

$script:PromptCopyBtn = New-Object System.Windows.Forms.Button
$script:PromptCopyBtn.Text = 'Copy Prompt'
$script:PromptCopyBtn.Location = [System.Drawing.Point]::new(868,18)
$script:PromptCopyBtn.Size = [System.Drawing.Size]::new(105,32)
$promptTab.Controls.Add($script:PromptCopyBtn)

$script:PromptOpenFolderBtn = New-Object System.Windows.Forms.Button
$script:PromptOpenFolderBtn.Text = 'Open Prompts Folder'
$script:PromptOpenFolderBtn.Location = [System.Drawing.Point]::new(979,18)
$script:PromptOpenFolderBtn.Size = [System.Drawing.Size]::new(142,32)
$promptTab.Controls.Add($script:PromptOpenFolderBtn)

# Metadata fields
$promptIdLabel = New-Object System.Windows.Forms.Label
$promptIdLabel.Text = 'Identifier (auto):'
$promptIdLabel.Location = [System.Drawing.Point]::new(458,96)
$promptIdLabel.Size = [System.Drawing.Size]::new(110,24)
$promptTab.Controls.Add($promptIdLabel)

$script:PromptIdBox = New-Object System.Windows.Forms.TextBox
$script:PromptIdBox.Location = [System.Drawing.Point]::new(565,94)
$script:PromptIdBox.Size = [System.Drawing.Size]::new(556,25)
$promptTab.Controls.Add($script:PromptIdBox)

$promptPurposeLabel = New-Object System.Windows.Forms.Label
$promptPurposeLabel.Text = 'Purpose / Use:'
$promptPurposeLabel.Location = [System.Drawing.Point]::new(458,130)
$promptPurposeLabel.Size = [System.Drawing.Size]::new(105,24)
$promptTab.Controls.Add($promptPurposeLabel)

$script:PromptPurposeBox = New-Object System.Windows.Forms.TextBox
$script:PromptPurposeBox.Location = [System.Drawing.Point]::new(565,128)
$script:PromptPurposeBox.Size = [System.Drawing.Size]::new(556,25)
$promptTab.Controls.Add($script:PromptPurposeBox)

$promptTagsLabel = New-Object System.Windows.Forms.Label
$promptTagsLabel.Text = 'Tags (optional):'
$promptTagsLabel.Location = [System.Drawing.Point]::new(458,164)
$promptTagsLabel.Size = [System.Drawing.Size]::new(110,24)
$promptTab.Controls.Add($promptTagsLabel)

$script:PromptTagsBox = New-Object System.Windows.Forms.TextBox
$script:PromptTagsBox.Location = [System.Drawing.Point]::new(565,162)
$script:PromptTagsBox.Size = [System.Drawing.Size]::new(556,25)
$promptTab.Controls.Add($script:PromptTagsBox)

# Last updated is automatic on Save and shown in the library list; it is not
# an editable metadata field. Keep a hidden instance to preserve legacy calls.
$script:PromptUpdatedBox = New-Object System.Windows.Forms.TextBox
$script:PromptUpdatedBox.Visible = $false

$promptStoredLabel = New-Object System.Windows.Forms.Label
$promptStoredLabel.Text = 'Saved automatically with date/time. Rich formatting is retained as HTML.'
$promptStoredLabel.Location = [System.Drawing.Point]::new(458,198)
$promptStoredLabel.Size = [System.Drawing.Size]::new(663,24)
$promptTab.Controls.Add($promptStoredLabel)

# A single editable rich-text prompt window. No Markdown source/preview split.
$promptEditorLabel = New-Object System.Windows.Forms.Label
$promptEditorLabel.Text = 'Prompt Content — paste formatted text from OneNote or Office'
$promptEditorLabel.Location = [System.Drawing.Point]::new(458,236)
$promptEditorLabel.Size = [System.Drawing.Size]::new(600,25)
$promptTab.Controls.Add($promptEditorLabel)

# Hidden legacy RichTextBox is only used to import old .rtf/.md records.
$script:PromptEditor = New-Object System.Windows.Forms.RichTextBox
$script:PromptEditor.Visible = $false
$script:PromptEditor.Font = New-Object System.Drawing.Font('Segoe UI',10)
$promptTab.Controls.Add($script:PromptEditor)

# Real HTML editing surface: native HTML paste from OneNote and Office, including
# nested numbered lists, headings, coloured text, indents and paragraph layout.
$script:PromptBrowser = New-Object System.Windows.Forms.WebBrowser
$script:PromptBrowser.Location = [System.Drawing.Point]::new(458,264)
$script:PromptBrowser.Size = [System.Drawing.Size]::new(663,440)
$script:PromptBrowser.ScriptErrorsSuppressed = $true
$script:PromptBrowser.AllowWebBrowserDrop = $false
$script:PromptBrowser.IsWebBrowserContextMenuEnabled = $true
$script:PromptBrowser.WebBrowserShortcutsEnabled = $true
$promptTab.Controls.Add($script:PromptBrowser)

$script:PromptStatusLabel = New-Object System.Windows.Forms.Label
$script:PromptStatusLabel.Text = 'READY'
$script:PromptStatusLabel.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$script:PromptStatusLabel.Location = [System.Drawing.Point]::new(458,710)
$script:PromptStatusLabel.Size = [System.Drawing.Size]::new(663,24)
$promptTab.Controls.Add($script:PromptStatusLabel)

$script:PromptAutoSaveTimer = New-Object System.Windows.Forms.Timer
$script:PromptAutoSaveTimer.Interval = 1200


# Settings tab
$script:SetName = $null
$script:SetAppPath = $null
$script:SetPackageFolder = $null
$script:SetVerifiedFolder = $null
$script:SetHttpUrl = $null
$script:SetDrToolkit = $null
$script:SetPatterns = $null
$script:SetTempFolder = $null
$script:SetOutputFolder = $null
$script:SetLogsFolder = $null
$script:SetArchiveFolder = $null
$script:SetInstallFolder = $null
$script:SetAutoCleanTemp = $null
$setTab = New-Object System.Windows.Forms.TabPage
$setTab.Text='Settings'
$setTab.AutoScroll = $true
$setTab.AutoScrollMinSize = [System.Drawing.Size]::new(1080,900)
$tabs.TabPages.Add($setTab)

$sy=25
function Add-SettingRow(
    [string]$Label,
    [ref]$Store,
    [int]$Y,
    [bool]$MultiLine=$false,
    [bool]$OpenFolder=$false
) {
    $l=New-Object System.Windows.Forms.Label
    $l.Text=$Label
    $l.Location=[System.Drawing.Point]::new(30,$Y)
    $l.Size=[System.Drawing.Size]::new(190,26)
    $setTab.Controls.Add($l)

    $textW = if ($OpenFolder) { 590 } else { 700 }

    if ($MultiLine) {
        $t=New-Object System.Windows.Forms.TextBox
        $t.Multiline=$true
        $t.ScrollBars='Vertical'
        $t.Location=[System.Drawing.Point]::new(225,$Y)
        $t.Size=[System.Drawing.Size]::new($textW,80)
    }
    else {
        $t=New-Object System.Windows.Forms.TextBox
        $t.Location=[System.Drawing.Point]::new(225,$Y)
        $t.Size=[System.Drawing.Size]::new($textW,25)
    }

    $t.Anchor='Top,Left,Right'
    $setTab.Controls.Add($t)
    $Store.Value=$t

    if ($OpenFolder) {
        $open = New-Object System.Windows.Forms.Button
        $open.Text = 'Open Folder'
        $open.Location = [System.Drawing.Point]::new(825,($Y - 2))
        $open.Size = [System.Drawing.Size]::new(105,30)
        $open.Anchor = 'Top,Right'
        $open.Tag = $t
        $open.Add_Click({
            param($sender,$eventArgs)
            Open-FolderSafe ([System.Windows.Forms.TextBox]$sender.Tag).Text
        })
        $setTab.Controls.Add($open)
    }
}

Add-SettingRow 'Name' ([ref]$script:SetName) $sy; $sy+=42
Add-SettingRow 'Application path' ([ref]$script:SetAppPath) $sy $false $true; $sy+=42
Add-SettingRow 'Package folder' ([ref]$script:SetPackageFolder) $sy $false $true; $sy+=42
Add-SettingRow 'Verified package folder' ([ref]$script:SetVerifiedFolder) $sy $false $true; $sy+=42
Add-SettingRow 'HTTP URL' ([ref]$script:SetHttpUrl) $sy; $sy+=42
Add-SettingRow 'Disaster Recovery Toolkit Folder' ([ref]$script:SetDrToolkit) $sy $false $true; $sy+=42
Add-SettingRow 'Package patterns (one per line)' ([ref]$script:SetPatterns) $sy $true; $sy+=108

$storageGroup = New-Object System.Windows.Forms.GroupBox
$storageGroup.Text = 'STORAGE & PATHS - Manager-wide'
$storageGroup.Location = [System.Drawing.Point]::new(30,$sy)
$storageGroup.Size = [System.Drawing.Size]::new(1010,215)
$storageGroup.Anchor = 'Top,Left,Right'
$setTab.Controls.Add($storageGroup)

function Add-StoragePathRow([string]$Label,[ref]$Store,[int]$Y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Label
    $l.Location = [System.Drawing.Point]::new(15,$Y)
    $l.Size = [System.Drawing.Size]::new(200,26)
    $storageGroup.Controls.Add($l)

    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = [System.Drawing.Point]::new(215,$Y)
    $t.Size = [System.Drawing.Size]::new(545,25)
    $t.Anchor = 'Top,Left,Right'
    $storageGroup.Controls.Add($t)
    $Store.Value = $t

    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = 'Browse...'
    $browse.Location = [System.Drawing.Point]::new(770,($Y - 2))
    $browse.Size = [System.Drawing.Size]::new(82,30)
    $browse.Anchor = 'Top,Right'
    $browse.Tag = $t
    $browse.Add_Click({ param($sender,$eventArgs) Browse-FolderIntoTextBox ([System.Windows.Forms.TextBox]$sender.Tag) })
    $storageGroup.Controls.Add($browse)

    $open = New-Object System.Windows.Forms.Button
    $open.Text = 'Open Folder'
    $open.Location = [System.Drawing.Point]::new(860,($Y - 2))
    $open.Size = [System.Drawing.Size]::new(123,30)
    $open.Anchor = 'Top,Right'
    $open.Tag = $t
    $open.Add_Click({ param($sender,$eventArgs) Open-FolderSafe ([System.Windows.Forms.TextBox]$sender.Tag).Text })
    $storageGroup.Controls.Add($open)
}

Add-StoragePathRow 'AI Dev Toolkit Folder' ([ref]$script:SetInstallFolder) 30
Add-StoragePathRow 'Temporary Working Folder' ([ref]$script:SetTempFolder) 72
Add-StoragePathRow 'Permanent Script Output Folder' ([ref]$script:SetOutputFolder) 114
Add-StoragePathRow 'Execution Logs Folder' ([ref]$script:SetLogsFolder) 156
Add-StoragePathRow 'Package Archive Folder' ([ref]$script:SetArchiveFolder) 198

$script:SetAutoCleanTemp = New-Object System.Windows.Forms.CheckBox
$script:SetAutoCleanTemp.Text = 'Automatically clean the temporary extracted run folder after a successful run'
$script:SetAutoCleanTemp.Location = [System.Drawing.Point]::new(215,242)
$script:SetAutoCleanTemp.Size = [System.Drawing.Size]::new(650,28)
$storageGroup.Controls.Add($script:SetAutoCleanTemp)

$storageHint = New-Object System.Windows.Forms.Label
$storageHint.Text = 'AI Dev Toolkit Folder is used by incremental patches. Archive ZIP moves completed packages out of the active package folder.'
$storageHint.Location = [System.Drawing.Point]::new(215,271)
$storageHint.Size = [System.Drawing.Size]::new(760,22)
$storageGroup.Controls.Add($storageHint)

$storageGroup.Size = [System.Drawing.Size]::new(1010,305)
$sy += 320
$saveSettings=New-Object System.Windows.Forms.Button
$saveSettings.Text='SAVE SETTINGS'
$saveSettings.Location=[System.Drawing.Point]::new(225,$sy)
$saveSettings.Size=[System.Drawing.Size]::new(180,38)
$setTab.Controls.Add($saveSettings)

$configLabel=New-Object System.Windows.Forms.Label
$configLabel.Text="Persistent config: $ConfigPath"
$configLabel.Location=[System.Drawing.Point]::new(30,[int]($sy + 60))
$configLabel.Size=[System.Drawing.Size]::new(950,28)
$setTab.Controls.Add($configLabel)


# Responsive Operations layout
function Update-MainResponsiveLayout {
    if ($null -eq $form -or $null -eq $tabs) { return }

    $fw = [Math]::Max(760,$form.ClientSize.Width)
    $fh = [Math]::Max(560,$form.ClientSize.Height)
    $pad = 18
    $gap = 10

    # Wide header: title on left, application/theme controls on right.
    # Compact header: title on first row, application/theme controls on second row.
    $wideHeader = ($fw -ge 1160)

    if ($wideHeader) {
        $title.Location = [System.Drawing.Point]::new($pad,15)

        $themeW = 150
        $comboW = 260
        $labelW = 140
        $right = $fw - $pad

        $themeX = $right - $themeW
        $comboX = $themeX - $gap - $comboW
        $labelX = $comboX - $gap - $labelW

        $appLbl.Location = [System.Drawing.Point]::new($labelX,26)
        $script:AppCombo.Location = [System.Drawing.Point]::new($comboX,21)
        $script:AppCombo.Size = [System.Drawing.Size]::new($comboW,27)
        $script:ThemeButton.Location = [System.Drawing.Point]::new($themeX,20)
        $script:ThemeButton.Size = [System.Drawing.Size]::new($themeW,30)

        $stripY = 61
        $script:MultipleRunsCheck.Location = [System.Drawing.Point]::new($pad,62)

        $installedX = 205
        $warningW = 310
        $warningX = $fw - $pad - $warningW
        $installedW = [Math]::Max(360,$warningX - $installedX - 10)

        $script:InstalledStatusLabel.Location = [System.Drawing.Point]::new($installedX,$stripY)
        $script:InstalledStatusLabel.Size = [System.Drawing.Size]::new($installedW,24)
        $script:LastApplyWarningLabel.Location = [System.Drawing.Point]::new($warningX,$stripY)
        $script:LastApplyWarningLabel.Size = [System.Drawing.Size]::new($warningW,24)

        $tabsY = 90
    }
    else {
        $title.Location = [System.Drawing.Point]::new($pad,12)

        $themeW = 135
        $labelW = 140
        $secondY = 54
        $right = $fw - $pad

        $appLbl.Location = [System.Drawing.Point]::new($pad,($secondY + 5))
        $comboX = $pad + $labelW
        $themeX = $right - $themeW
        $comboW = [Math]::Max(220,$themeX - $gap - $comboX)

        $script:AppCombo.Location = [System.Drawing.Point]::new($comboX,$secondY)
        $script:AppCombo.Size = [System.Drawing.Size]::new($comboW,27)
        $script:ThemeButton.Location = [System.Drawing.Point]::new($themeX,($secondY - 1))
        $script:ThemeButton.Size = [System.Drawing.Size]::new($themeW,30)

        $stripY = 88
        $script:MultipleRunsCheck.Location = [System.Drawing.Point]::new($pad,89)

        $installedX = 205
        $warningW = [Math]::Min(270,[Math]::Max(210,[int]($fw * 0.27)))
        $warningX = $fw - $pad - $warningW
        $installedW = [Math]::Max(280,$warningX - $installedX - 8)

        $script:InstalledStatusLabel.Location = [System.Drawing.Point]::new($installedX,$stripY)
        $script:InstalledStatusLabel.Size = [System.Drawing.Size]::new($installedW,24)
        $script:LastApplyWarningLabel.Location = [System.Drawing.Point]::new($warningX,$stripY)
        $script:LastApplyWarningLabel.Size = [System.Drawing.Size]::new($warningW,24)

        $tabsY = 118
    }

    $tabsX = 15
    $tabsW = [Math]::Max(700,$fw - 30)
    $tabsH = [Math]::Max(430,$fh - $tabsY - 18)
    $tabs.Location = [System.Drawing.Point]::new($tabsX,$tabsY)
    $tabs.Size = [System.Drawing.Size]::new($tabsW,$tabsH)
}

function Update-OperationsResponsiveLayout {
    if ($null -eq $opTab) { return }

    $cw = [Math]::Max(640,$opTab.ClientSize.Width)
    $ch = [Math]::Max(420,$opTab.ClientSize.Height)
    $pad = 18
    $gap = 12
    $usable = [Math]::Max(580,$cw - ($pad * 2))

    # Package selector row: active ZIP + Refresh + Browse + Archive ZIP.
    # Archive ZIP is the move-package workflow from v1.0.22.
    $refreshW = 92
    $browseW = 92
    $archiveW = 118
    $buttonGap = 8
    $comboW = $usable - $refreshW - $browseW - $archiveW - ($buttonGap * 3)

    if ($comboW -lt 220) {
        # Very narrow fallback: package selector on its own row,
        # action buttons on the row below.
        $script:PackageCombo.Location = [System.Drawing.Point]::new($pad,40)
        $script:PackageCombo.Size = [System.Drawing.Size]::new($usable,27)

        $buttonY = 73
        $script:RefreshPackagesBtn.Location = [System.Drawing.Point]::new($pad,$buttonY)
        $script:BrowsePackageBtn.Location = [System.Drawing.Point]::new(($pad + $refreshW + $buttonGap),$buttonY)
        $script:ArchivePackageBtn.Location = [System.Drawing.Point]::new(($pad + $refreshW + $browseW + ($buttonGap * 2)),$buttonY)

        $script:RefreshPackagesBtn.Size = [System.Drawing.Size]::new($refreshW,30)
        $script:BrowsePackageBtn.Size = [System.Drawing.Size]::new($browseW,30)
        $script:ArchivePackageBtn.Size = [System.Drawing.Size]::new($archiveW,30)

        $topY = 114
    }
    else {
        $script:PackageCombo.Location = [System.Drawing.Point]::new($pad,40)
        $script:PackageCombo.Size = [System.Drawing.Size]::new($comboW,27)

        $refreshX = $pad + $comboW + $buttonGap
        $browseX = $refreshX + $refreshW + $buttonGap
        $archiveX = $browseX + $browseW + $buttonGap

        $script:RefreshPackagesBtn.Location = [System.Drawing.Point]::new($refreshX,40)
        $script:BrowsePackageBtn.Location = [System.Drawing.Point]::new($browseX,40)
        $script:ArchivePackageBtn.Location = [System.Drawing.Point]::new($archiveX,40)

        $script:RefreshPackagesBtn.Size = [System.Drawing.Size]::new($refreshW,30)
        $script:BrowsePackageBtn.Size = [System.Drawing.Size]::new($browseW,30)
        $script:ArchivePackageBtn.Size = [System.Drawing.Size]::new($archiveW,30)

        $topY = 80
    }

    # Clear version / execution confirmation strip.
    $badgeY = $topY
    $versionW = [Math]::Min(260,[Math]::Max(200,[int]($usable * 0.22)))
    $statusStripH = 32
    $script:PackageVersionLabel.Location = [System.Drawing.Point]::new($pad,$badgeY)
    $script:PackageVersionLabel.Size = [System.Drawing.Size]::new($versionW,$statusStripH)
    $script:PackageExecutionLabel.Location = [System.Drawing.Point]::new(($pad + $versionW + 10),$badgeY)
    $script:PackageExecutionLabel.Size = [System.Drawing.Size]::new([Math]::Max(260,$usable - $versionW - 10),$statusStripH)

    $contentTopY = $topY + 40

    # Details + Quick Scripts.
    $narrow = ($usable -lt 860)
    if (-not $narrow) {
        $leftW = [Math]::Max(320,[int](($usable - $gap) * 0.38))
        $rightW = $usable - $leftW - $gap
        $rightX = $pad + $leftW + $gap

        $script:PackageInfoBox.Location = [System.Drawing.Point]::new($pad,$contentTopY)
        $script:PackageInfoBox.Size = [System.Drawing.Size]::new($leftW,150)

        $quickScriptsTitle.Location = [System.Drawing.Point]::new($rightX,$contentTopY)
        $script:QuickScriptsPanel.Location = [System.Drawing.Point]::new($rightX,($contentTopY + 24))
        $script:QuickScriptsPanel.Size = [System.Drawing.Size]::new($rightW,126)

        $actionY = $contentTopY + 166
    }
    else {
        $script:PackageInfoBox.Location = [System.Drawing.Point]::new($pad,$contentTopY)
        $script:PackageInfoBox.Size = [System.Drawing.Size]::new($usable,108)

        $quickY = $contentTopY + 118
        $quickScriptsTitle.Location = [System.Drawing.Point]::new($pad,$quickY)
        $script:QuickScriptsPanel.Location = [System.Drawing.Point]::new($pad,($quickY + 24))
        $script:QuickScriptsPanel.Size = [System.Drawing.Size]::new($usable,126)

        $actionY = $quickY + 166
    }

    foreach ($button in @(
        $script:ApplyBtn,
        $script:VerifyBtn,
        $script:RollbackBtn,
        $script:ContinuityBtn
    )) {
        if ($null -ne $button) { $button.Visible = $false }
    }

    # CANCEL remains right aligned without clipping.
    $cancelW = 118
    $cancelX = $pad + $usable - $cancelW
    $script:CancelBtn.Location = [System.Drawing.Point]::new($cancelX,$actionY)
    $script:CancelBtn.Size = [System.Drawing.Size]::new($cancelW,34)
    $script:CancelBtn.Visible = $true

    foreach ($label in @(
        $script:ApplyScriptLabel,
        $script:VerifyScriptLabel,
        $script:RollbackScriptLabel,
        $script:ContinuityScriptLabel
    )) {
        if ($null -ne $label) { $label.Visible = $false }
    }
    if ($null -ne $otherScriptsLabel) { $otherScriptsLabel.Visible = $false }
    if ($null -ne $script:OtherScriptsCombo) { $script:OtherScriptsCombo.Visible = $false }
    if ($null -ne $otherScriptsHint) { $otherScriptsHint.Visible = $false }

    $statusY = $actionY + 5
    $copyLogW = 110
    $copyLogX = $cancelX - $copyLogW - 8
    $script:CopyOperationLogBtn.Location = [System.Drawing.Point]::new($copyLogX,$actionY)
    $script:CopyOperationLogBtn.Size = [System.Drawing.Size]::new($copyLogW,34)
    $statusW = [Math]::Max(200,$copyLogX - $pad - 12)
    $script:OperationStatus.Location = [System.Drawing.Point]::new($pad,$statusY)
    $script:OperationStatus.Size = [System.Drawing.Size]::new($statusW,24)

    $outputY = $actionY + 44

    # Handoff must remain visible at all supported window heights.
    $bottomPad = 10
    $handoffGap = 8
    $handoffH = if ($ch -lt 610) { 130 } elseif ($ch -lt 700) { 145 } else { 165 }
    $availableOutputH = $ch - $outputY - $handoffGap - $handoffH - $bottomPad
    $outputH = [Math]::Max(55,$availableOutputH)

    $script:OperationOutput.Location = [System.Drawing.Point]::new($pad,$outputY)
    $script:OperationOutput.Size = [System.Drawing.Size]::new($usable,$outputH)

    $handoffY = $outputY + $outputH + $handoffGap
    $handoffGroup.Location = [System.Drawing.Point]::new($pad,$handoffY)
    $handoffGroup.Size = [System.Drawing.Size]::new($usable,$handoffH)

    # v1.0.40: one wide file list for LOGS and generated ZIP/files.
    $innerW = [Math]::Max(500,$handoffGroup.ClientSize.Width - 24)
    $innerH = [Math]::Max(82,$handoffGroup.ClientSize.Height - 36)
    $buttonW = 118
    $buttonGap2 = 8
    $buttonX = 12 + $innerW - $buttonW
    $listW = [Math]::Max(300,$buttonX - 12 - $buttonGap2)

    $script:CurrentLogLabel.Visible = $false
    $script:CurrentOutputLabel.Visible = $false

    $script:LogList.Location = [System.Drawing.Point]::new(12,24)
    $script:LogList.Size = [System.Drawing.Size]::new($listW,$innerH)
    if ($script:LogList.Columns.Count -ge 2) {
        $script:LogList.Columns[0].Width = 155
        $script:LogList.Columns[1].Width = [Math]::Max(260,$listW - 160)
    }

    $buttonH = 34
    if ($null -ne $script:OpenLogsBtn) {
        $script:OpenLogsBtn.Location = [System.Drawing.Point]::new($buttonX,24)
        $script:OpenLogsBtn.Size = [System.Drawing.Size]::new($buttonW,$buttonH)
    }
    if ($null -ne $script:RefreshLogsBtn) {
        $script:RefreshLogsBtn.Location = [System.Drawing.Point]::new($buttonX,(24 + $buttonH + 8))
        $script:RefreshLogsBtn.Size = [System.Drawing.Size]::new($buttonW,$buttonH)
    }

    # No artificial vertical scroll requirement when the controls fit.
    $opTab.AutoScrollMinSize = [System.Drawing.Size]::new(0,($handoffGroup.Bottom + 4))
}

function Update-DrResponsiveLayout {
    if ($null -eq $drTab) { return }

    $cw = [Math]::Max(640,$drTab.ClientSize.Width)
    $ch = [Math]::Max(420,$drTab.ClientSize.Height)
    $pad = 18
    $gap = 10
    $usable = [Math]::Max(580,$cw - ($pad * 2))

    $drNote.Location = [System.Drawing.Point]::new($pad,18)
    $drNote.Size = [System.Drawing.Size]::new($usable,28)

    # The seven semantic DR action buttons are ALWAYS visible.
    # Update-OperationButtons enables operations whose configured fixed-toolkit
    # scripts exist for the selected target application.
    foreach ($button in @(
        $script:DrBackupBtn,
        $script:DrVerifyBtn,
        $script:DrFullBtn,
        $script:DrContinuityBtn,
        $script:DrRestoreBtn,
        $script:DrDestroyBtn,
        $script:DrListBtn
    )) {
        if ($null -ne $button) { $button.Visible = $true }
    }

    # v1.0.25 DR quick-script panel is intentionally not the main UI.
    if ($null -ne $drQuickTitle) { $drQuickTitle.Visible = $false }
    if ($null -ne $script:DrQuickScriptsPanel) { $script:DrQuickScriptsPanel.Visible = $false }

    # Responsive 4-column x 2-row DR grid.
    # Row 1: Backup / Verify / FULL / Continuity
    # Row 2: Test Restore / Destroy / List Snapshots / Cancel
    $colGap = 10
    $buttonW = [Math]::Max(130,[int](($usable - ($colGap * 3)) / 4))
    $buttonH = 38

    $x1 = $pad
    $x2 = $x1 + $buttonW + $colGap
    $x3 = $x2 + $buttonW + $colGap
    $x4 = $x3 + $buttonW + $colGap
    $row1 = 55
    $row2 = 103

    $script:DrBackupBtn.Location = [System.Drawing.Point]::new($x1,$row1)
    $script:DrVerifyBtn.Location = [System.Drawing.Point]::new($x2,$row1)
    $script:DrFullBtn.Location = [System.Drawing.Point]::new($x3,$row1)
    $script:DrContinuityBtn.Location = [System.Drawing.Point]::new($x4,$row1)

    $script:DrRestoreBtn.Location = [System.Drawing.Point]::new($x1,$row2)
    $script:DrDestroyBtn.Location = [System.Drawing.Point]::new($x2,$row2)
    $script:DrListBtn.Location = [System.Drawing.Point]::new($x3,$row2)
    $script:DrCancelBtn.Location = [System.Drawing.Point]::new($x4,$row2)

    foreach ($button in @(
        $script:DrBackupBtn,
        $script:DrVerifyBtn,
        $script:DrFullBtn,
        $script:DrContinuityBtn,
        $script:DrRestoreBtn,
        $script:DrDestroyBtn,
        $script:DrListBtn,
        $script:DrCancelBtn
    )) {
        $button.Size = [System.Drawing.Size]::new($buttonW,$buttonH)
    }

    $statusY = 155
    $copyDrW = 110
    $copyDrX = $pad + $usable - $copyDrW
    $script:CopyDrLogBtn.Location = [System.Drawing.Point]::new($copyDrX,($statusY - 2))
    $script:CopyDrLogBtn.Size = [System.Drawing.Size]::new($copyDrW,29)
    $script:DrStatus.Location = [System.Drawing.Point]::new($pad,$statusY)
    $script:DrStatus.Size = [System.Drawing.Size]::new([Math]::Max(200,$usable - $copyDrW - 12),24)

    $outputY = 185
    $handoffH = if ($ch -lt 600) { 130 } elseif ($ch -lt 700) { 145 } else { 165 }
    $handoffGap = 8
    $outputH = [Math]::Max(85,$ch - $outputY - $handoffGap - $handoffH - 10)

    $script:DrOutput.Location = [System.Drawing.Point]::new($pad,$outputY)
    $script:DrOutput.Size = [System.Drawing.Size]::new($usable,$outputH)

    $drHandoff.Location = [System.Drawing.Point]::new($pad,($outputY + $outputH + $handoffGap))
    $drHandoff.Size = [System.Drawing.Size]::new($usable,$handoffH)

    # v1.0.40: one wide file list for LOGS and generated ZIP/files.
    $innerW = [Math]::Max(500,$drHandoff.ClientSize.Width - 24)
    $innerH = [Math]::Max(82,$drHandoff.ClientSize.Height - 36)
    $sideButtonW = 118
    $sideButtonX = 12 + $innerW - $sideButtonW
    $listW = [Math]::Max(300,$sideButtonX - 12 - 8)

    $script:DrCurrentLogLabel.Visible = $false
    $script:DrCurrentOutputLabel.Visible = $false

    $script:DrLogList.Location = [System.Drawing.Point]::new(12,24)
    $script:DrLogList.Size = [System.Drawing.Size]::new($listW,$innerH)
    if ($script:DrLogList.Columns.Count -ge 2) {
        $script:DrLogList.Columns[0].Width = 155
        $script:DrLogList.Columns[1].Width = [Math]::Max(260,$listW - 160)
    }

    if ($null -ne $script:DrOpenLogsBtn) {
        $script:DrOpenLogsBtn.Location = [System.Drawing.Point]::new($sideButtonX,24)
        $script:DrOpenLogsBtn.Size = [System.Drawing.Size]::new($sideButtonW,34)
    }

    if ($null -ne $script:DrRefreshLogsBtn) {
        $script:DrRefreshLogsBtn.Location = [System.Drawing.Point]::new($sideButtonX,66)
        $script:DrRefreshLogsBtn.Size = [System.Drawing.Size]::new($sideButtonW,34)
    }

    $drTab.AutoScrollMinSize = [System.Drawing.Size]::new(0,($drHandoff.Bottom + 4))
}


# Events
# AI Prompt events
$script:PromptSearchBox.Add_TextChanged({
    Refresh-PromptLibrary -SelectId $script:PromptCurrentId -SkipEditorLoad
})
$script:PromptList.Add_SelectedIndexChanged({
    if ($script:PromptSuppressSelection) { return }
    # Capture any recent paste/typing before changing prompts, even if the
    # periodic autosave poll has not fired yet.
    Watch-PromptHtmlChanges
    if ($script:PromptList.SelectedItems.Count -lt 1) { return }
    $newId = [string]$script:PromptList.SelectedItems[0].Tag
    if ($script:PromptDirty -and -not [string]::IsNullOrWhiteSpace($script:PromptCurrentId) -and
        -not [string]::Equals($script:PromptCurrentId,$newId,[System.StringComparison]::OrdinalIgnoreCase)) {
        [void](Save-CurrentPrompt -Silent -SkipRefresh)
    }
    Load-PromptIntoEditor $newId
})
$script:PromptList.Add_ItemDrag({
    Start-PromptTextDrag $script:PromptList
})
$script:PromptNewBtn.Add_Click({ New-Prompt })
$script:PromptSaveBtn.Add_Click({ [void](Save-CurrentPrompt) })
$script:PromptDuplicateBtn.Add_Click({ Duplicate-Prompt })
$script:PromptDeleteBtn.Add_Click({ Delete-CurrentPrompt })
$script:PromptRefreshBtn.Add_Click({
    Watch-PromptHtmlChanges
    if ($script:PromptDirty -and -not [string]::IsNullOrWhiteSpace($script:PromptCurrentId)) {
        [void](Save-CurrentPrompt -Silent -SkipRefresh)
    }
    Refresh-PromptLibrary -SelectId $script:PromptCurrentId
})
$script:PromptCopyBtn.Add_Click({ Copy-CurrentPrompt })
$script:PromptOpenFolderBtn.Add_Click({ Open-FolderSafe $PromptLibraryDir })
foreach ($control in @($script:PromptIdBox,$script:PromptPurposeBox,$script:PromptTagsBox)) {
    $control.Add_TextChanged({ Mark-PromptDirty })
}
$script:PromptBrowser.Add_Navigating({
    param($sender,$eventArgs)
    # Do not let pasted hyperlinks navigate the application away from the editor.
    if ($null -ne $eventArgs.Url -and $eventArgs.Url.Scheme -ne 'about') {
        $eventArgs.Cancel = $true
    }
})
$script:PromptBrowser.Add_DocumentCompleted({
    param($sender,$eventArgs)
    # DocumentCompleted is advisory: the UI timer and Save also reconcile
    # readiness against the actual HTML DOM. Never reset a user's dirty state.
    [void](Confirm-PromptBrowserReady)
})
# Polling captures paste via Ctrl+V, the native context menu, drag, and typing;
# it never changes source files until normal auto-save completes.
$script:PromptBrowserPollTimer = New-Object System.Windows.Forms.Timer
$script:PromptBrowserPollTimer.Interval = 900
$script:PromptBrowserPollTimer.Add_Tick({ Watch-PromptHtmlChanges })
$script:PromptBrowserPollTimer.Start()
$script:PromptAutoSaveTimer.Add_Tick({
    $script:PromptAutoSaveTimer.Stop()
    if ($script:PromptDirty -and -not $script:PromptIsNew -and -not [string]::IsNullOrWhiteSpace($script:PromptCurrentId)) {
        if (Save-CurrentPrompt -Silent -SkipRefresh) {
            Refresh-PromptLibrary -SelectId $script:PromptCurrentId -SkipEditorLoad
            Set-PromptUiStatus ("AUTO-SAVED — {0}" -f (Get-Date -Format 'dd/MM/yyyy HH:mm:ss'))
        }
    }
})

$opTab.Add_Resize({ Update-OperationsResponsiveLayout })
$drTab.Add_Resize({ Update-DrResponsiveLayout })
$form.Add_Resize({ Update-MainResponsiveLayout; Update-OperationsResponsiveLayout; Update-DrResponsiveLayout })
$script:AppCombo.Add_SelectedIndexChanged({ On-ApplicationChanged })
$script:PackageCombo.Add_SelectedIndexChanged({ Refresh-PackageInfo })
$script:RefreshPackagesBtn.Add_Click({ Refresh-Packages })
$script:ArchivePackageBtn.Add_Click({ Archive-SelectedPackage })
$script:BrowsePackageBtn.Add_Click({
    $dlg=New-Object System.Windows.Forms.OpenFileDialog; $dlg.Filter='ZIP packages (*.zip)|*.zip'; $dlg.Title='Select script package (ZIP)'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:PackagePaths = @($dlg.FileName) + @($script:PackagePaths | Where-Object { $_ -ne $dlg.FileName })
        $script:PackageCombo.Items.Clear(); foreach ($p in $script:PackagePaths) { [void]$script:PackageCombo.Items.Add([System.IO.Path]::GetFileName($p)) }; $script:PackageCombo.SelectedIndex=0
    }
})
$script:MultipleRunsCheck.Add_CheckedChanged({ Refresh-PackageInfo })
$script:ApplyBtn.Add_Click({ Execute-PackageOperation 'apply' })
$script:VerifyBtn.Add_Click({ Execute-PackageOperation 'verify' })
$script:RollbackBtn.Add_Click({ Execute-PackageOperation 'rollback' })
$script:ContinuityBtn.Add_Click({ Execute-PackageOperation 'continuity' })
$script:CancelBtn.Add_Click({ if ($script:Process -and -not $script:Process.HasExited) { $script:RunContext.CancelRequested=$true; Kill-ProcessTree $script:Process.Id } })
$script:DrCancelBtn.Add_Click({ if ($script:Process -and -not $script:Process.HasExited) { $script:RunContext.CancelRequested=$true; Kill-ProcessTree $script:Process.Id } })
$script:CopyOperationLogBtn.Add_Click({ Copy-DisplayedExecutionLog $script:OperationOutput $script:CopyOperationLogBtn })
$script:CopyDrLogBtn.Add_Click({ Copy-DisplayedExecutionLog $script:DrOutput $script:CopyDrLogBtn })
$script:CopyOperationLogBtn.Add_MouseLeave({ $script:CopyOperationLogBtn.Text = 'Copy Log' })
$script:CopyDrLogBtn.Add_MouseLeave({ $script:CopyDrLogBtn.Text = 'Copy Log' })
$script:CopyLogHelp = New-Object System.Windows.Forms.ToolTip
$script:CopyLogHelp.SetToolTip($script:CopyOperationLogBtn,'Copies all text in the on-screen execution log, including lines outside the visible scroll area. Log viewer may cap very large logs.')
$script:CopyLogHelp.SetToolTip($script:CopyDrLogBtn,'Copies all text in the on-screen DR log, including lines outside the visible scroll area. Log viewer may cap very large logs.')
$script:DrBackupBtn.Add_Click({ Execute-DrOperation 'backup' })
$script:DrVerifyBtn.Add_Click({ Execute-DrOperation 'verify_backup' })
$script:DrFullBtn.Add_Click({ Execute-DrOperation 'full_recovery' })
$script:DrContinuityBtn.Add_Click({ Execute-DrOperation 'continuity_snapshot' })
$script:DrRestoreBtn.Add_Click({ Execute-DrOperation 'test_restore' })
$script:DrDestroyBtn.Add_Click({ Execute-DrOperation 'destroy_test' })
$script:DrListBtn.Add_Click({ Execute-DrOperation 'list_snapshots' })
$script:OpenLogsBtn.Add_Click({ Open-SelectedHandoffFolder $script:LogList })
$script:DrOpenLogsBtn.Add_Click({ Open-SelectedHandoffFolder $script:DrLogList })
$script:RefreshLogsBtn.Add_Click({ Refresh-LogHandoff })
$script:DrRefreshLogsBtn.Add_Click({ Refresh-LogHandoff })
$saveSettings.Add_Click({ Save-SelectedSettings })
$script:CurrentLogLabel.Add_MouseDown({ if ($script:CurrentLogLabel.Tag) { Start-FileDrag $script:CurrentLogLabel ([string]$script:CurrentLogLabel.Tag) } })
$script:CurrentOutputLabel.Add_MouseDown({ if ($script:CurrentOutputLabel.Tag) { Start-FileDrag $script:CurrentOutputLabel ([string]$script:CurrentOutputLabel.Tag) } })
$script:DrCurrentLogLabel.Add_MouseDown({ if ($script:DrCurrentLogLabel.Tag) { Start-FileDrag $script:DrCurrentLogLabel ([string]$script:DrCurrentLogLabel.Tag) } })
$script:DrCurrentOutputLabel.Add_MouseDown({ if ($script:DrCurrentOutputLabel.Tag) { Start-FileDrag $script:DrCurrentOutputLabel ([string]$script:DrCurrentOutputLabel.Tag) } })
$script:LogList.Add_ItemDrag({
    param($sender,$eventArgs)
    Start-HandoffSelectionDrag $sender ([System.Windows.Forms.ListViewItem]$eventArgs.Item)
})
$script:DrLogList.Add_ItemDrag({
    param($sender,$eventArgs)
    Start-HandoffSelectionDrag $sender ([System.Windows.Forms.ListViewItem]$eventArgs.Item)
})

$timer=New-Object System.Windows.Forms.Timer
$timer.Interval=500
$timer.Add_Tick({
    if (-not $script:RunContext) { return }

    # Finalization has priority over UI rendering. A display/read exception must
    # never prevent a completed process from being finalized.
    try {
        if ($script:Process -and $script:Process.HasExited) {
            Finalize-ManagedOperation
            return
        }
    }
    catch {}

    try {
        $logItem = Get-Item -LiteralPath $script:RunContext.LogPath -ErrorAction SilentlyContinue
        if ($null -ne $logItem -and $logItem.Length -ne $script:LastObservedLogLength) {
            $script:LastObservedLogLength = $logItem.Length
            $text = Read-TextShared $script:RunContext.LogPath
            if ($text -ne $script:LastLogText) {
                $box = $script:RunContext.OutputBox
                Update-LiveLogBox $box $text
            }
        }
    }
    catch {}
})
$form.Add_FormClosing({
    Watch-PromptHtmlChanges
    if ($script:PromptDirty -and -not $script:PromptIsNew -and -not [string]::IsNullOrWhiteSpace($script:PromptCurrentId)) {
        [void](Save-CurrentPrompt -Silent -SkipRefresh)
    }
    if ($script:Process -and -not $script:Process.HasExited) { Kill-ProcessTree $script:Process.Id }
})

Refresh-Applications
Refresh-LogHandoff
Load-LatestOperationView
Initialize-PromptLibrary
Refresh-PromptLibrary

if ($SmokeTest) {
    Write-Host '[PASS] Full Windows Forms UI construction smoke test.'
    try { $timer.Dispose() } catch {}
    try { if ($null -ne $script:PromptAutoSaveTimer) { $script:PromptAutoSaveTimer.Dispose() } } catch {}
    try { if ($null -ne $script:PromptBrowserPollTimer) { $script:PromptBrowserPollTimer.Dispose() } } catch {}
    try { $form.Dispose() } catch {}
    exit 0
}

$timer.Start()
Update-MainResponsiveLayout
Update-OperationsResponsiveLayout
Update-DrResponsiveLayout
Apply-Theme $script:ThemeMode
Refresh-InstalledStatusStrip
[void]$form.ShowDialog()
