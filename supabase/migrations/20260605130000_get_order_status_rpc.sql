-- Passive order-status read for the storefront. The static_qr fleet is all
-- ESP32-relay, where capture is lock-coupled (only the device, via
-- complete-order, calls payment_result). The browser must therefore NOT
-- capture; it only observes the status the device set. anon has no direct
-- access to pending_orders (locked down), so expose a SECURITY DEFINER reader
-- that returns ONLY the status (no cart, no amount, no secret) for one orderid.
--
-- Applied to prod via Supabase MCP on 2026-06-05.
create or replace function public.get_order_status(p_orderid text)
returns text
language sql
security definer
set search_path = public
as $$
  select status from pending_orders where orderid = p_orderid;
$$;

revoke all on function public.get_order_status(text) from public;
grant execute on function public.get_order_status(text) to anon, authenticated;
