#!/usr/bin/env python3
"""Release pipeline for the ESP32 firmwares (esp-pulse / esp-relay).

Replaces release-pulse.ps1 and release-relay.ps1, which were byte-identical
apart from the words "pulse" and "relay" -- 8 KB of duplication that could
only drift. The per-target differences are the TARGETS table below; the
pipeline is one implementation.

Three release streams share this repo, kept apart purely by tag prefix +
asset name: the tablet APK ("v*"), esp-relay ("relay-v*" + "relay-mart.bin")
and esp-pulse ("pulse-v*" + "pulse-mart.bin"). The device's OTA checker
(ota_find_update in main.c) only looks at its own prefix, so a pulse board
never pulls a relay build and vice versa.

What it does:
  1. Bumps FW_VERSION_NAME / FW_VERSION_CODE in main.c (patch +1, or --version)
  2. Builds with idf.py (the ESP-IDF env is loaded automatically)
  3. Commits the bump, tags `<target>-vX.Y.Z+CODE`, pushes
  4. Creates a GitHub Release and uploads the .bin under the OTA asset name

Usage:
  python scripts/release_fw.py pulse -m "Add periodic OTA check"
  python scripts/release_fw.py relay -m "..." --version 1.2.0
  python scripts/release_fw.py pulse -m "..." --dry-run
  python scripts/release_fw.py pulse -m "..." --no-push
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import (  # noqa: E402
    REPO_ROOT, OWNER_REPO, derive_build, bump_patch, parse_semver, fail, git,
    idf_env, info, ok, require_gh, run, step, tag_exists, warn,
)

# name -> (firmware dir, built .bin, OTA asset name, tag prefix)
# The .bin name comes from project(...) in the firmware's CMakeLists.txt; the
# asset name must match OTA_ASSET_NAME in that firmware's main.c.
TARGETS = {
    "pulse": ("firmware/esp-pulse", "esp_pulse_mart.bin", "pulse-mart.bin", "pulse-v"),
    "relay": ("firmware/esp-relay", "esp_relay_mart.bin", "relay-mart.bin", "relay-v"),
}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", choices=sorted(TARGETS))
    ap.add_argument("-m", "--message", required=True,
                    help="commit message / release notes")
    ap.add_argument("--version", help='override semver "X.Y.Z" (no +code)')
    ap.add_argument("--prerelease", action="store_true")
    ap.add_argument("--no-push", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    fw_rel, bin_name, asset_name, tag_prefix = TARGETS[args.target]
    fw_path = REPO_ROOT / fw_rel
    main_c = fw_path / "main" / "main.c"
    bin_path = fw_path / "build" / bin_name

    if not main_c.exists():
        fail(f"Not found: {main_c}")

    env = None if args.dry_run else require_gh()

    # ---------- current version ----------
    step("Reading current version from main.c")
    text = main_c.read_text(encoding="utf-8")
    m = re.search(r'#define\s+FW_VERSION_NAME\s+"(\d+)\.(\d+)\.(\d+)"', text)
    if not m:
        fail('Cannot find #define FW_VERSION_NAME "X.Y.Z" in main.c')
    cur = (int(m[1]), int(m[2]), int(m[3]))
    info(f"Current: {cur[0]}.{cur[1]}.{cur[2]}")

    new = parse_semver(args.version) if args.version else bump_patch(*cur)
    code = derive_build(*new)                       # matches ota_tag_code()
    name = f"{new[0]}.{new[1]}.{new[2]}"
    tag = f"{tag_prefix}{name}+{code}"
    info(f"New:     {name}   (tag: {tag}, code: {code})")

    where = tag_exists(tag)
    if where:
        fail(f"Tag {tag} already exists {where}. Bump further.")

    # ---------- bump main.c ----------
    step(f"Bumping main.c to {name} (code {code})")
    if args.dry_run:
        info(f'[DRY] would set FW_VERSION_NAME="{name}", FW_VERSION_CODE={code}')
    else:
        bumped = re.sub(r'(#define\s+FW_VERSION_NAME\s+)"\d+\.\d+\.\d+"',
                        rf'\g<1>"{name}"', text)
        bumped = re.sub(r'(#define\s+FW_VERSION_CODE\s+)\d+',
                        rf'\g<1>{code}', bumped)
        if bumped == text:
            fail("Failed to rewrite the version defines in main.c")
        main_c.write_text(bumped, encoding="utf-8")
        ok("main.c version bumped")

    bumped_uncommitted = not args.dry_run
    try:
        # ---------- build ----------
        step("Building firmware (idf.py build)")
        if args.dry_run:
            info("[DRY] would run: idf.py build")
        else:
            run(["idf.py", "build"], cwd=fw_path, env=idf_env())
            if not bin_path.exists():
                fail(f"Expected firmware not found: {bin_path}")
            ok(f"Firmware ready ({bin_path.stat().st_size / 1024:.0f} KB)")

        # ---------- commit + tag ----------
        step("Committing version bump")
        if args.dry_run:
            info(f'[DRY] would: git commit -m "{args.message}"')
        else:
            git("add", str(main_c))
            git("commit", "-m", args.message)
            bumped_uncommitted = False
            ok(f"Committed: {args.message}")

            step(f"Creating tag {tag}")
            git("tag", "-a", tag, "-m", args.message)
            ok(f"Tag {tag} created")

        if args.no_push:
            info("Skipping push (--no-push). Done locally.")
            return
        if args.dry_run:
            info("[DRY] would push branch + tag, create release, upload bin")
            return

        # ---------- push ----------
        branch = git("rev-parse", "--abbrev-ref", "HEAD")
        step(f"Pushing branch {branch} + tag {tag}")
        git("push", "origin", branch)
        git("push", "origin", tag)
        ok("Pushed branch + tag")

        # ---------- release ----------
        # The .bin is uploaded under the OTA asset name, not its build name:
        # ota_find_update() searches the release's assets for that exact
        # string, so esp_pulse_mart.bin would be invisible to the device.
        step(f"Creating GitHub Release {tag} and uploading {asset_name}")
        staged = bin_path.parent / asset_name
        staged.write_bytes(bin_path.read_bytes())
        gh_args = ["gh", "release", "create", tag, "--repo", OWNER_REPO,
                   "--title", tag, "--notes", args.message]
        if args.prerelease:
            gh_args.append("--prerelease")
        gh_args.append(str(staged))
        run(gh_args, env=env)

        url = run(["gh", "release", "view", tag, "--repo", OWNER_REPO,
                   "--json", "url", "--jq", ".url"],
                  env=env, capture=True).stdout.strip()
        print()
        ok(f"FIRMWARE RELEASE {tag} PUBLISHED")
        info(f"Release: {url}")
        info(f"Asset:   {url}/download/{asset_name}".replace("/tag/", "/download/"))

    except SystemExit:
        if bumped_uncommitted:
            warn("Rolling back the main.c bump...")
            git("checkout", "HEAD", "--", str(main_c), check=False)
        raise


if __name__ == "__main__":
    main()
