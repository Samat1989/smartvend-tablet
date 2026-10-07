#!/usr/bin/env python3
"""Publish an esp-rt build to Supabase Storage for OTA. No git, no tags.

    updates/esp-rt-<variant>/manifest.json + esp-rt-<variant>-<version>.bin

Manifest: {version, code, url, size, sha256, notes, published_at,
           devices?: [board ID, ...], pins?: {"<ID>": {version, code, url, size, sha256}}}

  devices  only these boards get the release (a trial roll-out); absent = all.
  pins     a board gets exactly this build, even an older one. Without a pin a
           board never goes down.

Usage:
  publish_esp_rt.py pulse --devices C05D89AD0D74     # build/pulse -> trial on one board
  publish_esp_rt.py pulse --all                      # everybody
  publish_esp_rt.py pulse --pin ID --file old.bin --version 1.1.0 --code 10100
  publish_esp_rt.py pulse --pin ID --version 1.1.1   # an already published build, no file
  publish_esp_rt.py pulse --unpin ID
  publish_esp_rt.py pulse --show

A new release keeps the existing `pins`; `--all` drops `devices`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import _supabase  # noqa: E402
from _common import REPO_ROOT, fail, info, ok, step  # noqa: E402

RT = REPO_ROOT / "firmware" / "esp-rt"
ID_RE = re.compile(r"^[0-9A-F]{12}$")


def config_version() -> tuple[str, int]:
    text = (RT / "main" / "config.h").read_text()
    name = re.search(r'#define\s+FW_VERSION_NAME\s+"([^"]+)"', text)
    code = re.search(r"#define\s+FW_VERSION_CODE\s+(\d+)", text)
    if not name or not code:
        fail("FW_VERSION_NAME / FW_VERSION_CODE not found in main/config.h")
    return name.group(1), int(code.group(1))


def read_manifest(stream: str) -> dict:
    # Fresh copy: the public URL sits behind a CDN with a 60 s cache.
    req = urllib.request.Request(_supabase.manifest_url(stream) + f"?t={int(datetime.now().timestamp())}")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code in (400, 404):
            return {}
        fail(f"manifest fetch failed: HTTP {e.code}")


def write_manifest(key: str, stream: str, m: dict) -> None:
    _supabase.upload(key, f"{stream}/manifest.json",
                     json.dumps(m, ensure_ascii=False, indent=2).encode(),
                     cache=_supabase.MANIFEST_CACHE)


def upload_bin(key: str, stream: str, src: Path, version: str) -> dict:
    blob = src.read_bytes()
    name = f"{stream}-{version}.bin"
    info(f"uploading {name} ({len(blob) / 1048576:.2f} MB)")
    url = _supabase.upload(key, f"{stream}/{name}", blob, cache=_supabase.BINARY_CACHE)
    return {"url": url, "size": len(blob), "sha256": hashlib.sha256(blob).hexdigest()}


def check_ids(ids: list[str]) -> list[str]:
    ids = [i.strip().upper() for i in ids if i.strip()]
    bad = [i for i in ids if not ID_RE.match(i)]
    if bad:
        fail(f"not a board ID (12 upper-case hex): {', '.join(bad)}")
    return ids


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("variant", choices=["pulse", "relay"])
    ap.add_argument("--devices", help="comma-separated board IDs: trial roll-out")
    ap.add_argument("--all", action="store_true", help="release to every board")
    ap.add_argument("--notes", default="")
    ap.add_argument("--pin", metavar="ID", help="pin one board to --file")
    ap.add_argument("--unpin", metavar="ID")
    ap.add_argument("--file", type=Path, help="binary for --pin; omit to reuse a published --version")
    ap.add_argument("--version", help="version name for --pin")
    ap.add_argument("--code", type=int, help="version code for --pin (default: A.B.C -> A*10000+B*100+C)")
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args()

    stream = f"esp-rt-{a.variant}"
    key = _supabase.secret_key()
    manifest = read_manifest(stream)

    if a.show:
        print(json.dumps(manifest, ensure_ascii=False, indent=2))
        return

    if a.unpin:
        [bid] = check_ids([a.unpin])
        if bid not in manifest.get("pins", {}):
            fail(f"{bid} is not pinned")
        del manifest["pins"][bid]
        if not manifest["pins"]:
            del manifest["pins"]
        write_manifest(key, stream, manifest)
        ok(f"{bid} unpinned — it follows the general release again")
        return

    if a.pin:
        [bid] = check_ids([a.pin])
        if not manifest:
            fail("no release published yet: publish one first (a pin edits an existing manifest)")
        if a.file or not a.version:
            cfg_name, cfg_code = config_version()
            version, code = a.version or cfg_name, a.code or cfg_code
            src = a.file or RT / "build" / a.variant / "esp_rt.bin"
            if not src.exists():
                fail(f"{src} not found")
            step(f"Pin {bid} to {version} ({code})")
            entry = {"version": version, "code": code, **upload_bin(key, stream, src, version)}
        else:
            # Reuse a build that is already in Storage (every release stays there).
            version = a.version
            m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version)
            if not a.code and not m:
                fail("--version must look like 1.1.1, or pass --code")
            code = a.code or int(m[1]) * 10000 + int(m[2]) * 100 + int(m[3])
            url = _supabase.public_url(f"{stream}/{stream}-{version}.bin")
            step(f"Pin {bid} to published {version} ({code})")
            try:
                with urllib.request.urlopen(url, timeout=120) as r:
                    blob = r.read()
            except urllib.error.HTTPError as e:
                fail(f"{url}: HTTP {e.code} — that version was never published")
            entry = {"version": version, "code": code, "url": url,
                     "size": len(blob), "sha256": hashlib.sha256(blob).hexdigest()}
        manifest.setdefault("pins", {})[bid] = entry
        write_manifest(key, stream, manifest)
        ok(f"{bid} pinned to {version}")
        return

    # Release the current build.
    if not a.devices and not a.all:
        fail("say who gets it: --devices ID[,ID...] for a trial or --all for every board")
    src = RT / "build" / a.variant / "esp_rt.bin"
    if not src.exists():
        fail(f"{src} not found — build the {a.variant} variant first")
    version, code = config_version()
    if manifest and code < manifest.get("code", 0) and a.all:
        fail(f"{code} is below the published {manifest['code']}; boards never go down on their own. "
             f"Use --pin to move one board.")
    # A forgotten rebuild publishes the old binary under the new code: the board
    # would reinstall it at every check, because the image reports the old code.
    sha = hashlib.sha256(src.read_bytes()).hexdigest()
    same = [m for m in [manifest, *manifest.get("pins", {}).values()]
            if m.get("sha256") == sha and m.get("code") != code]
    if same or src.stat().st_mtime < (RT / "main" / "config.h").stat().st_mtime:
        fail(f"{src.name} is not a build of {version} (identical to an already published "
             f"one, or older than config.h). Run idf.py build first.")
    step(f"Publish esp-rt {a.variant} {version} ({code})")
    new = {
        "version": version,
        "code": code,
        "notes": a.notes,
        "published_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        **upload_bin(key, stream, src, version),
    }
    if a.devices:
        new["devices"] = check_ids(a.devices.split(","))
    if manifest.get("pins"):
        new["pins"] = manifest["pins"]
    write_manifest(key, stream, new)
    ok(f"{stream}: {version} -> {', '.join(new['devices']) if 'devices' in new else 'all boards'}")
    info(_supabase.manifest_url(stream))


if __name__ == "__main__":
    main()
