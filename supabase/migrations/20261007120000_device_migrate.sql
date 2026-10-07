-- ============================================================
-- Переход старых плат (esp-pulse / esp-relay) на esp-rt без кода из панели
--
-- Старая плата знает свой machid и secret (SmartVend, тот же, что в
-- micromarkets.secret). После обновления по воздуху esp-rt находит их в старой
-- NVS и вызывает device_migrate: сервер сверяет secret и выдаёт канал и ключ,
-- как device_pair выдаёт их по коду. Время открытия, настроенное на плате в
-- сервисном режиме, переезжает в micromarkets.open_seconds.
--
-- Защита та же, что у device_pair: общий лимит неверных попыток (20 за 10
-- минут на проект), только static-QR аппараты, новые topic/key при каждой
-- привязке. Функция временная: когда все платы перешли, её удаляют отдельной
-- миграцией.
-- ============================================================

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
  if v_kind is distinct from 'micromarket_static'
     or coalesce(trim(v_secret), '') = ''
     or trim(coalesce(p_secret, '')) <> trim(v_secret) then
    insert into public.device_pair_failures default values;
    return jsonb_build_object('ok', false, 'error', 'bad_secret');
  end if;

  -- Одна плата — один аппарат; код привязки, если был выпущен, больше не нужен.
  delete from public.device_rt where device_id = v_dev and machid <> p_machid;
  delete from public.device_pair_codes where machid = p_machid;

  v_topic := gen_random_uuid();
  v_key   := public._rand_hex(2);

  insert into public.device_rt (machid, topic, key, device_id, paired_at)
  values (p_machid, v_topic, v_key, v_dev, now())
  on conflict (machid) do update
     set topic     = excluded.topic,
         key       = excluded.key,
         device_id = excluded.device_id,
         paired_at = excluded.paired_at;

  -- Перенос времени открытия с платы. Только пока у аппарата значение по
  -- умолчанию: если владелец уже менял его в панели, панель главнее.
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

comment on function public.device_migrate(bigint, text, text, int) is
  'Временная: привязка платы esp-rt, перешедшей со старой прошивки, по machid '
  'и secret из её NVS. Ответ {ok, topic, key}; неверные попытки в общем '
  'лимите 20 за 10 минут. Удалить, когда все платы перешли.';
