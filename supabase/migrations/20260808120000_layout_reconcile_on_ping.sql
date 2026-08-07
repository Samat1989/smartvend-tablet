-- ============================================================
-- Layout reconciliation on the heartbeat.
--
-- set_machine_layout is fired unawaited and only debugPrints its failures,
-- so a save made while the tablet had no network left the cabinet and the
-- cloud silently disagreeing: right shelves on the machine, last week's
-- shelves in the owner panel. Nothing retried until the app restarted.
--
-- The heartbeat already runs every minute, so it carries a hash of the
-- local layout and the server answers whether to re-send. Steady state
-- costs 16 bytes; a full push happens only on a real divergence.
--
-- WHY A TIMESTAMP AND NOT JUST A HASH. Two tablets can be paired to the
-- same machid — a replacement paired while the old one is still powered on
-- the bench. On hashes alone they ping-pong forever: A sees B's hash and
-- re-pushes, B sees A's and re-pushes, two writes a minute for good.
-- "Online" can't arbitrate, both are online. The layout's own edit time can:
-- the older tablet is told it's behind and goes quiet after one attempt.
-- ============================================================

alter table public.micromarkets
  add column if not exists layout_hash text,
  add column if not exists layout_updated_at timestamptz;

-- ── set_machine_layout: also record what was stored and when ─────────────
-- Hash is computed by the tablet over its own encoding. The server never
-- recomputes it: jsonb normalises key order and whitespace, so a hash taken
-- here would never match the client's and every ping would report a false
-- divergence.
create or replace function public.set_machine_layout(
  p_machid bigint,
  p_secret text,
  p_layout jsonb,
  p_hash   text default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  perform public._assert_machine(p_machid, p_secret);
  update public.micromarkets
     set layout_json       = p_layout,
         layout_hash       = p_hash,
         layout_updated_at = now()
   where id = p_machid;
end;
$$;

revoke execute on function public.set_machine_layout(bigint, text, jsonb, text)
  from public, authenticated;
grant  execute on function public.set_machine_layout(bigint, text, jsonb, text) to anon;

-- ── device_ping: now answers instead of returning void ───────────────────
-- CREATE OR REPLACE can't change a return type, so the old signature goes
-- first. Both are dropped explicitly — the 4-arg form is what's live now.
drop function if exists public.device_ping(bigint, text, boolean, text);

create function public.device_ping(
  p_machid      bigint,
  p_secret      text,
  p_board_ok    boolean     default null,
  p_app_version text        default null,
  p_layout_hash text        default null,
  p_layout_at   timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_hash text;
  v_at   timestamptz;
  v_layout text := 'ok';
begin
  perform public._assert_machine(p_machid, p_secret);

  insert into public.device_status (machid, last_seen_at, board_ok, app_version, updated_at)
  values (p_machid, now(), p_board_ok, p_app_version, now())
  on conflict (machid) do update set
    last_seen_at = now(),
    board_ok     = excluded.board_ok,
    app_version  = coalesce(excluded.app_version, public.device_status.app_version),
    updated_at   = now();

  -- Older clients send no hash at all; say nothing rather than provoking
  -- a push they wouldn't understand.
  if p_layout_hash is null then
    return jsonb_build_object('layout', 'ok');
  end if;

  select layout_hash, layout_updated_at into v_hash, v_at
    from public.micromarkets where id = p_machid;

  if v_hash is distinct from p_layout_hash then
    -- Never stored a hash (first ping after this migration), or the tablet
    -- edited more recently than whatever is up here → it wins.
    if v_at is null or p_layout_at is null or p_layout_at > v_at then
      v_layout := 'push';
    else
      v_layout := 'stale';   -- another tablet is ahead; stay quiet
    end if;
  end if;

  return jsonb_build_object('layout', v_layout);
end;
$$;

revoke execute on function public.device_ping(bigint, text, boolean, text, text, timestamptz)
  from public, authenticated;
grant  execute on function public.device_ping(bigint, text, boolean, text, text, timestamptz) to anon;
