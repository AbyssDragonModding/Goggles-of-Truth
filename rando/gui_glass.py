"""Alternate "glass" GUI built with Raven (https://github.com/oscar-soirey/Raven).

Install the Python bindings first:   pip install raven-gui
Started by ootr_remake.pyw.
"""
import math
import os
import queue
import random
import struct
import subprocess
import sys
import threading
import traceback
import zlib

import raven as r

from . import settings as S
from . import gamecheck, gamefiles, longshot, updater, usersettings
from .generator import VERSION, generate

ACCENT = (0.36, 0.80, 0.56)          # Kokiri green
GOLD = (0.96, 0.80, 0.38)            # Triforce gold for headings
MUTED = (0.78, 0.82, 0.86, 0.85)
OK_GREEN = (0.40, 0.86, 0.52)
BAD_RED = (0.96, 0.46, 0.44)


# --------------------------------------------------------------------------- wallpaper
def _wallpaper_png(w=640, h=420):
    """Procedural night-sky gradient with soft glows, made at runtime (no image files shipped).
    Glass materials blur and refract this, which gives the frosted look."""
    glows = [(0.18, 0.22, 0.42, (34, 168, 116)),   # forest green
             (0.84, 0.18, 0.34, (214, 168, 64)),   # gold
             (0.62, 0.92, 0.46, (58, 92, 210)),    # lake blue
             (0.05, 0.95, 0.30, (120, 60, 170))]   # twilight purple
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        v = y / h
        for x in range(w):
            u = x / w
            c = [10 + 8 * v, 16 + 10 * (1 - v), 30 + 22 * v]
            for gx, gy, rad, col in glows:
                d = math.hypot(u - gx, (v - gy) * h / w) / rad
                k = max(0.0, 1.0 - d) ** 2 * 0.6
                c = [c[i] * (1 - k) + col[i] * k for i in range(3)]
            rows += bytes(int(min(255, max(0, q))) for q in c)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))


# --------------------------------------------------------------------------- XML layout
UI_XML = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ui", "main.xml")
GOLD_HEX, MUTED_HEX = "#F5CC61", "#C7D1DBD9"


