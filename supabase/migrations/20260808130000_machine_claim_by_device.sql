-- ============================================================
-- One tablet per machine: a claim held by device id.
--
-- machid + secret is a shared credential — nothing stopped two tablets from
-- pairing to the same machine. That isn't only a status/layout nuisance:
-- both write the SAME inventory and sales. A sale on cabinet B decrements
-- cabinet A's stock, both show "5 left" and both sell it, and the owner's
-- revenue report mixes two locations with no way to separate them later.
--
-- RELEASE IS ALWAYS EXPLICIT — no timeout, by design. Two paths, and the
-- second covers every failure of the first:
--   1. «Выйти из аккаунта» on the tablet   → release_machine
--   2. «Отвязать планшет» in the owner panel → admin_release_machine
-- A dead, smashed or lost tablet is handled by (2), so a "holder went quiet
-- for N minutes" heuristic would only add a way to lose a claim by accident
-- on a bad GSM day.
--
-- Rotating the secret at pairing would have been the obvious lock, but the
-- secret is also the LV payment-signing key — rotating it breaks payments.
-- Hence a separate claim.
-- ============================================================

alter table public.device_status
  add column if not exists device_id  text,
  add column if not exists claimed_at timestamptz;

comment on column public.device_status.device_id is
  'ANDROID_ID of the tablet holding this machine (falls back to a UUID the '
  'app generates when ANDROID_ID is unreadable). Null = unclaimed, which is '
  'also how tablets on builds older than the claim behave.';

-- ── Claim ────────────────────────────────────────────────────────────────
-- Called from the pairing screen after verify_pairing succeeds. Returns a
-- verdict instead of raising: the screen wants to *show* who holds the
-- machine and since when, not just fail.
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
  perform public._assert_machine(p_machid, p_secret);
  if p_device_id is null or btrim(p_device_id) = '' then
    raise exception 'device id required' using errcode = '22023';
  end if;

  select device_id, last_seen_at into v_holder, v_seen
    from public.device_status where machid = p_machid;

  -- Held by someone else — refuse and say by whom, so the operator can
  -- decide whether to sign out on that tablet or unbind from the panel.
  if v_holder is not null and v_holder <> p_device_id then
    return jsonb_build_object(
      'ok', false, 'reason', 'occupied', 'last_seen_at', v_seen);
  end if;

  insert into public.device_status (machid, device_id, claimed_at, last_seen_at, updated_at)
  values (p_machid, p_device_id, now(), now(), now())
  on conflict (machid) do update set
    device_id  = excluded.device_id,
    -- Re-claiming from the same tablet (app reinstall, re-pairing) keeps the
    -- original claim time; only a genuine handover resets it.
    claimed_at = coalesce(public.device_status.claimed_at, excluded.claimed_at),
    updated_at = now();

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.claim_machine(bigint, text, text)
  from public, authenticated;
grant  execute on function public.claim_machine(bigint, text, text) to anon;

-- ── Release from the tablet ──────────────────────────────────────────────
-- Only the holder may release: a tablet that already lost the claim must not
-- be able to knock the current one off.
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
  perform public._assert_machine(p_machid, p_secret);
  update public.device_status
     set device_id = null, claimed_at = null, updated_at = now()
   where machid = p_machid
     and device_id = p_device_id;
end;
$$;

revoke execute on function public.release_machine(bigint, text, text)
  from public, authenticated;
grant  execute on function public.release_machine(bigint, text, text) to anon;

-- ── Release from the owner panel ─────────────────────────────────────────
-- The escape hatch for a tablet that can't sign itself out. Owner-scoped:
-- authenticated caller must own the machine.
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
     set device_id = null, claimed_at = null, updated_at = now()
   where machid = p_machid;
end;
$$;

revoke execute on function public.admin_release_machine(bigint) from public, anon;
grant  execute on function public.admin_release_machine(bigint) to authenticated;

-- ── Heartbeat enforces the claim ─────────────────────────────────────────
drop function if exists public.device_ping(bigint, text, boolean, text, text, timestamptz);

create function public.device_ping(
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
  perform public._assert_machine(p_machid, p_secret);

  select device_id into v_holder from public.device_status where machid = p_machid;

  -- Someone else holds the machine. Report it and write NOTHING: letting an
  -- intruder refresh last_seen_at would keep the lamp green off the wrong
  -- tablet, which is the very confusion the claim exists to remove.
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

revoke execute on function public.device_ping(bigint, text, boolean, text, text, timestamptz, text)
  from public, authenticated;
grant  execute on function public.device_ping(bigint, text, boolean, text, text, timestamptz, text) to anon;
