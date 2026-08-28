-- ============================================================
-- Каталог грузится по факту изменения, пинг реже, окно offline шире.
--
-- Планшет раз в минуту тянул полный каталог машины — inventory + categories,
-- два запроса, — и в подавляющем большинстве случаев получал байт в байт то
-- же, что минуту назад. Связка была осознанной (20260807120000: «on its
-- existing 60-second catalog refresh cycle, no new credential, no new
-- schedule»), но с тех пор на пинг навесили board_ok, app_version,
-- ter_number и вердикт отвязки, а каталог как опрашивался вслепую, так и
-- опрашивался.
--
-- Считать тут надо не байты полезных данных, а ЗАПРОСЫ. HttpClient в Dart
-- закрывает простаивающее соединение через 15 секунд, поэтому при интервале
-- от минуты и выше каждый запрос платит TLS-рукопожатие заново: цепочка
-- сертификатов ~2,6 КБ плюс ~1,7 КБ на остальное. Тело ответа пинга — 66
-- байт, то есть один процент от его стоимости. Три запроса в минуту это
-- ~840 МБ в месяц на планшет; после этой миграции — ~50 МБ.
--
-- Приём тот же, что уже работает для раскладки слотов, но направление
-- обратное. Раскладку рисует оператор НА ПЛАНШЕТЕ, поэтому планшет шлёт свой
-- layout_hash, а сервер судит и отвечает 'push'. Каталог правит владелец В
-- АДМИНКЕ, источник правды здесь — поэтому планшету нечего присылать: сервер
-- сам считает отпечаток и кладёт в ответ, а планшет сравнивает его с тем,
-- что видел в прошлый раз.
--
-- Отпечаток считает СЕРВЕР, а не планшет. Иначе клиенту пришлось бы
-- воспроизвести эту строку побайтно — тот же порядок полей, тот же формат
-- numeric, — и первое же расхождение в форматировании дало бы либо вечную
-- перезагрузку каталога, либо вечную тишину. Планшет хранит непрозрачную
-- строку и сравнивает с предыдущей; ошибиться там негде.
-- ============================================================

