"""Extract the item icons from OoT (Switch 2) romfs as PNGs, for building a tracker.

The game files can be an extracted romfs folder (or the game folder holding it) or the game's .nup package,
read directly without extracting it (newest base/update package inside; reader in nup/, a55uka/nup, MIT).

Reads every ``UI/Tex/Icon/*.bntx.zs`` (zstd-compressed BNTX, one ASTC 4x4
texture each, already the largest size the game ships), un-swizzles the
block-linear data, decodes it and saves ``<IconName>.png``.

Quest items are not in that folder. Medallions and spirit stones
(DataFileImportantIcon_00-08), songs (OcarinaMelodyIcon_00-12), heart pieces,
ocarina buttons, etc. are pulled from the Common layout archive into
``extras/`` (skip with ``--no-extras``).

Requirements: Python 3.14+ (stdlib zstd), then
    pip install texture2ddecoder pillow

Usage:
    python extract_item_icons.py --romfs PATH [--out DIR] [--shadows] [--grayscale] [--no-extras]
(PATH: the romfs folder, the game folder holding it, or the game's .nup file)
"""
import argparse
import hashlib
import re
import struct
import sys
from pathlib import Path

try:
    from compression import zstd
except ImportError:
    raise ImportError("Needs Python 3.14+ for compression.zstd") from None
try:
    import texture2ddecoder as t2d
    from PIL import Image
except ImportError:
    raise ImportError("Missing packages. Run:  pip install texture2ddecoder pillow") from None


# Common-layout textures worth having on a tracker (used with --extras).
EXTRA_NAMES = re.compile(r"^(" + "|".join([
    r"CollectHeart(Base|Piece)_\d+",
    r"OcarinaMelodyIcon_\d+",
    r"OcarinaButton[ABXYLR]_\d+",
    r"DataFileImportantIcon_\d+",
    r"Nt_RupeeIconNew_\d+",
    r"AmiiboIcon(Big)?_\d+",
    r"HeartW_00_ASTC4x4",
    r"ClearMark_\d+",
    r"QuestionIcon_\d+",
]) + r")$")

# BNTX format type (high byte of the format id) -> (bytes per 4x4 block, decoder)
FORMATS = {
    0x1A: (8, t2d.decode_bc1),
    0x1C: (16, t2d.decode_bc3),
    0x1D: (8, t2d.decode_bc4),
    0x1E: (16, t2d.decode_bc5),
    0x20: (16, t2d.decode_bc7),
    0x2D: (16, lambda d, w, h: t2d.decode_astc(d, w, h, 4, 4)),
}


def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]


