"""Supabase Storage client for the release scripts. Stdlib only (urllib).

Why Storage instead of GitHub Releases: a GitHub repo is ONE tag namespace
shared by the tablet APK and both ESP firmwares, and every workaround in the
old pipeline came from that -- tag prefixes, the tablet's _tabletTag
whitelist, and the firmware fetching /tags instead of /releases because the
tablet's release JSON overflowed its buffer.

Storage has paths instead. Each stream owns a directory and its own
manifest, so a device fetches exactly one URL and gets exactly one answer:

    updates/tablet/manifest.json   + app-<version>-armeabi-v7a.apk
    updates/pulse/manifest.json    + pulse-mart-<version>.bin
    updates/relay/manifest.json    + relay-mart-<version>.bin

Nothing to filter, no shared list to parse, and the streams' version codes
can look alike because they are never compared to each other.
"""

from __future__ import annotations

import hashlib
import json
import os
import urllib.error
import urllib.request
from pathlib import Path

from _common import REPO_ROOT, fail, info, ok, step

PROJECT_REF = "cgvfhtvdtdjsyluhlcbq"          # SupabaseConfig.url in the app
BASE = f"https://{PROJECT_REF}.supabase.co"
BUCKET = "updates"                            # default; other buckets passed per call

# The manifest must go stale fast -- it is the only way a device learns a
# release exists, and Storage serves objects through a CDN. The binaries are
# content-addressed by filename and never change, so they can sit for a year.
MANIFEST_CACHE = 60           # seconds
BINARY_CACHE = 31536000       # 1 year

KEY_FILE = REPO_ROOT / ".supabase_key"

_CONTENT_TYPES = {
    ".apk": "application/vnd.android.package-archive",
    ".bin": "application/octet-stream",
    ".json": "application/json; charset=utf-8",
    ".webp": "image/webp",
}


def secret_key() -> str:
    """Supabase secret key, from $SUPABASE_SECRET_KEY or .supabase_key.

    This project is on Supabase's current key scheme -- the tablet ships a
    `sb_publishable_...` key (SupabaseConfig.anonKey), whose privileged
    counterpart is `sb_secret_...`. The legacy `service_role` JWT still
    works if that is what a given project hands out; both are passed the
    same way, so nothing here needs to tell them apart.

    Storage has no upload-only keys, so publishing needs a full-access one.
    Treat it like the GitHub PAT: gitignored file, never committed.
    """
    key = (os.environ.get("SUPABASE_SECRET_KEY")
           or os.environ.get("SUPABASE_SERVICE_KEY") or "").strip()
    if not key and KEY_FILE.exists():
        key = KEY_FILE.read_text(encoding="utf-8").strip()
    if not key:
        fail(f"Supabase secret key not found.\n"
             f"  Put it in {KEY_FILE} (gitignored), or set "
             f"SUPABASE_SECRET_KEY.\n"
             f"  Dashboard -> Project Settings -> API Keys -> Secret keys "
             f"(sb_secret_...).")
    return key


def _request(method: str, url: str, *, key: str, data: bytes | None = None,
             headers: dict | None = None) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("apikey", key)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except urllib.error.URLError as e:
        fail(f"Supabase unreachable: {e.reason}")


def ensure_bucket(key: str, *, public: bool = True, bucket: str = BUCKET) -> None:
    """Create the bucket if it isn't there. Idempotent."""
    status, body = _request("GET", f"{BASE}/storage/v1/bucket/{bucket}", key=key)
    if status == 200:
        existing = json.loads(body)
        if existing.get("public") is not public:
            fail(f"Bucket '{bucket}' exists but public={existing.get('public')}, "
                 f"expected public={public}. Fix it in the dashboard.")
        return
    if status not in (400, 404):
        fail(f"Bucket lookup failed ({status}): {body.decode(errors='replace')}")

    step(f"Creating bucket '{bucket}' (public={public})")
    status, body = _request(
        "POST", f"{BASE}/storage/v1/bucket", key=key,
        data=json.dumps({"name": bucket, "id": bucket, "public": public}).encode(),
        headers={"Content-Type": "application/json"})
    if status not in (200, 201):
        fail(f"Bucket create failed ({status}): {body.decode(errors='replace')}")
    ok(f"Bucket '{bucket}' created")


