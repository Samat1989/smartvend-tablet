"""Shared helpers for the release scripts in this directory.

Linux only. These replace the original PowerShell scripts (release.ps1,
release-pulse.ps1, release-relay.ps1, make-web-flasher.ps1) that the project
used before the move off Windows.

Python rather than shell because the pipelines are mostly version arithmetic
and careful in-place rewrites of pubspec.yaml / main.c -- exactly the work
bash is worst at. Stdlib only, no dependencies.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# --------------------------------------------------------------------------
# Repo layout
# --------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
OWNER = "Samat1989"
REPO = "smartvend-tablet"
OWNER_REPO = f"{OWNER}/{REPO}"


# --------------------------------------------------------------------------
# Console output
# --------------------------------------------------------------------------

_C = sys.stdout.isatty()
CYAN = "\033[36m" if _C else ""
GREEN = "\033[32m" if _C else ""
YELLOW = "\033[33m" if _C else ""
RED = "\033[31m" if _C else ""
GRAY = "\033[90m" if _C else ""
RESET = "\033[0m" if _C else ""


def step(msg: str) -> None:
    print(f"\n{CYAN}==> {msg}{RESET}", flush=True)


def info(msg: str) -> None:
    print(f"{GRAY}    {msg}{RESET}", flush=True)


def ok(msg: str) -> None:
    print(f"{GREEN}[OK] {msg}{RESET}", flush=True)


def warn(msg: str) -> None:
    print(f"{YELLOW}[WARN] {msg}{RESET}", flush=True)


def fail(msg: str) -> "NoReturn":  # noqa: F821
    print(f"{RED}ERROR: {msg}{RESET}", file=sys.stderr, flush=True)
    sys.exit(1)


# --------------------------------------------------------------------------
# Process helpers
# --------------------------------------------------------------------------

def resolve(name: str, env: dict | None = None) -> str | None:
    return shutil.which(name, path=(env or os.environ).get("PATH"))


def require(name: str, hint: str) -> str:
    exe = resolve(name)
    if not exe:
        fail(f"{name} not found on PATH. {hint}")
    return exe


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    env: dict | None = None,
    check: bool = True,
    capture: bool = False,
) -> subprocess.CompletedProcess:
    """Run a command; check=True aborts the script on a non-zero exit."""
    proc = subprocess.run(
        args,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        capture_output=capture,
    )
    if check and proc.returncode != 0:
        if capture and proc.stderr:
            print(proc.stderr, file=sys.stderr)
        fail(f"`{' '.join(args)}` failed (exit {proc.returncode})")
    return proc


# --------------------------------------------------------------------------
# git
# --------------------------------------------------------------------------

def git(*args: str, check: bool = True, capture: bool = True) -> str:
    """git, always rooted at the repo, returning stdout.

    Only the exit code is ever consulted: git writes progress and advice to
    stderr on perfectly successful commands.
    """
    r = run(["git", "-C", str(REPO_ROOT), *args], check=check, capture=capture)
    return (r.stdout or "").strip() if capture else ""


def tag_exists(tag: str) -> str | None:
    """Return where the tag already lives ('locally'/'on origin'), else None."""
    git("fetch", "--tags", "origin", check=False)
    if git("tag", "-l", tag, check=False) == tag:
        return "locally"
    if git("ls-remote", "--tags", "origin", f"refs/tags/{tag}", check=False):
        return "on origin"
    return None


def require_clean_tree() -> None:
    """Abort on uncommitted TRACKED changes.

    The point of the gate is that the tag describes what was built. Untracked
    files are in neither the commit nor the artifact, so they cannot break
    that -- and blocking on them means one stray directory anywhere in the
    monorepo stops releases forever. They are printed, not enforced.
    """
    untracked = [l for l in git("status", "--porcelain",
                               "--untracked-files=all").splitlines()
                 if l.startswith("??")]
    if untracked:
        warn("Untracked files present (not part of the release):")
        print("\n".join(untracked))

    dirty = git("status", "--porcelain", "--untracked-files=no")
    if dirty:
        print(dirty)
        fail("Tracked files have uncommitted changes. Commit or stash first.")


def current_branch() -> str:
    return git("rev-parse", "--abbrev-ref", "HEAD")


# --------------------------------------------------------------------------
# GitHub CLI
#
# All three pipelines go through `gh`. The firmware scripts used to hand-roll
# the REST API with a PAT -- ~60 lines of create-release / upload-asset /
# error-handling that `gh release create` already does.
#
# `gh auth login` (keyring) is the normal path and needs no token file.
# .github_token is only a fallback for a headless box with no keyring.
# --------------------------------------------------------------------------

TOKEN_FILE = REPO_ROOT / ".github_token"


def require_gh() -> dict:
    require("gh", "Install it: sudo apt install gh")
    env = dict(os.environ)
    if not env.get("GH_TOKEN") and TOKEN_FILE.exists():
        tok = TOKEN_FILE.read_text(encoding="utf-8").strip()
        if tok:
            env["GH_TOKEN"] = tok
            info(f"Auth: {TOKEN_FILE.name}")
    if run(["gh", "auth", "status"], env=env, check=False,
           capture=True).returncode != 0:
        fail("Not logged in to gh. Run: gh auth login  (or drop a "
             f"fine-grained PAT with Contents:read+write on {OWNER_REPO} "
             f"into {TOKEN_FILE})")
    return env


# --------------------------------------------------------------------------
# Version arithmetic
# --------------------------------------------------------------------------

def derive_build(major: int, minor: int, patch: int) -> int:
    """build = major*10000 + minor*100 + patch   (1.1.21 -> 10121)

    The build number is DERIVED from the version, never invented. With each
    part capped at 99 this is strictly monotonic as the version grows, so a
    version code can't drift out of sync with the version name. Matches
    ota_tag_code() in the firmware.
    """
    return major * 10000 + minor * 100 + patch


def bump_patch(major: int, minor: int, patch: int) -> tuple[int, int, int]:
    """patch +1 with rollover at 99, carrying into minor then major."""
    patch += 1
    if patch > 99:
        patch, minor = 0, minor + 1
    if minor > 99:
        minor, major = 0, major + 1
    return major, minor, patch


def parse_semver(text: str) -> tuple[int, int, int]:
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", text.strip())
    if not m:
        fail(f"Version must be X.Y.Z (got '{text}').")
    return int(m[1]), int(m[2]), int(m[3])


# --------------------------------------------------------------------------
# ESP-IDF environment
#
# idf.py only exists after export.sh has been sourced, and a shell script
# cannot be sourced into this process. So: run it in a subshell, dump the
# resulting environment, and build with that. Replaces the `get_idf` profile
# function the PowerShell scripts relied on.
# --------------------------------------------------------------------------

def _guess_idf_path() -> Path | None:
    if os.environ.get("IDF_PATH") and Path(os.environ["IDF_PATH"]).is_dir():
        return Path(os.environ["IDF_PATH"])
    root = Path.home() / "esp"
    if root.is_dir():
        # ~/esp/v5.5.1/esp-idf first, then a bare ~/esp/esp-idf; newest first.
        for c in sorted(root.glob("*/esp-idf"), reverse=True) + [root / "esp-idf"]:
            if (c / "export.sh").exists():
                return c
    return None


def idf_env() -> dict:
    """Return an environment with idf.py + the toolchain on PATH."""
    if resolve("idf.py"):
        return dict(os.environ)

    idf_path = _guess_idf_path()
    if not idf_path:
        fail("ESP-IDF not found. Set IDF_PATH, or source it first: "
             ". ~/esp/<version>/esp-idf/export.sh")

    script = idf_path / "export.sh"
    step(f"Loading ESP-IDF environment ({idf_path})")
    proc = subprocess.run(["bash", "-c", f'. "{script}" >/dev/null 2>&1 && env -0'],
                          text=True, capture_output=True)
    if proc.returncode != 0:
        fail(f"Sourcing {script} failed:\n{proc.stderr.strip()}")

    env = dict(line.split("=", 1) for line in proc.stdout.split("\0") if "=" in line)
    if not resolve("idf.py", env):
        fail(f"Sourced {script} but idf.py is still not on PATH.")
    ok("ESP-IDF environment loaded")
    return env
