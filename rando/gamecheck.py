"""Game version check: only run on game versions the randomizer is known to work with.

The randomizer edits data files whose layout can change between game updates, so a different version could
produce a broken mod. The check hashes the game's executable (`exefs/main`) with SHA-256 and compares it with
KNOWN_VERSIONS. The exefs folder is normally next to the romfs folder (`<game>/exefs` and `<game>/romfs`).
For a .nup the exefs inside the package the generator reads is checked (see rando/gamefiles.py).

To add a version: dump its exefs, run `python -m rando.gamecheck <exefs folder>` and add the printed hash.
"""
import hashlib
import os

TITLE_ID = "0400486024dec000"

# SHA-256 of exefs/main -> description shown to the user
KNOWN_VERSIONS = {
    "7db9ddfda088c22d219ef13496decd7077c68cd67d4b37f53f4ac46a082768f2": "v1.1.1",
}

_cache = {}   # (path, size, mtime) -> sha256, so re-checking the same file is instant


class GameCheck:
    """Result of a check. `ok` is True only for a whitelisted version; `message` explains the result."""

    def __init__(self, ok, status, message, exefs=None, sha256=None, version=None):
        self.ok, self.status, self.message = ok, status, message
        self.exefs, self.sha256, self.version = exefs, sha256, version

    def __repr__(self):
        return "GameCheck(%s, %s)" % (self.status, self.message)


def default_exefs(romfs):
    """`<game>/exefs` for a romfs at `<game>/romfs` (or for the game folder `<game>` itself), or None."""
    from .gamefiles import clean_path, find_romfs
    romfs = clean_path(romfs)
    if not romfs:
        return None
    found = find_romfs(romfs)                     # the real romfs, if a subfolder or the game folder was chosen
    romfs = os.path.abspath(found or romfs)
    for path in (os.path.join(os.path.dirname(romfs), "exefs"), os.path.join(romfs, "exefs")):
        if os.path.isfile(os.path.join(path, "main")):
            return path
    for path in (os.path.join(os.path.dirname(romfs), "exefs"), os.path.join(romfs, "exefs")):
        if os.path.isdir(path):
            return path
    return None


def _sha256(path):
    st = os.stat(path)
    key = (os.path.abspath(path), st.st_size, st.st_mtime_ns)
    if key not in _cache:
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for block in iter(lambda: fh.read(1 << 20), b""):
                h.update(block)
        _cache[key] = h.hexdigest()
    return _cache[key]


def _title_id(npdm):
    """Program ID from main.npdm's ACI0 section (a path or the file's bytes), or None if it can't be read."""
    try:
        if isinstance(npdm, bytes):
            data = npdm
        else:
            with open(npdm, "rb") as fh:
                data = fh.read()
        i = data.find(b"ACI0")
        return data[i + 0x10:i + 0x18][::-1].hex() if i >= 0 else None
    except OSError:
        return None


def _verdict(source, tid, digest):
    """GameCheck for a title ID and exefs/main hash read from `source` (folder or .nup)."""
    if tid and tid != TITLE_ID:
        return GameCheck(False, "wrong_game", "This game is a different title (title ID %s, expected %s)."
                         % (tid.upper(), TITLE_ID.upper()), source)
    version = KNOWN_VERSIONS.get(digest)
    if version is None:
        return GameCheck(False, "unsupported",
                         "Sorry, this game version isn't supported. It may be outdated, or newer than this release "
                         "of the randomizer. Please update the game and the randomizer to their latest versions.\n"
                         "(SHA-256 of exefs/main: %s)" % digest, source, digest)
    return GameCheck(True, "ok", "Supported game version (%s)." % version, source, digest, version)


def check_nup(path):
    """Check the exefs of the package a .nup's romfs is read from."""
    from .gamefiles import GameFilesError, NupFiles
    try:
        nup = NupFiles(path)
    except GameFilesError as e:
        return GameCheck(False, "missing", str(e), path)
    try:
        key = ("nup", os.path.abspath(path), os.stat(path).st_mtime_ns)
        if key not in _cache:
            _cache[key] = (_title_id(nup.exefs_read("main.npdm") or b""), nup.exefs_sha256("main"))
        tid, digest = _cache[key]
    except GameFilesError as e:
        return GameCheck(False, "missing", str(e), path)
    finally:
        nup.close()
    if digest is None:
        return GameCheck(False, "missing", "The .nup has no exefs/main to check the game version with.", path)
    return _verdict(path, tid, digest)


def check(exefs=None, romfs=None):
    """Check a game: `romfs` may be a .nup (its own exefs is checked), else the exefs folder `exefs` (or the one
    next to the romfs folder when `exefs` is empty)."""
    from .gamefiles import clean_path, find_romfs, is_nup
    romfs = clean_path(romfs)
    if romfs and is_nup(romfs):
        return check_nup(romfs)
    exefs = clean_path(exefs) or default_exefs(romfs)
    if not exefs:
        if romfs and not find_romfs(romfs):
            return GameCheck(False, "missing", "%s is not the game's romfs folder (it holds Banc, Event, Pack, RSDB...). "
                                               "Choose the romfs folder or the game's .nup file." % romfs)
        where = os.path.dirname(os.path.abspath(find_romfs(romfs))) if romfs else "the romfs folder's parent"
        return GameCheck(False, "missing", "exefs folder not found in %s. Extract the exefs from your game the same "
                                           "way as the romfs and keep both side by side (<game>/romfs and "
                                           "<game>/exefs), or choose the game's .nup file." % where)
    main = os.path.join(exefs, "main")
    if not os.path.isfile(main):
        return GameCheck(False, "missing", "No 'main' file in %s. Choose the game's extracted exefs folder." % exefs,
                         exefs)
    return _verdict(exefs, _title_id(os.path.join(exefs, "main.npdm")), _sha256(main))


if __name__ == "__main__":
    import sys
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    res = check_nup(arg) if arg and os.path.isfile(arg) else check(arg)
    print(res.message)
    if res.sha256:
        print("sha256:", res.sha256)
    sys.exit(0 if res.ok else 1)