def upload(key: str, path: str, data: bytes, *, cache: int,
           bucket: str = BUCKET) -> str:
    """Upload one object, overwriting if present. Returns its public URL."""
    ctype = _CONTENT_TYPES.get(Path(path).suffix, "application/octet-stream")
    status, body = _request(
        "POST", f"{BASE}/storage/v1/object/{bucket}/{path}", key=key, data=data,
        headers={
            "Content-Type": ctype,
            "cache-control": f"max-age={cache}",
            "x-upsert": "true",
        })
    if status not in (200, 201):
        fail(f"Upload of {path} failed ({status}): {body.decode(errors='replace')}")
    return public_url(path, bucket=bucket)


def public_url(path: str, *, bucket: str = BUCKET) -> str:
    return f"{BASE}/storage/v1/object/public/{bucket}/{path}"


def manifest_url(stream: str) -> str:
    return public_url(f"{stream}/manifest.json")


def publish(key: str, stream: str, artifact: Path, manifest: dict) -> str:
    """Upload an artifact, then the manifest that points at it.

    The order is not an implementation detail: the manifest is the only thing
    a device reads to learn a version exists. Publishing it before the binary
    lands means every device that checks in between gets a 404.

    `manifest` is filled in with url/size/sha256 here. Returns the manifest's
    public URL.
    """
    blob = artifact.read_bytes()
    art_path = f"{stream}/{artifact.name}"
    info(f"uploading {artifact.name} ({len(blob) / 1048576:.1f} MB)")
    url = upload(key, art_path, blob, cache=BINARY_CACHE)

    # sha256 is for diagnosing a truncated upload and for the firmware streams
    # later; the tablet's real integrity gate is Android verifying the APK
    # signature at install time, which is stronger than any hash we ship.
    body = {
        **manifest,
        "url": url,
        "size": len(blob),
        "sha256": hashlib.sha256(blob).hexdigest(),
    }
    man_path = f"{stream}/manifest.json"
    info(f"uploading {man_path}")
    upload(key, man_path,
           json.dumps(body, ensure_ascii=False, indent=2).encode("utf-8"),
           cache=MANIFEST_CACHE)
    return public_url(man_path)


def bucket_info(key: str, bucket: str = BUCKET) -> dict:
    """The bucket's own settings -- public flag, size cap, allowed MIME types."""
    status, body = _request("GET", f"{BASE}/storage/v1/bucket/{bucket}", key=key)
    if status != 200:
        fail(f"Bucket lookup for '{bucket}' failed ({status}): "
             f"{body.decode(errors='replace')}")
    return json.loads(body)


def list_objects(key: str, prefix: str, *, bucket: str = BUCKET) -> set[str]:
    """Every object name directly under `prefix`, as a set.

    Used to make a bulk upload resumable: the caller diffs this against what
    it is about to send and skips what already landed. Storage's list API is
    one flat page per call (it does not recurse into sub-prefixes), so this
    pages until a short page comes back.
    """
    names: set[str] = set()
    offset, page = 0, 100
    while True:
        status, body = _request(
            "POST", f"{BASE}/storage/v1/object/list/{bucket}", key=key,
            data=json.dumps({
                "prefix": prefix,
                "limit": page,
                "offset": offset,
                "sortBy": {"column": "name", "order": "asc"},
            }).encode(),
            headers={"Content-Type": "application/json"})
        if status != 200:
            fail(f"List of {bucket}/{prefix} failed ({status}): "
                 f"{body.decode(errors='replace')}")
        batch = json.loads(body)
        for o in batch:
            # A sub-folder comes back as an entry with a null id. Skip those:
            # only real objects count as "already uploaded".
            if o.get("id") is None:
                continue
            # Names are documented as relative to the prefix, but normalising
            # is one line and the alternative failure is silent -- a resume
            # that matches nothing re-uploads the whole set.
            name = o["name"]
            if name.startswith(prefix + "/"):
                name = name[len(prefix) + 1:]
            names.add(name)
        if len(batch) < page:
            return names
        offset += page