def deswizzle(data, width_bytes, rows, block_height_log2):
    """Undo block-linear swizzling (GOB = 64 bytes x 8 rows = 512 bytes).

    Inside a GOB the Switch 2 puts the 16-byte units in a different order from
    the Switch 1 / Tegra X1 layout: address bits 4..8 = y0, y1, x16, y2, x32.
    """
    bh = 1 << block_height_log2
    gobs_x = -(-width_bytes // 64)
    out = bytearray(width_bytes * rows)
    for y in range(rows):
        row_base = ((y // (8 * bh)) * 512 * bh * gobs_x + ((y % (8 * bh)) // 8) * 512
                    + (y & 1) * 16 + ((y >> 1) & 1) * 32 + ((y >> 2) & 1) * 128)
        dst = y * width_bytes
        for x in range(0, width_bytes, 16):  # each 16-byte run is contiguous
            addr = row_base + (x // 64) * 512 * bh + ((x >> 4) & 1) * 64 + ((x >> 5) & 1) * 256
            n = min(16, width_bytes - x)
            out[dst + x:dst + x + n] = data[addr:addr + n]
    return bytes(out)


def apply_comp_sel(img, sel):
    """Apply the BNTX channel mapping (per R,G,B,A: 0=zero 1=one 2..5=source R,G,B,A)."""
    if sel == b"\x02\x03\x04\x05":
        return img
    src = img.split()
    const = {0: Image.new("L", img.size, 0), 1: Image.new("L", img.size, 255)}
    return Image.merge("RGBA", [src[s - 2] if 2 <= s <= 5 else const.get(s, const[0]) for s in sel])


def read_textures(bntx, name_filter=None):
    """Yield (name, RGBA PIL.Image) for each texture in a BNTX file (mip 0, layer 0)."""
    count, info_ptrs = u32(bntx, 0x24), u64(bntx, 0x28)
    for i in range(count):
        t = u64(bntx, info_ptrs + 8 * i)  # BRTI header
        name_off = u64(bntx, t + 0x60)
        name = bntx[name_off + 2:name_off + 2 + u16(bntx, name_off)].decode()
        if name_filter and not name_filter.match(name):
            continue
        fmt = u32(bntx, t + 0x1C)
        if fmt >> 8 not in FORMATS:
            print(f"  skip {name}: unsupported format {fmt:#x}")
            continue
        bpb, decode = FORMATS[fmt >> 8]
        w, h = u32(bntx, t + 0x24), u32(bntx, t + 0x28)
        data_off = u64(bntx, u64(bntx, t + 0x70))  # first mip pointer
        linear = deswizzle(bntx[data_off:], -(-w // 4) * bpb, -(-h // 4), u32(bntx, t + 0x34))
        img = Image.frombytes("RGBA", (w, h), decode(linear, w, h), "raw", "BGRA")
        yield name, apply_comp_sel(img, bntx[t + 0x58:t + 0x5C])


def grayscale(img):
    """Black-and-white copy that keeps the original transparency."""
    lum = img.convert("L")
    return Image.merge("RGBA", (lum, lum, lum, img.getchannel("A")))


def export(data, dest, name_filter=None, gray_dest=None):
    """Save the textures of one .bntx.zs file (its bytes) as PNGs."""
    n = 0
    for name, img in read_textures(zstd.decompress(data), name_filter):
        img.save(dest / f"{name}.png")
        n += 1
        if gray_dest:
            grayscale(img).save(gray_dest / f"{name}.png")
            n += 1
    return n


COMMON_BNTX = "UI/Layout2Archive/Common.Product.100.Nin_Ounce_NVN2.bntx.zs"


# ---------------------------------------------------------------- game files: folder or .nup

class FolderRomfs:
    """An extracted romfs folder."""

    def __init__(self, path):
        self.path = self.label = Path(path)

    def files(self, folder):
        """Names of the .bntx.zs files in a romfs folder (sorted), or None when the folder is missing."""
        d = self.path / folder
        return sorted(f.name for f in d.glob("*.bntx.zs")) if d.is_dir() else None

    def exists(self, rel):
        return (self.path / rel).is_file()

    def read(self, rel):
        return (self.path / rel).read_bytes()

    def close(self):
        pass


class NupRomfs:
    """The romfs of the newest base/update package in a .nup, read in place (each file checked against its
    SHA-256 in the package)."""

    def __init__(self, path):
        from nup import format as NF
        from nup.read import NupReader
        self.path = self.label = Path(path)
        self.reader = NupReader(str(path))
        try:
            pkgs = [p for p in self.reader.packages if p.kind in (NF.KIND_BASE, NF.KIND_UPDATE)]
            if not pkgs or len({p.title_id & ~0xFFF for p in pkgs}) != 1:
                raise ValueError("the .nup must hold one game's base or update package")
            newest = max(p.version for p in pkgs)
            pkgs = [p for p in pkgs if p.version == newest]
            if len(pkgs) != 1 or pkgs[0].romfs_dir == NF.NO_DIR:
                raise ValueError("the .nup's newest package has no romfs")
            self.dirs, self.index = {}, {}
            r, stack, seen = self.reader, [(pkgs[0].romfs_dir, "")], set()
            while stack:
                d, prefix = stack.pop()
                if d in seen:
                    raise ValueError("the .nup's folder tree is damaged")
                seen.add(d)
                _, first, count = r.dirs[d]
                names = self.dirs[prefix.rstrip("/")] = []
                for child in r.children[first:first + count]:
                    is_dir = child < r.dir_count
                    entry = child if is_dir else child - r.dir_count
                    name = (r.dirs if is_dir else r.files)[entry][0].decode("utf-8")
                    if is_dir:
                        stack.append((entry, prefix + name + "/"))
                    else:
                        names.append(name)
                        self.index[prefix + name] = entry
        except BaseException:
            self.reader.close()
            raise

    def files(self, folder):
        names = self.dirs.get(folder.strip("/"))
        return None if names is None else sorted(n for n in names if n.endswith(".bntx.zs"))

    def exists(self, rel):
        return rel in self.index

    def read(self, rel):
        i = self.index[rel]
        data = self.reader.read_file(i)
        if hashlib.sha256(data).digest() != self.reader.file_info(i)[2]:
            raise ValueError(f"romfs/{rel} in {self.path} is damaged (SHA-256 mismatch)")
        return data

    def close(self):
        self.reader.close()


def is_nup(path):
    path = Path(path)
    try:
        with open(path, "rb") as fh:
            return path.is_file() and fh.read(3) == b"NUP"
    except OSError:
        return False


def find_romfs(path):
    """The game files for a path: a .nup file, the romfs folder itself or a folder holding it. Returns a
    FolderRomfs or NupRomfs, or None if the path holds no icons. A .nup that can't be read raises ValueError."""
    path = Path(str(path).strip().strip('"'))
    if path.is_file():
        if not is_nup(path):
            return None
        try:
            src = NupRomfs(path)
        except (ValueError, OSError, IndexError, struct.error) as e:
            raise ValueError(f"{path.name} is not a readable .nup: {e}") from e
        if src.files(ICON_FOLDER) is None:
            src.close()
            return None
        return src
    for cand in (path, path / "romfs"):
        if (cand / ICON_FOLDER).is_dir():
            return FolderRomfs(cand)
    return None


ICON_FOLDER = "UI/Tex/Icon"


def extract(romfs, out, shadows=False, grayscale=False, extras=True, log=print):
    """Extract the icons from `romfs` (a FolderRomfs / NupRomfs from find_romfs, or a romfs folder path) into
    `out`. Returns the number of PNGs written. Raises FileNotFoundError when the icon files are missing."""
    if isinstance(romfs, (str, Path)):
        src = find_romfs(romfs)
        if src is None:
            raise FileNotFoundError(f"No {ICON_FOLDER} in {romfs}")
    else:
        src = romfs
    out = Path(out)
    gray = out / "grayscale" if grayscale else None
    # (source folder, colour output, grayscale output or None)
    jobs = [(ICON_FOLDER, out, gray)]
    if shadows:
        jobs.append(("UI/Tex/IconSh", out / "shadows", None))  # already black

    total = 0
    for folder, dest, gray_dest in jobs:
        files = src.files(folder)
        if files is None:
            raise FileNotFoundError(f"Not found: {src.label}/{folder}")
        for d in (dest, gray_dest):
            if d:
                d.mkdir(parents=True, exist_ok=True)
        log(f"{folder}  ->  {dest}  ({len(files)} files)")
        for name in files:
            total += export(src.read(f"{folder}/{name}"), dest, gray_dest=gray_dest)

    if extras:
        if not src.exists(COMMON_BNTX):
            raise FileNotFoundError(f"Not found: {src.label}/{COMMON_BNTX}")
        dest = out / "extras"
        gray_dest = gray / "extras" if gray else None
        for d in (dest, gray_dest):
            if d:
                d.mkdir(parents=True, exist_ok=True)
        log(f"{COMMON_BNTX.rsplit('/', 1)[1]}  ->  {dest}  (filtered)")
        total += export(src.read(COMMON_BNTX), dest, EXTRA_NAMES, gray_dest)

    log(f"Done: {total} PNGs written to {out}")
    return total


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--romfs", required=True, help="your extracted romfs folder, or your game's .nup file")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent / "icons"),
                    help="output folder (default: %(default)s)")
    ap.add_argument("--shadows", action="store_true", help="also export the *_Sh drop-shadow icons")
    ap.add_argument("--no-extras", dest="extras", action="store_false",
                    help="skip the quest-item icons from the Common layout archive")
    ap.add_argument("--grayscale", action="store_true",
                    help="also export black-and-white copies (e.g. 'not collected' tracker state) into grayscale/")
    args = ap.parse_args()
    try:
        extract(args.romfs, args.out, args.shadows, args.grayscale, args.extras)
    except (FileNotFoundError, ValueError) as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main()
