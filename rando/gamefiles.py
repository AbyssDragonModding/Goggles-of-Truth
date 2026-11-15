"""The game's files, read from an extracted romfs folder or straight from a .nup package.

Everything the generator reads from the game goes through a GameFiles object, so both sources work the same way.
Paths are romfs-relative with "/" separators ("Pack/ZsDic.pack.zs"); "" is the romfs root. Nothing is ever
written to the source: the .nup is opened read-only and the mod is written to its own folder.

A .nup (NX Package, https://github.com/a55uka/nup) holds a game's base and/or update packages, each with its own
exefs and full romfs. Like Clawshot, the newest base/update package of the one game in the file is used, and every
file read is checked against the SHA-256 stored in the package.
"""
import hashlib
import os

from .nup import format as NF
from .nup.read import NupReader

NUP_MAGIC = b"NUP"
APPLICATION_ID_MASK = ~0xFFF   # an update's title ID is the base's + 0x800; both share the application ID


class GameFilesError(Exception):
    """The chosen path isn't a usable romfs folder or .nup."""


def _rel(path):
    return "/".join(p for p in path.replace("\\", "/").split("/") if p and p != ".")


def clean_path(path):
    """A chosen or typed path made usable: no surrounding quotes or spaces, no file:// URL form, no \\\\?\\
    prefix, the platform's separators and no trailing separator."""
    path = (path or "").strip().strip("\0").strip().strip('"').strip("'").strip()
    if path.lower().startswith("file://"):
        from urllib.parse import unquote, urlparse
        path = unquote(urlparse(path).path)
        if os.name == "nt" and len(path) > 2 and path[0] == "/" and path[2] == ":":
            path = path[1:]                          # /D:/x -> D:/x
    if path.startswith(("\\\\?\\", "//?/")):
        path = path[4:]
    return os.path.normpath(path) if path else ""


def is_nup(path):
    """True for a file that starts with the NUP magic (whatever its extension)."""
    path = clean_path(path)
    try:
        if not os.path.isfile(path):
            return False
        with open(path, "rb") as fh:
            return fh.read(3) == NUP_MAGIC
    except OSError:
        return False


def _is_romfs(folder):
    return os.path.isfile(os.path.join(folder, "Pack", "ZsDic.pack.zs")) and os.path.isdir(os.path.join(folder, "Banc"))


def find_romfs(folder):
    """The romfs for a chosen folder: the folder itself, its 'romfs' subfolder (a dump's game folder), or the romfs
    it is inside (a folder dialog can hand back a subfolder such as romfs/Banc). None when there is none."""
    folder = clean_path(folder)
    if not folder or not os.path.isdir(folder):
        return None
    folder = os.path.abspath(folder)
    if _is_romfs(os.path.join(folder, "romfs")) and not _is_romfs(folder):
        return os.path.join(folder, "romfs")
    cand = folder
    for _ in range(4):
        if _is_romfs(cand):
            return cand
        parent = os.path.dirname(cand)
        if parent == cand:
            break
        cand = parent
    return None


class GameFiles:
    kind = "?"
    path = ""        # what the user chose (folder or .nup), for messages

    def read(self, rel):
        raise NotImplementedError

    def exists(self, rel):
        """True if `rel` is a file."""
        raise NotImplementedError

    def isdir(self, rel):
        raise NotImplementedError

    def listdir(self, rel=""):
        """Names of the files and folders in folder `rel` (unsorted), like os.listdir."""
        raise NotImplementedError

    def close(self):
        pass

    def __repr__(self):
        return "%s(%r)" % (type(self).__name__, self.path)


class FolderFiles(GameFiles):
    """An extracted romfs folder."""
    kind = "folder"

    def __init__(self, romfs):
        self.path = self.romfs = romfs

    def _abs(self, rel):
        return os.path.join(self.romfs, *_rel(rel).split("/")) if _rel(rel) else self.romfs

    def read(self, rel):
        with open(self._abs(rel), "rb") as fh:
            return fh.read()

    def exists(self, rel):
        return os.path.isfile(self._abs(rel))

    def isdir(self, rel):
        return os.path.isdir(self._abs(rel))

    def listdir(self, rel=""):
        return os.listdir(self._abs(rel))


