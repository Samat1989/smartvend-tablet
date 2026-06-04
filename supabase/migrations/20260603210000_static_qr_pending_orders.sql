-- ============================================================
-- static_qr payment flow — server-side pending-order record
--
-- The static_qr customer storefront (/micromarket?id=<machid>) initiates a
-- Kaspi payment via the create-payment Edge Function and polls verify-payment.
-- Those functions (service_role) recompute the amount from inventory and store
-- it here keyed by the gateway orderid, so verify-payment finalizes the sale
-- from SERVER data (never trusting the client for money/quantities).
--
-- Only the Edge Functions (service_role, which bypasses RLS) touch this table;
-- anon/authenticated have no access.
--
-- Applied to prod via Supabase MCP on 2026-06-03 (static_qr_pending_orders).
-- ============================================================
create table if not exists public.pending_orders (
  orderid        text primary key,
  torderid       text,
  micromarket_id bigint not null references public.micromarkets(id),
  amount         numeric not null default 0,
  cart           jsonb not null default '[]'::jsonb,
  status         text not null default 'pending',   -- 'pending' | 'completed'
  created_at     timestamptz not null default now()
);

alter table public.pending_orders enable row level security;
revoke all on public.pending_orders from anon, authenticated;
