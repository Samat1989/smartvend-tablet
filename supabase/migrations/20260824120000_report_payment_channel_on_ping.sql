-- ============================================================
-- The heartbeat reports which payment rail the cabinet is on.
--
-- The channel is chosen on the tablet, at pairing: an installer ticks
-- "O!Деньги (Кыргызстан)" and the machine starts asking the gateway for
-- O!Dengi QRs (terNumber=ODG) instead of Kaspi ones. That choice lives on
-- the tablet because it is a property of where the cabinet physically
-- stands, and because the tablet is what talks to the payment gateway.
--
-- Which leaves the owner panel blind: two machines look identical in the
-- fleet list while one of them charges som. So the tablet tells us what it
-- picked, on the beat it already sends every minute, and the panel shows it.
--
-- REPORTED, NOT CONFIGURED. This column never drives a payment — nothing
-- reads it back. It is the device's own account of itself, which means a
-- tablet re-paired without the tick silently goes back to Kaspi and the
-- panel will show that after the next beat rather than preventing it.
-- ============================================================

alter table public.device_status
  add column if not exists ter_number text;

comment on column public.device_status.ter_number is
  'Payment channel last reported by the tablet: null = Kaspi QR (the '
  'gateway''s default when the field is absent), ''ODG'' = O!Dengi, '
  'Kyrgyzstan. Display only — no code reads this to decide a payment.';

-- Appended at the end so CREATE OR REPLACE accepts the new shape.
create or replace view public.device_status_view
with (security_invoker = on) as
  select
    machid,
    last_seen_at,
    -- null for BarysVend: that protocol has no health poll, so the tablet
    -- reports "unknown" rather than passing off "serial port is open" as a
    -- working board. The panel shows such machines as plain online/offline.
    board_ok,
    app_version,
    (last_seen_at > now() - interval '5 minutes') as online,
    ter_number
  from public.device_status;

grant select on public.device_status_view to authenticated;

-- ── device_ping: one more thing the tablet tells us ──────────────────────
-- Signature changes, so the old form goes first (CREATE OR REPLACE cannot
-- add a parameter). Body is otherwise verbatim from
-- 20260808140000_enforce_claim_on_machine_writes.sql — including the
-- p_check_claim = false, without which _assert_machine would raise on a
-- replaced tablet instead of letting the ping answer 'claim': 'lost'.
drop function if exists public.device_ping(bigint, text, boolean, text, text, timestamptz, text);

create function public.device_ping(
  p_machid      bigint,
  p_secret      text,
  p_board_ok    boolean     default null,
  p_app_version text        default null,
  p_layout_hash text        default null,
  p_layout_at   timestamptz default null,
  p_device_id   text        default null,
  p_ter_number  text        default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_hash   text;
  v_at     timestamptz;
  v_holder text;
  v_layout text := 'ok';
begin
  perform public._assert_machine(p_machid, p_secret, false);

  select device_id into v_holder from public.device_status where machid = p_machid;

  -- Someone else holds the machine. Report it and write NOTHING: letting an
  -- intruder refresh last_seen_at would keep the lamp green off the wrong
  -- tablet, which is the very confusion the claim exists to remove.
  if v_holder is not null and p_device_id is not null and v_holder <> p_device_id then
    return jsonb_build_object('claim', 'lost', 'layout', 'ok');
  end if;

  insert into public.device_status
    (machid, last_seen_at, board_ok, app_version, ter_number, updated_at)
  values
    (p_machid, now(), p_board_ok, p_app_version,
     nullif(btrim(coalesce(p_ter_number, '')), ''), now())
  on conflict (machid) do update set
    last_seen_at = now(),
    board_ok     = excluded.board_ok,
    app_version  = coalesce(excluded.app_version, public.device_status.app_version),
    -- Absent parameter (an app that predates this migration) means "no
    -- report" and keeps what we had; an empty string is a real report of
    -- "Kaspi" and must be able to clear a stale 'ODG'.
    ter_number   = case
                     when p_ter_number is null then public.device_status.ter_number
                     else nullif(btrim(p_ter_number), '')
                   end,
    updated_at   = now();

  if p_layout_hash is null then
    return jsonb_build_object('claim', 'ok', 'layout', 'ok');
  end if;

  select layout_hash, layout_updated_at into v_hash, v_at
    from public.micromarkets where id = p_machid;

  if v_hash is distinct from p_layout_hash then
    if v_at is null or p_layout_at is null or p_layout_at > v_at then
      v_layout := 'push';
    else
      v_layout := 'stale';
    end if;
  end if;

  return jsonb_build_object('claim', 'ok', 'layout', v_layout);
end;
$$;

revoke execute on function
  public.device_ping(bigint, text, boolean, text, text, timestamptz, text, text)
  from public, authenticated;
grant execute on function
  public.device_ping(bigint, text, boolean, text, text, timestamptz, text, text) to anon;
