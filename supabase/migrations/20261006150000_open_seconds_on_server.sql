-- ============================================================
-- Время открытия замка — настройка аппарата на сервере
--
-- Раньше плата хранила своё время открытия (opensec) и задавала его в портале;
-- сервисное открытие приносило время ещё и из панели. Теперь одно число на
-- аппарат, и оно в панели: сервер кладёт его в каждую подписанную команду
-- (open при оплате, service-open), плата своих настроек не держит.
--
-- Замок защёлкивается только когда геркон видит магнит закрытой двери, так
-- что это время — окно, чтобы открыть дверь, а не «сколько она открыта».
-- По умолчанию 20 секунд.
-- ============================================================

alter table public.micromarkets
  add column if not exists open_seconds int not null default 20;

alter table public.micromarkets drop constraint if exists micromarkets_open_seconds_check;
alter table public.micromarkets add constraint micromarkets_open_seconds_check
  check (open_seconds between 1 and 600);

-- service_opens.seconds был 10…600 под выбор 1/3/5 минут в панели; теперь там
-- время аппарата, и оно может быть короче (1…600).
alter table public.service_opens drop constraint if exists service_opens_seconds_check;
alter table public.service_opens add constraint service_opens_seconds_check
  check (seconds between 1 and 600);

comment on column public.micromarkets.open_seconds is
  'Сколько секунд плата esp-rt держит замок открытым после оплаты и при '
  'сервисном открытии. Приходит плате в каждой подписанной команде.';


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
  if v_kind <> 'micromarket_static' then
    raise exception 'machine % is not a static-QR fridge (kind=%)', p_machid, v_kind
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

comment on function public.set_open_seconds(bigint, int) is
  'Задаёт время открытия замка аппарата (1…600 с). Владелец — своего, '
  'суперадмин — любого.';


-- request_service_open поднимал любое время до 10 секунд — под прежний выбор из
-- панели. Время аппарата может быть 1…600, поэтому пол теперь 1.
create or replace function public.request_service_open(
  p_machid  bigint,
  p_seconds int default 20
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
  v_id    uuid;
  v_sec   int := least(greatest(coalesce(p_seconds, 20), 1), 600);
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

  if v_kind = 'vending' then
    raise exception 'machine % has no lock (kind=%)', p_machid, v_kind
      using errcode = '22023';
  end if;

  update public.service_opens
     set status = 'expired'
   where machid = p_machid
     and status = 'pending';

  insert into public.service_opens
    (machid, requested_by, seconds, expires_at)
  values
    (p_machid, v_uid, v_sec, now() + interval '10 minutes')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'seconds', v_sec);
end;
$$;

revoke execute on function public.request_service_open(bigint, int) from public, anon;
grant  execute on function public.request_service_open(bigint, int) to authenticated;
