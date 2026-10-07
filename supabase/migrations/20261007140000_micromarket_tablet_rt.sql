-- ============================================================
-- Плата esp-rt у аппарата с планшетом (micromarket_tablet)
--
-- В аппарате 4000008 два устройства: планшет показывает витрину и платит через
-- create-payment, а замком управляет автономная плата esp-pulse / esp-relay.
-- Плата переходит на esp-rt вместе со всеми — релиз на GitHub читают все платы
-- с префиксом, исключить одну нельзя. Поэтому:
--
--   1. привязка платы (код из панели и device_migrate) разрешена и для
--      micromarket_tablet, не только для micromarket_static;
--   2. сигнал «плата жива» (device_beat, touch_device_seen) пишется в device_rt.
--      Раньше он шёл в device_status, а там у аппарата с планшетом уже строка
--      самого планшета (device_ping): версия приложения мигала бы между
--      планшетом и платой, а лампа планшета горела бы, пока жива одна плата.
--
-- Данные платы теперь: device_rt.last_seen_at и device_rt.board_ver.
-- ============================================================

alter table public.device_rt
  add column if not exists last_seen_at timestamptz,
  add column if not exists board_ver    text;

comment on column public.device_rt.last_seen_at is
  'Последний beat платы (раз в 15 минут) или момент, когда панель увидела её уход из Presence.';
comment on column public.device_rt.board_ver is
  'Версия прошивки esp-rt из последнего beat.';

-- Перенос уже накопленного: до сих пор плата писала в device_status.
update public.device_rt d
   set last_seen_at = ds.last_seen_at,
       board_ver    = ds.app_version
  from public.device_status ds
 where ds.machid = d.machid
   and d.last_seen_at is null
   and d.machid in (select id from public.micromarkets where kind = 'micromarket_static');


