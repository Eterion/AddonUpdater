# Addon Updater

Check and update your WoW Forever addons from a simple keyboard menu. Runs on Windows 10/11 using the included Windows PowerShell 5.1.

## Get started

1. Extract the updater into its own folder and keep all its files together.
2. Double-click **UpdateAddons.cmd**.
3. Choose your WoW installation. If it isn't listed, choose **Enter a custom path**.
4. Available updates start checked. Use **Up/Down** to move and **Space** to uncheck any you want to skip.
5. Close WoW, press **Enter**, and let the updates finish. The Status column shows progress for each selected addon.

Press **Q** or **Esc** to exit a menu. Let an installation finish before closing the window.

Your WoW folder is remembered: future launches go straight to checking its addons. Press **C** to choose another game folder. If the saved folder is unavailable, the folder picker appears automatically.

The updater can live anywhere you can write files, outside the game's AddOns folder.

## Which addons work?

Supports Spoken, Spoken audio, Dialogue UI, and other addons with a compatible GitHub release. A CurseForge download alone may not provide enough information to find updates.

If an addon needs a source, highlight it and press **S** to choose from the repositories found in its files. If a suitable release can't be verified, the list shows the reason.

Every launch checks online for updates. The first Spoken audio check may take a minute or two; later checks reuse verified hashes for unchanged files. Only changed or missing audio files are downloaded.

## More controls

| Key | Action |
| --- | --- |
| Up / Down | Move through the list |
| Space | Check or uncheck an update |
| Enter | Install checked updates |
| A / N | Select all / none |
| S | Choose an addon's source |
| R | Check again |
| C | Change game folder |
| Home / End | Jump to the first / last addon |
| Q / Esc | Exit |

For a custom path, select your `World of Warcraft`, `_forever_`, or `_forever_\Interface\AddOns` folder.

## Updating the updater

Downloaded release copies check for a newer Addon Updater version at startup. Choose **Update Addon Updater and restart** or **Skip for now**. Your saved settings are kept.

To switch from an installation launched by `Addon Updater.cmd`, extract the new ZIP over that installation and open `UpdateAddons.cmd`. The old launcher can be removed.

Update copies inside a Git checkout through Git.

## Backups and recovery

Downloads are checked before installation. Replaced addons are backed up in:

```text
<Forever client>\Interface\ForeverAddonUpdater-Backups\<update-id>
```

If installation fails, the updater restores the addon it was replacing. Updates that already finished stay installed. Your game settings in `WTF` are preserved.

To restore an addon manually, close WoW and the updater, move the affected current addon folders aside, then move their backup folders into AddOns. Restore all folders from the same update together. Each backup includes a `restore.json` record.

Updater program backups are stored in `.self-update\backups` beside the scripts. If a power loss or interrupted rollback leaves the updater incomplete, restore its program files from the recorded backup before running it again. Failed staging is retained for recovery. Backups remain until you remove them.

## Technical details

- Addon sources come from compatible TOC metadata or top-level README links. Ambiguous sources require a choice. CurseForge, WoWInterface and Wago IDs alone don't enable automatic downloads.
- Generic GitHub updates require a stable packaged ZIP and verifiable interface compatibility. Spoken uses release ZIPs and checksums; its audio uses signed manifests and file hashes. Dialogue UI uses compatible versioned tags.
- Archive paths, checksums, addon versions, dependencies and bundle membership are checked before replacement. Unverifiable packages are withheld; older versions don't replace newer ones.
- Self-updates use stable releases from `Eterion/AddonUpdater`, with GitHub's SHA-256 digest and a package file manifest. Verification trusts the GitHub repository and HTTPS.
- `config.json` sets the target interface version, currently `16001`. Personal choices are saved in Git-ignored `settings.local.json` and `sources.local.json`.
- Addon cache and staging use `Interface\ForeverAddonUpdater-Data`. A stale `running.lock` there may be removed after all updater sessions have closed.
- The bundled signature-verification library and its license are described in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Command-line options

```powershell
# Check without installing
.\AddonUpdater.ps1 -CheckOnly
.\AddonUpdater.ps1 -CheckOnly -AddonsPath 'D:\Games\World of Warcraft'

# Preview the menu with sample data
.\AddonUpdater.ps1 -Demo

# Skip the updater's own version check for this run
.\AddonUpdater.ps1 -SkipSelfUpdate
```

Read-only checks cache results in `.check-data` beside the scripts. The launcher sets execution policy for its own process only.

## Development and releases

Run the offline tests:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Run-StartupTests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Run-SelfUpdateTests.ps1
```

To publish a release:

1. Set the version in `version.json`, such as `1.0.0`, and commit the release files.
2. Run the test suites above, then `scripts\Build-Release.ps1` using Windows PowerShell 5.1.
3. Create a stable GitHub release from that commit with a matching tag, such as `v1.0.0`. Attach `dist\AddonUpdater.zip` with that exact filename.
4. Verify self-updating from an older packaged copy outside a Git checkout.

The package excludes personal settings, caches and development files. Published stable releases are distributed as self-updates.
