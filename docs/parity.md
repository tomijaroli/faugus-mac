# Parity matrix (upstream 2.5.6)

Status: `todo`, `wip`, `done`, `dropped`, `deviation`.

| Area | Upstream | Mac port | Status |
| --- | --- | --- | --- |
| Atomic JSON writes (`core.atomic_write`, indent 4, no ASCII escape) | `core.py` | `FaugusCore/JSON` | done |
| `config.json` defaults and string booleans | `config_manager.py` | `FaugusCore/Config` | done |
| `games.json` `GAME_FIELDS` + unknown field preservation | `utils.py` | `FaugusCore/Games` | done |
| `format_title`, `unique_gameid` | `utils.py` | `FaugusCore/Games` | done |
| Hidden games survive save | `launcher.py:save_games` | `FaugusCore/Games` | done |
| Games backup snapshots (20 kept) | `launcher.py:backup_games` | `FaugusCore/Games` | done |
| gettext + 70% completeness filter | `language_config.py` | `FaugusCore/I18n` | done |
| Paths (XDG to Library) | `path_manager.py` | `FaugusCore/Paths` | done |
| Runner Manager (Gcenx Wine) | Proton Manager | `RunnerManager` | done (P3.1: Staging/Devel/Stable tabs, newest-first releases with Latest marker, Download with progress / Cancel / Remove, installed-only runners kept, Rosetta box) |
| Winetricks (Add Game dialog, Settings default prefix) | `on_button_winetricks_clicked`, `on_button_winetricks_default_clicked`, `--winetricks-log` | `Winetricks`, `WinetricksView` | done, native (P3.3: winetricks 20260125 pinned by SHA-256 in `components/winetricks`, run with `/bin/sh`; native verb picker from `list-all` because zenity does not exist on macOS; installs unattended with `-q`, shared download cache, live log window, Cancel kills the process group; `cabextract` reminder; disabled while the game runs; the log also goes to `Logs/Faugus/<game>/winetricks.log`) |
| Winecfg (Add Game dialog, Settings default prefix) | `on_button_winecfg_clicked`, `on_button_winecfg_default_clicked` | `RunnerMode`, `GameEditorView`, `SettingsView` | done (P3.2: `wine winecfg` through `--run winecfg --in-prefix`; creates the prefix and records it for Cancel; Settings asks to save pending changes first, runs in `<default-prefix>/default` with the default runner) |
| Run (Settings default prefix) | `on_button_run_default_clicked` | `SettingsView` | done (P3.2) |
| Graphics backend per game | n/a | `Graphics` | done (default/dxvk/wined3d/wined3d-vulkan; dxmt/d3dmetal only when a runner declares them) |
| Prefix creation | umu-run | `Prefix` | done (verified on real Wine Staging 11.21) |
| Runner mode (`--game`) | `runner.py` | `RunnerMode` | done (pre/post-launch hooks, `--logs`, Rosetta prompt; `--run <file>` with `--in-game <id>` or `--in-prefix <dir>`: no splash, no playtime, no hooks, untagged so it never touches a running game) |
| Splash, logs, stop, playtime | `runner.py` | `Splash`, `Logs` | done (Stop about 3.4 s; logs window shows wine.log and faugus.log) |
| List mode, context menu | `launcher.py` | `Library` | wip (P1: Play with logs, Edit, Delete, Duplicate, Hide, locations, Show logs; Category in P2; Run file in the prefix with Recent and Clear recent in P2.4c; Steam games: no Duplicate, Logs or prefix, Steam's own playtime, dimmed when not installed) |
| Grid / Covers / Carrousel | `launcher.py` | `Library` | done (P2.3: Grid and Covers with zoom, labels, orientation, max columns, position, overview panel, custom-order drag, background and widget colours; Carrousel with arrow keys, scroll wheel and click; startup window size; Ctrl+H hidden games; dominant colour and banner wait for artwork/SteamGridDB) |
| Add / Edit / Duplicate / Delete | `launcher.py` | `AddGame` | wip (P2.4b: cover and icon via Load from file / Load from URL / Remove, cover preview in Covers and Carrousel, title and icon read from the executable's PE resources; P2.4a: Windows type with General and Settings pages, Specific Runner, Graphics, launch-arguments and presets editor, pre/post-launch, SDL/No Sleep/Discord RPC (stored), Additional Application bat, validation marks, "already exists", Duplicate and Delete dialogs with the shared-prefix warning; P2.4c: Run button, Run an installer (detects the installed `.exe` from new `.lnk` shortcuts, 10 tries 2 s apart) and discard of prefixes created in the dialog (Trash, and only prefixes that did not exist before the run); P2.4d: Steam Game type (Steam User and Title pickers fed by the local Steam install, Steam's icon, no Settings page); Refresh and the banner wait for SteamGridDB; store-launcher types (Epic, GOG, ...) are not planned) |
| Settings | `launcher.py` | `Settings` | wip (P2.2: General and Interface tabs, language, global env vars, clear logs, live preview with Cancel revert, Cmd+,; tray/autostart/Discord/gamepad/SteamGridDB/sounds/backup rows land with their features) |
| Tray | `tray_sni.py` | `Tray` | todo |
| Gamepad / console mode | `gamepad.py` | `Gamepad` | todo |
| Backup / restore | `backup.py` | `Backup` | todo |
| Desktop shortcuts | `.desktop` | stub `.app` | todo |
| Steam shortcuts | `shortcuts.vdf` | `Steam` | todo |
| Discord RPC | `discord_rpc.py` | `Discord` | todo |
| SteamGridDB | `steamgriddb.py` | `SteamGridDB` | todo |
| Interface sounds | `assets/sounds` | `Sounds` | todo |
| Linux import | n/a | `Migration` | todo |
| Lossless Scaling | `lossless_*` | n/a | dropped |
| GameMode | `gamemode` | n/a | dropped |
| GPU select | `gpu` | n/a | dropped |
| Wayland / WOW64 / HDR | misc | n/a | dropped |
| Anti-cheat (EAC/BE) | `components/eac,be` | n/a | dropped |
| Kill-all | `kill` | Faugus processes only | deviation |

