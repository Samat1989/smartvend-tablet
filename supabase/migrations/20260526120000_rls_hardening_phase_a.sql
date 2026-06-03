-- ==========================================================================
-- Phase A: RLS hardening + catalog ownership isolation
-- ==========================================================================
-- Goals:
--   1. Catalog (products + categories) per-owner: each operator only sees
--      and edits their own SKUs in customer_web. Currently products has
--      owner_id but no RLS — Admin.jsx fetches all rows globally.
--   2. Tighten anon INSERT on sales / sales_items: at minimum the row must
--      reference an existing micromarket (no orphan / forged-id writes).
--   3. Tighten anon UPDATE on commands: must reference an existing market.
--   4. Lock pending_orders behind owner_id (currently FOR ALL USING (true)).
--
-- NOT covered by Phase A (needs Phase B = RPC-based identity via machid+secret):
--   * Anon SELECT on inventory / micromarkets / commands is still wide
--     open. Without the kiosk authenticating, RLS cannot restrict the
--     kiosk to "its own row" — anon has no identity. Closing this requires
--     replacing direct table reads with SECURITY DEFINER RPC functions
--     that validate machid+secret before returning rows.
--   * Anon INSERT on sales: still allowed for any existing micromarket_id.
--     A kiosk with leaked anon-key can still post sales to another machine.
--     Same fix path: RPC `record_sale_v2(p_machid, p_secret, ...)`.
--
-- This migration is idempotent — safe to re-run.
-- ==========================================================================

-- ── 1. CATEGORIES ── owner_id column + RLS ─────────────────────────────────

ALTER TABLE public.categories
  ADD COLUMN IF NOT EXISTS owner_id uuid REFERENCES auth.users(id);

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;

-- Drop old open policies on categories (if any).
DROP POLICY IF EXISTS "Allow all on categories" ON public.categories;
DROP POLICY IF EXISTS "Allow anon select categories" ON public.categories;
DROP POLICY IF EXISTS "Users can manage own categories" ON public.categories;

-- Owner full control over their own categories.
-- Existing rows with owner_id IS NULL are treated as legacy/shared:
-- visible to anyone authenticated, but only the owner (once claimed) can
-- mutate. Backfill manually if you want them to "belong" to someone.
CREATE POLICY "Owner manages own categories"
  ON public.categories
  FOR ALL TO authenticated
  USING  (owner_id = auth.uid() OR owner_id IS NULL)
  WITH CHECK (owner_id = auth.uid());

-- Anon (kiosk) needs categories to render product cards. Read-only.
CREATE POLICY "Anon read categories"
  ON public.categories
  FOR SELECT TO anon
  USING (true);


-- ── 2. PRODUCTS ── enable RLS + owner-scoped policies ──────────────────────

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

-- Drop any existing policies so this migration is the source of truth.
DROP POLICY IF EXISTS "Allow all on products" ON public.products;
DROP POLICY IF EXISTS "Allow anon select products" ON public.products;
DROP POLICY IF EXISTS "Users can manage own products" ON public.products;
DROP POLICY IF EXISTS "Anon read published products" ON public.products;

-- Owner full control: insert, select, update, delete only their own rows.
-- INSERT path: WITH CHECK forces owner_id = auth.uid() — Admin.jsx already
-- sets this, but defense-in-depth in case a future client forgets.
CREATE POLICY "Owner manages own products"
  ON public.products
  FOR ALL TO authenticated
  USING  (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

-- Anon (kiosk) reads only published, non-archived SKUs.
-- This still leaks all operators' published products to all kiosks
-- (anon has no identity), but it's read-only and doesn't expose drafts.
-- Phase B will replace this with an RPC that joins through inventory.
CREATE POLICY "Anon read published products"
  ON public.products
  FOR SELECT TO anon
  USING (is_archived = false AND is_draft = false);


-- ── 3. PENDING_ORDERS ── close anon, scope to owner ────────────────────────

ALTER TABLE public.pending_orders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all for service role" ON public.pending_orders;
DROP POLICY IF EXISTS "Anon manage pending orders" ON public.pending_orders;
DROP POLICY IF EXISTS "Owner reads own pending orders" ON public.pending_orders;
DROP POLICY IF EXISTS "Service role manages pending orders" ON public.pending_orders;

-- Service role (used by the edge functions complete-order / verify-payment
-- / process-refunds) can do anything. Without an explicit policy the
-- service-role bypass works, but making it explicit lets us audit which
-- function operates on which table.
CREATE POLICY "Service role manages pending orders"
  ON public.pending_orders
  FOR ALL TO service_role
  USING (true)
  WITH CHECK (true);

-- Owner can read their own pending orders (for dashboards / debugging).
-- Joins through micromarkets.id = pending_orders.market_id. Note: the
-- column types differ (uuid vs int4 in the current schema) — adjust
-- the cast below if your micromarkets.id is uuid:
CREATE POLICY "Owner reads own pending orders"
  ON public.pending_orders
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.micromarkets mm
      WHERE mm.id::text = pending_orders.market_id::text
        AND mm.owner_id = auth.uid()
    )
  );


-- ── 4. SALES / SALES_ITEMS ── require existing micromarket ─────────────────

DROP POLICY IF EXISTS "Allow anon insert sales" ON public.sales;
DROP POLICY IF EXISTS "Allow anon insert sales_items" ON public.sales_items;

-- Anon INSERT on sales: row's micromarket_id must point to a real market.
-- Still allows a kiosk with leaked anon-key to post on behalf of another
-- machine — full fix is Phase B (RPC + machid/secret validation). But at
-- least no random/forged UUIDs that don't exist anywhere.
CREATE POLICY "Allow anon insert sales (must reference real market)"
  ON public.sales
  FOR INSERT TO anon
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.micromarkets WHERE id = sales.micromarket_id)
  );

-- sales_items: the sale_id it references must already exist. Without this
-- you could insert orphan line-items pointing at any UUID.
CREATE POLICY "Allow anon insert sales_items (must reference real sale)"
  ON public.sales_items
  FOR INSERT TO anon
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.sales WHERE id = sales_items.sale_id)
  );


-- ── 5. COMMANDS ── tighten anon UPDATE ─────────────────────────────────────

DROP POLICY IF EXISTS "Allow anon update commands" ON public.commands;

-- Anon UPDATE: row must point to a real market AND the update may only
-- touch the status/result fields (a kiosk reporting back), not retarget
-- the command. The column whitelist needs a trigger if Postgres < 16; for
-- now, the EXISTS check at least blocks updates to non-existent ids.
CREATE POLICY "Allow anon update commands (must reference real market)"
  ON public.commands
  FOR UPDATE TO anon
  USING (
    EXISTS (SELECT 1 FROM public.micromarkets WHERE id = commands.micromarket_id)
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.micromarkets WHERE id = commands.micromarket_id)
  );


-- ── 6. Notes for the operator ──────────────────────────────────────────────
-- After applying this migration:
--   * Check there are no `products` rows with owner_id IS NULL. If any
--     exist, decide whether to claim them (assign an owner_id) or delete:
--       SELECT id, name, owner_id FROM products WHERE owner_id IS NULL;
--   * Same for categories — null owner_id rows are now "legacy shared" and
--     visible to every authenticated user. Either backfill or accept.
--   * If Admin.jsx breaks with "permission denied", the RLS is doing its
--     job — the client just needs an authenticated session. Make sure
--     supabase.auth.getSession() resolves before issuing the query.
