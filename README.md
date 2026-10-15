## v1.0.3 process lifecycle markers

- Each run log now contains an explicit `[AOM] PROCESS STARTED` block with `STATUS: RUNNING` and start time.
- The same log ends with `[AOM] PROCESS FINISHED`, exit code, result, finish time, and duration.
- The viewer forces one final refresh after writing the footer, so completion is visible on screen rather than only on disk.
- Execution engine remains unchanged.


## v1.0.3 interface/live-log fixes

- Restores `ALLOW MULTIPLE RUNS` in a permanently visible position below the header.
- Operations, Disaster Recovery and Settings tabs now support vertical scrolling.
- Live output appends only new log content and forcibly follows the latest line.
- AI handoff run-log area is restored below the output, with current/recent `.log` files draggable to ChatGPT.
- During a running operation, the handoff list refreshes so the current log remains available immediately.
- The proven CMD -> .log execution engine is unchanged.
# Application Operations Manager PS v1.0.3

## v1.0.3 startup fix

- Replaces all `System.Drawing.Point` / `System.Drawing.Size` `New-Object` constructor calls with PowerShell 5.1-safe `.NET ::new(...)` construction, including the Settings-tab arithmetic coordinate that failed on Windows.
- Preflight now runs a full **Windows Forms UI construction smoke test** before launching the Manager, so runtime form-construction errors are caught before the main GUI starts.


This version intentionally removes the Python/PySide execution stack.

It is built entirely on Windows PowerShell 5.1 + Windows Forms and uses the exact process-launch mechanism that was manually proven on the target Windows PC in AOM Core Log Runner v0.3:

```text
PowerShell GUI
  -> .NET ProcessStartInfo
  -> cmd.exe
  -> temporary CMD wrapper
  -> BAT/CMD/PS1
  -> stdout + stderr redirected directly to one .log
  -> GUI reads that same .log every 150 ms
```

## Why this version exists

The Python Manager repeatedly stalled before the child script started. The run logs proved the failure occurred between the Python/Qt launcher and `cmd.exe`.

This version removes that layer completely.

## Start

Double-click:

```text
Open_Manager.bat
```

If the PowerShell GUI cannot start, the console remains open so the startup error can be read.

## Run logs

Logs are stored under:

```text
%LOCALAPPDATA%\ApplicationOperationsManagerPS\LOGS
```

Names follow:

```text
PON_Bikes_Automation_YYYYMMDD_HHMMSS.log
CALC_Calculator_App_YYYYMMDD_HHMMSS.log
```

The Operations and Disaster Recovery tabs show the current and recent `.log` files. They can be dragged directly to ChatGPT.

## Input handling

Routine UPDATE and non-destructive DR actions are started with one blank input line pre-fed so a normal final `pause` completes automatically.

Known interactive DR operations are handled before launch:

- Destroy isolated test: the Manager asks for `DESTROY PON` / `DESTROY CALC` and pre-feeds it to the script.
- Create FULL Recovery Folder: the Manager asks for the snapshot/path and pre-feeds it.

## Test package

A non-destructive test ZIP is included:

```text
TEST_PACKAGE\PON_Manager_PS_Test_1012.0900.zip
```

Use Browse in the Operations tab and run APPLY first. Expected:

```text
[PASS] Live output stage 1/3
[WARN] Intentional STDERR line
[PASS] Live output stage 3/3
APPLY RESULT: PASS
ACTION RESULT: PASS
Press any key to continue . . .
[PASS] PAUSE acknowledgement received.
SCRIPT RESULT: PASS
[AOM] RESULT: PASS
```

No manual Enter should be required.

## Safety

- `ALLOW MULTIPLE RUNS` is off by default.
- APPLY is persistently locked after an attempt for the same ZIP SHA256 unless multiple-run mode is deliberately enabled.
- Repeating APPLY in multiple-run mode requires explicit confirmation.
- Verified packages are archived only after an Apply attempt followed by Verify PASS.
- Only one operation can run at a time.
- CANCEL terminates the process tree.

## Configuration

The first launch copies the bundled `config.default.json` to:

```text
%LOCALAPPDATA%\ApplicationOperationsManagerPS\config.json
```

The Settings tab edits the selected application's main paths and package patterns.


## v1.0.27 UI/log additions
- Clear `TARGET APPLICATION` and `SELECTED SCRIPT PACKAGE` labels.
- Package summary explicitly identifies both the target application and selected ZIP.
- Live output colours: PASS green, WARN yellow/goldenrod, FAIL/error red.
- Physical `.log` files remain plain text for AI handoff.
- ZIP-only execution boundary and one-run ALLOW MULTIPLE RUNS reset are retained from v1.0.4.


