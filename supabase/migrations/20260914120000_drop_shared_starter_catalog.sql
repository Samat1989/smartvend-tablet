-- ============================================================
-- Drop the shared starter catalog
--
-- Introduced in 20260819120000_shared_starter_catalog.sql: `products` rows
-- with `owner_id IS NULL` were platform templates, and copy_starter_products()
-- cloned every published one into an owner's catalog on a button press.
--
-- Replaced by a shared photo bank (product-images/library/, see
-- scripts/import_photo_library.py). The goal was always ONE COPY OF EACH
-- PICTURE, and a shared catalog was an expensive way to get it: it meant
-- ~3000 template rows that the "Скопировать стартовый набор" button would
-- clone wholesale into an operator's catalog, with no undo short of SQL, and
-- that list_catalog() would fold into every tablet's picker response. The
-- photo bank reaches the same `image_url` for every owner with zero rows in
-- `products`.
--
-- Left alone on purpose:
--   * public.is_superadmin() — the policy dropped below is its only caller in
--     this repo, but 20260904120000_service_open.sql reads the same claim
--     inline, the schema predates the migration history, and there may be
--     dashboard-created policies that are not in here. A six-line stable
--     helper is harmless; removing it is risk for no gain.
--   * categories.owner_id IS NULL — a separate, older "legacy shared"
--     convention from 20260526160000, unrelated to starter templates.
-- ============================================================

-- ---- 0. Refuse to run if there is anything to lose --------------------
-- The August migration verified 0 rows with a NULL owner before widening
-- SELECT; the button has been live since. If a template was created, or
-- someone pressed Copy, then dropping source_product_id loses provenance and
-- narrowing list_catalog() makes those products vanish from every tablet's
-- picker. Fail loudly instead — a human decides what happens to those rows.
do $$
declare
  v_templates int;
  v_copies    int;
begin
  select count(*) into v_templates from public.products where owner_id is null;
  select count(*) into v_copies
    from public.products where source_product_id is not null;

  if v_templates > 0 or v_copies > 0 then
    raise exception
      'Refusing to drop the starter catalog: % template row(s) with owner_id IS NULL '
      'and % row(s) copied from one. Decide what happens to them first '
      '(give the templates an owner, or delete them), then re-run.',
      v_templates, v_copies;
  end if;
end $$;

-- ---- 1. The copy itself ------------------------------------------------
drop function if exists public.copy_starter_products();

-- ---- 2. Policies -------------------------------------------------------
drop policy if exists "Superadmin manages shared products" on public.products;

-- Back to own-rows-only. The per-command Insert/Update/Delete policies from
-- 20260819120000 are already correctly scoped and stay as they are.
drop policy if exists "Read own and shared products" on public.products;

create policy "Read own products"
  on public.products for select to authenticated
  using (owner_id = (select auth.uid()));

-- ---- 3. Provenance of a copy -------------------------------------------
drop index if exists public.products_owner_source_uk;

alter table public.products
  drop column if exists source_product_id;

-- ---- 4. The tablet's catalog RPC ---------------------------------------
-- Same signature, so no new APK is needed: only the ownerless branch goes.
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
    where p.owner_id = v_owner
      and (p_include_archived or p.is_archived = false)
      and (p_include_drafts   or p.is_draft = false)
    order by p.name asc;
end;
$$;

revoke execute on function public.list_catalog(bigint, text, boolean, boolean)
  from public, authenticated;
grant  execute on function public.list_catalog(bigint, text, boolean, boolean) to anon;
