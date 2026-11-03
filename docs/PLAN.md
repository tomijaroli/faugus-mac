# Faugus for Mac: port plan (tracks Faugus Launcher 2.5.6)

Accepted after a two-model debate (Opus 5.5 and Grok 4.7). Baseline: upstream tag `2.5.6`,
commit `17adc903eb2bce21c333ac104351fc1f448c05ac`. Code is MIT. Icons and sounds are
CC BY 4.0 (c) 2026 Felix Ribeiro. Target: Apple Silicon, macOS 14+, arm64 only. Greenfield port.

## 1. What "1:1" means

The same user outcome: screens and flows (List / Grid / Covers / Carrousel, Add/Edit,
Duplicate, Delete, Settings, Backup/Restore, Create Shortcut, Runner Manager replacing
Proton Manager, logs viewer, splash, donate, power menu, tray, console mode), the same data
files, CLI verbs, strings and timings. Exceptions are rows marked Dropped or Deviation in
`docs/parity.md`.

- **Data files:** `config.json` keeps upstream keys and string booleans `"True"/"False"`.
  `games.json` keeps `GAME_FIELDS`. Also `envar.json`, `presets.json`, `categories.json`,
  `custom-order.json`, `latest-games.json`, `recent-run-files.json`, `running-games.json`,
  `filechooser_folders.json`. Backup tar keeps manifest v2, `.faugus_marker`,
  `settings/{config,data,state}`, `prefixes/`, `shortcuts/`, `protons/`.
- **CLI verbs:** `--game <id>`, `--run <spec>`, `--shortcut <file>`, `--daemon`, `--hide`,
  `--console`, and a single file argument.
- **Strings:** upstream msgids, all 27 translations, the 70% completeness filter.
- **Gamepad:** the `gamepad.py` roles and README table.
- **Timings:** running poll 1 s; stop poll 1 s; playtime save 30 s; backup check 60 s; donate
  monthly after 14,400 s total playtime; 20 `games-data-*.json` snapshots; 5 recent games in the
  tray; installer lnk detection 10 x 2 s.

## 2. Non-goals

Anti-cheat (EAC/BattlEye), Lossless Scaling, GPU select, Wayland, HDR, WOW64 toggle, GameMode,
Steam Linux Runtime selection, protonfixes, GTK theme engines; shipping or auto-downloading
D3DMetal/GPTK, CrossOver files or DXMT; Intel Macs; the Mac App Store; claiming to be upstream;
running Linux binaries.

## 3. App shell

Native Swift 6 app, SwiftUI plus AppKit (`NSStatusItem`, `NSPanel` splash, window and
fullscreen management, `NSOpenPanel`, drag sources). Logic in the Swift package `FaugusCore`.
Python GTK4/libadwaita is rejected: Linux coupling (D-Bus SNI tray, libmanette, /proc scanning,
portals, pkexec, xdg, Gtk.MediaFile) and no way to notarize a PyGObject bundle.

Key mappings (full list in `docs/parity.md`):

- **Entry:** single binary `Faugus for Mac.app/Contents/MacOS/Faugus` parses the same verbs;
  the cask links it as `faugus-launcher`.
- **Launch path:** `LaunchSpec` maps `.exe` to `bin/wine`, `.msi` to `wine msiexec /i`, `.bat`
  to `wine cmd /c`, `.lnk` to `wine start /unix`, `.reg` to `wine regedit`.
- **Prefix:** explicit `wineboot -u`, a `.faugus-prefix.json` marker, `winemenubuilder.exe=d`.
- **Runner Manager:** Gcenx Wine Staging/Devel/Stable, 100 releases per page.
- **Components:** only winetricks and DXVK-macOS are downloaded.
- **Steam:** `~/Library/Application Support/Steam`; launch via `open steam://rungameid/<appid>`.
- **Shortcuts:** stub `.app` in `~/Applications/Faugus/` and/or `~/Desktop`; Finder Services item.
- **Prefer SDL:** WineBus registry `HKLM\System\CurrentControlSet\Services\WineBus`; on sets
  `Enable SDL`=1 and `DisableHidraw`=1; off deletes both.
