$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$manager = Join-Path $root 'Manager.ps1'
$config = Join-Path $root 'config.default.json'
$testZip = Join-Path $root 'TEST_PACKAGE\PON_Manager_PS_Test_1012.0900.zip'
$versionFile = Join-Path $root 'VERSION.txt'
$displayVersion = if (Test-Path -LiteralPath $versionFile) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { 'Application Operations Manager PS' }

Write-Host '============================================================'
Write-Host ($displayVersion.ToUpperInvariant() + ' - PREFLIGHT')
Write-Host '============================================================'

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($manager,[ref]$tokens,[ref]$errors)
if (@($errors).Count -gt 0) {
    Write-Host '[FAIL] Manager.ps1 PowerShell parser errors:'
    foreach ($e in @($errors)) { Write-Host ('  ' + $e.Message + ' at ' + $e.Extent.StartLineNumber) }
    exit 1
}
Write-Host '[PASS] Manager.ps1 parses under this Windows PowerShell.'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Write-Host '[PASS] Required Windows/.NET assemblies loaded.'

$cfg = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
if (@($cfg.applications).Count -lt 2) { throw 'Default configuration does not contain PON and CALC.' }
if ($null -eq $cfg.PSObject.Properties['storage']) { throw 'Default configuration does not contain Storage & Paths settings.' }
foreach ($name in @('temp_folder','output_folder','logs_folder','archive_folder','auto_clean_temp_after_success')) {
    if ($null -eq $cfg.storage.PSObject.Properties[$name]) { throw "Default storage configuration missing $name." }
}
Write-Host '[PASS] Default configuration JSON + Storage & Paths.'

if (-not (Test-Path -LiteralPath $env:ComSpec -PathType Leaf)) { throw 'cmd.exe not found through COMSPEC.' }
Write-Host ('[PASS] cmd.exe: ' + $env:ComSpec)

if (-not (Test-Path -LiteralPath $testZip -PathType Leaf)) { throw 'Bundled test package not found.' }
$zip = [System.IO.Compression.ZipFile]::OpenRead($testZip)
try {
    $names = @($zip.Entries | ForEach-Object { $_.FullName })
    foreach ($name in @('PACKAGE_INFO.json','01_Apply_Manager_Test.bat','02_Verify_Manager_Test.bat','03_Rollback_Manager_Test.bat','04_Continuity_Manager_Test.bat')) {
        if ($names -notcontains $name) { throw "Bundled test ZIP missing $name" }
    }
}
finally { $zip.Dispose() }
Write-Host '[PASS] Bundled test package structure.'

Write-Host '[INFO] Running full Windows Forms UI construction smoke test...'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager -SmokeTest
if ($LASTEXITCODE -ne 0) {
    throw "Manager UI construction smoke test failed with exit code $LASTEXITCODE."
}
Write-Host '[PASS] Full Windows Forms UI construction smoke test.'

Write-Host ''
Write-Host 'PREFLIGHT RESULT: PASS'
exit 0
