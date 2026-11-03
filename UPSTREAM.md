# Upstream baseline

| Field | Value |
| --- | --- |
| Project | Faugus Launcher |
| Repository | https://github.com/Faugus/faugus-launcher |
| Tag | `2.5.6` |
| Commit | `17adc903eb2bce21c333ac104351fc1f448c05ac` |
| Checkout | `upstream/` (git submodule) |

The port tracks this tag. To bump, move the submodule, diff `GAME_FIELDS`,
`ConfigManager.default_config`, CLI verbs and the `.pot` file, update
`docs/parity.md`, then bump this file.
