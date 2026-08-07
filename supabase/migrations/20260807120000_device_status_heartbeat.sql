-- ============================================================
-- Device heartbeat: is the machine on-line, and is its board answering?
--
-- Two separate signals on purpose. A tablet can be perfectly on-line with a
-- dead control board — nothing dispenses, but the machine looks healthy.
-- That's the most common and most annoying failure, and one lamp hides it.
--
-- Deliberately NOT columns on `micromarkets`: this row is rewritten every
-- minute per machine, and putting that churn in the configuration table
-- would bloat it for readers that only ever want name/kind/secret.
-- ============================================================

create table if not exists public.device_status (
  machid      bigint primary key
                references public.micromarkets(id) on delete cascade,
  last_seen_at timestamptz not null default now(),
  -- null = the device never reported (static-QR relay has no board);
  -- true/false = the tablet's own BoardClient watchdog verdict.
  board_ok     boolean,
  app_version  text,
  updated_at   timestamptz not null default now()
);

alter table public.device_status enable row level security;

-- Owners read the status of their own machines; the admin panel needs
-- nothing else. Writes never come from a client — device_ping is
-- SECURITY DEFINER and runs as the owner of this migration.
revoke all on public.device_status from anon, authenticated;
grant select on public.device_status to authenticated;

drop policy if exists "Owner reads own device status" on public.device_status;
create policy "Owner reads own device status"
  on public.device_status for select to authenticated
  using (exists (
    select 1 from public.micromarkets m
    where m.id = device_status.machid
      and m.owner_id = (select auth.uid())
  ));

-- ── Heartbeat ────────────────────────────────────────────────────────────
-- Called by the vending tablet on its existing 60-second catalog refresh
-- cycle, authenticated by the same (machid, secret) pair its sale/inventory
-- RPCs use. No new credential, no new schedule.
create or replace function public.device_ping(
  p_machid      bigint,
  p_secret      text,
  p_board_ok    boolean default null,
  p_app_version text    default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  perform public._assert_machine(p_machid, p_secret);

  insert into public.device_status (machid, last_seen_at, board_ok, app_version, updated_at)
  values (p_machid, now(), p_board_ok, p_app_version, now())
  on conflict (machid) do update set
    last_seen_at = now(),
    board_ok     = excluded.board_ok,
    -- Keep the last known version when a caller omits it, so an older
    -- client that doesn't send one doesn't blank the field.
    app_version  = coalesce(excluded.app_version, public.device_status.app_version),
    updated_at   = now();
end;
$$;

revoke execute on function public.device_ping(bigint, text, boolean, text)
  from public, authenticated;
grant execute on function public.device_ping(bigint, text, boolean, text) to anon;

-- ── Read side ────────────────────────────────────────────────────────────
-- `online` is computed HERE, at read time, never stored. A machine whose
-- power was pulled never gets the chance to write "I am offline", so a
-- stored flag would leave the whole fleet showing green after a blackout.
-- Computing it in SQL also settles it against the database clock instead of
-- the browser's, which on a kiosk network can be minutes off.
--
-- Threshold is 3 missed beats at the tablet's 60-second cadence.
create or replace view public.device_status_view
with (security_invoker = on) as
  select
    machid,
    last_seen_at,
    board_ok,
    app_version,
    (last_seen_at > now() - interval '3 minutes') as online
  from public.device_status;

grant select on public.device_status_view to authenticated;

comment on view public.device_status_view is
  'Per-machine heartbeat with online computed at read time (3 min threshold). '
  'security_invoker = on, so the owner RLS policy on device_status applies.';
