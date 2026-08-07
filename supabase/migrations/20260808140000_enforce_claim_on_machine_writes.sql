-- ============================================================
-- Claim enforcement on every machine-scoped write.
--
-- The claim already blocks a second tablet at PAIRING, but a tablet that was
-- the holder and then lost it — owner unbound it, a replacement took over —
-- would keep selling until someone noticed. Its sales and stock decrements
-- land on a cabinet that is no longer its own.
--
-- The check goes into _assert_machine, which every machine-scoped write RPC
-- already calls: open_sale, record_sale_item, complete_sale, upsert_inventory,
-- update_inventory_wiring, bulk_update_price, bulk_update_curtain,
-- delete_inventory, set_machine_layout. Eight function bodies stay untouched,
-- and anything added later inherits the check.
--
-- The device id arrives as an `x-device-id` REQUEST HEADER, not a parameter.
-- Adding one to eight signatures would mean dropping and recreating each, and
-- PostgREST would have to disambiguate overloads for the whole rollout window
-- while old and new tablets call in parallel. PostgREST exposes headers via
-- current_setting('request.headers') — verified against this project.
--
-- p_check_claim exists because claim_machine / release_machine / device_ping
-- call this helper too, and they must ANSWER rather than throw: the pairing
-- screen shows who holds the machine, and the heartbeat returns claim='lost'
-- so the tablet can unpair itself. An exception would surface as an opaque
-- network error in both.
--
-- Applied to prod via Supabase MCP as two migrations
-- (enforce_claim_on_machine_writes + claim_rpcs_skip_claim_check); folded
-- into one file here for readability.
-- ============================================================

drop function if exists public._assert_machine(bigint, text);

create function public._assert_machine(
  p_machid      bigint,
  p_secret      text,
  p_check_claim boolean default true
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_secret text;
  v_holder text;
  v_device text;
begin
  select secret into v_secret from public.micromarkets where id = p_machid;
  if v_secret is null then
    raise exception 'micromarket % not found', p_machid using errcode = '22023';
  end if;
  if btrim(v_secret) <> btrim(p_secret) then
    raise exception 'bad secret' using errcode = '28P01';
  end if;

  if not p_check_claim then return; end if;

  select device_id into v_holder from public.device_status where machid = p_machid;
  if v_holder is null then return; end if;

  -- Null outside a PostgREST request (psql, tests) and on tablets running a
  -- build older than the claim. Both are allowed through: this exists to stop
  -- a tablet that KNOWS it had the machine and lost it, not to lock out the
  -- fleet mid-rollout. Tighten to "header required" once every tablet is
  -- updated — the claim is only fully binding after that.
  v_device := nullif(
    current_setting('request.headers', true)::json ->> 'x-device-id', '');
  if v_device is null then return; end if;

  if v_holder <> v_device then
    raise exception 'machine % is claimed by another tablet', p_machid
      using errcode = '42501';
  end if;
end;
$$;

revoke execute on function public._assert_machine(bigint, text, boolean)
  from public, anon, authenticated;

-- claim_machine / release_machine / device_ping re-created to pass
-- p_check_claim = false. Bodies are otherwise identical to
-- 20260808130000_machine_claim_by_device.sql.
create or replace function public.claim_machine(
  p_machid    bigint,
  p_secret    text,
  p_device_id text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_holder text;
  v_seen   timestamptz;
begin
  perform public._assert_machine(p_machid, p_secret, false);
  if p_device_id is null or btrim(p_device_id) = '' then
    raise exception 'device id required' using errcode = '22023';
  end if;

  select device_id, last_seen_at into v_holder, v_seen
    from public.device_status where machid = p_machid;

  if v_holder is not null and v_holder <> p_device_id then
    return jsonb_build_object(
      'ok', false, 'reason', 'occupied', 'last_seen_at', v_seen);
  end if;

  insert into public.device_status (machid, device_id, claimed_at, last_seen_at, updated_at)
  values (p_machid, p_device_id, now(), now(), now())
  on conflict (machid) do update set
    device_id  = excluded.device_id,
    claimed_at = coalesce(public.device_status.claimed_at, excluded.claimed_at),
    updated_at = now();

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.release_machine(
  p_machid    bigint,
  p_secret    text,
  p_device_id text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  perform public._assert_machine(p_machid, p_secret, false);
  update public.device_status
     set device_id = null, claimed_at = null, updated_at = now()
   where machid = p_machid
     and device_id = p_device_id;
end;
$$;

create or replace function public.device_ping(
  p_machid      bigint,
  p_secret      text,
  p_board_ok    boolean     default null,
  p_app_version text        default null,
  p_layout_hash text        default null,
  p_layout_at   timestamptz default null,
  p_device_id   text        default null
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

  if v_holder is not null and p_device_id is not null and v_holder <> p_device_id then
    return jsonb_build_object('claim', 'lost', 'layout', 'ok');
  end if;

  insert into public.device_status (machid, last_seen_at, board_ok, app_version, updated_at)
  values (p_machid, now(), p_board_ok, p_app_version, now())
  on conflict (machid) do update set
    last_seen_at = now(),
    board_ok     = excluded.board_ok,
    app_version  = coalesce(excluded.app_version, public.device_status.app_version),
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