## v1.0.27 package-selection corrections
- Refresh preserves the currently selected ZIP if it still exists.
- The package dropdown discovers and shows ALL ZIP files in the configured package folder.
- An explicitly browsed ZIP remains in the list even if it is outside that folder.
- `package_patterns` no longer hide ZIPs or block script-discovery packages.
- Packages without `PACKAGE_INFO.json` are no longer labelled/blocked as Legacy.
- Only explicit contradictory `application_id` metadata blocks execution.
- Execution still remains strictly inside the selected ZIP.

## v1.0.27
- Persistent DAY/NIGHT toggle on main screen.
- Theme is visual only; execution/package/DR logic unchanged.
- Existing semantic PASS/WARN/FAIL live-log colours retained.


## v1.0.27 startup/preflight correction
- Fixes the PowerShell parser error introduced in v1.0.7 at the final ShowDialog call.
- `Apply-Theme` and `ShowDialog()` are now separate PowerShell statements.
- `Open_Manager.bat` reads the displayed version from VERSION.txt.
- `00_Preflight.ps1` reads the displayed version from VERSION.txt.
- Corrects the DAY/NIGHT base-colour reference for the Operations RichTextBox.
- All v1.0.6 ZIP-only package-selection safety and v1.0.7 theme functionality remain retained.


## v1.0.27 theme-state path correction
- Fixes the UI smoke-test failure caused by using undefined `$StateRoot`.
- Theme persistence now uses the Manager's existing `$StateDir`:
  `%LOCALAPPDATA%\ApplicationOperationsManagerPS\STATE\theme.txt`
- DAY/NIGHT remains UI-only.
- Execution engine, ZIP-only execution, Refresh behaviour, DR behaviour,
  coloured log rendering and multiple-run reset are unchanged.


## v1.0.27 resolved-script display
This version is based directly on v1.0.9. The experimental v1.1.0/v1.1.1
quick-run branch is not included.

Operations UI changes:
- APPLY / VERIFY / ROLLBACK / CONTINUITY SNAPSHOT buttons keep their existing names.
- The exact script mapped to each operation is shown directly above its button.
- If an operation is unavailable, the label says `Not available`.
- Detected script labels use green text; unavailable labels use grey.
- Scripts present in the selected ZIP but not mapped to one of the four standard
  operations are listed under `OTHER PACKAGE SCRIPTS`.
- Existing execution behaviour is unchanged: standard buttons execute their
  existing mapped operation.
- ZIP-only safety, Refresh selection preservation, coloured live logs,
  ALLOW MULTIPLE RUNS reset and DAY/NIGHT mode are retained.


## v1.0.27 Quick Script Buttons
Built directly from v1.0.10.

- Adds `QUICK SCRIPT BUTTONS` to Operations.
- Each executable `.bat`, `.cmd` or `.ps1` inside the selected ZIP gets its own numbered button.
- One click on a numbered button executes that exact ZIP-relative script.
- Standard APPLY / VERIFY / ROLLBACK / CONTINUITY SNAPSHOT controls remain below.
- Execution remains strictly ZIP-only.
- Explicit package/application metadata mismatch is still blocked.
- The existing live coloured log, lifecycle footer, draggable logs and DAY/NIGHT theme are reused.
- `ALLOW MULTIPLE RUNS` returns to OFF after a direct script launch.
- Quick-script buttons are disabled while another process is running.


## v1.0.27 compact Operations layout
Built directly from v1.0.11.

UI-only changes:
- Selected-package details are compact and positioned at the upper-left.
- Quick numbered script buttons are positioned directly beside package details at upper-right.
- Standard APPLY / VERIFY / ROLLBACK / CONTINUITY / CANCEL buttons remain in one compact row.
- The mapped-script `Not available` labels are hidden.
- `OTHER PACKAGE SCRIPTS` is hidden because Quick Script Buttons already expose every executable script.
- The live script output now spans the full Operations width and receives substantially more vertical space.
- The live output anchors to all four sides so it expands with the window.
- AI handoff remains below the live output and accessible by scrolling.
- No execution, package-selection, safety, logging, colour, theme, DR, or multiple-run logic was changed.


## v1.0.27 responsive layout
Built directly from v1.0.12.

