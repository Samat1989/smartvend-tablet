-- ==========================================================================
-- Fix: anon INSERT on sales_items silently failing since RLS hardening
-- ==========================================================================
-- Background:
--   20260526120000_rls_hardening_phase_a.sql added
--     WITH CHECK (EXISTS (SELECT 1 FROM sales WHERE id = sales_items.sale_id))
--   on the anon INSERT policy. The intent was "the sale_id must reference a
--   real sale". But sales has no anon SELECT policy (only owner/authenticated
--   reads), so under RLS the EXISTS subquery returns zero rows for anon and
--   the WITH CHECK is always false → every sales_items insert from a kiosk
--   is rejected.
--
--   Symptom: from 2026-05-26 12:00 UTC onward, sales rows are inserted but
--   their sales_items rows are missing. The web admin's receipt view (which
--   filters on dispensed=false to flag "не выдано / к возврату") has nothing
--   to show. The tablet only debugPrints the 403 — operator never sees it.
--
-- Fix:
--   The integrity guarantee the policy was reaching for ("sale_id must exist")
--   is already enforced by the sales_items_sale_id_fkey foreign key. Drop the
--   redundant RLS check so the FK does its job. Net result: the security
--   posture is the same as the migration intended (anon can post line-items
--   only against existing sales), but it actually works.
-- ==========================================================================

DROP POLICY IF EXISTS "Allow anon insert sales_items (must reference real sale)"
  ON public.sales_items;

CREATE POLICY "Allow anon insert sales_items"
  ON public.sales_items
  FOR INSERT TO anon
  WITH CHECK (sale_id IS NOT NULL);
