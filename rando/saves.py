"""Per-seed saves: each seed keeps its own save slots, in Longshot and in Switch emulators.

The game keeps all its save data in one folder per account:
    Longshot (Windows):   %APPDATA%\\Longshot\\save\\<account id>\\
    Longshot (Linux):     ~/.local/share/Longshot/save/<account id>/ (or $XDG_DATA_HOME, or ~/.config)
    emulators:            <NAND folder>/user/save/0000000000000000/<profile>/0400486024DEC000/
                          (<emulator user folder>/nand, unless its config/qt-config.ini sets nand_directory)
                          (the yuzu family: Eden, Citron, Sudachi, Lichii, ...; the mods are in
                          <user folder>/load/0400486024DEC000/<mod>)
with the same files in each: option.sav (the game's options), account.sav (a small account-wide table), and the
six save slots slot_00 ... slot_05 (caption.sav + progress.sav each).

Everything but option.sav belongs to a seed. The seed whose saves are in the game's folder is named in a marker
file there (MARKER). Switching to another seed (after generating one, or with "Play this seed"):
  1. the game's current slots and account.sav are copied into the seed that owns them: <seed folder>/saves/<account>
     (a folder Longshot and the emulators don't read: they only load a mod's romfs and exefs);
     slots no seed owns (made before this, or with the seed folder gone) are copied to save_backups/ instead;
  2. the game's slots are replaced by the new seed's stored ones, or emptied for a seed that has none
     (account.sav is then kept), and the marker names the new seed.
Nothing is deleted before it has been copied somewhere. option.sav is never touched. The game must be closed:
it keeps its saves open while running.

Switching seeds on and off: Longshot loads every folder in mods/ except ones starting with "." "-" "_", so a seed is
switched off by renaming it to _<name> (rando/longshot.py). Emulators of the yuzu family load every folder in
load/<title id>/ that isn't turned off in their own settings, so a seed is switched off by moving it into
load/GogglesOfTruth_off/, which they don't read (it isn't a title id).
"""
import datetime
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field

from . import longshot

TITLE_ID = "0400486024DEC000"
MARKER = "goggles_of_truth_seed.txt"
STORE = "saves"
SHARED = {"option.sav", MARKER, "seed_settings.txt"}
EMU_OFF = "GogglesOfTruth_off"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKUPS = os.path.join(ROOT, "save_backups")
EMULATOR_EXES = ("yuzu", "suyu", "sudachi", "citron", "eden", "torzu", "lichii", "fritchii", "ryujinx", "ryubing")


class SaveError(Exception):
    pass


@dataclass
class Target:
    kind: str                       # "Longshot" or "emulator"
    mods: str                       # where the seeds are (Longshot mods/, or load/<title id>/)
    save_dirs: list = field(default_factory=list)
    off: str = ""                   # emulators: where switched-off seeds go
    exe_dir: str = ""               # emulators: the emulator's own folder, when it's portable
    note: str = ""                  # a warning to show (the emulator reads its mods elsewhere)


# --------------------------------------------------------------------------- where things are
def longshot_save_dirs():
    home = os.path.expanduser("~")
    if sys.platform == "win32":
        roots = [os.path.join(os.environ.get("APPDATA") or os.path.join(home, "AppData", "Roaming"), "Longshot")]
    else:
        data = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
        conf = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
        roots = [os.path.join(data, "Longshot"), os.path.join(conf, "Longshot"), os.path.join(data, "longshot")]
    return _account_dirs([os.path.join(r, "save") for r in roots])


def _account_dirs(parents):
    out = []
    for p in parents:
        try:
            names = sorted(os.listdir(p))
        except OSError:
            continue
        for n in names:
            d = os.path.join(p, n)
            if os.path.isdir(d) and _looks_like_save(d):
                out.append(d)
    return out


def _looks_like_save(d):
    try:
        return any(n == "option.sav" or n == "account.sav" or re.match(r"slot_\d+$", n) for n in os.listdir(d))
    except OSError:
        return False


def emulator_user_dir(out):
    """The emulator's user folder if `out` is its load/<title id> folder, else None."""
    out = os.path.abspath(out or "")
    if os.path.basename(out).upper() == TITLE_ID and os.path.basename(os.path.dirname(out)).lower() == "load":
        return os.path.dirname(os.path.dirname(out))
    return None