class NupFiles(GameFiles):
    """The romfs and exefs of the newest base/update package in a .nup."""
    kind = "nup"

    def __init__(self, path):
        self.path = path
        try:
            self.reader = NupReader(path)
        except (NF.NupError, ValueError, IndexError, UnicodeError) as e:
            raise GameFilesError("%s is not a valid .nup: %s" % (path, e)) from e
        except OSError as e:
            raise GameFilesError("Couldn't open %s: %s" % (path, e)) from e
        try:
            packages = [p for p in self.reader.packages if p.kind in (NF.KIND_BASE, NF.KIND_UPDATE)]
            if not packages or len({p.title_id & APPLICATION_ID_MASK for p in packages}) != 1:
                raise GameFilesError("The .nup must hold one game's base or update package.")
            newest = max(p.version for p in packages)
            packages = [p for p in packages if p.version == newest]
            if len(packages) != 1 or packages[0].romfs_dir == NF.NO_DIR:
                raise GameFilesError("The .nup's newest package has no complete romfs.")
            self.package = packages[0]
            self.title_id = "%016x" % self.package.title_id
            self._romfs = None   # built on first use: (dirs {rel: {name: is_dir}}, files {rel: index})
        except BaseException:
            self.reader.close()
            raise

    # -------------------------------------------------------------- tree
    def _tree(self, top):
        """({folder rel: {name: is_dir}}, {file rel: file index}) for one package folder."""
        r = self.reader
        dirs, files, seen = {}, {}, set()
        stack = [(top, "")]
        while stack:
            index, prefix = stack.pop()
            if index in seen:
                raise GameFilesError("The .nup's folder tree is damaged (a folder appears twice).")
            seen.add(index)
            _, first, count = r.dirs[index]
            entries = dirs[prefix.rstrip("/")] = {}
            for child in r.children[first:first + count]:
                is_dir = child < r.dir_count
                entry = child if is_dir else child - r.dir_count
                table = r.dirs if is_dir else r.files
                if entry >= len(table):
                    raise GameFilesError("The .nup's folder tree is damaged (index %d out of range)." % child)
                name = table[entry][0].decode("utf-8")
                if not name or name in (".", "..") or any(c in name for c in '/\\\0'):
                    raise GameFilesError("The .nup has an unsafe file name: %r" % (prefix + name))
                entries[name] = is_dir
                if is_dir:
                    stack.append((entry, prefix + name + "/"))
                else:
                    files[prefix + name] = entry
        return dirs, files

    @property
    def romfs(self):
        if self._romfs is None:
            self._romfs = self._tree(self.package.romfs_dir)
        return self._romfs

    def _read_index(self, index, what):
        data = self.reader.read_file(index)
        if hashlib.sha256(data).digest() != self.reader.file_info(index)[2]:
            raise GameFilesError("%s in %s is damaged (SHA-256 mismatch)." % (what, self.path))
        return data

    # -------------------------------------------------------------- romfs
    def read(self, rel):
        rel = _rel(rel)
        index = self.romfs[1].get(rel)
        if index is None:
            raise FileNotFoundError("romfs/%s is not in %s" % (rel, self.path))
        return self._read_index(index, "romfs/" + rel)

    def exists(self, rel):
        return _rel(rel) in self.romfs[1]

    def isdir(self, rel):
        return _rel(rel) in self.romfs[0]

    def listdir(self, rel=""):
        rel = _rel(rel)
        if rel not in self.romfs[0]:
            raise FileNotFoundError("romfs/%s is not a folder in %s" % (rel, self.path))
        return list(self.romfs[0][rel])

    # -------------------------------------------------------------- exefs
    def exefs_file(self, name):
        """File index of exefs/<name>, or None."""
        if self.package.exefs_dir == NF.NO_DIR:
            return None
        r = self.reader
        _, first, count = r.dirs[self.package.exefs_dir]
        for child in r.children[first:first + count]:
            if child >= r.dir_count and r.files[child - r.dir_count][0].decode("utf-8", "replace") == name:
                return child - r.dir_count
        return None

    def exefs_sha256(self, name):
        """SHA-256 (hex) of exefs/<name>, checked by reading it, or None if it's missing."""
        index = self.exefs_file(name)
        return None if index is None else hashlib.sha256(self._read_index(index, "exefs/" + name)).hexdigest()

    def exefs_read(self, name):
        index = self.exefs_file(name)
        return None if index is None else self._read_index(index, "exefs/" + name)

    def close(self):
        self.reader.close()


def open_game(path):
    """GameFiles for a .nup, an extracted romfs folder, or a game folder holding 'romfs'."""
    if isinstance(path, GameFiles):
        return path
    path = clean_path(path)
    if not path:
        raise GameFilesError("Choose your game: an extracted romfs folder or a .nup file.")
    if os.path.isfile(path):
        if not is_nup(path):
            raise GameFilesError("%s is not a .nup package. Choose a .nup file or the extracted romfs folder."
                                 % path)
        return NupFiles(path)
    if os.path.isdir(path):
        romfs = find_romfs(path)
        if romfs is None:
            raise GameFilesError("That folder does not look like the game's extracted romfs\n"
                                 "(expected Pack/ZsDic.pack.zs and a Banc folder).")
        return FolderFiles(romfs)
    raise GameFilesError("%s doesn't exist." % path)
