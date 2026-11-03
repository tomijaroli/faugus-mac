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
| Runner Manager (Gcenx Wine) | Proton Manager | `RunnerManager` | todo |
| Graphics backend per game | n/a | `Graphics` | todo |
| Prefix creation | umu-run | `Prefix` | todo |
| Runner mode (`--game`) | `runner.py` | `RunnerMode` | todo |
| Splash, logs, stop, playtime | `runner.py` | `Splash`, `Logs` | todo |
| List mode, context menu | `launcher.py` | `Library` | todo |
| Grid / Covers / Carrousel | `launcher.py` | `Library` | todo |
| Add / Edit / Duplicate / Delete | `launcher.py` | `AddGame` | todo |
| Settings | `launcher.py` | `Settings` | todo |
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
