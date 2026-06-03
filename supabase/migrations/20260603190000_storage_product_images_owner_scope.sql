-- ============================================================
-- F9: product-images storage bucket hardening
--
-- Before: the bucket was public with two authenticated policies whose only
-- predicate was bucket_id='product-images':
--   * "Allow auth uploads" (INSERT) — any operator could upload arbitrary
--     file types / sizes (free hosting / malware staging from the project CDN)
--   * "Allow auth updates" (UPDATE, with_check NULL) — any operator could
--     OVERWRITE ANY object, i.e. deface another operator's product images.
--
-- Fix (no app change needed — Admin uploads with upsert:false + random
-- filenames, so it never UPDATEs existing objects):
--   * Scope UPDATE to owner = auth.uid() so an operator can only touch their
--     own objects. storage.objects.owner is auto-set to the uploader's uid;
--     all 56 existing objects already have it populated.
--   * Constrain the bucket to image MIME types + a 5 MB size cap.
--
-- Left public-read on purpose: product images are displayed publicly anyway.
-- Switching to a private bucket + signed URLs would need Admin.jsx changes
-- (getPublicUrl) and is optional future hardening.
--
-- Applied to prod via Supabase MCP on 2026-06-03 (storage_product_images_owner_scope).
-- ============================================================

drop policy if exists "Allow auth updates" on storage.objects;
create policy "Allow auth updates"
  on storage.objects
  for update to authenticated
  using      (bucket_id = 'product-images' and owner = (select auth.uid()))
  with check (bucket_id = 'product-images' and owner = (select auth.uid()));

update storage.buckets
   set allowed_mime_types = array['image/webp','image/png','image/jpeg'],
       file_size_limit    = 5242880   -- 5 MB
 where id = 'product-images';
