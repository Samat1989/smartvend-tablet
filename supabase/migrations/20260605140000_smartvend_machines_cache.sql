-- Cache of the SmartVend machine list so device-provision doesn't refetch the
-- 1.85MB upstream file on every call. Refreshed only on a cache miss (a machid
-- not present yet). Backend-only: holds secrets, so no anon/authenticated
-- access — the edge function reads/writes it with the service_role key.
--
-- Applied to prod via Supabase MCP on 2026-06-05.
create table if not exists public.smartvend_machines (
  machid     bigint primary key,
  uuid       text not null,
  secret     text not null,
  name       text,
  updated_at timestamptz not null default now()
);

alter table public.smartvend_machines enable row level security;
revoke all on public.smartvend_machines from anon, authenticated;
-- (no RLS policy: only service_role, which bypasses RLS, may touch it)