def _attr(text):
    """A value for an XML attribute: escaped, line breaks kept."""
    return (str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;").replace("\n", "&#10;"))


def _card(title, body, top=0, bottom=0):
    return ('<Border Material="FrostedGlass" CornerRadius="16" Padding="18,14,18,16" Shadow="18,0,4" Slot.Auto="true" '
            'Slot.Padding="6,%d,6,%d"><VBox Spacing="10"><Label Text="%s" TextSize="16" Color="%s"/>%s</VBox></Border>'
            % (top, bottom, _attr(title), GOLD_HEX, body))


def settings_xml(tab):
    """The cards of one settings tab, from rando/settings.py: one card per group, a switch per on/off setting,
    a label and a drop-down per choice. Each control is named set_<key> and fires the action set.<key>."""
    groups = []
    for key, t, group, text, typ, opts, default, tip in S.SETTINGS:
        if t != tab or typ == "list":
            continue
        if not groups or groups[-1][0] != group:
            groups.append((group, []))
        if typ == "bool":
            groups[-1][1].append('<Checkbox Name="set_%s" Style="Switch" Text="%s" Tooltip="%s" OnChanged="set.%s"/>'
                                 % (key, _attr(text), _attr(tip), key))
        else:
            items = "|".join(label.replace("|", "/") for _, label in opts)
            groups[-1][1].append(
                '<HBox Spacing="12"><Label Text="%s" TextSize="14" Tooltip="%s" Slot.Fill="1" Slot.VAlign="Center"/>'
                '<ComboBox Name="set_%s" Items="%s" Tooltip="%s" OnChanged="set.%s" Slot.Fill="0.9"/></HBox>'
                % (_attr(text), _attr(tip), key, _attr(items), _attr(tip), key))
    return "".join(_card(g, "".join(rows), top=10 if i == 0 and tab != "ROM Options" else 0)
                   for i, (g, rows) in enumerate(groups))


def unsupported_xml():
    return "".join('<Label Text="%s" TextSize="14"/><Label Text="%s" TextSize="13" Color="%s" Wrap="true" '
                   'Slot.Padding="20,0,0,6"/>' % (_attr("\u2022  " + name), _attr(why), MUTED_HEX)
                   for name, why in S.UNSUPPORTED)


def window_xml():
    """rando/ui/main.xml with its generated parts filled in."""
    with open(UI_XML, encoding="utf-8") as fh:
        text = fh.read()
    for tab in {s[1] for s in S.SETTINGS}:
        text = text.replace("<!--@@settings %s@@-->" % tab, settings_xml(tab))
    text = text.replace("@@preset_items@@", _attr("|".join(PRESET_ITEMS)))
    tip = "Sets every gameplay setting for a seed difficulty (Excluded Locations and Create Spoiler Log are kept).\n" \
          "Only options confirmed in-game are used. Change anything afterwards and the preset shows Custom.\n\n" + \
          "\n\n".join("%s: %s" % (n, S.PRESET_TIPS[n]) for n in S.PRESETS)
    text = text.replace("@@preset_tip@@", _attr(tip))
    return text.replace("<!--@@unsupported@@-->", unsupported_xml())


PRESET_ITEMS = ["Custom"] + list(S.PRESETS)


# --------------------------------------------------------------------------- app
class GlassApp:
    def __init__(self):
        if not r.Rinit(r.R_BACKEND_VULKAN):
            raise RuntimeError("Raven could not start (a Vulkan driver is required).")
        r.Rlook_set(r.R_LOOK_RAVEN_GLASS_DARK)
        r.Rtheme_set_dark(1)
        r.Rtheme_set_accent(*ACCENT)
        r.Rtheme_set_material(r.R_MATERIAL_FROSTED_GLASS)
        tex = r.Rtexture_create(_wallpaper_png())
        if tex != r.R_INVALID_ID:
            r.Rtheme_set_wallpaper(tex)

        st, paths, self.load_messages = usersettings.load()
        self.st = S.normalize(st)
        self.excluded = set(self.st["excluded_locations"])
        self.paths = {"romfs": paths["romfs"], "out": paths["out"], "name": "", "seed": ""}
        self._syncing = False        # True while the preset drop-down is set from code
        self._loaded = False         # nothing is saved until the window is filled in
        self.game = None             # last gamecheck.GameCheck result
        self.queue = queue.Queue()
        self.busy = False
        self.world = None
        self.world_path = None
        self.locations = []          # all location names (from the scan)
        self.visible = []            # names currently shown in the exclusion list
        self.filter = ""
        self.log_lines = []
        self.controls = {}           # setting key -> widget
        self._phase = 0.0

        self.window = r.Rwindow_create_from_xml(window_xml())
        if self.window == r.R_INVALID_ID:
            err = r.Rerror_get_last()
            raise RuntimeError("The window layout (rando/ui/main.xml) could not be loaded: %s" % (err[1] or err[0]))
        self._bind()
        r.Rwindow_show(self.window)
        self._timer = r.Rtimer_create(0.1, r.R_TRUE, self._poll)

    # ------------------------------------------------------------------ build
    def _w(self, name):
        w = r.Rwidget_find(self.window, name)
        if w == r.R_INVALID_ID:
            raise RuntimeError("rando/ui/main.xml has no widget named %s" % name)
        return w

    def _bind(self):
        """Find the named widgets of the XML layout, fill them in and bind its actions."""
        for name in ("romfs_in", "out_in", "name_in", "seed_in", "hash_lab", "game_lab", "filter_in",
                     "excl_count", "excl_list", "sstr_in", "progress", "log", "preset_in", "preset_lab"):
            setattr(self, name, self._w(name))
        self.gen_btn = self._w("generate")
        r.Rlabel_set_text(self._w("subtitle"), "Switch 2 remake edition  \u00b7  v%s  \u00b7  your game, your mod" % VERSION)
        for key in ("romfs", "out"):
            r.Rtext_input_set_text(getattr(self, key + "_in"), self.paths[key])

        actions = {
            "rando.open_folder": self.open_output, "rando.generate": self.generate, "rando.scan": self.scan,
            "rando.random_seed": self._random_seed, "rando.clear_excluded": self._clear_excluded,
            "rando.import_string": self._import_string, "rando.copy_string": self._copy_string,
            "rando.reset": lambda: self._apply_settings(S.normalize({})),
        }
        for name, fn in actions.items():
            r.Raction_bind(name, lambda sender, action, ud, f=fn: f())
        r.Raction_bind("rando.browse.nup", lambda sender, action, ud: self._browse_nup())
        r.Raction_bind("rando.longshot", lambda sender, action, ud: self._use_longshot())
        for key, title in (("romfs", "Select the extracted romfs folder"),
                           ("out", "Select the output folder")):
            r.Raction_bind("rando.browse." + key,
                           lambda sender, action, ud, k=key, t=title: self._browse(k, getattr(self, k + "_in"), t))
        for key in ("romfs", "out", "name", "seed"):
            r.Raction_bind("rando.path." + key, lambda sender, action, ud, k=key:
                           self._path_changed(k, r.Rtext_input_get_text(sender) or ""))
        r.Raction_bind("rando.preset", lambda sender, action, ud: self._preset_chosen(r.Rcombo_box_get_selected(sender)))
        r.Raction_bind("rando.filter", lambda sender, action, ud: self._apply_filter(r.Rtext_input_get_text(sender)))
        r.Raction_bind("rando.toggle_excluded",
                       lambda sender, action, ud: self._toggle_excluded(r.Rlist_view_get_selected(sender)))

        for key, tab, group, text, typ, opts, default, tip in S.SETTINGS:
            if typ == "list":
                continue
            w = self._w("set_" + key)
            self.controls[key] = w
            if typ == "bool":
                r.Rcheckbox_set_checked(w, 1 if self.st[key] else 0)
                r.Raction_bind("set." + key, lambda sender, action, ud, k=key:
                               self._set(k, bool(r.Rcheckbox_is_checked(sender))))
            else:
                r.Rcombo_box_set_selected(w, next((i for i, o in enumerate(opts) if o[0] == self.st[key]), 0))
                r.Raction_bind("set." + key, lambda sender, action, ud, k=key, o=opts: self._set_choice(k, o, sender))
        self._update_excl_count()
        self._loaded = True
        self._refresh_string()
        self.write("Ready. Pick your romfs and an output folder, then Generate.")
        for m in self.load_messages:
            self.write(m)
        if not self.paths["out"].strip():
            self._use_longshot(quiet=True)     # first start with Longshot installed: use its mods folder
        update_msg = os.environ.pop(updater.MSG_ENV, None)     # set by updater.check() at launch
        if update_msg:
            self.write(update_msg)
        self._verify_game()

    def _set_choice(self, key, opts, combo):
        i = r.Rcombo_box_get_selected(combo)
        if 0 <= i < len(opts):
            self._set(key, opts[i][0])

    # ------------------------------------------------------------------ settings
    def _set(self, key, value):
        self.st[key] = value
        self._refresh_string()

    def _preset_chosen(self, index):
        if self._syncing or not 0 < index < len(PRESET_ITEMS):
            return                                   # "Custom", or set from code
        name = PRESET_ITEMS[index]
        st = dict(self.st)
        st["excluded_locations"] = sorted(self.excluded)
        self._apply_settings(S.apply_preset(st, name))
        self.write("Preset %s applied." % name)

    def _settings_changed(self):
        """After any change: show which preset matches and save user_settings.toml."""
        if not self._loaded:
            return
        preset = S.matching_preset(self.current_settings())
        self._syncing = True
        try:
            r.Rcombo_box_set_selected(self.preset_in, PRESET_ITEMS.index(preset or "Custom"))
        finally:
            self._syncing = False
        r.Rlabel_set_text(self.preset_lab, "Saved to user_settings.toml" if self._save() is None
                          else "Couldn't save user_settings.toml")

    def current_settings(self):
        st = dict(self.st)
        st["excluded_locations"] = sorted(self.excluded)
        return S.normalize(st)

    def _apply_settings(self, st):
        self.st = S.normalize(st)
        self.excluded = set(self.st["excluded_locations"])
        for key, w in self.controls.items():
            spec = S.SPEC[key]
            if spec[4] == "bool":
                r.Rcheckbox_set_checked(w, 1 if self.st[key] else 0)
            else:
                idx = next((i for i, o in enumerate(spec[5]) if o[0] == self.st[key]), 0)
                r.Rcombo_box_set_selected(w, idx)
        self._fill_exclusions()
        self._refresh_string()

    def _refresh_string(self):
        """Every settings change ends here: the settings string, the preset and the saved file follow it."""
        if hasattr(self, "sstr_in"):
            r.Rtext_input_set_text(self.sstr_in, S.to_string(self.current_settings()))
        self._settings_changed()

    def _import_string(self):
        try:
            self._apply_settings(S.from_string(r.Rtext_input_get_text(self.sstr_in) or ""))
            self.write("Settings imported.")
        except Exception as e:
            r.Rmessage_box(self.window, "Invalid settings string", str(e), r.R_MESSAGE_OK)

    def _copy_string(self):
        self._refresh_string()
        r.Rclipboard_set_text(r.Rtext_input_get_text(self.sstr_in))
        self.write("Settings string copied to clipboard.")

    # ------------------------------------------------------------------ exclusions
    def _apply_filter(self, text):
        self.filter = (text or "").lower()
        self._fill_exclusions()

    def _fill_exclusions(self):
        if not hasattr(self, "excl_list"):
            return
        self.visible = [n for n in self.locations if self.filter in n.lower()]
        r.Rlist_view_clear_items(self.excl_list)
        for n in self.visible:
            r.Rlist_view_add_item(self.excl_list, self._excl_text(n))
        self._update_excl_count()

    def _excl_text(self, name):
        return ("✖  " if name in self.excluded else "      ") + name

    def _toggle_excluded(self, index):
        if not 0 <= index < len(self.visible):
            return
        n = self.visible[index]
        self.excluded.symmetric_difference_update({n})
        r.Rlist_view_set_item_text(self.excl_list, index, self._excl_text(n))
        self._update_excl_count()
        self._refresh_string()

    def _clear_excluded(self):
        self.excluded.clear()
        self._fill_exclusions()
        self._refresh_string()

    def _update_excl_count(self):
        r.Rlabel_set_text(self.excl_count, "%d excluded" % len(self.excluded))

    # ------------------------------------------------------------------ actions
    def _browse(self, key, ti, title):
        desc = r.RFileDialogDesc()
        desc.parent = self.window
        desc.title = title.encode("utf-8")
        cur = self.paths.get(key) or ""
        if os.path.isdir(cur):
            desc.directory = cur.encode("utf-8")
        path = gamefiles.clean_path(r.Rfile_dialog_select_folder(desc))
        if path and key == "romfs":
            path = gamefiles.find_romfs(path) or path     # e.g. romfs/Banc chosen, or the game folder
        if path:
            r.Rtext_input_set_text(ti, path)
            self._path_changed(key, path)

    def _browse_nup(self):
        desc = r.RFileDialogDesc()
        desc.parent = self.window
        desc.title = b"Select your game's .nup file"
        cur = (self.paths.get("romfs") or "").strip()
        folder = cur if os.path.isdir(cur) else os.path.dirname(cur)
        if folder and os.path.isdir(folder):
            desc.directory = folder.encode("utf-8")
        filters = (r.RFileFilter * 2)(r.RFileFilter(b"Game package (*.nup)", b"*.nup"),
                                      r.RFileFilter(b"All files", b"*"))
        desc.filters = filters
        desc.filter_count = 2
        path = r.Rfile_dialog_open(desc)
        if path:
            path = path.decode("utf-8") if isinstance(path, bytes) else path
            r.Rtext_input_set_text(self.romfs_in, path)
            self._path_changed("romfs", path)

    def _use_longshot(self, quiet=False):
        """Point the output folder at the Longshot game's mods folder (rando/longshot.py). With quiet=True
        (the first start), do nothing and say nothing when Longshot isn't found."""
        builds = longshot.find_builds()
        if not builds:
            if not quiet:
                r.Rmessage_box(self.window, "Longshot", "No Longshot game was found.\n\nBuild the game with the "
                               "Longshot launcher first, or choose its mods folder with Browse (the mods folder "
                               "goes next to longshot.exe in the game folder).", r.R_MESSAGE_OK)
            return
        b = builds[0]
        try:
            os.makedirs(b.mods, exist_ok=True)
        except OSError as e:
            self.write("Longshot: couldn't create %s: %s" % (b.mods, e))
            return
        r.Rtext_input_set_text(self.out_in, b.mods)
        self._path_changed("out", b.mods)
        self.write("Longshot: seeds go to %s (game %s). Older randomizer seeds there are switched off when "
                   "you generate a new one." % (b.mods, b.name))
        if len(builds) > 1:
            self.write("  Other Longshot games found (choose their mods folder with Browse to use one): "
                       + "; ".join(x.folder for x in builds[1:]))
        if not (self.paths.get("romfs") or "").strip():
            nup = b.nup if b.nup and os.path.isfile(b.nup) else longshot.launcher_nup()
            if nup:
                r.Rtext_input_set_text(self.romfs_in, nup)
                self._path_changed("romfs", nup)
                self.write("Longshot: game file taken from the Longshot launcher: %s" % nup)

    def _path_changed(self, key, text):
        self.paths[key] = text
        if key == "romfs":
            self._verify_game()
        if key in ("romfs", "out") and self._loaded:
            self._save()

    def _verify_game(self):
        """Hash exefs/main (in the .nup, or next to the romfs folder) and show the result (green = supported)."""
        romfs = gamefiles.clean_path(r.Rtext_input_get_text(self.romfs_in))
        try:
            self.game = gamecheck.check(None, romfs)
        except OSError as e:
            self.game = gamecheck.GameCheck(False, "missing", "Couldn't read the exefs: %s" % e)
        g = self.game
        if g.ok:
            where = "  (from the .nup)" if gamefiles.is_nup(romfs) else "  (exefs found next to the romfs folder)"
            text, color = g.message + where, OK_GREEN
        elif g.status == "missing":
            text, color = g.message, MUTED
        else:
            text, color = g.message.split("\n")[0], BAD_RED
        r.Rlabel_set_text(self.game_lab, text)
        r.Rlabel_set_color(self.game_lab, *(color if len(color) == 4 else color + (1.0,)))
        r.Rlabel_set_text(self.hash_lab, "exefs/main SHA-256: %s" % (g.sha256 or "-"))
        hcolor = color if g.sha256 else MUTED
        r.Rlabel_set_color(self.hash_lab, *(hcolor if len(hcolor) == 4 else hcolor + (1.0,)))
        return g

    def _require_game(self):
        g = self._verify_game()
        if not g.ok:
            r.Rmessage_box(self.window, "Game version not supported" if g.status != "missing" else "exefs not found",
                           g.message, r.R_MESSAGE_OK)
        return g.ok

    def open_output(self):
        out = (r.Rtext_input_get_text(self.out_in) or "").strip()
        if not out or not os.path.isdir(out):
            r.Rmessage_box(self.window, "Output", "The output folder doesn't exist yet.\n"
                                                  "Choose one on the ROM Options tab, or generate a seed first.",
                           r.R_MESSAGE_OK)
            return
        try:
            if sys.platform == "win32":
                os.startfile(out)
            else:
                subprocess.Popen(["open" if sys.platform == "darwin" else "xdg-open", out])
        except OSError as e:
            r.Rmessage_box(self.window, "Output", "Couldn't open the folder:\n%s" % e, r.R_MESSAGE_OK)

    def _random_seed(self):
        s = "".join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(10))
        r.Rtext_input_set_text(self.seed_in, s)
        self.paths["seed"] = s

    def _check_paths(self, need_out=True):
        romfs = gamefiles.clean_path(r.Rtext_input_get_text(self.romfs_in))
        out = (r.Rtext_input_get_text(self.out_in) or "").strip()
        nup = gamefiles.is_nup(romfs)
        if not nup and not (romfs and os.path.isdir(romfs) and gamefiles.find_romfs(romfs)):
            r.Rmessage_box(self.window, "Game", "Choose your game's .nup file or its extracted romfs folder.\n"
                                                "(A romfs folder holds Pack/ZsDic.pack.zs and a Banc folder.)",
                           r.R_MESSAGE_OK)
            return None
        if need_out:
            if not out:
                r.Rmessage_box(self.window, "Output", "Choose an output folder.", r.R_MESSAGE_OK)
                return None
            ar, ao = os.path.abspath(gamefiles.find_romfs(romfs) if not nup else romfs), os.path.abspath(out)
            if not nup and os.path.splitdrive(ar)[0].lower() == os.path.splitdrive(ao)[0].lower() and \
                    os.path.commonpath([ar, ao]) == ar:
                r.Rmessage_box(self.window, "Output", "The output folder must not be inside the romfs folder.",
                               r.R_MESSAGE_OK)
                return None
        return romfs, out

    def scan(self):
        paths = self._check_paths(need_out=False)
        if paths and self._require_game():
            self._run_bg(lambda: self._ensure_world(paths[0]), "Scan complete.")

    def _ensure_world(self, romfs):
        from .world import World
        if self.world is None or self.world_path != romfs:
            if self.world is not None:
                self.world.files.close()          # release the previous .nup
                self.world = None
            if gamefiles.is_nup(romfs):
                self.queue.put(("log", "Reading the game from %s" % romfs))
            self.world = World(romfs, progress=lambda m: self.queue.put(("log", m)))
            self.world_path = romfs
            self.queue.put(("locations", sorted(l.name for l in self.world.locations)))
            self.queue.put(("log", "Found %d item locations." % len(self.world.locations)))

    def generate(self):
        paths = self._check_paths()
        if not paths or not self._require_game():
            return
        exefs = self.game.exefs
        romfs, out = paths
        st = self.current_settings()
        seed = (r.Rtext_input_get_text(self.seed_in) or "").strip() or None
        name = (r.Rtext_input_get_text(self.name_in) or "").strip() or None
        self.paths.update(romfs=romfs, out=out)
        self._save()

        def job():
            self._ensure_world(romfs)
            res = generate(romfs, out, st, seed=seed, mod_name=name, world=self.world, exefs=exefs,
                           progress=lambda m: self.queue.put(("log", m)))
            self.queue.put(("done", res))
        self._run_bg(job, None)

    def _run_bg(self, fn, done_msg):
        if self.busy:
            return
        self.busy = True
        r.Rwidget_set_enabled(self.gen_btn, 0)

        def wrap():
            try:
                fn()
                if done_msg:
                    self.queue.put(("log", done_msg))
            except Exception as e:
                self.queue.put(("error", "%s\n\n%s" % (e, traceback.format_exc())))
            finally:
                self.queue.put(("idle", None))
        threading.Thread(target=wrap, daemon=True).start()

    # ------------------------------------------------------------------ UI-thread pump
    def _poll(self, timer, ud):
        if self.busy:                                   # gentle back-and-forth "working" bar
            self._phase += 0.08
            r.Rprogress_bar_set_value(self.progress, 0.5 + 0.5 * math.sin(self._phase))
        try:
            while True:
                kind, val = self.queue.get_nowait()
                if kind == "log":
                    self.write(val)
                elif kind == "locations":
                    self.locations = val
                    self._fill_exclusions()
                elif kind == "done":
                    r.Rtext_input_set_text(self.seed_in, val["seed"])
                    r.Rprogress_bar_set_value(self.progress, 1.0)
                    self.write("Seed %s written to %s" % (val["seed"], val["mod_root"]))
                    r.Rmessage_box(self.window, "Mod created", "%s\n\nSettings string:\n%s" % (
                        val["mod_root"], val["settings_string"]), r.R_MESSAGE_OK)
                elif kind == "error":
                    self.write("ERROR: " + val.splitlines()[0])
                    r.Rprogress_bar_set_value(self.progress, 0.0)
                    r.Rmessage_box(self.window, "Generation failed", val[:2000], r.R_MESSAGE_OK)
                elif kind == "idle":
                    self.busy = False
                    r.Rwidget_set_enabled(self.gen_btn, 1)
        except queue.Empty:
            pass

    def write(self, msg):
        self.log_lines.append(msg)
        r.Rlist_view_add_item(self.log, msg)
        n = r.Rlist_view_get_item_count(self.log)
        if n > 400:
            r.Rlist_view_remove_item(self.log, 0)
            n -= 1
        r.Rlist_view_scroll_to_item(self.log, n - 1)

    # ------------------------------------------------------------------ user_settings.toml
    def _save(self):
        """Write user_settings.toml (rando/usersettings.py). Returns an error text or None."""
        err = usersettings.save(self.current_settings(), self.paths)
        if err and not getattr(self, "_save_warned", False):
            self._save_warned = True
            self.write("Couldn't save user_settings.toml: %s" % err)
        return err

    def run(self):
        while r.Rwait_frame(-1.0):
            pass
        r.Rshutdown()


def run():
    GlassApp().run()