## Known P1 deviations and trade-offs

| Topic | Behaviour |
| --- | --- |
| Stop | SIGTERM to the game's process group, `wineserver -k` started without waiting, force kill of every `FAUGUSID`-tagged process after a 3 s grace. Wine's own graceful `wineserver -k` takes about 10 s, so a Stop may lose registry writes made during the session. |
| Process tagging | `FAUGUSID` and `WINEPREFIX` are placed last in `envp`; Wine overwrites the start of the argv/env block when it renames itself, and the scanner skips the resulting empty strings. |
| Play | Toolbar Play and double-click run without logs; "Play with logs" is the context-menu item, as upstream. |
| Delete prefix | The prefix goes to the Trash, never `rm`. Upstream offers the checkbox even for a shared prefix (with a warning); here the warning is shown and the checkbox is disabled, so another game's prefix is never removed. |
| Duplicate | As upstream the copy shares the original's prefix and keeps its playtime and category; the old Mac-only "(copy)" shortcut is gone in favour of upstream's title prompt. |
| Add / Edit | "Specific Proton" is "Specific Runner". The Lossless, MangoHud, GameMode and Linux-runtime widgets do not exist. The SDL flag is stored (and kept for Linux), but Wine on macOS already uses SDL for controllers, so it changes nothing at launch. |
| Settings | Header bar, Theme (Adwaita/GTK engine), GPU, MangoHud, GameMode, Wayland driver, WOW64 are not shown (Linux only); Winetricks, Winecfg and Run work in the default prefix. Default Runner lists installed runners. Color Scheme drives the macOS appearance. A language change applies immediately instead of after a restart. |
| Main window controls | Zoom, sort, category, add, settings, kill, play and search live in the native toolbar instead of upstream's bottom bar and top bar. Kill all stops Faugus-managed games only. |
| Context menu | Standard SwiftUI menu; upstream's gamepad-friendly popover arrives with P5. |
| Run in the prefix | Upstream sets `FAUGUS_DISABLE_UPDATES` for a game's "Run file in the prefix". Here it skips only the runner update check; a runner that is not installed at all is still installed. A file run starts in the game's folder, shows no splash and never writes playtime. |
| Discard prefixes on Cancel | Upstream records every prefix that exists after a Run, including ones that existed before, and deletes them with `rmtree`. Here only prefixes the run created are offered, prefixes a saved game uses are excluded, and the Trash is used. |
| Steam type | Upstream runs `steam -applaunch <appid>` (Linux). macOS has no such command line, so Faugus opens `steam://rungameid/<appid>` (or `steam://run/<appid>//<arguments>/` when the game has arguments) with `open`, which starts Steam if needed. The `-silent -nobigpicture ...` flags are not passed. Steam's data lives in `~/Library/Application Support/Steam` (`steamapps/libraryfolders.vdf`, `userdata`, `appcache/librarycache`); nothing there is ever written. macOS Steam has no Proton prefixes, so "Open prefix location" is disabled for Steam games. Faugus records only `last_played` for them; playtime comes from Steam's `localconfig.vdf`. Steam shortcuts ("add to Steam") are not part of this phase. |
| `--splash`, `--winetricks-log` | Upstream runs the splash and the winetricks log as separate GTK helper processes. Here the runner draws its own splash and the Winetricks window has its own log, so these two modes exist in the parser but exit with a message. |
| `--donate` and the donation dialog | Not ported: it asks for donations to the upstream author's Ko-fi and PayPal, which has no place in a separate port. The `show-donate` and `donate-last` config keys are preserved untouched. |
| Winetricks verbs | winetricks is a shell script that downloads installers and needs `cabextract` (and sometimes `7z`); the cask depends on `cabextract` and the dialog reminds the user when it is missing. Verbs run under Rosetta like everything else; some need a real Windows installer GUI and can fail on Wine. |
