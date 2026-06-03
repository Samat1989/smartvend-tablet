-- ============================================================
-- Sales RPCs — secret-scoped, server-priced (ADDITIVE)
--
-- Part of the security-hardening effort (see docs/security-audit-2026-06.md).
-- Replaces the tablet's direct anon POST/PATCH on sales/sales_items/inventory
-- (audit findings F2 cross-tenant writes, F4 client-supplied prices) with
-- SECURITY DEFINER RPCs that:
--   * validate (machid, secret) via _assert_machine (never expose secret)
--   * scope every write to the calling machine's own rows
--   * look up the authoritative price from inventory server-side
--   * decrement stock atomically on a successful dispense
--   * recompute the sale amount server-side as the sum of dispensed items
--
-- Mirrors the existing incremental flow: open_sale -> record_sale_item* -> complete_sale.
-- The legacy batch recordSale path in the Dart client will be dropped in the
-- client rewrite in favour of these.
--
-- Additive: live tablets keep using the direct-anon paths until the new APK
-- ships; anon write access is revoked in the later lockdown migration.
--
-- Applied to prod via Supabase MCP on 2026-06-03 (sales_rpcs_secret_scoped).
-- Smoke-tested end-to-end inside a rolled-back transaction (server price + atomic
-- stock decrement verified, no rows persisted).
-- ============================================================

-- Open a sale shell up-front. Returns the new (server-generated) sale id.
create or replace function public.open_sale(
  p_machid         bigint,
  p_secret         text,
  p_payment_id     text,
  p_expected_total int
) returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_id uuid;
begin
  perform public._assert_machine(p_machid, p_secret);
  insert into public.sales (micromarket_id, amount, status, payment_id)
  values (p_machid, p_expected_total, 'in_progress', p_payment_id)
  returning id into v_id;
  return v_id;
end;
$$;

-- Record one dispense step against an open sale. Price is looked up SERVER-SIDE
-- from this machine's inventory (not trusted from the client). On a successful
-- dispense, stock is decremented atomically.
create or replace function public.record_sale_item(
  p_machid         bigint,
  p_secret         text,
  p_sale_id        uuid,
  p_product_id     uuid,
  p_qty            int default 1,
  p_dispensed      boolean default true,
  p_result_code    int default null,
  p_result_message text default null
) returns void
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_price numeric;
begin
  perform public._assert_machine(p_machid, p_secret);

  if not exists (
    select 1 from public.sales
    where id = p_sale_id and micromarket_id = p_machid
  ) then
    raise exception 'sale % not found for machine %', p_sale_id, p_machid
      using errcode = '22023';
  end if;

  select price into v_price
  from public.inventory
  where id = p_product_id and micromarket_id = p_machid;
  if v_price is null then
    raise exception 'product % not in inventory of machine %', p_product_id, p_machid
      using errcode = '22023';
  end if;

  insert into public.sales_items
    (sale_id, product_id, price, quantity, dispensed, result_code, result_message)
  values
    (p_sale_id, p_product_id, v_price, coalesce(p_qty, 1), p_dispensed,
     p_result_code, p_result_message);

  if p_dispensed then
    update public.inventory
       set stock = greatest(coalesce(stock, 0) - coalesce(p_qty, 1), 0)
     where id = p_product_id and micromarket_id = p_machid;
  end if;
end;
$$;

-- Close a sale: recompute amount server-side as the sum of DISPENSED items,
-- mark completed. Returns the final amount.
create or replace function public.complete_sale(
  p_machid  bigint,
  p_secret  text,
  p_sale_id uuid
) returns numeric
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_amount numeric;
begin
  perform public._assert_machine(p_machid, p_secret);

  if not exists (
    select 1 from public.sales
    where id = p_sale_id and micromarket_id = p_machid
  ) then
    raise exception 'sale % not found for machine %', p_sale_id, p_machid
      using errcode = '22023';
  end if;

  select coalesce(sum(price * quantity) filter (where dispensed), 0)
    into v_amount
  from public.sales_items
  where sale_id = p_sale_id;

  update public.sales
     set amount = v_amount, status = 'completed'
   where id = p_sale_id and micromarket_id = p_machid;

  return v_amount;
end;
$$;

-- Least privilege: tablet (anon) only. Supabase auto-grants anon+authenticated;
-- strip authenticated/public, keep anon.
revoke execute on function public.open_sale(bigint, text, text, int)                                   from public, authenticated;
revoke execute on function public.record_sale_item(bigint, text, uuid, uuid, int, boolean, int, text)  from public, authenticated;
revoke execute on function public.complete_sale(bigint, text, uuid)                                    from public, authenticated;
grant  execute on function public.open_sale(bigint, text, text, int)                                   to anon;
grant  execute on function public.record_sale_item(bigint, text, uuid, uuid, int, boolean, int, text)  to anon;
grant  execute on function public.complete_sale(bigint, text, uuid)                                    to anon;
