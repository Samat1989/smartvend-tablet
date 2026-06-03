-- =========================================================================
-- RLS cleanup + performance indexes (Phase B sweep)
-- =========================================================================
-- Applied via Supabase MCP on 2026-05-26 in response to a Supabase
-- "exhausting resources" warning. The root cause turned out to be a cron
-- job (`* * * * *`) pinging `cron-process-payments` edge function which
-- blocked for 50 s on every invocation polling an empty `pending_orders`
-- table. Cron was unscheduled separately (SELECT cron.unschedule(5)) and
-- 50K stale rows in cron.job_run_details were deleted.
--
-- This migration handles the schema-level cleanup that was outstanding
-- after the Phase A RLS migration left duplicate policies behind:
--
--   1. Drop duplicate/overlapping policies so each query evaluates one
--      policy per role/action instead of 2-3.
--   2. Close the gaping `anon DELETE/INSERT/UPDATE inventory USING(true)`
--      — kiosk's anon-key could wipe stock for any micromarket. INSERT/
--      UPDATE now require WITH CHECK that micromarket_id references a
--      real market (same pattern as sales/sales_items). DELETE is
--      authenticated-owner-only.
--   3. Re-create owner-scoped policies using `(select auth.uid())`
--      instead of bare `auth.uid()`. The bare form re-evaluates per
--      row; the SELECT form is cached for the whole query. Surfaced as
--      `auth_rls_initplan` lint warning across 9 tables.
--   4. Add 8 covering indexes for unindexed foreign keys identified by
--      `unindexed_foreign_keys` lint. Sequential scans before this.
--
-- Phase C (future): replace direct anon writes (sales INSERT, commands
-- UPDATE, inventory INSERT/UPDATE) with SECURITY DEFINER RPCs that
-- validate machid+secret. Until then anon can write on behalf of any
-- existing market — the EXISTS check only blocks orphan/forged-UUID
-- inserts, not impersonation across operators.
-- =========================================================================

-- ── categories ─────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Allow auth changes on categories" ON public.categories;
DROP POLICY IF EXISTS "Allow public reads on categories" ON public.categories;
DROP POLICY IF EXISTS "Anon read categories" ON public.categories;
DROP POLICY IF EXISTS "Owner manages own categories" ON public.categories;

CREATE POLICY "Anon read categories"
  ON public.categories FOR SELECT TO anon USING (true);

CREATE POLICY "Owner manages own categories"
  ON public.categories FOR ALL TO authenticated
  USING  (owner_id = (select auth.uid()) OR owner_id IS NULL)
  WITH CHECK (owner_id = (select auth.uid()));


-- ── commands ───────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Allow anon select commands" ON public.commands;
DROP POLICY IF EXISTS "Allow anon update commands (must reference real market)" ON public.commands;
DROP POLICY IF EXISTS "Users can manage commands for own markets" ON public.commands;

CREATE POLICY "Anon read commands"
  ON public.commands FOR SELECT TO anon USING (true);

CREATE POLICY "Anon update commands (real market)"
  ON public.commands FOR UPDATE TO anon
  USING      (EXISTS (SELECT 1 FROM public.micromarkets m WHERE m.id = commands.micromarket_id))
  WITH CHECK (EXISTS (SELECT 1 FROM public.micromarkets m WHERE m.id = commands.micromarket_id));

CREATE POLICY "Owner manages commands"
  ON public.commands FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.micromarkets m
    WHERE m.id = commands.micromarket_id AND m.owner_id = (select auth.uid())
  ));


-- ── inventory ──────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Allow anon delete inventory" ON public.inventory;
DROP POLICY IF EXISTS "Allow anon insert inventory" ON public.inventory;
DROP POLICY IF EXISTS "Allow anon select inventory" ON public.inventory;
DROP POLICY IF EXISTS "Allow anon update inventory" ON public.inventory;
DROP POLICY IF EXISTS "Users can manage inventory of own markets" ON public.inventory;

CREATE POLICY "Anon read inventory"
  ON public.inventory FOR SELECT TO anon USING (true);

CREATE POLICY "Anon insert inventory (real market)"
  ON public.inventory FOR INSERT TO anon
  WITH CHECK (EXISTS (SELECT 1 FROM public.micromarkets m WHERE m.id = inventory.micromarket_id));

CREATE POLICY "Anon update inventory (real market)"
  ON public.inventory FOR UPDATE TO anon
  USING      (EXISTS (SELECT 1 FROM public.micromarkets m WHERE m.id = inventory.micromarket_id))
  WITH CHECK (EXISTS (SELECT 1 FROM public.micromarkets m WHERE m.id = inventory.micromarket_id));