- Operations controls recalculate position and width when the window is resized.
- Package selector, Refresh and Browse stay within the available width.
- Package Details and Quick Script Buttons are side-by-side on normal/wide windows.
- On narrower windows, those blocks stack vertically instead of clipping.
- Quick Script buttons resize with their panel.
- APPLY / VERIFY / ROLLBACK / CONTINUITY / CANCEL divide the width evenly.
- Status, output and AI handoff stay within the current window width.
- AI handoff child controls also reflow.
- Hidden duplicated `Not available` / Other Package Scripts UI remains hidden.
- This patch does not redesign the script-output height behavior.
- Execution and safety logic are unchanged.


## v1.0.27 responsive output + persistent last run + improved night mode
Built directly from v1.0.13.

- Live script output now grows/shrinks vertically with the Operations tab.
- AI handoff remains visible below it instead of being pushed off-screen.
- Package/quick-button responsive behaviour from v1.0.13 is retained.
- Night mode uses a darker, cleaner palette with higher text contrast.
- On startup and when switching application, the latest run log is loaded automatically into the live output.
- The latest draggable log is also refreshed, so the previous operation remains visible immediately after opening the app.
- No execution-engine, ZIP-only safety, DR, or package-selection logic was changed.


## v1.0.27 OpenLogs button initialization fix
Built directly from v1.0.14.

- Fixes startup failure under PowerShell StrictMode caused by reading
  `$script:OpenLogsBtn` before it had been created.
- Initializes `$script:OpenLogsBtn = $null` before UI construction.
- Responsive layout also checks that the variable exists before using it.
- If the handoff Open Logs button is present, it is stored in script scope so
  responsive positioning can safely access it.
- No execution engine, ZIP-only safety, DR, package-selection, theme, log-colour,
  or Quick Script behavior was changed.


## v1.0.27 Test-Path condition fix
Built directly from v1.0.15.

- Fixes runtime failure caused by PowerShell parsing `-and` as a Test-Path parameter.
- The optional Open Logs button check now correctly groups the Test-Path expression:
  `if ((Test-Path variable:script:OpenLogsBtn) -and ($null -ne $script:OpenLogsBtn))`
- No execution-engine, responsive-layout, ZIP-only safety, theme, logging,
  DR, package-selection, or Quick Script logic was changed.


## v1.0.27 ZIP execution history + Quick-Script-only Operations
Built directly from v1.0.16.

- Every completed package-controlled execution saves a copy of its run log back
  inside the selected ZIP under:
  `EXECUTION_LOGS/<script>/<timestamp>_<PASS|FAIL|CANCELLED>.log`
- The Manager's normal external `.log` remains available for drag/drop and diagnostics.
- Quick-script single-run protection is now path/script based rather than SHA based,
  because embedding logs changes the ZIP hash after each run.
- APPLY / VERIFY / ROLLBACK / CONTINUITY SNAPSHOT are removed from the visible
  Operations workflow.
- Quick Script Buttons are the primary one-click execution mechanism.
- CANCEL remains visible and available while a process is running.
- Responsive layout, last-run loading, improved night mode, log colours,
  ZIP-only execution and DR behaviour are retained.


## v1.0.27 Refresh selects newest package
Built directly from v1.0.17.

- Pressing `Refresh` rescans ZIP packages and orders them by `LastWriteTime` descending.
- The newest ZIP is always selected automatically after Refresh.
- A package chosen with `Browse...` remains selected until Refresh is pressed.
- No execution, logging, ZIP-history, responsive-layout, theme, DR, or safety logic changed.


## v1.0.27 horizontal Quick Script Buttons
Built directly from v1.0.18.

- Quick Script Buttons now render left-to-right in a single horizontal row.
- Buttons are numbered and show the exact script filename.
- More than four scripts continue to the right of the existing buttons.
- If the row exceeds the visible panel width, the Quick Scripts area provides horizontal scrolling.
- The Quick Scripts panel uses less vertical space.
- Execution, ZIP-history logging, newest-on-Refresh behaviour, responsive layout,
  theme, DR and safety logic are unchanged.


## v1.0.27 Quick Script buttons in vertical columns
Built directly from v1.0.19.

- Replaces the single horizontal row of Quick Script buttons.
- Quick Script buttons now render in vertical columns:
  1..4 in the first column, 5..8 in the second column, 9..12 in the third column, and so on.
- The Quick Scripts panel is tall enough to show four rows clearly.
- Additional columns extend to the right; the panel provides horizontal scrolling if required.
- Execution, ZIP-history logging, newest-on-Refresh behaviour, responsive layout,
  theme, DR and safety logic remain unchanged.


