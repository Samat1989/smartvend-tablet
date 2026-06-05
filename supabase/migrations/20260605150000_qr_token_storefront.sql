-- Anti-enumeration: each machine gets an unguessable qr_token (printed in the
-- QR instead of the sequential machid), and the storefront reads its catalog
-- through a token-gated RPC. Anon's direct SELECT on inventory is revoked so
-- stock can't be read by guessing machids — the only path is get_storefront(token).
--
-- Applied to prod via Supabase MCP on 2026-06-05.

-- 1) Unguessable per-machine token (128-bit hex), backfilled + defaulted.
alter table public.micromarkets add column if not exists qr_token text;
update public.micromarkets
  set qr_token = replace(gen_random_uuid()::text, '-', '')
  where qr_token is null;
alter table public.micromarkets
  alter column qr_token set default replace(gen_random_uuid()::text, '-', '');
create unique index if not exists micromarkets_qr_token_key on public.micromarkets(qr_token);

-- 2) Token-gated storefront read: machine info + inventory, NEVER the secret.
--    SECURITY DEFINER so it works after we revoke anon's direct inventory read.
create or replace function public.get_storefront(p_token text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select case when m.id is null then null else jsonb_build_object(
    'machid', m.id,
    'name', m.name,
    'kind', m.kind,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'name', i.name, 'price', i.price, 'stock', i.stock,
        'image_url', i.image_url, 'category_id', i.category_id
      ) order by i.name)
      from inventory i where i.micromarket_id = m.id
    ), '[]'::jsonb)
  ) end
  from micromarkets m
  where m.qr_token = p_token;
$$;
revoke all on function public.get_storefront(text) from public;
grant execute on function public.get_storefront(text) to anon, authenticated;

-- 3) Close the enumeration hole: anon can no longer read inventory directly.
--    (Admin uses the authenticated role; get_storefront runs as definer.)
revoke select on public.inventory from anon;
