-- ============================================================
-- Step 3: LOCKDOWN — revoke anon's direct table access
--
-- Applied only AFTER tablet 1.1.4 (secret-scoped RPC writes/pairing) was
-- rolled out to all machines. Closes the audit's top findings:
--   F1  — anon could read micromarkets.secret (payment signing key)
--   F2  — anon could write inventory/sales/sales_items of ANY market
--   F10 — duplicate weak anon sales_items insert policy
--   F11 — (partial) strip anon TRUNCATE
--
-- All tablet writes/pairing now go through SECURITY DEFINER RPCs that
-- validate (machid, secret) via _assert_machine and run as the owner, so
-- they are unaffected by these revokes. Anon keeps only what the tablet's
-- direct reads need (SELECT on inventory + categories) and EXECUTE on the
-- RPCs.
--
-- REVERSIBLE: re-grant the verbs and recreate the dropped policies if an
-- un-updated machine is found still writing directly.
--
-- Applied to prod via Supabase MCP on 2026-06-03 (lockdown_revoke_anon_direct_access).
-- Verified post-apply: anon SELECT on micromarkets/products = denied; anon
-- INSERT on inventory/sales/sales_items = denied; RPC sale path + list_catalog
-- still work; security advisor no longer reports the secret-readable finding.
-- ============================================================

-- F1: secret no longer anon-readable.
revoke select on public.micromarkets from anon;
drop policy if exists "Anon read micromarkets" on public.micromarkets;

-- Catalog now served per-owner via list_catalog(); drop blanket anon read +
-- anon draft insert (drafts now via create_draft_product()).
revoke select, insert, update, delete on public.products from anon;
drop policy if exists "Anon read published products" on public.products;
drop policy if exists "Anon insert draft product" on public.products;

-- F2: no direct anon writes — RPCs only.
revoke insert, update, delete on public.inventory from anon;
revoke insert, update, delete on public.sales from anon;
revoke insert, update, delete on public.sales_items from anon;
drop policy if exists "Anon insert inventory (real market)" on public.inventory;
drop policy if exists "Anon update inventory (real market)" on public.inventory;
drop policy if exists "Anon insert sales (real market)"     on public.sales;
drop policy if exists "Anon insert sales_items (real sale)" on public.sales_items;
drop policy if exists "Allow anon insert sales_items"       on public.sales_items;

-- F11: anon never needs TRUNCATE.
revoke truncate on public.micromarkets, public.products, public.inventory,
                   public.sales, public.sales_items, public.categories from anon;

-- Intentionally kept for anon:
--   SELECT on inventory ("Anon read inventory") + categories ("Anon read categories")
--   EXECUTE on verify_pairing / open_sale / record_sale_item / complete_sale /
--            upsert_inventory / update_inventory_wiring / bulk_update_price /
--            bulk_update_curtain / delete_inventory / create_draft_product /
--            list_catalog / set_machine_layout
