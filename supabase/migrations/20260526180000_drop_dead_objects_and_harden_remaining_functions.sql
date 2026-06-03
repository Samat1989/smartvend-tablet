-- =========================================================================
-- Drop dead objects + harden remaining functions
-- =========================================================================
-- Applied via Supabase MCP on 2026-05-26 after retiring all legacy clients:
--   * lock-only micromarket (ESP32 + create-payment/verify-payment/complete-order)
--   * micromarket_app (old Flutter tablet for micromarkets)
--   * pos_app (Android POS)
-- Only m102_tester (vending) is in production now; customer_web runs
-- with VITE_ADMIN_ONLY=true so the App.jsx checkout flow is tree-shaken
-- out of the bundle.
--
-- Dead objects with zero live caller:
--   * pending_orders table — work queue for the now-deleted
--     cron-process-payments edge function. 43 historical rows.
--   * commands table — ESP32 lock-flow signal channel. m102_tester does
--     not touch this table. 74 historical rows, last activity 7+ days ago.
--   * decrement_stock(uuid, int) — invoked only by the deleted edge
--     functions. m102_tester PATCHes inventory.stock directly.
--
-- Retained-function hardening (silences advisor lints without behaviour
-- change):
--   * handle_new_user — auth.users insert trigger. Triggers run as the
--     function owner regardless of grants, so revoking EXECUTE from
--     anon/authenticated stops anyone from invoking it via the REST
--     /rpc endpoint while leaving the trigger path intact. search_path
--     pinned to silence the mutable-search-path lint.
--   * rls_auto_enable — event trigger. Same pattern: triggers don't
--     need REST-callable EXECUTE.
--
-- Kept intentionally (security advisor will still flag, by design):
--   * set_machine_layout — kiosk RPC validated by machid+secret. anon
--     EXECUTE is required for m102_tester to push layouts.
-- =========================================================================

-- ── dead tables ────────────────────────────────────────────────────────────
DROP TABLE IF EXISTS public.pending_orders CASCADE;
DROP TABLE IF EXISTS public.commands CASCADE;

-- ── dead RPC ───────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.decrement_stock(uuid, integer);

-- ── retained-function hardening ────────────────────────────────────────────

ALTER FUNCTION public.handle_new_user()
  SET search_path = pg_catalog, public, pg_temp;

REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM anon, authenticated;
