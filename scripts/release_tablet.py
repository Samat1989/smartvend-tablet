#!/usr/bin/env python3
"""One-shot tablet release: build signed APKs, tag, push, publish to GitHub.

Replaces apps/tablet/scripts/release.ps1. Uploads the armeabi-v7a split as the
release's only asset -- that is the one every tablet installs (see ABI_OFFSET
below and UpdateService.assetName).

Requirements (one-time):
  1. GitHub CLI + auth:  sudo apt install gh && gh auth login
     (a fine-grained PAT in .github_token at the repo root also works, and
     is the fallback for a headless box with no keyring)
  2. apps/tablet/android/release.jks + key.properties -- both gitignored,
     copy them in by hand (see android/README_RELEASE_SIGNING.md)
  3. A JDK, only for the signature sanity check. Without one the check is
     skipped with a warning rather than blocking the release.

Usage:
  python scripts/release_tablet.py                        # auto-bump patch
  python scripts/release_tablet.py --version 1.2.0        # derived build
  python scripts/release_tablet.py --version 1.2.0+10200  # explicit build
  python scripts/release_tablet.py --notes "Fixes X"      # else auto-generated

VERSION AND BUILD NUMBERS -- the part that is easy to get wrong.

The build number is DERIVED from the version, never invented:
    build = major*10000 + minor*100 + patch      (1.1.21 -> 10121)
With each part capped at 99 this is strictly monotonic as the version grows,
so versionCode can't drift out of sync with the version name.

The TAG carries a different number than pubspec, on purpose. Flutter's
--split-per-abi adds an ABI offset to the shipped versionCode (armeabi-v7a =
+1000), so the APK installed on a tablet reports `pubspec build + 1000`.
UpdateService compares the tag's build against the installed versionCode, so
the tag must encode the POST-offset value or every release looks older than
what is already on the machine. pubspec keeps the pre-offset base so
day-to-day Flutter tooling stays sane.

    pubspec.yaml   version: 1.1.21+10121
    git tag        v1.1.21+11121
    installed APK  versionCode 11121

The offset is 1000 because UpdateService.assetName is pinned to
app-armeabi-v7a-release.apk -- the tablet always installs that split. If that
ever changes, change ABI_OFFSET with it (arm64-v8a = 2000).

The script fails loud -- any unexpected state (dirty tree, missing keystore,
tag already taken, gh not logged in) stops the run before anything
irreversible happens.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import (  # noqa: E402
    REPO_ROOT, OWNER_REPO, bump_patch, current_branch, derive_build, fail, git,
    info, ok, require, require_clean_tree, require_gh, resolve, run, step,
    tag_exists, warn,
)

PROJECT = REPO_ROOT / "apps" / "tablet"
ABI_OFFSET = 1000          # armeabi-v7a -- see the module docstring
APK_DIR = "build/app/outputs/flutter-apk"
APK_NAME = "app-armeabi-v7a-release.apk"


def find_keytool() -> str | None:
    """keytool is not on PATH on a plain Linux box; look where JDKs actually live."""
    exe = resolve("keytool")
    if exe:
        return exe
    roots: list[Path] = []
    if os.environ.get("JAVA_HOME"):
        roots.append(Path(os.environ["JAVA_HOME"]))
    home = Path.home()
    # Android Studio ships its own JBR, which is usually the only JDK present.
    roots += [
        home / "android-studio" / "jbr",
        Path("/opt/android-studio/jbr"),
        Path("/snap/android-studio/current/android-studio/jbr"),
    ]
    roots += sorted(Path("/usr/lib/jvm").glob("*"), reverse=True)
    for r in roots:
        cand = r / "bin" / "keytool"
        if cand.is_file():
            return str(cand)
    return None


def verify_signature(store_pass: str) -> None:
    """Sanity-check the keystore before uploading. Advisory, not a gate."""
    step("Verifying APK signature")
    keytool = find_keytool()
    if not keytool:
        warn("keytool not found (no JDK on this machine) -- skipping the "
             "signature check. `sudo apt install default-jdk` re-enables it.")
        return
    proc = run([keytool, "-list", "-keystore", str(PROJECT / "android/release.jks"),
                "-storepass", store_pass, "-alias", "smartvend"],
               check=False, capture=True)
    line = next((l.strip() for l in proc.stdout.splitlines() if "SHA-256" in l), None)
    if not line:
        warn("Could not read the keystore fingerprint -- continuing anyway.")
        return
    print(line)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", help="1.2.0 or 1.2.0+10200")
    ap.add_argument("--build", type=int, help="override the derived build number")
    ap.add_argument("--notes", help="release notes (else auto-generated)")
    ap.add_argument("--draft", action="store_true")
    ap.add_argument("--skip-build", action="store_true",
                    help="reuse the APKs already on disk")
    ap.add_argument("--no-push", action="store_true")
    args = ap.parse_args()

    print(f"Project: {PROJECT}")

    # --- Preflight ----------------------------------------------------------
    step("Checking prerequisites")
    env = require_gh()
    require("flutter", "Install the Flutter SDK and put it on PATH.")

    keystore = PROJECT / "android" / "release.jks"
    keyprops = PROJECT / "android" / "key.properties"
    if not keystore.exists():
        fail(f"{keystore} not found. See android/README_RELEASE_SIGNING.md. "
             "(It is gitignored -- copy it over from the machine that has it.)")
    if not keyprops.exists():
        fail(f"{keyprops} not found. Copy from key.properties.example.")

    store_pass = ""
    for line in keyprops.read_text(encoding="utf-8").splitlines():
        if line.startswith("storePassword="):
            store_pass = line.split("=", 1)[1].strip()

    # --- Work out the next version -----------------------------------------
    pubspec = PROJECT / "pubspec.yaml"
    text = pubspec.read_text(encoding="utf-8")
    m = re.search(r"(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$", text)
    if not m:
        fail("Could not parse 'version: X.Y.Z+NNNN' from pubspec.yaml")
    cur_version = f"{m[1]}.{m[2]}.{m[3]}+{m[4]}"
    cur = (int(m[1]), int(m[2]), int(m[3]))
    print(f"Current: {cur_version}")

    explicit_build: int | None = None
    if args.version:
        mv = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?", args.version.strip())
        if not mv:
            fail(f"Version must be 1.2.0 or 1.2.0+10200 (got '{args.version}').")
        new = (int(mv[1]), int(mv[2]), int(mv[3]))
        if mv[4]:
            explicit_build = int(mv[4])
    else:
        new = bump_patch(*cur)

    if args.build is not None:
        build = args.build
    elif explicit_build is not None:
        build = explicit_build
    else:
        build = derive_build(*new)

    new_version = f"{new[0]}.{new[1]}.{new[2]}+{build}"
    tag_build = build + ABI_OFFSET
    tag = f"v{new[0]}.{new[1]}.{new[2]}+{tag_build}"
    print(f"New:     {new_version}   (tag: {tag}, shipped versionCode: {tag_build})")

    # --- Tag must not exist yet -- check BEFORE touching pubspec ------------
    where = tag_exists(tag)
    if where:
        fail(f"Tag {tag} already exists {where}. Pick another version.")

    # --- Bump pubspec + commit ---------------------------------------------
    if new_version != cur_version:
        step(f"Bumping pubspec to {new_version}")
        updated = re.sub(r"(?m)^version:\s*\d+\.\d+\.\d+\+\d+\s*$",
                         f"version: {new_version}", text)
        if updated == text:
            fail("Failed to rewrite the version line.")
        pubspec.write_text(updated, encoding="utf-8")
        git("add", str(pubspec))
        git("commit", "-m", f"Bump version to {new_version}")

    require_clean_tree()

    # --- Build signed APKs --------------------------------------------------
    # The build stays --split-per-abi even though only the v7a split ships:
    # the per-ABI split is what adds the +1000 offset to versionCode, and the
    # whole tag calculation above is built on that. The other splits are left
    # on disk for local testing and simply aren't uploaded.
    apk = PROJECT / APK_DIR / APK_NAME
    if args.skip_build:
        step("Skipping build (--skip-build). Reusing existing APKs.")
    else:
        step("Building release APKs (split-per-abi)")
        run(["flutter", "pub", "get"], cwd=PROJECT)
        run(["flutter", "build", "apk", "--release", "--split-per-abi"], cwd=PROJECT)
    if not apk.exists():
        fail(f"Expected APK not found: {apk}")

    verify_signature(store_pass)

    # --- Tag + push ---------------------------------------------------------
    step(f"Tagging {tag}")
    git("tag", tag)

    branch = current_branch()
    if args.no_push:
        info("Skipping push (--no-push). Tag created locally only.")
    else:
        step(f"Pushing branch {branch} + tag {tag}")
        git("push", "origin", branch)
        git("push", "origin", tag)

    # --- Create GitHub Release + upload the APK -----------------------------
    # One asset, on purpose. UpdateService.assetName is pinned to
    # app-armeabi-v7a-release.apk, so that is the only file any tablet ever
    # downloads; the arm64 and x86_64 splits were dead weight on the release
    # page and an invitation to hand-install the wrong one.
    step(f"Creating GitHub Release {tag}")
    gh_args = ["gh", "release", "create", tag, "--repo", OWNER_REPO, "--title", tag]
    gh_args += ["--notes", args.notes] if args.notes else ["--generate-notes"]
    if args.draft:
        gh_args.append("--draft")
    gh_args.append(str(apk))
    run(gh_args, env=env)

    url = run(["gh", "release", "view", tag, "--repo", OWNER_REPO,
               "--json", "url", "--jq", ".url"], env=env, capture=True).stdout.strip()
    step("Done")
    ok(f"Release URL: {url}")
    print(f"APK URL:     {url.replace('/tag/', '/download/')}/{APK_NAME}")
    print()
    print("On the tablet: service-mode -> Обновление -> Проверить обновление.")


if __name__ == "__main__":
    main()
