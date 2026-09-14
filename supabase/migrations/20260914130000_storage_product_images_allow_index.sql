-- ============================================================
-- Let product-images hold the photo bank's index
--
-- 20260603200000_storage_product_images_webp_only.sql narrowed the bucket to
-- image/webp alone, on the reasoning that "the admin re-encodes every picked
-- image to image/webp client-side before upload, and nothing else uploads to
-- this bucket". That held until the shared photo bank
-- (scripts/import_photo_library.py) added one more object beside the photos:
--
--     product-images/library/index.json   [{"n": name, "f": md5}, ...]
--
-- It is what the admin panel's picker reads to know which photos exist, so it
-- belongs next to them rather than in a second bucket.
--
-- What this gives up, honestly: an authenticated operator can now also upload
-- JSON here, not just WebP. That is a smaller loosening than it reads as --
-- Storage matches the request's declared Content-Type, not the actual bytes,
-- so anyone minded to park arbitrary data in this bucket could already do it
-- by labelling it image/webp. The list keeps out honest mistakes (a 20 MB
-- PNG, a PDF), and both of those are still rejected.
--
-- The 5 MB cap and the owner-scoped UPDATE policy from
-- 20260603190000_storage_product_images_owner_scope.sql are untouched.
-- ============================================================

update storage.buckets
   set allowed_mime_types = array['image/webp', 'application/json']
 where id = 'product-images';