- **No Sleep:** `IOPMAssertionCreateWithName`.
- **Stop/kill:** stop file `state/stop-<id>` plus a `sysctl KERN_PROCARGS2` FAUGUSID scan.
  Kill-all is limited to Faugus processes (Deviation).
- **Logs:** `~/Library/Logs/Faugus/<id>/{faugus.log,wine.log}`.
- **Gamepad:** GameController.framework (A confirm, B back, X kill, Y menu, LB add, RB settings,
  Menu power), thresholds 0.7/0.3, repeat 0.5 s then 0.1 s, right-stick deadzone 0.2, speed 1600.
- **Backups:** APFS clone with copy fallback, `/usr/bin/tar`, reject escaping members,
  LaunchAgent via `SMAppService.agent` (`StartInterval` 60, `--daemon --once`).
- **i18n:** bundled `.po` parsed at runtime, plus a `faugus-mac` domain for Mac strings.
- **Sounds:** `assets/sounds/<theme>-{navigate,confirm,cancel,warning}.ogg` via stb_vorbis +
  AVAudioEngine, volume^(1/3).

## 4. Runtime

- **Runner:** Gcenx WineHQ macOS builds (x86_64 under Rosetta 2). Default `Wine-Staging Latest`,
  then Devel and Stable.
- **DXMT** does not work on stock Gcenx Wine. **Homebrew** disabled its Wine casks on 2026-09-01.
- **Graphics:** per-game `graphics` is one of `default`, `dxvk`, `wined3d`, `wined3d-vulkan`,
  `dxmt`, `d3dmetal`; config `mac-graphics-backend` defaults to `dxvk`. Missing values are not
  backfilled.
  - **dxvk:** non-builtin DXVK-macOS repack (`dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz`),
    d3d10core and d3d11 only. Copy into `system32` and `syswow64`,
    `WINEDLLOVERRIDES=d3d11,d3d10core=n,b`, `MVK_CONFIG_RESUME_LOST_DEVICE=1`, leave
    `DXVK_ASYNC` unset, do not copy `dxvk.conf`.
  - **wined3d:** `d3d11,d3d10core=b`, restore the runner's builtin DLLs; renderer is OpenGL.
  - **wined3d-vulkan:** adds `WINE_D3D_CONFIG=renderer=vulkan`.
  - **dxmt / d3dmetal:** only on runners that declare them in `faugus-runner.json`.
- **Invariants:** Faugus never writes inside a runner Wine tree or CrossOver.app, and never
  downloads MoltenVK, DXMT or GPTK.
- **Runner Manager:** do not set `LSFileQuarantineEnabled`. Remove `com.apple.quarantine` if
  present. Never re-sign. Run `bin/wine` directly. Reject archive members with absolute paths,
  `..`, or escaping links.
- **Rosetta:** check `/usr/bin/arch -x86_64 /usr/bin/true`; if missing,
  `softwareupdate --install-rosetta --agree-to-license` via an admin prompt.
- **Redistribution:** the bundle ships only port code, upstream assets with attribution,
  translations, stb_vorbis and Sparkle.

## 5. Process model

- **Launch:** the GUI spawns `Faugus --game <id> [--logs]` via `posix_spawn` with
  `POSIX_SPAWN_SETSID`, cwd set to the game dir, stdio on `/dev/null`. The runner is an
  `.accessory` `NSApplication`.
- **Steps:** resolve runner, Rosetta check, splash and updates, donate check, prefix creation,
  graphics backend, WineBus, pre-launch hook, spawn with `FAUGUSID`/`WINEPREFIX`/merged overrides,
  write `running-games.json` `{gameid: runner pid}`.
- **While running:** poll the stop file, save playtime, Discord, sleep assertion, close the
  splash via `CGWindowListCopyWindowInfo`, `wineserver -w` after `wine` exits.