def _emulator_dir_setting(user, key):
    """A folder setting (nand_directory, load_directory) from the emulator's config/qt-config.ini, or None."""
    for cfg in (os.path.join(user, "config", "qt-config.ini"), os.path.join(user, "config", "config.ini")):
        try:
            with open(cfg, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    m = re.match(r"\s*%s\s*=\s*(.+?)\s*$" % key, line)
                    if m and m.group(1).strip('"'):
                        return os.path.normpath(m.group(1).strip('"'))
        except OSError:
            continue
    return None


def emulator_nand_dir(user):
    """The emulator's NAND folder: its qt-config.ini can move it anywhere (nand_directory; Fritchii's points at
    Lichii's), else <user>/nand."""
    return _emulator_dir_setting(user, "nand_directory") or os.path.join(user, "nand")


def emulator_load_note(user):
    """A warning if the emulator reads its mods from another load folder than <user>/load (load_directory)."""
    load = _emulator_dir_setting(user, "load_directory")
    if load and os.path.normcase(os.path.abspath(load)) != os.path.normcase(os.path.join(user, "load")):
        return ("this emulator reads its mods from %s, not from this folder: use %s as the output folder"
                % (load, os.path.join(load, TITLE_ID)))
    return ""


def emulator_save_dirs(user):
    base = os.path.join(emulator_nand_dir(user), "user", "save", "0000000000000000")
    out = []
    try:
        profiles = sorted(os.listdir(base))
    except OSError:
        return out
    for prof in profiles:
        try:
            titles = os.listdir(os.path.join(base, prof))
        except OSError:
            continue
        out += [os.path.join(base, prof, t) for t in titles if t.upper() == TITLE_ID]
    return out


def target_for(out):
    """The save target for output folder `out`, or None if it isn't a Longshot or emulator mods folder."""
    if longshot.is_mods_folder(out):
        return Target("Longshot", os.path.abspath(out), longshot_save_dirs())
    user = emulator_user_dir(out)
    if user:
        parent = os.path.dirname(user)                  # portable emulators keep "user" next to the program
        return Target("emulator", os.path.abspath(out), emulator_save_dirs(user),
                      os.path.join(os.path.dirname(os.path.abspath(out)), EMU_OFF),
                      parent if os.path.basename(user).lower() == "user" else "", emulator_load_note(user))
    return None


# --------------------------------------------------------------------------- seeds
def is_seed(name):
    return name.lstrip("_").startswith(longshot.SEED_PREFIXES)


def seed_name(folder_name):
    """GogglesOfTruth_X for "_GogglesOfTruth_X" or "_GogglesOfTruth_X (2)"."""
    return re.sub(r" \(\d+\)$", "", folder_name.lstrip("_"))


def seeds(target):
    """[(seed name, folder path, switched on)] for every seed in the target, newest first."""
    found = []
    places = [(target.mods, True)] + ([(target.off, False)] if target.off else [])
    for place, on_here in places:
        try:
            names = os.listdir(place)
        except OSError:
            continue
        for n in names:
            p = os.path.join(place, n)
            if os.path.isdir(p) and is_seed(n):
                on = on_here and not n.startswith(longshot.OFF_PREFIXES)
                found.append((seed_name(n), p, on))
    found.sort(key=lambda s: os.path.getmtime(s[1]), reverse=True)
    return found


def seed_folder(target, name):
    """The folder of seed `name` (switched on or off), or None."""
    found = None
    for n, p, on in seeds(target):
        if n == name:
            if on:
                return p
            found = found or p
    return found


def switch_on(target, name):
    """Make `name` the only seed the game loads. Returns its folder."""
    folder = seed_folder(target, name)
    if folder is None:
        raise SaveError("seed %s not found in %s" % (name, target.mods))
    if target.kind == "Longshot":
        want = os.path.join(target.mods, name)
        if os.path.normcase(folder) != os.path.normcase(want):
            if os.path.exists(want):
                raise SaveError("can't switch %s on: %s already exists" % (name, want))
            _rename(folder, want)
            folder = want
        longshot.switch_off_other_seeds(target.mods, name)
        left = longshot.active_seeds(target.mods, name)
    else:
        want = os.path.join(target.mods, name)
        if os.path.normcase(folder) != os.path.normcase(want):
            if os.path.exists(want):
                raise SaveError("can't switch %s on: %s already exists" % (name, want))
            _rename(folder, want)
            folder = want
        left = switch_off_emulator_seeds(target, name)
    if left:
        raise SaveError("these seeds couldn't be switched off (close the game first): %s" % ", ".join(left))
    return folder


def switch_off_emulator_seeds(target, keep):
    """Move every other seed out of load/<title id> into load/GogglesOfTruth_off. Returns the ones that failed."""
    failed = []
    try:
        names = sorted(os.listdir(target.mods))
    except OSError:
        return failed
    for n in names:
        p = os.path.join(target.mods, n)
        if n == keep or not is_seed(n) or not os.path.isdir(p):
            continue
        os.makedirs(target.off, exist_ok=True)
        dest, i = os.path.join(target.off, n), 2
        while os.path.exists(dest):
            dest, i = os.path.join(target.off, "%s (%d)" % (n, i)), i + 1
        try:
            os.rename(p, dest)
        except OSError:
            failed.append(n)
    return failed


def _rename(a, b):
    try:
        os.rename(a, b)
    except OSError as e:
        raise SaveError("couldn't move %s (close the game first): %s" % (a, e))


# --------------------------------------------------------------------------- the game must be closed
def _process_names():
    try:
        if sys.platform == "win32":
            out = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], capture_output=True, text=True, timeout=15,
                                 creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout
            return {line.split('","')[0].strip('"').lower() for line in out.splitlines() if line.startswith('"')}
        out = subprocess.run(["ps", "-A", "-o", "comm="], capture_output=True, text=True, timeout=15).stdout
        return {os.path.basename(l.strip()).lower() for l in out.splitlines() if l.strip()}
    except (OSError, subprocess.SubprocessError):
        return None


