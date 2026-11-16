"""Longshot (https://git.magicbean.dev/MagicBeanDev/Longshot): find its game builds and their mods folder.

Longshot runs the game natively on PC. Its launcher builds the game from your own .nup into a game folder
(Games\\Longshot\\<version> in your user folder by default) and lists every build in builds.json:
    Windows: %LOCALAPPDATA%\\LongshotLauncher\\builds.json
    Linux:   ~/.local/share/LongshotLauncher/builds.json (or $XDG_DATA_HOME, or ~/.config)
Each entry has "folder", "name", "nup" and "default". The launcher's settings.json next to it has "nup" too.

Mods go in the game folder's "mods" folder, one folder per mod with a romfs folder inside: exactly what the
randomizer writes. Longshot loads every mod in that folder, sorted by name, and skips a folder whose name starts
with ".", "-" or "_". Two seeds at once would mix, so writing a seed there renames the older randomizer seeds
to "_<name>" (they stay, only switched off). It ignores exefs patches; the randomizer writes none.
"""
import json
import os
import re
import sys
from dataclasses import dataclass

MOD_PREFIX = "GogglesOfTruth_"
OLD_PREFIXES = ("OoTR_Remake_",)                  # seeds made before the 0.6.0 rename
SEED_PREFIXES = (MOD_PREFIX,) + OLD_PREFIXES
OFF_PREFIXES = (".", "-", "_")


@dataclass
class Build:
    name: str
    folder: str
    nup: str = ""
    default: bool = False

    @property
    def mods(self):
        return os.path.join(self.folder, "mods")


def _launcher_dirs():
    home = os.path.expanduser("~")
    if sys.platform == "win32":
        local = os.environ.get("LOCALAPPDATA") or os.path.join(home, "AppData", "Local")
        return [os.path.join(local, "LongshotLauncher")]
    data = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
    conf = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
    return [os.path.join(data, "LongshotLauncher"), os.path.join(conf, "LongshotLauncher"),
            os.path.join(data, "longshot")]


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def is_game_folder(folder):
    """A Longshot game folder: the launcher writes longshot_version.txt there, next to the game."""
    return bool(folder) and os.path.isfile(os.path.join(folder, "longshot_version.txt"))


def _version_key(name):
    return [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", name or "")]


def find_builds():
    """Every Longshot game folder found, the launcher's default build first."""
    builds, seen = [], set()

    def add(b):
        key = os.path.normcase(os.path.abspath(b.folder))
        if key not in seen and is_game_folder(b.folder):
            seen.add(key)
            builds.append(b)

    scan = [os.path.join(os.path.expanduser("~"), "Games", "Longshot")]
    for d in _launcher_dirs():
        data = _read_json(os.path.join(d, "builds.json")) or {}
        for e in data.get("builds") or []:
            if isinstance(e, dict) and isinstance(e.get("folder"), str):
                add(Build(str(e.get("name") or os.path.basename(e["folder"])), e["folder"],
                          e.get("nup") if isinstance(e.get("nup"), str) else "", bool(e.get("default"))))
        bf = (_read_json(os.path.join(d, "settings.json")) or {}).get("buildsFolder")
        if isinstance(bf, str) and bf:
            scan.append(bf)
    # builds the launcher doesn't list (portable, or made with the command line tools)
    for root in scan:
        try:
            names = sorted(os.listdir(root), key=_version_key, reverse=True)
        except OSError:
            continue
        for n in names:
            add(Build(n, os.path.join(root, n)))
    builds.sort(key=lambda b: not b.default)       # stable: the launcher's order, default first
    return builds


def launcher_nup():
    """The .nup the launcher was given (its settings.json), if that file still exists."""
    for d in _launcher_dirs():
        nup = (_read_json(os.path.join(d, "settings.json")) or {}).get("nup")
        if isinstance(nup, str) and os.path.isfile(nup):
            return nup
    for b in find_builds():
        if b.nup and os.path.isfile(b.nup):
            return b.nup
    return ""


def game_version(folder):
    """The version in a game folder's longshot_version.txt ("v3.0.0-rc.4"), or ""."""
    try:
        with open(os.path.join(folder, "longshot_version.txt"), encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("version="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def version_key(v):
    """Sortable form of "v3.0.0-rc.4": a release sorts after its own release candidates. None if unreadable."""
    m = re.match(r"v?(\d+)\.(\d+)\.(\d+)(?:-([A-Za-z]+)\.?(\d*))?", v or "")
    if not m:
        return None
    pre = (0, m.group(4).lower(), int(m.group(5) or 0)) if m.group(4) else (1, "", 0)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3))) + pre


def newer_build(out):
    """The launcher's default build if `out` is the mods folder of an older Longshot version, else None.
    The launcher puts each version in its own folder, so after a Longshot update the saved folder is stale."""
    if not is_mods_folder(out):
        return None
    builds = find_builds()
    if not builds or not builds[0].default:
        return None
    new = builds[0]
    if os.path.normcase(os.path.abspath(new.mods)) == os.path.normcase(os.path.abspath(out)):
        return None
    old_v, new_v = version_key(game_version(os.path.dirname(os.path.abspath(out)))), version_key(game_version(new.folder))
    return new if old_v and new_v and new_v > old_v else None


def is_mods_folder(path):
    """True if `path` is a Longshot game folder's mods folder."""
    if not path:
        return False
    path = os.path.abspath(path)
    return os.path.basename(path).lower() == "mods" and is_game_folder(os.path.dirname(path))


def switch_off_other_seeds(mods_dir, keep):
    """Rename every other randomizer seed in `mods_dir` to _<name>, so Longshot loads only `keep`.
    Returns [(old name, new name)]."""
    done = []
    try:
        names = os.listdir(mods_dir)
    except OSError:
        return done
    for n in sorted(names):
        if n == keep or not n.startswith(SEED_PREFIXES) or not os.path.isdir(os.path.join(mods_dir, n)):
            continue
        new, i = "_" + n, 2
        while os.path.exists(os.path.join(mods_dir, new)):
            new, i = "_%s (%d)" % (n, i), i + 1
        try:
            os.rename(os.path.join(mods_dir, n), os.path.join(mods_dir, new))
            done.append((n, new))
        except OSError:
            pass                                    # e.g. the game is running and has it open
    return done


def active_seeds(mods_dir, keep):
    """Other randomizer seeds still switched on in `mods_dir` (renaming them failed)."""
    try:
        return [n for n in os.listdir(mods_dir) if n.startswith(SEED_PREFIXES) and n != keep
                and os.path.isdir(os.path.join(mods_dir, n))]
    except OSError:
        return []