-- ── Код привязки: и для аппарата с планшетом ───────────────────────────────
create or replace function public.create_pair_code(
  p_machid bigint
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
  v_code  text;
  v_hash  text;
  v_exp   timestamptz := now() + interval '30 minutes';
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

  delete from public.device_pair_codes where expires_at < now();

  for i in 1..20 loop
    v_code := lpad(((('x' || substr(public._rand_hex(1), 1, 8))::bit(32)::bigint)
                     % 1000000)::text, 6, '0');
    v_hash := encode(sha256(convert_to(v_code, 'UTF8')), 'hex');
    exit when not exists (
      select 1 from public.device_pair_codes
       where code_hash = v_hash and machid <> p_machid);
    v_hash := null;
  end loop;
  if v_hash is null then
    raise exception 'could not allocate a pairing code' using errcode = '55000';
  end if;

  insert into public.device_pair_codes (machid, code_hash, created_by, expires_at, attempts)
  values (p_machid, v_hash, v_uid, v_exp, 0)
  on conflict (machid) do update
     set code_hash  = excluded.code_hash,
         created_by = excluded.created_by,
         expires_at = excluded.expires_at,
         attempts   = 0;

  return jsonb_build_object('code', v_code, 'expires_at', v_exp);
end;
$$;

revoke execute on function public.create_pair_code(bigint) from public, anon;
grant  execute on function public.create_pair_code(bigint) to authenticated;


-- ── device_migrate: и для аппарата с планшетом ─────────────────────────────
create or replace function public.device_migrate(
  p_machid        bigint,
  p_secret        text,
  p_device_id     text,
  p_open_seconds  int default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_dev    text := upper(trim(coalesce(p_device_id, '')));
  v_kind   text;
  v_secret text;
  v_topic  uuid;
  v_key    text;
begin
  if v_dev !~ '^[0-9A-F]{12}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_device');
  end if;

  delete from public.device_pair_failures where at < now() - interval '10 minutes';
  if (select count(*) from public.device_pair_failures) >= 20 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  select kind, secret into v_kind, v_secret
    from public.micromarkets where id = p_machid;

  -- Нет аппарата, чужой тип и неверный secret отвечают одинаково: по ответу
  -- нельзя узнать, какие machid существуют.
  if v_kind is null or v_kind not in ('micromarket_static', 'micromarket_tablet')
     or coalesce(trim(v_secret), '') = ''
     or trim(coalesce(p_secret, '')) <> trim(v_secret) then
    insert into public.device_pair_failures default values;
    return jsonb_build_object('ok', false, 'error', 'bad_secret');
  end if;

  delete from public.device_rt where device_id = v_dev and machid <> p_machid;
  delete from public.device_pair_codes where machid = p_machid;

  v_topic := gen_random_uuid();
  v_key   := public._rand_hex(2);

  insert into public.device_rt (machid, topic, key, device_id, paired_at, last_seen_at)
  values (p_machid, v_topic, v_key, v_dev, now(), now())
  on conflict (machid) do update
     set topic        = excluded.topic,
         key          = excluded.key,
         device_id    = excluded.device_id,
         paired_at    = excluded.paired_at,
         last_seen_at = excluded.last_seen_at;

  if p_open_seconds between 1 and 600 then
    update public.micromarkets
       set open_seconds = p_open_seconds
     where id = p_machid and open_seconds = 20;
  end if;

  return jsonb_build_object('ok', true, 'topic', v_topic, 'key', v_key);
end;
$$;

revoke execute on function public.device_migrate(bigint, text, text, int) from public;
grant  execute on function public.device_migrate(bigint, text, text, int) to anon, authenticated;


-- ── beat платы — в device_rt, не в device_status ──────────────────────────
create or replace function public.device_beat(
  p_topic uuid,
  p_key   text,
  p_ver   text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  update public.device_rt
     set last_seen_at = now(),
         board_ver    = coalesce(left(p_ver, 40), board_ver)
   where topic = p_topic and key = p_key;
  if not found then
    return jsonb_build_object('ok', false);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.device_beat(uuid, text, text) from public;
grant  execute on function public.device_beat(uuid, text, text) to anon, authenticated;

comment on function public.device_beat(uuid, text, text) is
  'Раз в 15 минут плата esp-rt сообщает «я жива»: канал и ключ из привязки — '
  'её единственный пропуск. Обновляет device_rt.last_seen_at и board_ver '
  '(не device_status: там у аппарата с планшетом строка самого планшета).';


-- ── момент ухода платы из Presence, отмеченный панелью ─────────────────────
create or replace function public.touch_device_seen(
  p_machid bigint
) returns void
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_super boolean := coalesce(
    (auth.jwt() -> 'app_metadata' ->> 'is_superadmin')::boolean, false);
  v_owner uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select owner_id into v_owner from public.micromarkets where id = p_machid;
  if not found then
    raise exception 'micromarket % not found', p_machid using errcode = '22023';
  end if;
  if not v_super and v_owner is distinct from v_uid then
    raise exception 'not your machine' using errcode = '42501';
  end if;

  update public.device_rt set last_seen_at = now() where machid = p_machid;
end;
$$;

revoke execute on function public.touch_device_seen(bigint) from public, anon;
grant  execute on function public.touch_device_seen(bigint) to authenticated;


-- ── панели нужно время последней связи платы ───────────────────────────────
drop function if exists public.my_device_rt();

create or replace function public.my_device_rt()
returns table (machid bigint, topic uuid, device_id text, paired_at timestamptz,
               last_seen_at timestamptz, board_ver text)
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select d.machid, d.topic, d.device_id, d.paired_at, d.last_seen_at, d.board_ver
    from public.device_rt d
    join public.micromarkets m on m.id = d.machid
   where m.owner_id = (select auth.uid())
      or coalesce((auth.jwt() -> 'app_metadata' ->> 'is_superadmin')::boolean, false);
$$;

revoke execute on function public.my_device_rt() from public, anon;
grant  execute on function public.my_device_rt() to authenticated;