- **Stop:** write the stop file, SIGTERM the process group, `wineserver -k` unless another game
  shares the prefix, then SIGKILL FAUGUSID-env processes after 3 s.
- **Logs:** with `--logs`, `WINEDEBUG=+timestamp,+pid,+tid,+seh,+debugstr,+loaddll`; else
  `WINEDEBUG=-all`.
- **IPC:** `DistributedNotificationCenter` names `refresh-menu`, `open`, `quit`.

## 6. Paths

`~/Library/Application Support/Faugus/{config,data,state,runners,components/{dxvk-macos,winetricks}}`,
`~/Library/Caches/Faugus/tmp`, `~/Library/Logs/Faugus/<id>/`, prefixes `~/Faugus`
(default `~/Faugus/default`), shortcuts `~/Applications/Faugus/` and `~/Desktop`.

Defaults match upstream except `default-runner` (`Wine-Staging Latest`) and language. Dropped
keys are kept and ignored, unknown game fields are preserved, writes are atomic.

Linux import: rewrite `/home/<user>/Faugus` paths, map Proton runners to "Default", mark
Linux-native entries "Needs attention", replace Proton native d3d DLLs with builtins, rename
`steamuser` to the Mac user and leave a symlink.

## 7. Packaging

"Faugus for Mac", executable `Faugus`, bundle id `me.tomijaroli.faugus-mac`, entitlement
`com.apple.security.automation.apple-events`, not sandboxed. Sparkle 2 (EdDSA update keys; no
Apple account needed).

**Signing decision (2026-11-03):** no paid Apple Developer account for now. Builds are ad-hoc
signed and not notarized, so users must approve the app once (right-click Open, or System
Settings > Privacy & Security > Open Anyway on recent macOS). Consequence: macOS may re-ask for
permissions after an update, and the Homebrew cask will also trigger the Gatekeeper prompt.
Revisit (Developer ID, hardened runtime, notarized and stapled DMG) when the project is shared
beyond friends.

Homebrew cask in the owner's tap (`tomijaroli/homebrew-faugus-mac`, repo
https://github.com/tomijaroli/faugus-mac) (arm64, macOS >= Sonoma, `depends_on formula: "cabextract"`,
binary `faugus-launcher`, `auto_updates true`, zap never touches `~/Faugus`; no
`requires_rosetta` caveat).

About text: "Unofficial macOS port of Faugus Launcher by Felix Ribeiro. Tracks upstream 2.5.6.
Not affiliated."

## 8. Phases

- **P0 Foundations (no Wine):** repo, XcodeGen, FaugusCore, CI, submodule, NOTICE, parity.md,
  Paths, Config, Games, atomic JSON, i18n runtime and 70% filter, release script.
- **P1 Vertical slice:** Rosetta check/install, minimal Runner Manager (Wine Staging Latest),
  DXVK-macOS component, prefix creation, Add Game (Windows), runner mode with splash/logs/
  running state/Stop/playtime/last_played, List mode with context menu, Logs window.
- **P2** library and settings. **P3** runtime and tools.
  **P4** macOS integration (tray, Discord RPC, SteamGridDB, Desktop/App Menu shortcuts; Steam
  shortcuts and auto-create-shortcuts dropped — see `docs/parity.md`).
  **P5** gamepad and console (done). **P6** backup and Linux import. **P7** i18n and release.

Port semver 0.x until parity; 1.0.0 at full 2.5.6 parity.

## 9. Open items (do not block P0/P1)

Decided: bundle id `me.tomijaroli.faugus-mac`; GitHub owner `tomijaroli`; no paid Apple
Developer account yet (ad-hoc signing).
Discord application registered by the owner; its (public) id is `DiscordApplication.clientID`. For the
Discord Rich Presence work in P4/P5 never reuse upstream's application id.
Still open: owned test games; P1 flip rules (Staging to Devel, dxvk to
wined3d-vulkan/wined3d); CrossOver bottle CLI; hosted-CI Metal; steamuser rename; UTIs for
msi/lnk/bat/reg; Metal HUD under WineD3D.