def game_running(target):
    """The name of a running game/emulator program that could have the saves open, "" if none, None if unknown."""
    names = _process_names()
    if names is None:
        return None
    if target.kind == "Longshot":
        hits = [n for n in names if n.startswith("longshot") and "launcher" not in n]
    else:
        exes = set()
        if target.exe_dir:
            try:
                exes = {n.lower() for n in os.listdir(target.exe_dir) if n.lower().endswith(".exe")}
            except OSError:
                pass
        hits = [n for n in names if n in exes or n.split(".")[0].split("-")[0] in EMULATOR_EXES]
    return hits[0] if hits else ""


# --------------------------------------------------------------------------- the swap
def owner(save_dir):
    try:
        with open(os.path.join(save_dir, MARKER), encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def _seed_files(d):
    try:
        return [n for n in os.listdir(d) if n not in SHARED]
    except OSError:
        return []


def _has_progress(d):
    return any(re.match(r"slot_\d+$", n) and os.listdir(os.path.join(d, n)) for n in _seed_files(d)
               if os.path.isdir(os.path.join(d, n)))


def _copy_items(src, dst, names):
    os.makedirs(dst, exist_ok=True)
    for n in names:
        s, t = os.path.join(src, n), os.path.join(dst, n)
        if os.path.isdir(t):
            shutil.rmtree(t)
        elif os.path.exists(t):
            os.remove(t)
        if os.path.isdir(s):
            shutil.copytree(s, t)
        else:
            shutil.copy2(s, t)


def _store_dir(target, seed, save_dir):
    folder = seed_folder(target, seed)
    return os.path.join(folder, STORE, os.path.basename(save_dir)) if folder else None


# Stored saves carry the seed's settings.txt (version, seed, settings string). A folder name used again for a
# different seed (a custom mod folder name) has a different settings.txt: its old saves aren't brought back.
IDENTITY = "seed_settings.txt"


def _identity(store):
    """settings.txt of the seed folder that holds `store` (<seed>/saves/<account>)."""
    try:
        with open(os.path.join(os.path.dirname(os.path.dirname(store)), "settings.txt"), encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def _write_identity(store):
    with open(os.path.join(store, IDENTITY), "w", encoding="utf-8") as fh:
        fh.write(_identity(store))


def switch_saves(target, new_seed, progress=print):
    """Put `new_seed`'s save slots into the game, after storing the ones there now. Returns what happened."""
    if not target.save_dirs:
        return ["no %s save folder yet (the game hasn't saved): %s starts with new saves" % (target.kind, new_seed)]
    running = game_running(target)
    if running:
        raise SaveError("%s is running; close it first, so its saves can be switched" % running)
    done = []
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    for d in target.save_dirs:
        old = owner(d)
        if old == new_seed:
            done.append("%s: already %s's saves" % (os.path.basename(d), new_seed))
            continue
        # 1. store what's there now
        items = _seed_files(d)
        dest = _store_dir(target, old, d) if old else None
        if dest is None and _has_progress(d):
            dest = os.path.join(BACKUPS, "%s %s %s" % (stamp, old or "unassigned", os.path.basename(d)))
        if dest is not None and items:
            if os.path.isdir(dest):
                for n in _seed_files(dest):                # an older copy of this seed's saves
                    p = os.path.join(dest, n)
                    shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
            _copy_items(d, dest, items)
            if not dest.startswith(BACKUPS):
                _write_identity(dest)
            done.append("%s: saves of %s kept in %s" % (os.path.basename(d), old or "no seed", dest))
        # 2. bring in the new seed's (or empty slots)
        src = _store_dir(target, new_seed, d)
        stored = _seed_files(src) if src and os.path.isdir(src) else []
        if stored:
            try:
                with open(os.path.join(src, IDENTITY), encoding="utf-8") as fh:
                    same = fh.read() == _identity(src)
            except OSError:
                same = True                                 # no record: trust it
            if not same:
                stale = os.path.join(BACKUPS, "%s %s (older seed of that name) %s" % (stamp, new_seed,
                                                                                     os.path.basename(d)))
                shutil.move(src, stale)
                done.append("%s: %s's stored saves are from another seed of the same name; moved to %s" % (
                    os.path.basename(d), new_seed, stale))
                stored = []
        for n in items:
            p = os.path.join(d, n)
            if n in stored or re.match(r"slot_\d+$", n):
                shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
        if stored:
            _copy_items(src, d, stored)
            done.append("%s: %s's saves restored" % (os.path.basename(d), new_seed))
        else:
            done.append("%s: new saves for %s (empty slots)" % (os.path.basename(d), new_seed))
        with open(os.path.join(d, MARKER), "w", encoding="utf-8") as fh:
            fh.write(new_seed + "\n")
    return done


def play(target, name, progress=print):
    """Switch `name` on (and every other seed off) and give it its own saves."""
    running = game_running(target)
    if running:
        raise SaveError("%s is running; close it first" % running)
    switch_on(target, name)
    return switch_saves(target, name, progress)
