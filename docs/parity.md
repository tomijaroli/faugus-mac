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
| Runner Manager (Gcenx Wine) | Proton Manager | `RunnerManager` | wip (P1: install Staging Latest, list, delete, Rosetta; versions/Devel/Stable in P3) |
| Graphics backend per game | n/a | `Graphics` | done (default/dxvk/wined3d/wined3d-vulkan; dxmt/d3dmetal only when a runner declares them) |
| Prefix creation | umu-run | `Prefix` | done (verified on real Wine Staging 11.21) |
| Runner mode (`--game`) | `runner.py` | `RunnerMode` | done (pre/post-launch hooks, `--logs`, Rosetta prompt; `--run`/`--splash`/`--donate` in P3+) |
| Splash, logs, stop, playtime | `runner.py` | `Splash`, `Logs` | done (Stop about 3.4 s; logs window shows wine.log and faugus.log) |
| List mode, context menu | `launcher.py` | `Library` | wip (P1: Play with logs, Edit, Delete, Duplicate, Hide, locations, Show logs; Category and Run file in P2) |
| Grid / Covers / Carrousel | `launcher.py` | `Library` | todo |
| Add / Edit / Duplicate / Delete | `launcher.py` | `AddGame` | wip (P1: Windows type; delete offers prefix to Trash; other types in P2) |
| Settings | `launcher.py` | `Settings` | wip (P1 sheet hosts the minimal Runner Manager only) |
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
| Delete prefix | The prefix goes to the Trash, never `rm`, and only when no other game uses it. |
| Context menu | Standard SwiftUI menu; upstream's gamepad-friendly popover arrives with P5. |
