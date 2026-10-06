-- ============================================================
-- «Был в сети …» для плат esp-rt
--
-- Presence в Realtime — это LWT: когда сокет платы умирает, канал сам рассылает
-- «ушла» (≈3 с). Но Presence ничего не помнит, а постоянного слушателя, который
-- записал бы это в базу, у Supabase нет. Поэтому время пишется двумя путями:
--
--   1. device_beat — плата раз в 15 минут шлёт «я жива» (HTTPS). Работает всегда,
--      даже когда панель закрыта; точность ±15 минут.
--   2. touch_device_seen — панель, увидев «ушла» в Presence, дописывает точное
--      время обрыва. Только пока панель открыта.
--
-- Оба пишут в device_status, откуда панель читает last_seen_at через
-- device_status_view, как для планшетов.
-- ============================================================

-- Плата называет себя каналом и ключом подписи — теми же, что получила при
-- привязке (device_rt); больше у неё ничего нет. Ответ {ok:false} вместо
-- исключения: неверная пара не должна сообщать, есть ли такой канал.
create or replace function public.device_beat(
  p_topic uuid,
  p_key   text,
  p_ver   text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_machid bigint;
begin
  select machid into v_machid
    from public.device_rt
   where topic = p_topic and key = p_key;
  if not found then
    return jsonb_build_object('ok', false);
  end if;

  insert into public.device_status (machid, last_seen_at, app_version, updated_at)
  values (v_machid, now(), left(p_ver, 40), now())
  on conflict (machid) do update
     set last_seen_at = now(),
         app_version  = coalesce(excluded.app_version, public.device_status.app_version),
         updated_at   = now();

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.device_beat(uuid, text, text) from public;
grant  execute on function public.device_beat(uuid, text, text) to anon, authenticated;

comment on function public.device_beat(uuid, text, text) is
  'Раз в 15 минут плата esp-rt сообщает «я жива»: канал и ключ из привязки — '
  'её единственный пропуск. Обновляет device_status.last_seen_at.';


-- Панель фиксирует момент, когда плата ушла из Presence. Владелец отмечает
-- только свою машину; своё же «последний раз в сети» подделывать незачем.
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
  -- Только у платы с Realtime-прошивкой: на планшетах last_seen_at пишет их
  -- собственный device_ping, и панель им не командует.
  if not exists (select 1 from public.device_rt where machid = p_machid) then
    return;
  end if;

  insert into public.device_status (machid, last_seen_at, updated_at)
  values (p_machid, now(), now())
  on conflict (machid) do update
     set last_seen_at = now(),
         updated_at   = now();
end;
$$;

revoke execute on function public.touch_device_seen(bigint) from public, anon;
grant  execute on function public.touch_device_seen(bigint) to authenticated;
