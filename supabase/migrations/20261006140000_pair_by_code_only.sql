-- ============================================================
-- Привязка платы esp-rt только по коду; плата не знает machid
--
-- Плата (прошивка 1.0.2+) называет себя своим MAC — device_id, 12 заглавных
-- hex без разделителей, — и больше ничем. Какому аппарату она служит, знает
-- только сервер: device_rt (machid, device_id, topic, key). Владелец вводит
-- на плате один код из панели; код выдан под конкретный аппарат, поэтому
-- номер аппарата на плате не нужен. Перенос платы на другой аппарат — новый
-- код, на плате ничего не меняется. Смена платёжного провайдера (machid —
-- номер машины в SmartVend) плату не затрагивает вовсе.
--
-- MAC не секрет (виден в эфире Wi-Fi), секрет — одноразовый код.
--
-- Подбор: без machid попытки на аппарат не посчитать, код угадывают сразу
-- среди всех живых кодов. Поэтому живой код уникален по проекту, а неверные
-- попытки ограничены общим лимитом: 20 за 10 минут.
--
-- Совместимость не держим: единственная привязанная плата перепрошивается.
-- Старая device_pair(machid, code, device_id) удаляется, живые коды старой
-- схемы (хэш с machid) сжигаются — достаточно выпустить новый.
-- ============================================================

-- ── Коды: хэш только от кода, уникален по проекту ─────────────────────────
delete from public.device_pair_codes;

create unique index if not exists device_pair_codes_code_hash_key
  on public.device_pair_codes (code_hash);

create table if not exists public.device_pair_failures (
  at timestamptz not null default now()
);
create index if not exists device_pair_failures_at_idx on public.device_pair_failures (at);
alter table public.device_pair_failures enable row level security;
revoke all on public.device_pair_failures from anon, authenticated;


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
  if v_kind <> 'micromarket_static' then
    raise exception 'machine % is not a static-QR fridge (kind=%)', p_machid, v_kind
      using errcode = '22023';
  end if;

  -- Просроченные коды держат место в уникальном индексе — убираем.
  delete from public.device_pair_codes where expires_at < now();

  -- Код ищет аппарат сам, поэтому должен быть уникален среди живых.
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


-- ── Привязка: код + ID платы ─────────────────────────────────────────────
drop function if exists public.device_pair(bigint, text, text);

create or replace function public.device_pair(
  p_code      text,
  p_device_id text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_row   public.device_pair_codes%rowtype;
  v_dev   text := upper(trim(coalesce(p_device_id, '')));
  v_topic uuid;
  v_key   text;
begin
  if v_dev !~ '^[0-9A-F]{12}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_device');
  end if;

  -- Общий лимит неверных попыток: 20 за 10 минут на весь проект.
  delete from public.device_pair_failures where at < now() - interval '10 minutes';
  if (select count(*) from public.device_pair_failures) >= 20 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  select * into v_row from public.device_pair_codes
   where code_hash = encode(sha256(convert_to(trim(coalesce(p_code, '')), 'UTF8')), 'hex')
   for update;

  if not found then
    insert into public.device_pair_failures default values;
    return jsonb_build_object('ok', false, 'error', 'bad_code');
  end if;
  if v_row.expires_at < now() then
    delete from public.device_pair_codes where machid = v_row.machid;
    return jsonb_build_object('ok', false, 'error', 'no_code');
  end if;

  delete from public.device_pair_codes where machid = v_row.machid;

  -- Плата, привязанная раньше к другому аппарату, оттуда уходит: одна плата —
  -- один аппарат. Новые канал и ключ при каждой привязке.
  delete from public.device_rt where device_id = v_dev and machid <> v_row.machid;
  v_topic := gen_random_uuid();
  v_key   := public._rand_hex(2);

  insert into public.device_rt (machid, topic, key, device_id, paired_at)
  values (v_row.machid, v_topic, v_key, v_dev, now())
  on conflict (machid) do update
     set topic     = excluded.topic,
         key       = excluded.key,
         device_id = excluded.device_id,
         paired_at = excluded.paired_at;

  return jsonb_build_object('ok', true, 'topic', v_topic, 'key', v_key);
end;
$$;

revoke execute on function public.device_pair(text, text) from public;
grant  execute on function public.device_pair(text, text) to anon, authenticated;

comment on function public.device_pair(text, text) is
  'Привязка платы esp-rt по коду из панели. Плата передаёт только код и свой '
  'ID (MAC, 12 hex); аппарат сервер находит по коду. Ответ {ok, topic, key}. '
  'Неверные попытки ограничены общим лимитом 20 за 10 минут.';


-- ── Панели нужен ID платы: по нему она ищет плату в Presence ──────────────
drop function if exists public.my_device_rt();

create or replace function public.my_device_rt()
returns table (machid bigint, topic uuid, device_id text, paired_at timestamptz)
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select d.machid, d.topic, d.device_id, d.paired_at
    from public.device_rt d
    join public.micromarkets m on m.id = d.machid
   where m.owner_id = (select auth.uid())
      or coalesce((auth.jwt() -> 'app_metadata' ->> 'is_superadmin')::boolean, false);
$$;

revoke execute on function public.my_device_rt() from public, anon;
grant  execute on function public.my_device_rt() to authenticated;
