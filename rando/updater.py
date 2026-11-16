"""Update check at launch: pull the newest version from GitHub, then restart the randomizer.

goggles_of_truth_rando.pyw calls check() before the window opens. It only does something when the randomizer folder is a
git clone (git clone https://github.com/AbyssDragonModding/Goggles-of-Truth) and git is installed. A downloaded zip
has no .git folder, so it is never touched.

What happens:
  1. git fetch the branch you're on (15 s at most; no internet just skips the check).
  2. If GitHub has newer commits, git pull --ff-only. That never merges or overwrites anything: if you changed a
     file the randomizer ships with, or have commits of your own that aren't on GitHub, the pull is skipped and
     the window's log says why.
  3. If requirements.txt changed, its packages are installed.
  4. The randomizer starts again from the updated files, and the new window's log lists what changed.

Turn it off with auto_update = false under [app] in user_settings.toml, or set the environment variable
OOTR_NO_UPDATE=1.
"""
import os
import subprocess
import sys

from . import usersettings

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MSG_ENV = "OOTR_UPDATE_MSG"          # message for the window's log, read by gui_glass
RESTARTED_ENV = "OOTR_JUST_UPDATED"  # set in the restarted process so it doesn't check again
FETCH_TIMEOUT = 15
PIP_TIMEOUT = 600
MAX_LOG_LINES = 15


class _GitError(Exception):
    pass


START_FILE = "goggles_of_truth_rando.pyw"   # the randomizer's start file (ootr_remake.pyw before 0.6.0)

def _run(args, timeout=30):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")     # never wait for a password prompt
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)  # no console windows flashing up under pythonw
    try:
        p = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=env,
                           creationflags=flags, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise _GitError(str(e))
    if p.returncode != 0:
        raise _GitError((p.stderr or p.stdout).strip() or "exit code %d" % p.returncode)
    return p.stdout.rstrip()


def _git(*args, timeout=30):
    return _run(["git", *args], timeout=timeout)


def enabled():
    if os.environ.get("OOTR_NO_UPDATE") or os.environ.get(RESTARTED_ENV):
        return False
    if not os.path.isdir(os.path.join(ROOT, ".git")):
        return False
    return usersettings.load_app().get("auto_update", True)


def update():
    """Pull if there's something newer. Returns (updated, message); message is None when there's nothing to say."""
    try:
        branch = _git("symbolic-ref", "--short", "-q", "HEAD")
        upstream = _git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    except _GitError:
        return False, None              # detached HEAD or no tracking branch: someone's own setup, leave it
    remote = upstream.split("/", 1)[0]
    try:
        _git("fetch", "--quiet", remote, timeout=FETCH_TIMEOUT)
    except _GitError as e:
        return False, "Update check skipped: couldn't reach GitHub (%s)." % e.args[0].splitlines()[0]
    behind = int(_git("rev-list", "--count", "HEAD..@{u}"))
    if not behind:
        return False, None
    ahead = int(_git("rev-list", "--count", "@{u}..HEAD"))
    if ahead:
        return False, ("An update is available (%d new commit(s) on %s), but this folder has %d commit(s) of its "
                       "own that aren't on GitHub, so it wasn't pulled. Run git pull yourself." % (behind, upstream, ahead))
    changed = _git("status", "--porcelain", "--untracked-files=no")
    if changed:
        files = ", ".join(line[3:] for line in changed.splitlines()[:5])
        return False, ("An update is available (%d new commit(s) on %s), but files the randomizer ships with were "
                       "changed in this folder (%s), so it wasn't pulled. Undo those changes or run git pull "
                       "yourself." % (behind, upstream, files))
    old = _git("rev-parse", "HEAD")
    try:
        _git("pull", "--ff-only", "--quiet", remote, branch, timeout=120)
    except _GitError as e:
        return False, "An update is available, but git pull failed: %s" % e.args[0]
    new = _git("rev-parse", "HEAD")
    lines = _git("log", "--format=  %s", "%s..%s" % (old, new)).splitlines()
    if len(lines) > MAX_LOG_LINES:
        lines = lines[:MAX_LOG_LINES] + ["  ... and %d more" % (len(lines) - MAX_LOG_LINES)]
    msg = ["Updated to the newest version (%s -> %s):" % (old[:7], new[:7])] + lines
    if "requirements.txt" in _git("diff", "--name-only", old, new).splitlines():
        try:
            _run([sys.executable, "-m", "pip", "install", "--upgrade", "-r", "requirements.txt"], timeout=PIP_TIMEOUT)
            msg.append("The required packages changed and were installed.")
        except _GitError as e:
            msg.append("The required packages changed, but installing them failed (run the setup again): %s"
                       % e.args[0].splitlines()[-1])
    return True, "\n".join(msg)


def restart():
    """Start the randomizer again from the updated files and return True, or False if that failed."""
    env = dict(os.environ, **{RESTARTED_ENV: "1"})
    script = os.path.abspath(sys.argv[0]) if sys.argv and sys.argv[0] else ""
    if not os.path.isfile(script):         # the update renamed or removed the file this was started from
        script = os.path.join(ROOT, START_FILE)
    try:
        subprocess.Popen([sys.executable, script, *sys.argv[1:]], cwd=ROOT, env=env)
        return True
    except OSError:
        return False


def check():
    """Run at launch. Returns True if the randomizer restarted (the caller should exit right away)."""
    if not enabled():
        return False
    try:
        updated, msg = update()
    except Exception as e:              # an update problem must never stop the randomizer from opening
        updated, msg = False, "Update check failed: %s" % e
    if msg:
        os.environ[MSG_ENV] = msg       # carried into the restarted process through its environment
    if updated and restart():
        return True
    if updated:
        os.environ[MSG_ENV] = msg + "\nRestart the randomizer to use the new version."
    return False
