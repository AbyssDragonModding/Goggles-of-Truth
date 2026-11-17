"""user_settings.toml: the randomizer window's saved settings and paths.

The file sits next to goggles_of_truth_rando.pyw. The window loads it when it opens and saves it whenever something changes.
Deleting it resets everything to the defaults. It's plain TOML, so it can also be edited by hand while the window
is closed: every setting is listed with its allowed values, and an unknown or invalid value falls back to the
default (the window's log says which).

Before 0.5.0 the window kept this in ~/.ootr_remake.json. That file is read once if user_settings.toml doesn't
exist yet, and is left where it is.
"""
import json
import os
import tomllib

from . import settings as S

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "user_settings.toml")
OLD_JSON = os.path.join(os.path.expanduser("~"), ".ootr_remake.json")
PATH_KEYS = (("game", "romfs"), ("output", "out"))      # TOML key, the window's own key
APP_DEFAULTS = {"auto_update": True}                     # [app]: options for the program itself, not the seed

HEADER = """\
# Goggles of Truth Randomizer: your settings.
#
# The randomizer window loads this file when it opens and saves it whenever you change something.
# Delete this file to reset everything to the defaults.
# You can also edit it by hand while the window is closed. Every setting below lists its allowed values;
# an unknown or invalid value is ignored and the default is used (the window's log says which).
"""


def _toml_str(s):
    # a JSON string is a valid TOML basic string (same escapes)
    return json.dumps(str(s), ensure_ascii=False)


def _toml_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, (list, tuple)):
        if not v:
            return "[]"
        return "[\n" + "".join("    %s,\n" % _toml_value(x) for x in v) + "]"
    return _toml_str(v)


def _check(key, value):
    """The value if it's valid for setting `key`, else None."""
    spec = S.SPEC[key]
    kind = spec[4]
    if kind == "bool":
        return value if isinstance(value, bool) else None
    if kind == "choice":
        return value if isinstance(value, str) and value in {o[0] for o in spec[5]} else None
    if kind == "list":
        return list(value) if isinstance(value, list) and all(isinstance(x, str) for x in value) else None
    if kind == "int":
        lo, hi = spec[5]
        return value if isinstance(value, int) and not isinstance(value, bool) and lo <= value <= hi else None
    return value


def validate(raw):
    """(settings, warnings): known keys with valid values on top of the defaults."""
    st, warnings = dict(S.DEFAULTS), []
    for key, value in (raw or {}).items():
        key = S.RENAMED.get(key, key)
        if key in S.BUILT_IN or key in S.REMOVED:
            continue                    # now part of every seed, or removed
        if key not in S.SPEC:
            warnings.append("unknown setting %r ignored (removed in this version, or misspelled)" % key)
            continue
        ok = _check(key, value)
        if ok is None:
            warnings.append("%s = %r is not allowed; using the default (%r)" % (key, value, S.DEFAULTS[key]))
            continue
        st[key] = ok
    return S.normalize(st), warnings


def load(path=PATH):
    """Returns (settings, paths, messages). Never raises: a broken file gives the defaults and a message."""
    paths = {"romfs": "", "out": ""}
    if not os.path.exists(path):
        if path == PATH and os.path.exists(OLD_JSON):
            try:
                with open(OLD_JSON, encoding="utf-8") as fh:
                    old = json.load(fh)
                st, warnings = validate(old.get("settings", {}))
                paths.update({k: str(old.get(k) or "") for k in ("romfs", "out")})
                return st, paths, ["Settings taken over from %s (saved to user_settings.toml from now on)." % OLD_JSON] + warnings
            except Exception:
                pass
        return dict(S.DEFAULTS), paths, []
    try:
        with open(path, "rb") as fh:
            data = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError) as e:
        return dict(S.DEFAULTS), paths, ["user_settings.toml couldn't be read (%s); using the defaults. "
                                         "It is replaced with the current settings when the window opens." % e]
    p = data.get("paths") or {}
    for tkey, key in PATH_KEYS:
        if isinstance(p.get(tkey), str):
            paths[key] = p[tkey]
    st, warnings = validate(data.get("settings") or {})
    return st, paths, ["user_settings.toml: " + w for w in warnings]


def load_app(path=PATH):
    """The [app] options (rando/updater.py reads auto_update), defaults for anything missing or invalid."""
    app = dict(APP_DEFAULTS)
    try:
        with open(path, "rb") as fh:
            raw = tomllib.load(fh).get("app") or {}
    except (OSError, tomllib.TOMLDecodeError):
        return app
    for key, default in APP_DEFAULTS.items():
        if isinstance(raw.get(key), type(default)):
            app[key] = raw[key]
    return app


def dumps(st, paths, app=None):
    st = S.normalize(st)
    app = dict(APP_DEFAULTS, **(app or {}))
    out = [HEADER, "[app]",
           "# Check GitHub for a newer version when the randomizer opens, pull it and restart (only in a git",
           "# clone; a downloaded zip is never changed): true or false. Default: true",
           "auto_update = %s" % _toml_value(app["auto_update"]),
           "", "[paths]",
           "# Your game (.nup file or extracted romfs folder) and the folder the mod is written to.",
           "# Backslashes are written as \\\\ (or use single quotes: game = 'D:\\Games\\game.nup')."]
    for tkey, key in PATH_KEYS:
        out.append("%s = %s" % (tkey, _toml_str(paths.get(key, ""))))
    preset = S.matching_preset(st)
    out += ["", "[settings]",
            "# Preset these settings match: %s. (Informational: a preset is applied from the window.)"
            % (preset or "none (custom)")]
    section = None
    for key, tab, group, label, kind, opts, default, tip in S.SETTINGS:
        if (tab, group) != section:
            section = (tab, group)
            out += ["", "# ---- %s: %s" % (tab, group)]
        if kind == "bool":
            allowed = "true or false"
        elif kind == "choice":
            allowed = ", ".join('"%s" (%s)' % (k, text) for k, text in opts)
        else:
            allowed = "a list of location names as the Exclusions tab shows them"
        out.append("# %s: %s. Default: %s" % (label, allowed, _toml_value(default).replace("\n", " ")))
        out.append("%s = %s" % (key, _toml_value(st[key])))
    return "\n".join(out) + "\n"


def save(st, paths, path=PATH):
    """Write the file (via a temporary file, so a crash never leaves half a file). Returns an error text or None."""
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(dumps(st, paths, load_app(path)))      # keep [app] as it is in the file
        os.replace(tmp, path)
        return None
    except OSError as e:
        return str(e)
