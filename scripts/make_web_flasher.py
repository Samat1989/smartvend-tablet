#!/usr/bin/env python3
"""Build esp-relay and produce the browser-flasher bundle in docs/flash/.

Replaces make-web-flasher.ps1.

Generates docs/flash/relay-merged.bin (bootloader + partition table + otadata
+ app merged into one 0x0 image) and refreshes the version in manifest.json.
ESP Web Tools (docs/flash/index.html) flashes that single image over Web
Serial, so a remote helper only needs Chrome/Edge + a USB cable.

Usage:
  python scripts/make_web_flasher.py                  # build + merge locally
  python scripts/make_web_flasher.py --commit         # also git-commit docs/flash
  python scripts/make_web_flasher.py --commit --push  # commit + push (Pages updates)
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import (  # noqa: E402
    REPO_ROOT, current_branch, fail, git, idf_env, info, ok, resolve, run,
    step,
)

FW_PATH = REPO_ROOT / "firmware" / "esp-relay"
MAIN_C = FW_PATH / "main" / "main.c"
OUT_DIR = REPO_ROOT / "docs" / "flash"
OUT_BIN = OUT_DIR / "relay-merged.bin"
MANIFEST = OUT_DIR / "manifest.json"


def esptool_cmd(env: dict) -> tuple[list[str], str]:
    """Return (argv prefix, merge subcommand name).

    esptool renamed merge_bin -> merge-bin in v5. The old spelling is still
    accepted as an alias in some 5.x builds but not all, so pick by version
    rather than guessing.
    """
    exe = resolve("esptool.py", env) or resolve("esptool", env)
    if not exe:
        fail("esptool not found. It ships with ESP-IDF; make sure the IDF "
             "environment loaded, or: pip install --user esptool")
    ver = run([exe, "version"], env=env, check=False, capture=True).stdout
    m = re.search(r"v?(\d+)\.", ver)
    major = int(m[1]) if m else 4
    return [exe], ("merge-bin" if major >= 5 else "merge_bin")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--commit", action="store_true", help="git-commit docs/flash")
    ap.add_argument("--push", action="store_true", help="push after committing")
    args = ap.parse_args()

    env = idf_env()

    step("Building firmware (idf.py build)")
    run(["idf.py", "build"], cwd=FW_PATH, env=env)

    step("Merging bootloader + partitions + app into one image")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    prefix, merge = esptool_cmd(env)
    # flash_args lists the offset/file pairs + flash params, with paths
    # relative to build/ -- hence cwd, and the literal "@flash_args".
    run([*prefix, "--chip", "esp32", merge, "-o", str(OUT_BIN), "@flash_args"],
        cwd=FW_PATH / "build", env=env)
    ok(f"relay-merged.bin: {OUT_BIN.stat().st_size / 1024:.0f} KB")

    # ---------- sync manifest version from main.c ----------
    m = re.search(r'#define\s+FW_VERSION_NAME\s+"([^"]+)"',
                  MAIN_C.read_text(encoding="utf-8"))
    if m:
        ver = m[1]
        # Written UTF-8 without a BOM so JSON.parse in the browser is happy --
        # a BOM here is a silent parse failure in the flasher page.
        text = re.sub(r'"version"\s*:\s*"[^"]*"', f'"version": "{ver}"',
                      MANIFEST.read_text(encoding="utf-8"))
        MANIFEST.write_text(text, encoding="utf-8")
        ok(f"manifest version -> {ver}")

    if args.commit:
        step("Committing docs/flash")
        git("add", str(OUT_DIR))
        git("commit", "-m", "web-flasher: refresh relay-merged.bin")
        if args.push:
            branch = current_branch()
            git("push", "origin", branch)
            ok(f"pushed {branch}")

    print()
    ok("Flasher bundle ready in docs/flash/")
    info("Enable once: GitHub repo -> Settings -> Pages -> Source: main /docs")
    info("Flasher URL: https://samat1989.github.io/smartvend-tablet/flash/")


if __name__ == "__main__":
    main()