-- ── Heartbeat ────────────────────────────────────────────────────────────
-- Сигнатура НЕ меняется: восемь аргументов, как сейчас на проде. В
-- 20260828120000 на этом чуть не разъехался весь парк — create or replace
-- сопоставляет функции по списку аргументов, и семиаргументный вариант завёл
-- бы вторую перегрузку вместо замены. Меняется только возвращаемый jsonb.
create or replace function public.device_ping(
  p_machid      bigint,
  p_secret      text,
  p_board_ok    boolean     default null,
  p_app_version text        default null,
  p_layout_hash text        default null,
  p_layout_at   timestamptz default null,
  p_device_id   text        default null,
  p_ter_number  text        default null
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
  v_catalog  text;
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

  insert into public.device_status
    (machid, last_seen_at, board_ok, app_version, ter_number, updated_at)
  values
    (p_machid, now(), p_board_ok, p_app_version,
     nullif(btrim(coalesce(p_ter_number, '')), ''), now())
  on conflict (machid) do update set
    last_seen_at = now(),
    board_ok     = excluded.board_ok,
    app_version  = coalesce(excluded.app_version, public.device_status.app_version),
    -- Absent parameter (an app that predates 20260824120000) means "no
    -- report" and keeps what we had; an empty string is a real report of
    -- "Kaspi" and must be able to clear a stale 'ODG'.
    ter_number   = case
                     when p_ter_number is null then public.device_status.ter_number
                     else nullif(btrim(p_ter_number), '')
                   end,
    updated_at   = now();

  -- Отпечаток каталога. Поля — ровно те, что запрашивает
  -- SupabaseApi.fetchInventory: лишнее здесь означает лишние перезагрузки,
  -- недостающее — правку, которая никогда не доедет до витрины.
  --
  -- coalesce НА КАЖДОЙ nullable-колонке, и это не перестраховка. В Postgres
  -- 'a' || NULL = NULL, а string_agg молча пропускает NULL: один незаполненный
  -- motor_id выбрасывал бы всю строку из отпечатка, и правки этого товара
  -- перестали бы доезжать. На проде сейчас 99 строк из 405 именно такие.
  --
  -- motor_id is not null в WHERE по той же причине, но с другой стороны:
  -- fetchInventory эти строки всё равно отбрасывает («unmapped row, skip»),
  -- так что их правки витрину не меняют и будить её незачем. Заодно условие
  -- ложится ровно на частичный индекс inventory_market_motor_uk.
  --
  -- categories в отпечаток не входят: они глобальные, меняются раз в год, и
  -- платить за их проверку на каждом пинге каждой машины дороже, чем один
  -- раз подождать следующей перезагрузки по другой причине.
  --
  -- order by id обязателен: без него string_agg собирает строки в порядке,
  -- который планировщик волен менять, и отпечаток «менялся» бы сам по себе.
  select md5(coalesce(string_agg(
           i.id::text                         || '|' ||
           coalesce(i.name, '')               || '|' ||
           coalesce(i.price::text, '')        || '|' ||
           coalesce(i.stock::text, '')        || '|' ||
           coalesce(i.image_url, '')          || '|' ||
           coalesce(i.motor_id::text, '')     || '|' ||
           coalesce(i.motor_type::text, '')   || '|' ||
           coalesce(i.curtain_mode::text, '') || '|' ||
           coalesce(i.emoji, '')              || '|' ||
           coalesce(i.category_id::text, '')  || '|' ||
           coalesce(i.product_id::text, ''),
           ',' order by i.id), ''))
    into v_catalog
    from public.inventory i
   where i.micromarket_id = p_machid
     and i.motor_id is not null;

  if p_layout_hash is null then
    return jsonb_build_object(
      'claim', 'ok', 'layout', 'ok', 'catalog', v_catalog);
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

  return jsonb_build_object(
    'claim', 'ok', 'layout', v_layout, 'catalog', v_catalog);
end;
$$;

revoke execute on function
  public.device_ping(bigint, text, boolean, text, text, timestamptz, text, text)
  from public, authenticated;
grant execute on function
  public.device_ping(bigint, text, boolean, text, text, timestamptz, text, text)
  to anon;

-- ── Окно offline ─────────────────────────────────────────────────────────
-- Биение теперь раз в пять минут, поэтому пятиминутное окно гасило бы лампу
-- на исправной машине после ОДНОГО пропущенного запроса — ровно то
-- дребезжание, из-за которого 20260807130000 поднимало порог с трёх минут до
-- пяти.
--
-- Запас в пропущенных биениях сокращается с пяти до трёх, но в абсолютном
-- времени растёт с 5 до 15 минут, так что случайный обрыв на GSM переживается
-- лучше прежнего. Платим тем, что о пропавшем аппарате узнаём позже: до
-- четверти часа вместо пяти минут. Осознанно — см. шапку.
--
-- ter_number в списке колонок ОБЯЗАТЕЛЕН: его добавила 20260824120000, и
-- пересоздание вью по тексту 20260807130000 молча снесло бы бейдж O!Bank в
-- админке. Определение снято с живой базы через pg_get_viewdef.
create or replace view public.device_status_view
with (security_invoker = on) as
  select
    machid,
    last_seen_at,
    -- null for BarysVend: that protocol has no health poll, so the tablet
    -- reports "unknown" rather than passing off "serial port is open" as a
    -- working board. The panel shows such machines as plain online/offline.
    board_ok,
    app_version,
    (last_seen_at > now() - interval '15 minutes') as online,
    ter_number
  from public.device_status;

grant select on public.device_status_view to authenticated;

comment on view public.device_status_view is
  'Per-machine heartbeat. `online` is computed at read time — 3 missed '
  '5-minute beats — against the database clock, never stored: a machine '
  'that loses power never gets to write "offline". board_ok is null when '
  'the board protocol has no health poll (BarysVend). security_invoker = on, '
  'so the owner RLS policy on device_status applies.';
