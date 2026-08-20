-- ============================================================
-- Shared starter catalog
--
-- A library of product templates maintained by the platform owner
-- (`is_superadmin`), which every micromarket owner can browse and COPY into
-- their own catalog. Copies are ordinary owned rows: the owner renames,
-- re-photographs or archives them freely, and the template can be changed or
-- removed later without touching anything already copied.
--
-- Templates are `products` rows with `owner_id IS NULL`. That convention
-- already exists for `categories` ("Owner manages own categories" reads
-- `owner_id = auth.uid() OR owner_id IS NULL`), and `list_catalog` already
-- serves them to tablets — `where (p.owner_id = v_owner or p.owner_id is null)`.
-- The only thing missing was the web side: RLS on `products` never returned
-- shared rows, and `WITH CHECK (owner_id = auth.uid())` meant nobody could
-- create one in the first place.
--
-- Safe to apply: verified before running that `products` holds ZERO rows with
-- `owner_id IS NULL` (182 rows, all owned), so widening SELECT cannot expose
-- one tenant's data to another.
--
-- Applied to prod via Supabase MCP on 2026-08-19.
-- ============================================================

-- ---- 1. Superadmin predicate -------------------------------------------
-- Reads the `is_superadmin` claim that 20260804120000 put into
-- auth.users.raw_app_meta_data. That lands in the JWT as `app_metadata` and
-- is writable only with the service_role key — unlike `user_metadata`, which
-- any signed-in user can rewrite on themselves.
create or replace function public.is_superadmin()
returns boolean
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb
       -> 'app_metadata' ->> 'is_superadmin')::boolean,
    false);
$$;

revoke all on function public.is_superadmin() from public;
grant execute on function public.is_superadmin() to authenticated;

-- ---- 2. Provenance of a copy -------------------------------------------
-- Which template a row was copied from. Makes the copy idempotent (press the
-- button twice, get nothing new) and leaves the door open for a future
-- "refresh from template". ON DELETE SET NULL: dropping a template must not
-- take an owner's product with it.
alter table public.products
  add column if not exists source_product_id uuid
    references public.products(id) on delete set null;

comment on column public.products.source_product_id is
  'Template this row was copied from (products.id with owner_id IS NULL). '
  'NULL for hand-made rows and for the templates themselves.';

-- One copy of a given template per owner — this is what makes
-- copy_starter_products() safe to call repeatedly.
create unique index if not exists products_owner_source_uk
  on public.products (owner_id, source_product_id)
  where source_product_id is not null;

-- ---- 3. Policies --------------------------------------------------------
-- Split per command. Postgres OR-combines permissive policies, so the
-- superadmin policy below simply adds rights on top of the owner ones
-- instead of replacing them.
drop policy if exists "Owner manages own products" on public.products;

create policy "Read own and shared products"
  on public.products for select to authenticated
  using (owner_id = (select auth.uid()) or owner_id is null);

create policy "Insert own products"
  on public.products for insert to authenticated
  with check (owner_id = (select auth.uid()));

create policy "Update own products"
  on public.products for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create policy "Delete own products"
  on public.products for delete to authenticated
  using (owner_id = (select auth.uid()));

-- Only the platform owner may create or edit templates. Note both USING and
-- WITH CHECK pin `owner_id IS NULL`: a superadmin editing their OWN products
-- goes through the owner policies above, and cannot accidentally hand a
-- private row to everyone by clearing its owner.
create policy "Superadmin manages shared products"
  on public.products for all to authenticated
  using (owner_id is null and public.is_superadmin())
  with check (owner_id is null and public.is_superadmin());

-- ---- 4. The copy itself -------------------------------------------------
-- SECURITY INVOKER on purpose: the caller already has every right this needs
-- (read templates via the SELECT policy, insert own rows via the INSERT one),
-- so RLS stays the thing enforcing tenancy. A definer here would add one more
-- entry to the pile of anon/authenticated-callable SECURITY DEFINER functions
-- the security advisor flags, for no gain.
--
-- Drafts and archived templates are skipped: a template is only offered once
-- the platform owner has published it.
create or replace function public.copy_starter_products()
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_count integer;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  insert into public.products
    (owner_id, name, image_url, emoji, category_id, volume_ml, description,
     is_draft, is_archived, source_product_id)
  select v_uid, t.name, t.image_url, t.emoji, t.category_id, t.volume_ml,
         t.description, false, false, t.id
  from public.products t
  where t.owner_id is null
    and t.is_draft = false
    and t.is_archived = false
    and not exists (
      select 1 from public.products c
      where c.owner_id = v_uid and c.source_product_id = t.id
    );

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.copy_starter_products() from public;
grant execute on function public.copy_starter_products() to authenticated;