CREATE POLICY "Owner manages inventory"
  ON public.inventory FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.micromarkets m
    WHERE m.id = inventory.micromarket_id AND m.owner_id = (select auth.uid())
  ));


-- ── micromarkets ───────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Allow anon select micromarkets" ON public.micromarkets;
DROP POLICY IF EXISTS "Users can manage own micromarkets" ON public.micromarkets;

CREATE POLICY "Anon read micromarkets"
  ON public.micromarkets FOR SELECT TO anon USING (true);

CREATE POLICY "Owner manages micromarkets"
  ON public.micromarkets FOR ALL TO authenticated
  USING ((select auth.uid()) = owner_id);


-- ── pending_orders ─────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Enable all pending_orders" ON public.pending_orders;
DROP POLICY IF EXISTS "Owner reads own pending orders" ON public.pending_orders;
DROP POLICY IF EXISTS "Service role manages pending orders" ON public.pending_orders;

CREATE POLICY "Service role manages pending orders"
  ON public.pending_orders FOR ALL TO service_role
  USING (true) WITH CHECK (true);

CREATE POLICY "Owner reads own pending orders"
  ON public.pending_orders FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.micromarkets mm
    WHERE mm.id::text = pending_orders.market_id::text AND mm.owner_id = (select auth.uid())
  ));


-- ── products ───────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Anon read published products" ON public.products;
DROP POLICY IF EXISTS "Owner manages own products" ON public.products;
DROP POLICY IF EXISTS "products_anon_insert_draft" ON public.products;
DROP POLICY IF EXISTS "products_anon_select" ON public.products;
DROP POLICY IF EXISTS "products_auth_select" ON public.products;
DROP POLICY IF EXISTS "products_owner_all" ON public.products;

CREATE POLICY "Anon read published products"
  ON public.products FOR SELECT TO anon
  USING (is_archived = false AND is_draft = false);

CREATE POLICY "Anon insert draft product"
  ON public.products FOR INSERT TO anon
  WITH CHECK (is_draft = true);

CREATE POLICY "Owner manages own products"
  ON public.products FOR ALL TO authenticated
  USING      (owner_id = (select auth.uid()))
  WITH CHECK (owner_id = (select auth.uid()));


-- ── profiles ───────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can manage own profile" ON public.profiles;

CREATE POLICY "Users can manage own profile"
  ON public.profiles FOR ALL TO authenticated
  USING ((select auth.uid()) = id);


-- ── sales ──────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Allow anon insert sales (must reference real market)" ON public.sales;
DROP POLICY IF EXISTS "Users can view sales of own markets" ON public.sales;

CREATE POLICY "Anon insert sales (real market)"
  ON public.sales FOR INSERT TO anon
  WITH CHECK (EXISTS (SELECT 1 FROM public.micromarkets m WHERE m.id = sales.micromarket_id));

CREATE POLICY "Owner reads sales of own markets"
  ON public.sales FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.micromarkets m
    WHERE m.id = sales.micromarket_id AND m.owner_id = (select auth.uid())
  ));


-- ── sales_items ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Allow anon insert sales_items (must reference real sale)" ON public.sales_items;
DROP POLICY IF EXISTS "Users can view sales_items of own markets" ON public.sales_items;

CREATE POLICY "Anon insert sales_items (real sale)"
  ON public.sales_items FOR INSERT TO anon
  WITH CHECK (EXISTS (SELECT 1 FROM public.sales s WHERE s.id = sales_items.sale_id));

CREATE POLICY "Owner reads sales_items of own markets"
  ON public.sales_items FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.sales s
    JOIN public.micromarkets m ON m.id = s.micromarket_id
    WHERE s.id = sales_items.sale_id AND m.owner_id = (select auth.uid())
  ));


-- ── indexes for unindexed foreign keys ─────────────────────────────────────
CREATE INDEX IF NOT EXISTS categories_owner_id_idx       ON public.categories(owner_id);
CREATE INDEX IF NOT EXISTS commands_micromarket_id_idx   ON public.commands(micromarket_id);
CREATE INDEX IF NOT EXISTS inventory_category_id_idx     ON public.inventory(category_id);
CREATE INDEX IF NOT EXISTS micromarkets_owner_id_idx     ON public.micromarkets(owner_id);
CREATE INDEX IF NOT EXISTS pending_orders_market_id_idx  ON public.pending_orders(market_id);
CREATE INDEX IF NOT EXISTS sales_micromarket_id_idx      ON public.sales(micromarket_id);
CREATE INDEX IF NOT EXISTS sales_items_sale_id_idx       ON public.sales_items(sale_id);
CREATE INDEX IF NOT EXISTS sales_items_product_id_idx    ON public.sales_items(product_id);
