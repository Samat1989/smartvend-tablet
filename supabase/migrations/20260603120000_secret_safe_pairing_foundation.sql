-- ============================================================
-- Secret-safe pairing foundation (ADDITIVE — revokes no existing access)
--
-- Part of the security-hardening effort (see docs/security-audit-2026-06.md).
-- Adds the building blocks that let the tablet validate pairing WITHOUT
-- reading micromarkets.secret over anon REST (audit finding F1/F5):
--   * _assert_machine()      — internal (machid, secret) check, never returns secret
--   * micromarkets_public    — secret-free view for web_app / static_qr
--   * verify_pairing()       — anon-callable pairing check, returns kind on match
--
-- Live tablets keep working via the existing direct-anon paths; the lockdown
-- (REVOKE anon writes / secret read) happens in a later migration only after
-- the tablet app is shipped using these RPCs.
--
-- Applied to prod via Supabase MCP on 2026-06-03 as two migrations
-- (secret_safe_pairing_foundation + restrict_assert_machine_execute); folded
-- into one file here for readability.
-- ============================================================

-- 1. Private helper: validate (machid, secret) without ever returning secret.
--    Callable ONLY from within other SECURITY DEFINER functions (run as owner).
create or replace function public._assert_machine(p_machid bigint, p_secret text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_secret text;
begin
  select secret into v_secret from public.micromarkets where id = p_machid;
  if v_secret is null then
    raise exception 'micromarket % not found', p_machid using errcode = '22023';
  end if;
  if btrim(v_secret) <> btrim(p_secret) then
    raise exception 'bad secret' using errcode = '28P01';
  end if;
end;
$$;

-- Supabase default privileges auto-grant EXECUTE to anon/authenticated on new
-- functions; strip them so this helper is never directly client-callable
-- (otherwise it becomes a secret-guessing oracle once secret read is locked down).
revoke execute on function public._assert_machine(bigint, text) from public, anon, authenticated;

-- 2. Public, secret-free view of micromarkets (for web_app / static_qr).
--    The tablet needs no micromarkets SELECT at all once it uses verify_pairing.
create or replace view public.micromarkets_public as
  select id, name, kind, location_name, status, layout_json
  from public.micromarkets;

grant select on public.micromarkets_public to anon, authenticated;

-- 3. Pairing check: returns kind on match, raises otherwise. Never returns secret.
create or replace function public.verify_pairing(p_machid bigint, p_secret text)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_kind text;
begin
  perform public._assert_machine(p_machid, p_secret);
  select kind into v_kind from public.micromarkets where id = p_machid;
  return v_kind;
end;
$$;

-- Only the tablet (anon) pairs; owners (authenticated) never do.
revoke execute on function public.verify_pairing(bigint, text) from public, authenticated;
grant  execute on function public.verify_pairing(bigint, text) to anon;
