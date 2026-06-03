-- ============================================================
-- Inventory-editing RPCs — secret-scoped (ADDITIVE)
--
-- Part of the security-hardening effort (see docs/security-audit-2026-06.md).
-- Replace the tablet's service-mode direct anon POST/PATCH/DELETE on inventory
-- and POST on products (audit findings F2 cross-tenant writes, F13 anon drafts)
-- with SECURITY DEFINER RPCs validated by _assert_machine and scoped to the
-- calling machine's own rows.
--
-- Maps to apps/tablet/lib/services/supabase_api.dart:
--   upsertProduct          -> upsert_inventory
--   updateInventoryWiring  -> update_inventory_wiring
--   bulkUpdatePrice        -> bulk_update_price
--   bulkUpdateCurtain      -> bulk_update_curtain
--   deleteProduct          -> delete_inventory
--   createDraftProduct     -> create_draft_product (now attributes owner_id)
--
-- Additive: live tablets keep the direct-anon paths until the new APK ships;
-- anon write access is revoked in the later lockdown migration.
--
-- Applied to prod via Supabase MCP on 2026-06-03 (inventory_edit_rpcs_secret_scoped).
-- Smoke-tested end-to-end in a rolled-back transaction (insert/update/wiring/bulk/
-- draft/delete all verified; wrong secret correctly raised "bad secret").
-- ============================================================

-- Insert (p_inventory_id null) or update an inventory row, scoped to the machine.
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

-- Update only wiring columns (motor_type / curtain_mode); null = leave as is.
create or replace function public.update_inventory_wiring(
  p_machid       bigint,
  p_secret       text,
  p_inventory_id uuid,
  p_motor_type   int,
  p_curtain_mode int
) returns void
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  perform public._assert_machine(p_machid, p_secret);
  update public.inventory set
    motor_type   = coalesce(p_motor_type, motor_type),
    curtain_mode = coalesce(p_curtain_mode, curtain_mode)
  where id = p_inventory_id and micromarket_id = p_machid;
end;
$$;

-- Bulk price update across this machine's rows. Returns rows affected.
create or replace function public.bulk_update_price(
  p_machid        bigint,
  p_secret        text,
  p_inventory_ids uuid[],
  p_price         int
) returns int
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_count int;
begin
  perform public._assert_machine(p_machid, p_secret);
  update public.inventory set price = p_price
  where micromarket_id = p_machid and id = any(p_inventory_ids);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Bulk curtain_mode update across this machine's rows. Returns rows affected.
create or replace function public.bulk_update_curtain(
  p_machid        bigint,
  p_secret        text,
  p_inventory_ids uuid[],
  p_curtain_mode  int
) returns int
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_count int;
begin
  perform public._assert_machine(p_machid, p_secret);
  update public.inventory set curtain_mode = p_curtain_mode
  where micromarket_id = p_machid and id = any(p_inventory_ids);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Delete one inventory row, scoped to the machine.
create or replace function public.delete_inventory(
  p_machid       bigint,
  p_secret       text,
  p_inventory_id uuid
) returns void
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  perform public._assert_machine(p_machid, p_secret);
  delete from public.inventory
  where id = p_inventory_id and micromarket_id = p_machid;
end;
$$;

-- Create a draft catalog product from the tablet's manual-entry path.
-- Attributes ownership to the machine's owner so it surfaces in that owner's
-- admin review. Returns the new product id.
create or replace function public.create_draft_product(
  p_machid      bigint,
  p_secret      text,
  p_name        text,
  p_image_url   text,
  p_emoji       text,
  p_category_id uuid
) returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_owner uuid;
  v_id    uuid;
begin
  perform public._assert_machine(p_machid, p_secret);
  select owner_id into v_owner from public.micromarkets where id = p_machid;
  insert into public.products (owner_id, name, image_url, emoji, category_id, is_draft)
  values (v_owner, p_name, p_image_url, p_emoji, p_category_id, true)
  returning id into v_id;
  return v_id;
end;
$$;

-- Least privilege: tablet (anon) only.
revoke execute on function public.upsert_inventory(bigint, text, uuid, uuid, int, text, int, int, int, int, text, text, uuid) from public, authenticated;
revoke execute on function public.update_inventory_wiring(bigint, text, uuid, int, int)     from public, authenticated;
revoke execute on function public.bulk_update_price(bigint, text, uuid[], int)               from public, authenticated;
revoke execute on function public.bulk_update_curtain(bigint, text, uuid[], int)             from public, authenticated;
revoke execute on function public.delete_inventory(bigint, text, uuid)                       from public, authenticated;
revoke execute on function public.create_draft_product(bigint, text, text, text, text, uuid) from public, authenticated;
grant  execute on function public.upsert_inventory(bigint, text, uuid, uuid, int, text, int, int, int, int, text, text, uuid) to anon;
grant  execute on function public.update_inventory_wiring(bigint, text, uuid, int, int)      to anon;
grant  execute on function public.bulk_update_price(bigint, text, uuid[], int)               to anon;
grant  execute on function public.bulk_update_curtain(bigint, text, uuid[], int)             to anon;
grant  execute on function public.delete_inventory(bigint, text, uuid)                       to anon;
grant  execute on function public.create_draft_product(bigint, text, text, text, text, uuid) to anon;
