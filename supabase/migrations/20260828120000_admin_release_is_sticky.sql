-- ============================================================
-- «Отвязать планшет» in the owner panel must stick.
--
-- admin_release_machine only nulls device_status.device_id, and nothing about
-- that reaches the tablet:
--
--   * device_ping sees v_holder = null, answers claim='ok', and the tablet
--     goes on selling as if nothing happened;
--   * on its next start _ensureClaim() calls claim_machine, finds the machine
--     free, and TAKES IT BACK — silently undoing the unbind.
--
-- So the panel button is only durable while the tablet is dead. Unbind a live
-- one and it either keeps running or re-claims itself on the next reboot; the
-- owner sees the lamp go green again and has no idea why. Reported from the
-- field: a tablet was unbound from the panel and stayed bound.
--
-- The fix is to remember WHO was released, not just that nobody holds the
-- machine. `released_device_id` is that memory, and it separates the two
-- states the old schema conflated:
--
--   device_id null, released_device_id null  → never claimed. Anyone may take
--                                              it (a fresh tablet, a build
--                                              older than the claim).
--   device_id null, released_device_id = X   → X was thrown off deliberately.
--                                              X is told; everyone else may
--                                              still claim.
--
-- The marker is cleared the moment the machine is claimed again, so it names
-- at most one tablet at a time and never accumulates.
--
-- A released tablet is NOT locked out forever: an installer who walks up and
-- types machid + secret on the pairing screen is making the opposite decision
-- on purpose, and accept_admin_release lets that path through. Only the
-- automatic boot-time re-claim is refused — that is the one nobody asked for.
-- ============================================================

alter table public.device_status
  add column if not exists released_at        timestamptz,
  add column if not exists released_device_id text;

comment on column public.device_status.released_device_id is
  'Tablet the owner unbound from this machine via admin_release_machine. It '
  'is told on its next claim/ping and unpairs itself; any OTHER tablet may '
  'claim the machine normally. Cleared on the next successful claim.';

comment on column public.device_status.released_at is
  'When the owner unbound released_device_id. Informational — the decision '
  'is made on released_device_id alone, so a clock skew cannot free a claim.';

-- ── Release from the owner panel ─────────────────────────────────────────
-- Same job as before, plus the note of who was shown the door.
create or replace function public.admin_release_machine(p_machid bigint)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if not exists (
    select 1 from public.micromarkets
     where id = p_machid and owner_id = (select auth.uid())
  ) then
    raise exception 'not your machine' using errcode = '42501';
  end if;

  update public.device_status
     set device_id  = null,
         claimed_at = null,
         -- coalesce: releasing an already-free machine (double click, or a
         -- machine whose tablet signed itself out first) must not erase the
         -- name of the tablet that still thinks it holds this cabinet.
         released_device_id = coalesce(device_id, released_device_id),
         released_at        = case
                                when coalesce(device_id, released_device_id)
                                     is not null then now()
                                else released_at
                              end,
         updated_at = now()
   where machid = p_machid;
end;
$$;

revoke execute on function public.admin_release_machine(bigint) from public, anon;
grant  execute on function public.admin_release_machine(bigint) to authenticated;

-- ── Release from the tablet ──────────────────────────────────────────────
-- «Выйти из аккаунта» in service mode. The tablet is unpairing itself, so
-- there is nobody left to notify: clear the marker rather than leave a stale
-- one to greet whoever pairs next.
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
     set device_id          = null,
         claimed_at         = null,
         released_device_id = null,
         released_at        = null,
         updated_at         = now()
   where machid = p_machid
     and device_id = p_device_id;
end;
$$;

revoke execute on function public.release_machine(bigint, text, text)
  from public, authenticated;
grant  execute on function public.release_machine(bigint, text, text) to anon;

-- ── The tablet accepts the unbind ────────────────────────────────────────
-- Called from the PAIRING SCREEN only, between verify_pairing and
-- claim_machine, i.e. after a human typed both credentials for this machine.
--
-- A separate RPC rather than a `p_after_pairing` flag on claim_machine: that
-- would mean dropping and recreating claim_machine with a wider signature,
-- and every tablet in the fleet calls it. A new function that old builds
-- never call cannot break them — and on a build that predates this migration
-- the call 404s, which is harmless because such a server has no marker to
-- clear either.
create or replace function public.accept_admin_release(
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
     set released_device_id = null,
         released_at        = null,
         updated_at         = now()
   where machid = p_machid
     and released_device_id = p_device_id;
end;
$$;

revoke execute on function public.accept_admin_release(bigint, text, text)
  from public, authenticated;
grant  execute on function public.accept_admin_release(bigint, text, text) to anon;

-- ── Claim ────────────────────────────────────────────────────────────────
-- Signature unchanged. One new verdict: a tablet the owner unbound is told
-- so instead of quietly taking the machine back.
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
  v_holder   text;
  v_seen     timestamptz;
  v_released text;
  v_rel_at   timestamptz;
begin
  perform public._assert_machine(p_machid, p_secret, false);
  if p_device_id is null or btrim(p_device_id) = '' then
    raise exception 'device id required' using errcode = '22023';
  end if;

  select device_id, last_seen_at, released_device_id, released_at
    into v_holder, v_seen, v_released, v_rel_at
    from public.device_status where machid = p_machid;

  if v_holder is not null and v_holder <> p_device_id then
    return jsonb_build_object(
      'ok', false, 'reason', 'occupied', 'last_seen_at', v_seen);
  end if;

  -- Unbound from the panel and asking for the machine back on its own. Only
  -- the released tablet is refused; a replacement claims normally, which is
  -- the whole point of the owner having pressed the button.
  if v_holder is null and v_released is not null
     and v_released = p_device_id then
    return jsonb_build_object(
      'ok', false, 'reason', 'released', 'released_at', v_rel_at);
  end if;

  insert into public.device_status
    (machid, device_id, claimed_at, last_seen_at, updated_at)
  values (p_machid, p_device_id, now(), now(), now())
  on conflict (machid) do update set
    device_id  = excluded.device_id,
    claimed_at = coalesce(public.device_status.claimed_at, excluded.claimed_at),
    -- The machine has a holder again; the note about the last one is spent.
    released_device_id = null,
    released_at        = null,
    updated_at = now();

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.claim_machine(bigint, text, text)
  from public, authenticated;
grant  execute on function public.claim_machine(bigint, text, text) to anon;

-- ── Heartbeat ────────────────────────────────────────────────────────────
-- Adds claim='released' next to the existing claim='lost'. Both mean "stop",
-- and the tablet tells them apart only to say the right thing on the pairing
-- screen: 'lost' — another tablet took over; 'released' — the owner unbound
-- this one.
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
  v_hash     text;
  v_at       timestamptz;
  v_holder   text;
  v_released text;
  v_layout   text := 'ok';
begin
  perform public._assert_machine(p_machid, p_secret, false);

  select device_id, released_device_id into v_holder, v_released
    from public.device_status where machid = p_machid;

  if v_holder is not null and p_device_id is not null and v_holder <> p_device_id then
    return jsonb_build_object('claim', 'lost', 'layout', 'ok');
  end if;

  -- Write NOTHING here either: a released tablet's beat must not put the
  -- lamp back on for a cabinet the owner has just detached it from.
  if v_holder is null and p_device_id is not null
     and v_released is not null and v_released = p_device_id then
    return jsonb_build_object('claim', 'released', 'layout', 'ok');
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

revoke execute on function public.device_ping(bigint, text, boolean, text, text, timestamptz, text)
  from public, authenticated;
grant  execute on function public.device_ping(bigint, text, boolean, text, text, timestamptz, text) to anon;
