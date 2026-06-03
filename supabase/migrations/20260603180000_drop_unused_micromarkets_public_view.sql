-- ============================================================
-- Drop the unused micromarkets_public view
--
-- It was created (20260603120000) as scaffolding for the future static_qr
-- customer web flow, but nothing uses it yet: the tablet pairs via
-- verify_pairing() and the admin reads micromarkets under the authenticated
-- owner policy. As a SECURITY DEFINER view it trips the security_definer_view
-- advisor (ERROR), so drop it for now.
--
-- When static_qr is built, recreate it deliberately — either security_invoker
-- with a column-scoped anon SELECT (so RLS still applies and secret stays
-- hidden), or a definer view with a documented rationale.
--
-- Applied to prod via Supabase MCP on 2026-06-03 (drop_unused_micromarkets_public_view).
-- ============================================================

drop view if exists public.micromarkets_public;
