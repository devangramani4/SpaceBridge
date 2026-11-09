# SpaceBridge — Storage & System Analyzer for macOS

**by Genius Bridge Technologies**

SpaceBridge is a native macOS app (Swift + SwiftUI) that shows exactly what is using your disk, finds large files and folders, analyzes installed apps, monitors RAM/CPU live, and helps you reclaim space safely. Everything runs locally and offline: there is no account, no analytics and no tracking. The free version makes no network connections at all; Pro only contacts the license server to check the license key.

> **Name.** "SpaceBridge" ties the product to the Genius Bridge brand ("bridge" between you and your Mac's storage). Bundle ID: `com.geniusbridge.SpaceBridge`. To rename, edit `APP`/`BUNDLE_ID` in `scripts/generate_xcodeproj.py`, the display name in `SpaceBridge/Resources/Info.plist`, and regenerate. Check trademark availability before you publish.

## Features

| Area | What it does |
|---|---|
| Dashboard | Disk capacity, used, available and purgeable space; file, folder and app counts; largest file and folder; recent large files; storage trend across scans; a category donut you can click |
| Storage | Volumes, category table with how each category is detected, standard locations, and folders marked **Access Restricted** with help on granting access |
| Largest Files | Top 10/50/100/500/custom, filter by category, sort by size, name, dates or type, bar chart, File Details inspector, Reveal in Finder, Copy Path, Move to Trash (with confirmation) |
| Largest Folders | Lazy-loading hierarchical tree with recursive sizes, expand/collapse (←/→), drill-down with breadcrumbs, bar chart |
| Applications | Every `.app` in `/Applications`, `~/Applications` and `/System/Applications`: version, developer (from the signing certificate), bundle ID, architecture (read from the Mach-O header), bundle size, live RAM/CPU including helper processes, last opened (Spotlight), code-signature check, storage breakdown (bundle, data, containers, caches, logs, preferences) |
| Running Apps | PID, CPU %, memory footprint, threads, state and user; Bring to Front, Reveal, Quit and Force Quit (confirmed, critical/system/other-user processes protected) |
| Memory | Total, used, app, wired, compressed, cached, available, swap used and available, kernel memory pressure, live chart, top processes |
| CPU | Total, user, system and idle; per-core usage; P/E core counts; load averages; live chart; top processes |
| Developer Storage | Xcode (DerivedData, Archives, CoreSimulator…), Node (node_modules across disk, npm, Yarn, pnpm), Android (Gradle, SDK, AVDs), Docker (Desktop, OrbStack, Colima, Lima, Rancher, Podman — probed, not assumed), Git repositories, other toolchains |
| Duplicates | Same size → same type → partial SHA-256 (first + last 64 KB) → full SHA-256. Hard links are ignored and one copy per group is always kept |
| Cleanup | **Safe to Remove / Review Before Removing / Do Not Remove**. Uses the tool's own command where trashing would be risky (Docker, pnpm, simulators) |
| Search | Uses the index: `*.zip`, `node_modules`, `size > 1 GB`, `modified > 1 year ago`, `ext:mov`, `in:Downloads`, `kind:folder`, `app:Chrome` |
| Storage Access | Per-location access status, Full Disk Access detection, Open System Settings |

## Free and Pro

The free tier covers scanning, the dashboard, Largest Files (up to Top 100), Largest Folders, Applications, Running Apps, Memory, CPU and basic search. **SpaceBridge Pro** ($99.99/year, with a 14-day free trial) adds one-click Cleanup, Duplicates, Developer Storage, advanced search, Top 500/custom lists, external drives, per-app storage breakdown and CSV export.

Licensing goes through Lemon Squeezy, which acts as merchant of record and collects US sales tax. Before release, put your store values in `ProConfiguration` (`Services/LicenseService.swift`). See **[MONETIZATION.md](MONETIZATION.md)** for pricing, payment setup, legal pages and the US go-to-market plan.

## Safety model

- **Scanning is read-only.** It uses only `opendir`/`readdir`/`lstat`, never follows symlinks, never crosses into other mounted volumes, and never opens file contents. Only the duplicate finder reads contents, and only for candidates.
- **Nothing is ever deleted automatically or permanently.** The only destructive call in the codebase is `FileManager.trashItem`, in `TrashService` (`Services/FileActions.swift`). It runs only from the confirmation sheet and re-checks the safety policy just before acting.
- **Protected locations** (`SecurityUtils.swift`): `/System`, `/usr`, `/bin`, `/sbin`, `/private`, `/var`, `/etc`, system `/Library` sub-folders, SIP-flagged items (`SF_RESTRICTED`), immutable items, read-only volumes, items without write permission on the parent, keychains, Mail, Messages, other users' homes, standard folders (Documents, Library…), and SpaceBridge's own bundle and database. These show **Protected by macOS** and the action is disabled. Path checks are case-insensitive and resolve `..` and parent symlinks.
- **Processes:** PID ≤ 1, SpaceBridge itself, critical daemons (WindowServer, launchd, loginwindow…), anything under `/System` or `/usr`, and processes owned by other users can never be quit.

## Architecture

```
SpaceBridge/
├── App/          SpaceBridgeApp (scenes, menus, shortcuts), AppModel (state stores)
├── Models/       FileItem, FolderItem, ApplicationInfo, ProcessInfo (ProcessSnapshot), StorageCategory (+ categorizer)
├── Services/     FileScanner, FolderAnalyzer, ApplicationScanner, ProcessMonitor, MemoryMonitor,
│                 CPUMonitor, DuplicateScanner, StorageAnalyzer, PermissionManager, CleanupAnalyzer,
│                 DeveloperStorageAnalyzer, SearchService, FileActions
├── Database/     SQLite wrapper, StorageDatabase actor (scan cache), ScanCache value types
├── Views/        One view per sidebar item, plus details and sheets
├── Components/   MetricCard, StorageChart (donut, bars, live, trend), FileTable, FolderTree, ProcessTable
├── Utilities/    ByteFormatter, SecurityUtils, DirectoryReader (POSIX), Sysctl
└── Resources/    Info.plist, entitlements, Assets (icon, accent color)
SpaceBridgeTests/ XCTest suites
scripts/          generate_xcodeproj.py, build_debug.sh, release.sh, make_dmg.sh, ExportOptions.plist
```

Services don't depend on SwiftUI. The database and scanner are injected, which is how the tests run against temporary folders and databases.

### Scanner design

- **Parallel, depth-first and bounded.** N workers (4 by default; you can change it in Settings) pull directories from an actor-based LIFO queue in a Swift `TaskGroup`. Memory stays roughly constant whatever the tree size, because only one directory listing per worker is held at a time.
- **One syscall per entry.** It reads with `readdir` + `fstatat`, not `URL` resource values, so it doesn't create millions of Foundation objects.
- **Incremental.** Each directory is diffed against the cache and only new, changed or removed rows are written. Folders that disappeared are pruned.
- **Batched writes.** SQLite in WAL mode, with a transaction committed every 20,000 operations or every second.
- **Cancel, pause, resume.** Cancelling keeps partial results. Resume continues with the same scan ID and skips directories already processed, without touching the disk. Pause suspends workers between directories.
- **Totals.** Recursive totals are computed once at the end, bottom-up in memory (about 80 bytes per folder).
- **Accuracy.** Sizes are space allocated on disk (`st_blocks × 512`), hard links are counted once, and logical size is stored too.
- **Errors never stop a scan.** Permission denied marks the folder **Access Restricted**; it is not retried during that scan. Items that vanish mid-scan, broken symlinks, invalid UTF-8 names and disconnected disks are handled and logged to the Diagnostics log in Settings.

### Honest numbers

- RAM/CPU per process use `proc_pid_rusage` (physical footprint, as in Activity Monitor). Where macOS refuses (root or other users' processes), the UI shows **Restricted** instead of a number.
- Memory comes from `host_statistics64`, `vm.swapusage` and `kern.memorystatus_vm_pressure_level`; CPU from `host_processor_info` tick deltas.
- "System & Unscanned" on the dashboard is used space that no scanned file accounts for (APFS snapshots, the VM/Preboot/Recovery volumes, purgeable data, restricted folders). It is reported as such, not split into made-up categories.
- APFS clones share blocks, but no public API reports that, so cloned files are each counted in full. "Last opened" for apps comes from Spotlight and shows "Not available" when Spotlight has no record.

## Requirements

- macOS 14 Sonoma or later (uses `@Observable`, `inspector`, Swift Charts sector marks)
- Xcode 16 or later
- No third-party dependencies. Frameworks used: SwiftUI, Charts, AppKit, Foundation, SQLite3, CryptoKit, Security, CoreServices, UniformTypeIdentifiers.

## Running in Xcode

1. Open `SpaceBridge.xcodeproj`.
2. Choose the **SpaceBridge** scheme and **My Mac**.
3. Press **⌘R**. The project is ad-hoc signed ("Sign to Run Locally") by default, so no developer account is needed to run it.
4. Click **Scan Mac** (⌘R inside the app). macOS asks once for access to Documents, Desktop and Downloads.
5. Optional: for Mail, Messages, Safari, Trash and device backups, open **Storage Access ▸ Open System Settings** and enable SpaceBridge under **Full Disk Access**. Then relaunch the app and scan again.

   Note: an ad-hoc signed build gets a new identity each time you rebuild, so macOS may ask for permissions again. Set your Team under *Signing & Capabilities* to avoid this.

Run the tests with **⌘U**, or from the command line:

```bash
./scripts/build_debug.sh test
```

To run the stress test at scale (it creates files only in a temporary folder):

```bash
SPACEBRIDGE_LARGE_TEST_FILES=1000000 xcodebuild -project SpaceBridge.xcodeproj -scheme SpaceBridge test -only-testing:SpaceBridgeTests/FileScannerTests/testLargeDirectoryTreePerformance
```

## Building a `.app`

**In Xcode:** choose **Product ▸ Archive**, then in the Organizer **Distribute App ▸ Direct Distribution** (Developer ID, notarized) or **Custom ▸ Copy App**.

**From the command line** (unsigned or ad-hoc, for local use):

```bash
xcodebuild -project SpaceBridge.xcodeproj -scheme SpaceBridge -configuration Release -derivedDataPath build/DerivedData build
```

The app is written to `build/DerivedData/Build/Products/Release/SpaceBridge.app`.

## Creating a `.dmg`

```bash
./scripts/make_dmg.sh build/DerivedData/Build/Products/Release/SpaceBridge.app build/SpaceBridge.dmg
```

This produces a compressed drag-to-Applications image, using only `hdiutil`.

## Code signing and notarization (Developer ID)

1. Enroll in the Apple Developer Program. In Xcode ▸ Settings ▸ Accounts, create a **Developer ID Application** certificate.
2. Store notarization credentials once. Use an app-specific password from appleid.apple.com:

   ```bash
   xcrun notarytool store-credentials SpaceBridgeNotary --apple-id you@example.com --team-id ABCDE12345
   ```

3. Build, sign with Hardened Runtime, notarize, staple and package:

   ```bash
   TEAM_ID=ABCDE12345 ./scripts/release.sh
   ```

   The script archives, exports with `scripts/ExportOptions.plist` (method `developer-id`), verifies with `codesign`, submits the app to `notarytool --wait`, staples it, builds the DMG, signs and notarizes the DMG, staples it, and checks both with `spctl`. The result is `build/SpaceBridge.dmg`.

4. To check a downloaded copy:

   ```bash
   spctl --assess --type execute --verbose /Applications/SpaceBridge.app
   ```

**Why not sandboxed?** A whole-disk analyzer can't work inside the App Sandbox, and Mac App Store apps can't get Full Disk Access. SpaceBridge is meant for direct Developer ID distribution with Hardened Runtime and notarization. It needs no runtime exceptions (no JIT, no library-validation opt-outs).

## Privacy

SpaceBridge works offline and your data stays on this Mac. It does not upload your files or filesystem information, and no one, including the developer, can see or share it. The only network request in the app is the Pro license check, which sends the license key and a random instance ID, nothing else. The scan cache (`~/Library/Application Support/SpaceBridge/ScanCache.sqlite`) holds only names, paths, sizes, dates and types, never contents. You can clear it in Settings.

## Regenerating the Xcode project

After adding or removing source files:

```bash
python3 scripts/generate_xcodeproj.py
```

Or, if you prefer XcodeGen, `xcodegen generate` builds an equivalent project from `project.yml`.
