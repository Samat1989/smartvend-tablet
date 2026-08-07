-- ============================================================
-- Offline threshold: 5 missed beats instead of 3.
--
-- The tablet beats every 60 s, so the previous 3-minute window flipped a
-- machine to "offline" after three misses. On GSM that happens routinely
-- — a tower handover or a couple of dropped requests is enough — and the
-- panel flapped grey/green on machines that were working fine. An operator
-- who can't trust the lamp stops looking at it, which costs more than a
-- five-minute delay in noticing a genuine outage.
--
-- 5 minutes = 5 consecutive misses. Nothing else about the row changes:
-- last_seen_at still updates on every successful beat, so a machine that
-- comes back is green again on its next ping, not five minutes later.
-- ============================================================

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
    (last_seen_at > now() - interval '5 minutes') as online
  from public.device_status;

grant select on public.device_status_view to authenticated;

comment on view public.device_status_view is
  'Per-machine heartbeat. `online` is computed at read time — 5 missed '
  '60-second beats — against the database clock, never stored: a machine '
  'that loses power never gets to write "offline". board_ok is null when '
  'the board protocol has no health poll (BarysVend). security_invoker = on, '
  'so the owner RLS policy on device_status applies.';
