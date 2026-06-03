-- ============================================================
-- Per-owner catalog for the tablet picker
--
-- The tablet runs as anon and the products anon SELECT policy
-- ("Anon read published products") has no owner filter, so the
-- "Выбрать из каталога" picker showed EVERY operator's products
-- (cross-tenant catalog leak — observed: one machine saw another
-- operator's 41 SKUs alongside its own 10).
--
-- This secret-scoped RPC returns only the catalog owned by the machine's
-- owner (plus any ownerless/global rows). The tablet's fetchProducts() now
-- calls this instead of a direct anon SELECT on products.
--
-- Applied to prod via Supabase MCP on 2026-06-03 (list_catalog_owner_scoped).
-- Verified: each machine's list_catalog returns only its owner's products.
-- ============================================================

create or replace function public.list_catalog(
  p_machid           bigint,
  p_secret           text,
  p_include_archived boolean default false,
  p_include_drafts   boolean default false
) returns setof public.products
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_owner uuid;
begin
  perform public._assert_machine(p_machid, p_secret);
  select owner_id into v_owner from public.micromarkets where id = p_machid;
  return query
    select *
    from public.products p
    where (p.owner_id = v_owner or p.owner_id is null)
      and (p_include_archived or p.is_archived = false)
      and (p_include_drafts   or p.is_draft = false)
    order by p.name asc;
end;
$$;

revoke execute on function public.list_catalog(bigint, text, boolean, boolean) from public, authenticated;
grant  execute on function public.list_catalog(bigint, text, boolean, boolean) to anon;
