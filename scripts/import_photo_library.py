#!/usr/bin/env python3
"""Bulk-import a product photo library into Supabase Storage.

WHAT THIS IS FOR

Operators used to have exactly one way to give a product a picture: pick a
file, crop it, upload it. Every operator re-photographed the same Coca-Cola.
This publishes a shared photo bank instead -- one copy of each picture, in
the bucket the app already serves from, which every operator's catalog can
point at. `image_url` is then literally the same string for everyone, so the
tablet's disk cache (cached_network_image) fetches each photo once across the
whole fleet.

Note what this does NOT do: it creates no rows in `public.products`. The
photo bank is a bank of FILES. Every operator still builds their own catalog;
the admin panel just offers these pictures as a source when creating a
product. A shared *catalog* was the first design and was dropped -- it meant
3019 template rows that `copy_starter_products()` would clone wholesale into
an operator's catalog on one button press.

LAYOUT IN THE BUCKET

    product-images/library/<md5>.webp     600px q85, ~24 KB -- what shoppers see
    product-images/library/t/<md5>.webp   200px q80, ~4 KB  -- the picker's grid
    product-images/library/index.json     [{"n": name, "f": md5}, ...]

The filename is the md5 of the encoded 600px file, and that is load-bearing
three times over: identical photos collapse to one object (the source set has
~192 such groups -- a product and its "Дисконт" twin share a shot), the URL
can be cached for a year because its content can never change, and a second
run re-derives the same names and uploads nothing.

600px q85 is not a taste call: it is what apps/web_app/src/Admin.jsx already
produces for hand-uploaded photos (targetSize = 600, toBlob('image/webp',
0.85)), and the biggest any photo is ever drawn is ~640px -- a product card
on a FHD tablet at 3 columns. The bucket only accepts image/webp anyway
(migration 20260603200000_storage_product_images_webp_only).

INPUT

A scrape directory holding:

    library.json                        {"products": [{name, category, image_name, ...}]}
    images/<category>/<image_name>      the photos themselves

DEPENDENCY -- the one exception to "stdlib only"

This needs Pillow, unlike every other script here. Decoding JPEG/PNG and
encoding WebP is not something stdlib does, and shelling out to cwebp or
ImageMagick would trade a Python import for a system package that is not
installed on this box either. Everything touching the network still goes
through _supabase.py's urllib client.

    sudo apt install python3-pil     # or: pip install Pillow

USAGE

    python3 scripts/import_photo_library.py --source ~/photos --dry-run
    python3 scripts/import_photo_library.py --source ~/photos --limit 20
    python3 scripts/import_photo_library.py --source ~/photos
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _common import REPO_ROOT, fail, info, ok, step, warn  # noqa: E402
import _supabase  # noqa: E402

BUCKET = "product-images"
PREFIX = "library"
THUMB_PREFIX = f"{PREFIX}/t"

FULL_PX, FULL_Q = 600, 85
THUMB_PX, THUMB_Q = 200, 80

# Content-addressed names, so the bytes behind a URL can never change.
PHOTO_CACHE = 31536000        # 1 year
# The index can change whenever the library grows, and it is one small file.
INDEX_CACHE = 300             # 5 minutes


def _load_pillow():
    """Import Pillow with an actionable message instead of a traceback."""
    try:
        from PIL import Image, features
    except ImportError:
        fail("Pillow is required by this script (the only non-stdlib "
             "dependency in scripts/).\n"
             "  sudo apt install python3-pil     # or: pip install Pillow")
    if not features.check("webp"):
        fail("This Pillow build has no WebP support, and the bucket accepts "
             "nothing else.\n  Reinstall Pillow with libwebp available.")
    return Image


def convert_one(job: tuple[str, str, str]) -> tuple[str, str, int, int]:
    """Encode one source photo into a full-size and a thumbnail WebP.

    Runs in a worker process, so it takes and returns only plain strings --
    and writes the bytes to disk rather than shipping ~100 MB back through
    the pool. Returns (source path, md5, full size, thumb size).
    """
    src, out_dir, thumb_dir = job
    Image = _load_pillow()

    with Image.open(src) as im:
        im.load()
        # Flatten onto white exactly like Admin.jsx's getCroppedImg does, so
        # library photos and hand-uploaded ones sit on the same background in
        # one grid. Some sources are PNGs with real transparency.
        if im.mode in ("RGBA", "LA") or "transparency" in im.info:
            rgba = im.convert("RGBA")
            flat = Image.new("RGB", rgba.size, (255, 255, 255))
            flat.paste(rgba, mask=rgba.split()[-1])
        else:
            flat = im.convert("RGB")

    full = flat.copy()
    full.thumbnail((FULL_PX, FULL_PX), Image.LANCZOS)
    # Per-process temp name: workers run concurrently in the same directory,
    # and the final name is not known until the bytes have been encoded.
    full_path = Path(out_dir) / f"__tmp-{os.getpid()}.webp"
    full.save(full_path, "WEBP", quality=FULL_Q, method=6)
    blob = full_path.read_bytes()
    digest = hashlib.md5(blob).hexdigest()

    final = Path(out_dir) / f"{digest}.webp"
    full_path.replace(final)

    thumb_path = Path(thumb_dir) / f"{digest}.webp"
    if not thumb_path.exists():
        thumb = flat.copy()
        thumb.thumbnail((THUMB_PX, THUMB_PX), Image.LANCZOS)
        thumb.save(thumb_path, "WEBP", quality=THUMB_Q, method=6)

    return src, digest, len(blob), thumb_path.stat().st_size


def read_library(source: Path, limit: int | None) -> list[dict]:
    """Parse library.json, keeping the products whose photo is still on disk.

    Deleting a file under images/ is how you drop a product from the library:
    the scrape carries things nobody wants on a vending machine, and pruning
    the folder is more direct than maintaining a list of exceptions beside it.
    So a missing photo is a deliberate act, reported and skipped, not an error
    -- library.json is left exactly as it was scraped.

    An empty result still fails: that means a wrong --source, or a pruning
    that went further than intended, and silently publishing nothing would
    look like success.
    """
    manifest = source / "library.json"
    if not manifest.exists():
        fail(f"No library.json in {source}")
    products = json.loads(manifest.read_text(encoding="utf-8")).get("products", [])
    if not products:
        fail(f"{manifest} has no 'products'")

    kept, dropped = [], []
    for p in products:
        p["_path"] = source / "images" / p["category"] / p["image_name"]
        (kept if p["_path"].exists() else dropped).append(p)

    if dropped:
        info(f"{len(dropped)} photo(s) deleted from images/ -- skipping those "
             f"products (e.g. {dropped[0]['name']})")
    if not kept:
        fail(f"No photos left under {source / 'images'} -- wrong --source, or "
             f"everything was deleted?")

    return kept[:limit] if limit else kept


def convert_all(products: list[dict], out: Path, workers: int) -> None:
    """Fill in each product's 'digest' by encoding its photo. Parallel, CPU-bound."""
    out_dir, thumb_dir = out / "full", out / "thumb"
    out_dir.mkdir(parents=True, exist_ok=True)
    thumb_dir.mkdir(parents=True, exist_ok=True)

    jobs = [(str(p["_path"]), str(out_dir), str(thumb_dir)) for p in products]
    by_path: dict[str, dict] = {str(p["_path"]): p for p in products}

    full_bytes = thumb_bytes = done = 0
    with ProcessPoolExecutor(max_workers=workers) as pool:
        for src, digest, n_full, n_thumb in pool.map(convert_one, jobs, chunksize=16):
            by_path[src]["digest"] = digest
            full_bytes += n_full
            thumb_bytes += n_thumb
            done += 1
            if done % 250 == 0 or done == len(jobs):
                info(f"{done}/{len(jobs)} encoded")

    unique = len({p["digest"] for p in products})
    ok(f"{len(products)} photos -> {unique} unique files "
       f"({len(products) - unique} duplicates collapsed)")
    info(f"full  {full_bytes / 1e6:6.1f} MB  ({full_bytes / len(products) / 1024:.1f} KB avg)")
    info(f"thumb {thumb_bytes / 1e6:6.1f} MB  ({thumb_bytes / len(products) / 1024:.1f} KB avg)")


