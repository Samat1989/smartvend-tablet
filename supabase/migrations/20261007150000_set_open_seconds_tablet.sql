-- ============================================================
-- Время открытия замка — и для аппарата с планшетом
--
-- set_open_seconds пускал только micromarket_static, поэтому у аппарата с
-- планшетом (micromarket_tablet), чья плата теперь на esp-rt, время открытия
-- из панели не менялось. Допустимы оба типа: время приходит платам в каждой
-- подписанной команде, а какой планшет рядом, ей безразлично.
-- ============================================================

create or replace function public.set_open_seconds(
  p_machid  bigint,
  p_seconds int
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_super boolean := coalesce(
    (auth.jwt() -> 'app_metadata' ->> 'is_superadmin')::boolean, false);
  v_kind  text;
  v_owner uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select kind, owner_id into v_kind, v_owner
    from public.micromarkets where id = p_machid;
  if v_kind is null then
    raise exception 'micromarket % not found', p_machid using errcode = '22023';
  end if;
  if not v_super and v_owner is distinct from v_uid then
    raise exception 'not your machine' using errcode = '42501';
  end if;
  if v_kind not in ('micromarket_static', 'micromarket_tablet') then
    raise exception 'machine % has no lock board (kind=%)', p_machid, v_kind
      using errcode = '22023';
  end if;
  if p_seconds is null or p_seconds < 1 or p_seconds > 600 then
    raise exception 'open time must be 1..600 seconds' using errcode = '22023';
  end if;

  update public.micromarkets set open_seconds = p_seconds where id = p_machid;
  return jsonb_build_object('ok', true, 'open_seconds', p_seconds);
end;
$$;

revoke execute on function public.set_open_seconds(bigint, int) from public, anon;
grant  execute on function public.set_open_seconds(bigint, int) to authenticated;
