#!/usr/bin/env python3
"""Generate FaugusCore test fixtures from the upstream 2.5.6 sources.

Everything is derived from `upstream/` (the git submodule) with `ast`, never by importing it
(upstream imports GTK). JSON is written with the exact call upstream uses:
`json.dump(data, f, indent=4, ensure_ascii=False)`.

Usage: python3 Tools/gen-fixtures/gen.py
"""
import ast
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
UP = os.path.join(ROOT, "upstream", "faugus")
OUT = os.path.join(ROOT, "Packages", "FaugusCore", "Tests", "FaugusCoreTests", "Fixtures")


def parse(path):
    with open(path, encoding="utf-8") as f:
        return ast.parse(f.read())


def game_fields():
    for node in parse(os.path.join(UP, "utils.py")).body:
        if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", "") == "GAME_FIELDS":
            return ast.literal_eval(node.value)
    sys.exit("GAME_FIELDS not found")


def default_config():
    tree = parse(os.path.join(UP, "config_manager.py"))
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Attribute) and t.attr == "default_config" for t in node.targets
        ):
            out = {}
            for k, v in zip(node.value.keys, node.value.values):
                key = ast.literal_eval(k)
                if isinstance(v, ast.Name):
                    out[key] = "<%s>" % v.id  # PREFIXES_DIR, lang
                else:
                    out[key] = ast.literal_eval(v)
            return out
    sys.exit("default_config not found")


def dump(name, data):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        json.dump(data, f, indent=4, ensure_ascii=False)


def sample_games(fields):
    """Games as upstream's `game_to_save_dict` would write them."""
    defaults = {f: "" for f in fields}
    defaults.update({"playtime": 0, "hidden": False, "no_sleep": False, "category": False})

    def mk(**kw):
        g = dict(defaults)
        g.update(kw)
        for f in ("mangohud", "gamemode", "sdl_enabled", "discord_rpc", "disable_umu"):
            g[f] = True if g[f] else ""
        g["addapp_enabled"] = "addapp_enabled" if g["addapp_enabled"] else ""
        return {f: g[f] for f in fields}

    return [
        mk(gameid="celeste", title="Celeste", path="/home/user/Games/Celeste/Celeste.exe",
           prefix="/home/user/Faugus/celeste", runner="Proton-CachyOS Latest",
           playtime=12345, last_played="2026-10-31 20:15:00"),
        mk(gameid="the-witcher-3-wild-hunt", title="The Witcher 3: Wild Hunt",
           path="/mnt/games/witcher3/bin/x64/witcher3.exe",
           prefix="/home/user/Faugus/the-witcher-3-wild-hunt", runner="GE-Proton10-4",
           launch_arguments='WINEDLLOVERRIDES="dxgi=n" PROTON_NO_ESYNC=1',
           game_arguments="-windowed", mangohud=True, gamemode=True, sdl_enabled=True,
           category=["RPG", "Favorites"], playtime=987654, pre_launch="/home/user/pre.sh",
           post_launch="/home/user/post.sh"),
        mk(gameid="hollow-knight-silksong", title="Hollow Knight: Silksong (日本語 ñ \"quoted\")",
           path="/home/user/Games/Silksong/Hollow Knight Silksong.exe",
           prefix="/home/user/Faugus/hk-silksong", runner="Default", hidden=True,
           discord_rpc=True, no_sleep=True, steamgriddb_id="5549890",
           cover="/home/user/.local/share/faugus-launcher/covers/hk.png"),
        mk(gameid="installer-test", title="Installer \\ Test\ttab", path="/tmp/setup.msi",
           prefix="/home/user/Faugus/installer-test", runner="Proton-GE Latest",
           addapp_enabled=True, addapp="/tmp/extra.exe", addapp_bat="/tmp/extra.bat",
           addapp_delay="5", addapp_first="True", disable_umu=True, runtime="steamrt3",
           steam_user="76561198000000000", icon="/home/user/.local/share/faugus-launcher/icons/x.png"),
    ]


def main():
    fields = game_fields()
    dump("game_fields.json", fields)

    cfg = default_config()
    dump("config.default.json", cfg)

    full = dict(cfg)
    full["default-prefix"] = "/home/user/Faugus"
    full["language"] = "pt_BR"
    full["default-runner"] = "Proton-CachyOS Latest"
    full["interface-mode"] = "Grid"
    full["system-tray"] = "True"
    full["playtime"] = 14400
    full["steamgriddb-api-key"] = "abc123"
    dump("config.upstream.json", full)

    dump("games.upstream.json", sample_games(fields))

    # Newer-upstream / Mac-only extra fields must survive a load/save cycle.
    games = sample_games(fields)
    games[0]["graphics"] = "wined3d"
    games[1]["future_field"] = {"nested": [1, 2.5, None, True], "text": "ü"}
    dump("games.extra-fields.json", games)

    dump("games.empty.json", [])
    dump("translation-counts.json", translation_counts())
    print("fixtures written to", OUT)


def translation_counts():
    """Entry counts exactly as upstream computes them: compile with msgfmt, then
    `len([k for k in GNUTranslations._catalog if k != ''])`, plus the resulting percentages."""
    import gettext
    import subprocess
    import tempfile

    langs_dir = os.path.join(ROOT, "upstream", "languages")
    counts = {}
    with tempfile.TemporaryDirectory() as tmp:
        for lang in sorted(os.listdir(langs_dir)):
            po = os.path.join(langs_dir, lang, "faugus-launcher.po")
            if not os.path.isfile(po):
                continue
            mo = os.path.join(tmp, lang + ".mo")
            subprocess.run(["msgfmt", po, "-o", mo], check=True)
            with open(mo, "rb") as f:
                cat = gettext.GNUTranslations(f)._catalog
            counts[lang] = len([k for k in cat if k != ""])
    total = max(counts.values())
    return {
        "counts": counts,
        "total": total,
        "percent": {k: v / total * 100.0 for k, v in counts.items()},
    }


if __name__ == "__main__":
    main()