def build_index(products: list[dict], out: Path) -> bytes:
    """The admin panel's search index: one entry per product, name + hash.

    Deliberately not a table. It is 78 KB gzipped, the browser caches it for
    the session, and search stays client-side and instant -- where a
    `stock_images` table would have meant a schema change, RLS policies and a
    paginated RPC for the same result.
    """
    index = [{"n": p["name"], "f": p["digest"]} for p in products]
    blob = json.dumps(index, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    (out / "index.json").write_bytes(blob)
    return blob


def upload_all(key: str, products: list[dict], out: Path, index: bytes,
               workers: int) -> None:
    """Push files first, index last, skipping whatever already landed."""
    # Check this BEFORE spending four minutes on photos. The bucket was
    # narrowed to image/webp alone in 20260603200000, back when nothing but
    # photos went into it, and the index is the first object that is not one.
    # Compare against the header the upload will actually send, not against a
    # hardcoded "application/json": Storage matches the whole header, so a
    # charset parameter is enough to turn an allowed type into a 415.
    index_type = _supabase.content_type_for("index.json")
    allowed = _supabase.bucket_info(key, bucket=BUCKET).get("allowed_mime_types")
    if allowed and index_type not in allowed:
        fail(f"'{BUCKET}' accepts only {', '.join(allowed)}, but the index is sent "
             f"as {index_type}, so it cannot "
             f"be published.\n"
             f"  Apply supabase/migrations/"
             f"20260914130000_storage_product_images_allow_index.sql, then re-run.\n"
             f"  Photos already uploaded are skipped, so a re-run is cheap.")

    step("Checking what is already in the bucket")
    have_full = {n.removesuffix(".webp")
                 for n in _supabase.list_objects(key, PREFIX, bucket=BUCKET)}
    have_thumb = {n.removesuffix(".webp")
                  for n in _supabase.list_objects(key, THUMB_PREFIX, bucket=BUCKET)}
    info(f"{len(have_full)} full, {len(have_thumb)} thumbs already there")

    digests = {p["digest"] for p in products}
    todo: list[tuple[Path, str]] = []
    for d in sorted(digests):
        if d not in have_full:
            todo.append((out / "full" / f"{d}.webp", f"{PREFIX}/{d}.webp"))
        if d not in have_thumb:
            todo.append((out / "thumb" / f"{d}.webp", f"{THUMB_PREFIX}/{d}.webp"))

    if not todo:
        ok("Nothing to upload -- every file is already in the bucket")
    else:
        step(f"Uploading {len(todo)} objects")
        done = 0
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = {pool.submit(_upload_one, key, src, path): path
                       for src, path in todo}
            for fut in as_completed(futures):
                fut.result()          # re-raises, aborting the run
                done += 1
                if done % 200 == 0 or done == len(todo):
                    info(f"{done}/{len(todo)} uploaded")
        ok(f"{len(todo)} objects uploaded")

    # Index last, on purpose: it is what the admin panel reads to learn a
    # photo exists. Publishing it before the files land means any operator who
    # opens the picker in between gets broken thumbnails.
    step("Uploading index.json")
    url = _supabase.upload(key, f"{PREFIX}/index.json", index,
                           cache=INDEX_CACHE, bucket=BUCKET)
    ok(f"index: {url}")


def _upload_one(key: str, src: Path, path: str) -> None:
    """One upload, retried -- a single 504 should not abandon 2000 files.

    _supabase.upload() reports a non-2xx through fail(), which prints and
    raises SystemExit. Catching that is what makes a retry possible; the warn
    below is so the ERROR line it already printed does not read as a lost
    file when the next attempt succeeds.
    """
    for attempt in range(1, 4):
        try:
            _supabase.upload(key, path, src.read_bytes(),
                             cache=PHOTO_CACHE, bucket=BUCKET)
            if attempt > 1:
                warn(f"{path} went through on attempt {attempt} "
                     f"(the error above was transient)")
            return
        except SystemExit:             # non-2xx, already printed by fail()
            if attempt == 3:
                raise RuntimeError(f"upload of {path} failed after 3 attempts")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", required=True, type=Path,
                    help="directory holding library.json and images/")
    ap.add_argument("--out", type=Path, default=REPO_ROOT / "build" / "photo-library",
                    help="where encoded files are staged (default: build/photo-library)")
    ap.add_argument("--limit", type=int, help="only the first N products")
    ap.add_argument("--dry-run", action="store_true",
                    help="encode and report, touch no network")
    ap.add_argument("--workers", type=int, default=min(8, (os.cpu_count() or 4)),
                    help="parallel encoders / uploaders")
    args = ap.parse_args()

    source = args.source.expanduser().resolve()
    if not source.is_dir():
        fail(f"--source {source} is not a directory")

    step(f"Reading {source / 'library.json'}")
    products = read_library(source, args.limit)
    ok(f"{len(products)} products")

    step(f"Encoding to {FULL_PX}px q{FULL_Q} + {THUMB_PX}px q{THUMB_Q} "
         f"({args.workers} workers)")
    args.out.mkdir(parents=True, exist_ok=True)
    convert_all(products, args.out, args.workers)

    index = build_index(products, args.out)
    ok(f"index.json: {len(index) / 1024:.0f} KB, {len(products)} entries")

    if args.dry_run:
        warn("--dry-run: nothing uploaded")
        info(f"staged in {args.out}")
        return

    upload_all(_supabase.secret_key(), products, args.out, index, args.workers)
    ok("Done")


if __name__ == "__main__":
    main()
