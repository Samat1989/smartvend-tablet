-- Tighten product-images to webp-only.
-- The admin re-encodes every picked image to image/webp client-side before
-- upload (apps/web_app/src/Admin.jsx — canvas.toBlob('image/webp', 0.85)),
-- and nothing else uploads to this bucket (the tablet only references
-- image_url, never uploads). So narrow allowed_mime_types from
-- [webp,png,jpeg] to [webp] — exactly matches the app, rejects anything else.
--
-- Applied to prod via Supabase MCP on 2026-06-03 (storage_product_images_webp_only).
update storage.buckets
   set allowed_mime_types = array['image/webp']
 where id = 'product-images';
