-- ============================================================
-- Fix: upsert_inventory idempotent on (micromarket_id, motor_id)
--
-- The inventory table has a partial unique index
--   inventory_market_motor_uk ON (micromarket_id, motor_id) WHERE motor_id IS NOT NULL
-- so inserting a product onto a motor slot that already has a row failed with
-- 23505 (HTTP 409) — surfacing on the tablet as "can't add product"
-- ([upsertProduct] failed: HTTP 409 ... duplicate key ... inventory_market_motor_uk).
--
-- Make the INSERT path an UPSERT against that index: assigning a product to an
-- occupied motor now UPDATES the existing row instead of erroring. The
-- explicit-id (edit) path is unchanged.
--
-- DB-only fix; the tablet's upsert_inventory call is unchanged (no APK rebuild
-- needed). Applied to prod via Supabase MCP on 2026-06-03
-- (upsert_inventory_on_conflict_motor). Smoke-tested in a rolled-back
-- transaction: insert onto an occupied motor returned the same row id.
-- ============================================================

create or replace function public.upsert_inventory(
  p_machid       bigint,
  p_secret       text,
  p_inventory_id uuid,
  p_product_id   uuid,
  p_motor_id     int,
  p_name         text,
  p_price        int,
  p_stock        int,
  p_motor_type   int,
  p_curtain_mode int,
  p_image_url    text,
  p_emoji        text,
  p_category_id  uuid
) returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_id uuid;
begin
  perform public._assert_machine(p_machid, p_secret);

  if p_inventory_id is null then
    insert into public.inventory
      (micromarket_id, product_id, motor_id, name, price, stock,
       motor_type, curtain_mode, image_url, emoji, category_id)
    values
      (p_machid, p_product_id, p_motor_id, p_name, p_price, p_stock,
       p_motor_type, p_curtain_mode, p_image_url, p_emoji, p_category_id)
    on conflict (micromarket_id, motor_id) where (motor_id is not null)
    do update set
      product_id   = excluded.product_id,
      name         = excluded.name,
      price        = excluded.price,
      stock        = excluded.stock,
      motor_type   = excluded.motor_type,
      curtain_mode = excluded.curtain_mode,
      image_url    = excluded.image_url,
      emoji        = excluded.emoji,
      category_id  = excluded.category_id
    returning id into v_id;
  else
    update public.inventory set
      product_id   = p_product_id,
      motor_id     = p_motor_id,
      name         = p_name,
      price        = p_price,
      stock        = p_stock,
      motor_type   = p_motor_type,
      curtain_mode = p_curtain_mode,
      image_url    = p_image_url,
      emoji        = p_emoji,
      category_id  = p_category_id
    where id = p_inventory_id and micromarket_id = p_machid
    returning id into v_id;
    if v_id is null then
      raise exception 'inventory % not found for machine %', p_inventory_id, p_machid
        using errcode = '22023';
    end if;
  end if;
  return v_id;
end;
$$;
