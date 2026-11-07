# Addon Updater

A terminal-based WoW Forever addon updater for **Windows PowerShell 5.1**, included with Windows 10/11. It does not require Node.js, PowerShell 7, a browser, npm, or an installed PowerShell module.

## Start

Double-click **Addon Updater.cmd**. It opens Windows PowerShell 5.1 and runs `AddonUpdater.ps1`. The CMD file is only a convenience launcher, since double-clicking a `.ps1` normally opens an editor. You can also right-click `AddonUpdater.ps1` and select **Run with PowerShell**.

Keep the scripts, `config.json`, and `lib` folder together in a writable folder. The updater can live anywhere; it does not belong inside WoW's `Interface\AddOns` folder.

## Choose your client

The first menu lists detected Forever installations and **Enter a custom path**. Use Up/Down and Enter. Custom paths can point at World of Warcraft, `_forever_`, or `_forever_\Interface\AddOns`. The updater verifies the Forever client contains `Wow.exe` and rejects filesystem links.

Your choice is remembered in `settings.local.json`, excluded from Git. Detection checks common installation locations on drives C through F. Custom paths support other drives and locations. Press **C** in the addon list to choose another client.

## Choose updates

All available updates start checked. The interface supports:

| Key | Action |
| --- | --- |
| Up / Down | Move through addons; long lists scroll |
| Space | Check or uncheck the highlighted update |
| A / N | Select all / select none |
| Enter | Install the checked updates |
| S | Choose the highlighted addon's GitHub source |
| R | Check for updates again |
| C | Choose another client |
| Q / Esc | Exit |
| Home / End | Jump to the first / last addon |

Only a custom installation path needs typed text. The normal selection flow uses keys, not entered numbers. Errors stay visible in the terminal.

## Progress and safeguards

The terminal shows overall addon completion and the current operation: bytes downloaded, files checked/unpacked/prepared, verification, backup, and installation. Unknown totals use an indeterminate progress display.

Close WoW before installing. Downloads are verified and staged before existing folders are replaced. Old folders are kept in `<Forever client>\Interface\ForeverAddonUpdater-Backups\<update-id>`, including a `restore.json` record. A normal folder-swap error restores the addon being installed; previously completed updates remain installed. Failed staging is retained for recovery. Your `WTF` folder is never changed.

Let the script finish once installation starts. Closing the terminal or killing PowerShell during a folder swap can interrupt rollback. To restore manually, close WoW and the updater, move the affected current addon folders aside, and move the matching backup folders into AddOns. Restore all folders from one update together. If power loss interrupts installation, inspect `restore.json` and retained staging before updating again.

Cache and staging live beside AddOns in `Interface\ForeverAddonUpdater-Data`. Backups are retained until you remove them. A stale `running.lock` may be removed only after all updater sessions have closed.

## Sources

- Explicit GitHub links in Forever-compatible TOC fields are detected automatically. Recognized fields include `X-Website`, `Website`, `X-Source`, `Source`, `X-GitHub` and `X-GitHub-Repo`.
- Top-level README links require a one-time choice with **S**. Bundled library folders are not searched. Ambiguous metadata also requires a choice. Selections are stored per client in Git-ignored `sources.local.json`.
- CurseForge, WoWInterface and Wago project identifiers are displayed. IDs alone do not enable automatic downloads; the generic provider currently uses GitHub.
- Generic GitHub updates use stable packaged ZIP releases. Compatibility must be established through release metadata (`release.json`/`.release.json`) or a matching TOC at the exact tag. Ambiguous packages, unknown version formats and unverifiable compatibility are withheld with a reason. Generic source-code snapshots are not installed.
- Spoken and its installed bundled modules use the author's stable GitHub release ZIPs and published SHA-256 checksums.
- Spoken audio uses the author's signed catalog. Ed25519 signatures, manifest digests and file SHA-256 checksums are verified. Only changed or missing audio files are downloaded; matching existing files are reused.
- Dialogue UI uses compatible versioned tags from its author's repository. It retains its dedicated tagged-snapshot adapter.

ZIP paths, sizes and CRCs are checked. Packaged TOCs, version, required dependencies and bundle membership are validated before replacement. Installed folders mapped to the same generic release update together; an unmapped installed bundle member blocks the update. New optional modules are not installed automatically. Older releases never replace newer installed versions.

`config.json` contains the target Forever interface version, currently `16001`; it has no personal path. Update this value when supporting a different Forever client interface.

## Updating Addon Updater

Packaged copies check for a newer stable release from `Eterion/AddonUpdater` on startup. Choose **Update Addon Updater and restart**, **Skip for now**, or **Q / Esc** to exit. If no release exists yet, startup continues normally. Network errors are displayed and leave the current updater usable. Demo mode and read-only addon checks do not check for updater releases. Use `-SkipSelfUpdate` to bypass the check for one run.

The updater accepts only the official `AddonUpdater.zip` release asset and verifies its size and GitHub-provided SHA-256 digest before extraction. Its file manifest is checked before replacement. This trusts the GitHub repository and HTTPS; it is not a separately signed publisher release.

Personal `settings.local.json`, `sources.local.json` and caches are preserved. Replaced program files are retained under `.self-update\backups`, with `restore.json`; a normal replacement failure rolls back the update. Failed staging is retained. If rollback itself fails, the updater stops and reports the backup and staging locations. After a power loss, restore the program files listed in `restore.json` from that backup before running again. Do not close the terminal while files are being replaced.

Self-updating is disabled when the updater is inside a Git checkout, including nested folders and Git worktrees. Update development copies with Git. Only one interactive session can run from the same updater folder at a time; its file lock is automatically released on exit.

## Verification library

The bundled, unmodified Bouncy Castle .NET Framework DLL provides Ed25519 verification missing from PowerShell 5.1's built-in framework APIs. It is included in `lib`; users do not install anything. Its published SHA-256 is checked before loading. License and provenance are in `THIRD_PARTY_NOTICES.md` and `lib\BouncyCastle.LICENSE.txt`.

## Command-line and testing

Read-only checks use the remembered client, or an explicit path:

```powershell
.\AddonUpdater.ps1 -CheckOnly
.\AddonUpdater.ps1 -CheckOnly -AddonsPath 'D:\Games\World of Warcraft'
```

Check-only mode writes its cache into the Git-ignored `.check-data` directory beside the scripts and cannot install. The first audio check hashes existing files and may take a minute or two. Later checks reuse hashes when file size and timestamps match.

Preview the keyboard interface without network or game access:

```powershell
.\AddonUpdater.ps1 -Demo
```

Run the self-contained offline regression suite, with no Pester installation:

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Run-SelfUpdateTests.ps1
```

The launcher applies execution policy only to its own PowerShell process; it does not change machine settings. No background service, scheduled task or browser server is installed. Public sources can fail or rate-limit requests; those failures are shown rather than reported as up-to-date.

## Preparing a GitHub release

1. Set the three-part version in `version.json` and commit the intended release files.
2. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Build-Release.ps1` and both test scripts above. The self-update suite also rebuilds the package.
3. Create a GitHub release tagged `v<version>`, for example `v1.0.0`, from that commit. Attach **`dist\AddonUpdater.zip`** with that exact asset name and publish it as a stable release. The package contains only program files, documentation and bundled libraries. Local settings, caches, Git metadata and development scripts are excluded.
4. For end-to-end live verification, run a previously released packaged copy outside a Git checkout and accept its update offer. GitHub supplies the asset digest after upload; packages without that digest are withheld.

Pushing commits alone does not distribute an update. Publishing the first release makes it available to download; self-updates become available when a later stable version is published.