## v1.0.27 Storage & Paths + permanent script outputs
Built directly from v1.0.20.

### Settings > Storage & Paths
Manager-wide configurable folders:
- Temporary Working Folder
- Permanent Script Output Folder
- Execution Logs Folder
- Optional automatic TEMP cleanup after successful runs

Each path has Browse and Open controls.

Defaults:
- `%APP_HOME%\TEMP`
- `%APP_HOME%\OUTPUT`
- `%APP_HOME%\LOGS`

Existing config files are migrated in memory with these defaults.

### Permanent script outputs
After an extracted package script finishes, the Manager scans folders named
`OUTPUT` inside that run's temporary extraction folder. Files created or
updated during the run are copied to:

`OUTPUT\<Application>\<Package>\<YYYYMMDD_HHMMSS>_<Script>_<Result>\`

The original relative path under the extracted package is preserved. Each
permanent run folder also contains `_AOM_RUN_INFO.txt`.

The Manager appends the permanent output path to its execution log.

### TEMP cleanup
If `Automatically clean the temporary extracted run folder after a successful run`
is enabled, the run's extracted folder is deleted only after generated OUTPUT
files have been copied and the Manager execution log has been saved into the ZIP.

Execution engine, ZIP-only safety, Quick Script Buttons, newest-on-Refresh,
night mode, responsive Operations layout and DR behaviour remain unchanged.


## v1.0.27 Package archive workflow
Built directly from v1.0.21.

### ARCHIVE ZIP
Operations now includes an `ARCHIVE ZIP` button beside Refresh and Browse.

The selected ZIP is moved to:

`<Package Archive Folder>\<Application ID>\<YYYY-MM>\`

Default Package Archive Folder:

`%USERPROFILE%\Downloads\AOM_Archive`

If a file with the same name already exists, a timestamp is added to the archived filename.

After a successful archive:
- the old selection is cleared,
- packages are rescanned,
- the newest remaining active ZIP is automatically selected.

Archived ZIPs keep all execution logs already embedded in them.

### Settings
`Package Archive Folder` is now available in Settings > Storage & Paths with
Browse and Open controls.

The archive is intentionally a subfolder of Downloads by default. Package discovery
only scans ZIP files directly in the configured active package folder, so archived
packages do not clutter the active package selector.

No script execution, generated-output preservation, DR, night mode or ZIP-log
history behaviour was changed.


## v1.0.27 Responsive layout fix
Built directly from v1.0.22. This is a layout-only patch and retains the
ARCHIVE ZIP / package-move workflow.

### Fixed
- TARGET APPLICATION, application selector and NIGHT/DAY MODE reflow correctly
  when the main window becomes narrower.
- The main tab area resizes from the actual form client size instead of relying
  on conflicting WinForms anchors.
- Refresh, Browse and ARCHIVE ZIP remain fully inside the Operations tab.
- Package Details and Quick Script Buttons continue to use responsive side-by-side
  or stacked layouts.
- Live script output resizes vertically while reserving visible space for AI handoff.
- Current draggable log, recent log list, Open Logs Folder and Refresh Logs all
  resize/reposition together.
- Both bottom-right log buttons are now part of responsive layout rather than
  retaining fixed coordinates.
- The Disaster Recovery output/log handoff area receives the same right-side
  button and resizing fix.
- Key controls remain visible without clipping at the supported minimum window size.

### Retained from v1.0.22
- ARCHIVE ZIP moves the selected ZIP to the configured package archive.
- Package Archive Folder setting.
- newest package selected on Refresh.
- execution logs embedded back into ZIPs.
- generated OUTPUT preservation.
- Quick Script buttons in four-row columns.
- execution engine, ZIP-only safety, DR behaviour and night mode.


## v1.0.27 Settings Open Folder buttons
Built directly from v1.0.23, so the responsive-layout fix and ARCHIVE ZIP workflow
are retained.

### Application settings
Adds `Open Folder` buttons for:
- Application path
- Package folder
- Verified package folder
- Legacy DR Toolkit

The folder is opened directly in Windows File Explorer using the current value
shown in the setting field.

### Storage & Paths
Existing Open buttons are renamed to `Open Folder` for clarity:
- Temporary Working Folder
- Permanent Script Output Folder
- Execution Logs Folder
- Package Archive Folder

Browse remains available where already supported.

No execution, ZIP logging, package archive, output preservation, Quick Script,
DR or safety logic changed.


## v1.0.27 Disaster Recovery Quick Script Buttons
Built directly from v1.0.24.

### Disaster Recovery tab
The DR tab now follows the same user-facing model as Operations:

- Detects DR operations from the currently selected ZIP.
- Shows the exact mapped script filenames as one-click buttons.
- Uses four vertical buttons per column, then continues in a new column.
- Provides horizontal scrolling when additional columns are required.
- Rebuilds automatically when the selected package changes.
- Respects single-run / Allow Multiple Runs behaviour.
- Disables DR quick buttons while another operation is running.

The original semantic DR buttons remain internally available for compatibility
but are hidden from the UI.

### Safety retained
DR quick buttons do NOT bypass the existing DR execution path. They call the
same `Execute-DrOperation` function, so:
- ZIP-only execution remains enforced.
- application-specific PON/CALC script checks remain enforced.
- Destroy Isolated Test still requires the exact DESTROY confirmation.
- Create FULL Recovery still requests the recovery source/snapshot.
- generated outputs, execution logs and cancellation continue unchanged.

### Retained from v1.0.24
- responsive layout fix
- ARCHIVE ZIP package-move workflow
- Settings Open Folder buttons
- permanent generated OUTPUT preservation
- ZIP execution-log history
- Quick Script buttons in Operations
- newest-on-Refresh behaviour


## v1.0.27 Disaster Recovery visible-button correction
Built directly from v1.0.25.

v1.0.25 incorrectly hid the original Disaster Recovery controls and made the
DR Quick Script panel the primary surface. This caused the DR tab to appear
empty whenever the currently selected ZIP contained no recognised DR scripts.

### Corrected behaviour
The six DR controls are always visible:
- Backup
- Verify Latest Backup
- Create FULL Recovery Folder
- Test Restore Latest
- Destroy Isolated Test
- List Snapshots

Each button is enabled only when the selected ZIP contains the corresponding
DR script. If an ordinary Operations/update ZIP is selected, the DR buttons
remain visible but disabled.

This preserves the important ZIP-only execution boundary while making the
interface understandable.

### Safety retained
- No fallback to the production DR toolkit.
- Destroy confirmation remains mandatory.
- FULL Recovery input remains mandatory.
- single-run / Allow Multiple Runs remains enforced.
- responsive output/log handoff remains fixed.
- ARCHIVE ZIP, Settings Open Folder, generated OUTPUT preservation,
  embedded ZIP logs and Operations Quick Script buttons remain unchanged.


## v1.0.27 Disaster Recovery fixed-toolkit correction
Built directly from v1.0.26.

The Disaster Recovery tab is now intentionally independent from the selected
Operations ZIP.

### DR source
DR executes directly from the configured toolkit folder for the selected
application. The default configuration points both PON and CALC to:

`C:\Docker-Projects\DR_Toolkit_CALC_PON`

The exact script names continue to come from each application's `dr_scripts`
mapping in config.json.

### Behaviour
- DR buttons are always visible.
- Each button is enabled when its configured BAT exists in the DR toolkit folder.
- Selecting, browsing, refreshing or archiving an Operations ZIP does not disable DR.
- Switching TARGET APPLICATION switches the DR mapping between PON and CALC.
- DR scripts run in place from the permanent toolkit; they are not copied into TEMP.
- DR execution logs remain in the Manager LOGS folder.
- No DR log is embedded into the Operations ZIP because DR is not package driven.

### Safety
- Destroy Isolated Test still requires exact `DESTROY PON` / `DESTROY CALC`.
- FULL Recovery still asks for its recovery source.
- single-run / Allow Multiple Runs protection remains active.
- TEMP cleanup can never delete the permanent DR toolkit because DR passes no
  WorkRoot to the cleanup routine.

### Settings
`Legacy DR Toolkit (NOT EXECUTED by Manager)` is renamed to:

`Disaster Recovery Toolkit Folder`

and retains its Open Folder button.

Operations remains ZIP-only and is otherwise unchanged.


## v1.0.28 trustworthy execution-state colours + package version confirmation
Built directly from v1.0.27.

### Script button states
Operations Quick Script buttons and Disaster Recovery buttons now use:
- neutral/grey = not executed
- amber = currently running
- green = completed PASS / exit code 0
- red = completed FAIL or CANCELLED

A button becomes green only after the process has actually finished successfully.
Clicking alone never produces a PASS state.

Execution results are stored persistently under:
`%LOCALAPPDATA%\ApplicationOperationsManagerPS\STATE\execution_states.json`

Therefore PASS/FAIL colours survive Manager restarts.

### Stable package identity
Package execution state does not use the mutable ZIP SHA because AOM inserts execution
logs into the ZIP after a run. Instead, AOM derives a stable identity from the ZIP's
non-`EXECUTION_LOGS` entries, so adding AOM history does not make the same package look new.

### Version confirmation strip
Operations now shows a dedicated line above the package details:
- `VERSION: <release>`
- `NOT EXECUTED`
- `RUNNING — <script>`
- `✓ EXECUTED / PASS — <script>`
- `✕ EXECUTED / FAIL — <script>`

When the latest execution for that exact package passes, the version and confirmation
are green. This makes it clear which package/version was actually executed.

`RELEASE_VERSION.txt` / package release metadata is preferred. If unavailable, AOM
extracts a release-like token such as `1012.1615` from the ZIP filename.

### DR
DR remains independent from Operations ZIPs and continues to execute the fixed toolkit
configured for the selected application. DR buttons receive the same persistent
running/PASS/FAIL visual states.

All v1.0.27 execution, safety, responsive-layout, ARCHIVE ZIP, Open Folder and output/log
behaviour is retained.


## v1.0.29 compact current-installed status strip
Built directly from v1.0.28.

### Top-screen installed status
A compact status strip now uses the existing unused header band beside
`ALLOW MULTIPLE RUNS`. No additional panel or vertical section was added.

Example:
`INSTALLED: 1012.1745 ✓ PASS | 02_Apply_Update.bat | 13 Oct 2026 08:25`

The strip changes when `TARGET APPLICATION` changes, so PON and CALC keep
independent installed-state records.

### What counts as installed
A package becomes the current installed version only after the exact script
that AOM has mapped as the package `apply` operation finishes with exit code 0.

Running Verify, Read Only, DB Check, Backup, Disaster Recovery or another package
script never changes CURRENT INSTALLED.

This also works when the mapped Apply script is launched through the one-click
Quick Script Buttons rather than the hidden legacy APPLY control.

### Failed APPLY protection
A failed or cancelled Apply does not overwrite the last known-good installed
version. Instead the known-good green line remains and a compact red indicator
appears at the right:

`LAST APPLY FAIL: <version> | <script>`

### Persistence
Installed state is stored per target application in:

`%LOCALAPPDATA%\ApplicationOperationsManagerPS\STATE\installed_states.json`

It survives Manager restarts.

All v1.0.28 button colours, selected-package version state, fixed-toolkit DR,
responsive layout, ARCHIVE ZIP, Open Folder and logging behaviour are retained.


## v1.0.30 Windows PowerShell parser fix
Built directly from v1.0.29.

Corrected the invalid interpolated string in the LAST APPLY warning:

`"LAST APPLY $lastResult: $failedVersion"`

to:

`"LAST APPLY ${lastResult}: $failedVersion"`

This is required by Windows PowerShell 5.1 when a variable inside a
double-quoted string is immediately followed by a colon.

No functional behaviour from v1.0.29 was otherwise changed.


## v1.0.31 Disaster Recovery Continuity Snapshot
Built directly from v1.0.30.

Adds a new `Continuity Snapshot` action to the Disaster Recovery tab.

Fixed DR Toolkit mapping:
- PON: `07_Create_Continuity_Snapshot_PON.bat`
- CALC: `07_Create_Continuity_Snapshot_CALC.bat`

The selected TARGET APPLICATION chooses the correct script automatically.
DR remains independent from the Operations ZIP.

DR layout now uses a compact 4-column x 2-row grid:
- Row 1: Backup | Verify Latest Backup | Create FULL Recovery Folder | Continuity Snapshot
- Row 2: Test Restore Latest | Destroy Isolated Test | List Snapshots | CANCEL

Continuity Snapshot uses the same persistent state colours:
neutral = not run, amber = running, green = PASS, red = FAIL/CANCELLED.

Existing config files are backward-compatible. If `continuity_snapshot` is absent,
AOM adds the correct PON/CALC mapping in memory without changing unrelated settings.


## v1.0.32 generated-output handoff + persistent target application
Built directly from v1.0.31.

### Generated files in the run log
AOM now records the exact permanent path of generated output files.

ZIP outputs are highlighted as:

`[PASS] ZIP READY FOR AI: <full path>`

The log also records:
- generated ZIP full path
- ZIP size
- ZIP SHA256
- final output result

For normal Operations packages, AOM reports the files after they are copied to
the configured permanent OUTPUT folder.

For fixed-toolkit Disaster Recovery runs, which intentionally have no temporary
WorkRoot, AOM detects newly created files under the permanent DR Toolkit OUTPUT
tree and reports their actual paths directly.

This does not change the proven process execution engine.

### Persistent TARGET APPLICATION
AOM now stores the last selected target application in:

`%LOCALAPPDATA%\ApplicationOperationsManagerPS\STATE\selected_application.txt`

If CALC was selected when AOM was closed, CALC is selected next time it starts.
The same applies to PON.

All v1.0.31 Continuity Snapshot, DR fixed-toolkit, execution-state colours,
installed-version strip, responsive layout, archive and logging behaviour are retained.


## v1.0.33 AI / Support Handoff: generated ZIP/file
Built directly from v1.0.32.

The handoff panel now exposes two separate draggable items:
- latest run LOG;
- generated ZIP/file from the latest run.

For a successful Continuity Snapshot the generated-file area displays:
`ZIP READY FOR AI`
`<snapshot>.zip`
`DRAG FILE TO CHATGPT`

AOM reads the exact final output path from its own completed log and only enables
the generated-file drag target when that file still exists.

Persistent TARGET APPLICATION (CALC/PON) from v1.0.32 is retained.
Core Runner v0.3 is unchanged.


## v1.0.34 — AI Dev Toolkit
Built directly from v1.0.33.

### New visible application name
The main window title and on-screen heading are now:
`AI Dev Toolkit`

The existing `%LOCALAPPDATA%\ApplicationOperationsManagerPS` state/config location
is intentionally retained so installed settings, selected target application,
history, logs and paths remain compatible.

### Transient action-button colours
Action colours no longer accumulate across several buttons.

When a new action starts:
- every other action button immediately returns to its neutral colour;
- only the current action is amber while running;
- only that latest action becomes green PASS or red FAIL/CANCELLED when finished;
- changing TARGET APPLICATION clears the transient action colour.

Execution history is still retained internally; this change only affects the button UI.

### UI freeze protection
The physical run `.log` is still complete and unchanged.

To reduce WinForms UI stalls during large or verbose scripts:
- live polling changed from 150 ms to 500 ms;
- AOM checks log file length before rereading it;
- the on-screen RichTextBox is capped at the latest 200,000 characters;
- process-exit finalisation is checked before log repainting, so a display error
  cannot prevent a completed process from being finalised.

Core Runner v0.3 process execution remains unchanged.


## v1.0.35 — black/bold package status strip
Built directly from v1.0.34.

The top Operations package status strip now uses black bold text for both:
- `VERSION: <release>`
- execution status such as `RUNNING`, `PASS`, `FAIL`, `CANCELLED`, or `NOT EXECUTED`

The previous amber/green/red text colours were removed from this strip.
Execution state remains visible in the status wording and in the action-button colours.

No process execution, DR, Continuity Snapshot, AI handoff, target persistence,
freeze-protection or package-selection logic was changed.


## v1.0.36 — consolidated UI/status build
Built directly from v1.0.35.

This release consolidates the latest requested UI behaviour into one baseline:

- Visible application name: `AI Dev Toolkit`.
- Package VERSION text is always black and bold.
- Package execution status text is always black and bold.
- Action button colours are transient:
  only the current/latest action keeps RUNNING/PASS/FAIL colouring.
- Starting another action returns previous action buttons to neutral.
- Switching CALC/PON clears transient action colouring.
- Last selected TARGET APPLICATION persists across app restarts.
- Live-log freeze protection remains enabled:
  500 ms polling, file-length gate, and capped on-screen log rendering.
- Physical `.log` files remain complete.
- Generated ZIP/file AI handoff remains available as a draggable file.
- Disaster Recovery Continuity Snapshot remains available.
- Core Runner v0.3 execution architecture remains unchanged.

This is the new consolidated baseline for subsequent AI Dev Toolkit releases.


## v1.0.37 — branding simplification
Built directly from v1.0.36.

The application branding is now simply:

`AI Dev Toolkit`

Changes:
- Main window title: `AI Dev Toolkit v1.0.37`
- Main on-screen heading: `AI Dev Toolkit`
- Package naming: `AI.DevToolkit.v1.0.37.zip`
- Documentation references updated to remove the personal name.

The existing `%LOCALAPPDATA%\ApplicationOperationsManagerPS` state/config directory
is intentionally unchanged to preserve all current settings, execution history,
selected CALC/PON target, paths, and compatibility.

No execution, DR, Continuity Snapshot, AI handoff, freeze-protection,
button-colour, or package-status behaviour was changed.


## v1.0.38 — guaranteed process finalisation / UI unlock
Built directly from v1.0.37.

This release fixes a reproduced stuck-RUNNING condition where:
- the physical log already contained `[AOM] PROCESS FINISHED`;
- the child script had returned an exit code;
- the Toolkit still showed `RUNNING / process active`;
- Refresh, Browse and Archive ZIP remained disabled.

Root cause:
`Finalize-ManagedOperation` marked the run as finalised before all post-run work had
completed. If a later post-processing step threw an exception, the function could
exit before clearing Process/RunContext and busy state. Because `Finalized` was
already true, the timer would not retry finalisation.

Fix:
- all optional post-run steps are independently guarded;
- final process/UI cleanup runs in a PowerShell `finally` block;
- Process and RunContext are always cleared after child-process completion;
- busy state is always released;
- Refresh/Browse/Archive and target controls receive a direct fallback unlock;
- post-run errors are recorded as `[WARN]` entries instead of stranding the UI;
- Core Runner v0.3 process-launch architecture is unchanged.

All v1.0.37 behaviour remains, including:
black/bold package status text, transient button colours, 500 ms live-log protection,
AI ZIP handoff, target persistence, fixed DR toolkit execution, and Continuity Snapshot.


## v1.0.39 — larger package status text
Built directly from v1.0.38.

The top package status strip has been made significantly easier to read:
- VERSION text: black, bold, 11 pt.
- RUNNING / PASS / FAIL status text: black, bold, 11 pt.
- Status strip height increased from 24 px to 32 px.
- VERSION area widened.
- Both labels are vertically centred.
- Extra spacing added before the package details / Quick Script area.

All v1.0.38 process-finalisation fixes and existing Toolkit behaviour are retained.


## v1.0.40 — unified AI / Support file list
Built directly from v1.0.39.

The bottom AI / Support area is now a single wide file list rather than two large
individual drag boxes.

The list includes:
- recent AOM `.log` files;
- generated `.zip` files referenced by those logs;
- other generated files referenced by those logs, when the files still exist.

Each row is prefixed with `[LOG]`, `[ZIP]`, or `[FILE]` and displays the full
filename. The list supports horizontal scrolling for long filenames.

Any listed file can be selected/dragged directly to ChatGPT.
`Open Selected` opens Windows Explorer with the chosen file selected.
`Refresh Files` rebuilds the list.

The same handoff behaviour is available in Operations and Disaster Recovery.

All v1.0.39 readability improvements and v1.0.38 finalisation protection remain.

## v1.0.41 — branding correction
Built directly from v1.0.40.

The application name is now correctly:

`AI Dev Toolkit`

Updated:
- main on-screen heading;
- Windows title bar;
- version text;
- package filename;
- documentation references.

No functional behaviour changed from v1.0.40.


## v1.0.42 — readable Quick Script buttons
Built directly from v1.0.41.

Quick Script buttons no longer use a fixed 220 px width.

New behaviour:
- preserves the established four-row column order: 1/2/3/4, then 5/6/7/8, etc.;
- measures the longest script filename in the selected package;
- makes the button column wide enough for that name where practical;
- uses the available Quick Scripts panel width for single-column packages;
- supports horizontal scrolling when multiple wide columns are required;
- hovering a button shows the exact full script path/name in a tooltip.

No script execution logic was changed.
All v1.0.41 behaviour is retained.


## v1.0.43 — simplified ARCHIVE ZIP confirmation
Built directly from v1.0.42.

ARCHIVE ZIP now uses one simple confirmation window:
- one primary `ARCHIVE ZIP` button;
- one `Don't ask me again for ARCHIVE ZIP` checkbox;
- the window close `X` cancels the action;
- the previous second `Archive complete` popup has been removed.

If `Don't ask me again` is selected, the preference is persisted under the
existing Toolkit STATE folder and subsequent ARCHIVE ZIP actions run directly.

All v1.0.42 Quick Script button readability improvements and prior functionality
are retained.


## v1.0.44 — compact auto-sized Quick Script buttons
Built directly from v1.0.43.

Quick Script buttons now use compact automatic sizing instead of stretching to
the panel width.

Rules:
- minimum button width: 260 px;
- width grows with the longest script name in each column;
- maximum button width: 460 px;
- long names use ellipsis when needed;
- hover tooltip always shows the complete script path/name;
- four-row column order is retained;
- different columns may have different widths;
- horizontal scrolling appears only when the combined compact columns exceed the panel.

No execution behaviour changed.
#   A I - D e v - T o o l k i t  
 