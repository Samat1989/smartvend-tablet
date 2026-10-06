-- ============================================================
-- Канал Supabase Realtime для плат static-QR (новая прошивка firmware/esp-rt)
--
-- Старые платы esp-relay/esp-pulse узнают об оплате из MQTT SmartVend и сами
-- зовут complete-order. Новая плата держит одно WebSocket-подключение к
-- Realtime, а платёж целиком ведёт create-payment:
--
--   ping/pong перед QR -> опрос payment_result, пока плата в Presence ->
--   code=1 -> finalize_paid_order(door_status='pending') -> подписанный open ->
--   плата отвечает opened -> set_sale_door_status('opened' | 'failed').
--
-- Что здесь:
--   1. device_rt         — канал и ключ подписи каждой привязанной платы.
--                          Есть строка = аппарат на новом пути (rt_flow).
--   2. device_pair_codes — одноразовый код привязки из панели.
--   3. sales.door_status — открылась ли дверь у оплаченной продажи.
--   4. finalize_paid_order с параметром p_door_status (старый вызов работает).
--   5. get_order_status понимает статус двери.
--
-- Совместимость: у машин без строки в device_rt не меняется ничего. Старые
-- продажи и продажи через complete-order получают door_status='opened'.
--
-- Зависимость: сервисное открытие через Realtime опирается на service_opens
-- из 20260904120000_service_open.sql. Эту миграцию самой по себе она не
-- требует, но edge-функция service-open-request без неё ответит ошибкой.
-- ============================================================


-- ── 1. Канал платы ───────────────────────────────────────────────────────
-- topic — имя публичного канала Realtime `dev:<topic>`. Канал публичный (его
-- слушают publishable-ключом), поэтому имя должно быть неугадываемым, а всё,
-- что открывает замок, подписано key (HMAC-SHA256). Плата получает оба только
-- при привязке по коду из панели и больше нигде.
create table if not exists public.device_rt (
  machid    bigint      primary key
                        references public.micromarkets(id) on delete cascade,
  topic     uuid        not null unique default gen_random_uuid(),
  key       text        not null,
  device_id text,
  paired_at timestamptz not null default now()
);

alter table public.device_rt enable row level security;
revoke all on public.device_rt from anon, authenticated;

comment on table public.device_rt is
  'Привязанные платы с Realtime-прошивкой: канал dev:<topic> и ключ подписи '
  'команд. Наличие строки включает для машины новый путь оплаты. Только '
  'service_role; владелец видит topic через my_device_rt().';


-- ── 2. Код привязки ──────────────────────────────────────────────────────
-- Один живой код на машину. Храним хэш, а не сам код: он нужен ровно один раз,
-- в момент ввода на плате.
create table if not exists public.device_pair_codes (
  machid     bigint      primary key
                         references public.micromarkets(id) on delete cascade,
  code_hash  text        not null,
  created_by uuid        not null,
  expires_at timestamptz not null,
  attempts   int         not null default 0
);

alter table public.device_pair_codes enable row level security;
revoke all on public.device_pair_codes from anon, authenticated;


-- 32 случайных бита из gen_random_uuid() (ядро PG, криптостойкий генератор),
-- без зависимости от pgcrypto.
create or replace function public._rand_hex(p_uuids int default 1)
returns text
language sql
volatile
set search_path = pg_catalog, public, pg_temp
as $$
  select string_agg(replace(gen_random_uuid()::text, '-', ''), '')
    from generate_series(1, greatest(p_uuids, 1));
$$;

revoke execute on function public._rand_hex(int) from public, anon, authenticated;


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
  -- Плата esp-rt стоит только на холодильниках со статическим QR. На вендинге,
  -- планшете и экране свои клиенты; код для них — ошибка интерфейса.
  if v_kind <> 'micromarket_static' then
    raise exception 'machine % is not a static-QR fridge (kind=%)', p_machid, v_kind
      using errcode = '22023';
  end if;

  v_code := lpad(((('x' || substr(public._rand_hex(1), 1, 8))::bit(32)::bigint)
                   % 1000000)::text, 6, '0');

  insert into public.device_pair_codes (machid, code_hash, created_by, expires_at, attempts)
  values (p_machid,
          encode(sha256(convert_to(p_machid::text || ':' || v_code, 'UTF8')), 'hex'),
          v_uid, v_exp, 0)
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

comment on function public.create_pair_code(bigint) is
  'Выдаёт владельцу (или суперадмину) одноразовый 6-значный код привязки '
  'платы на 30 минут. Новый код заменяет прежний.';


-- Зовёт плата из портала настройки, publishable-ключом. Ошибки — ответом
-- {ok:false}, а не исключением: исключение откатило бы и счётчик попыток.
create or replace function public.device_pair(
  p_machid    bigint,
  p_code      text,
  p_device_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_row   public.device_pair_codes%rowtype;
  v_topic uuid;
  v_key   text;
begin
  select * into v_row from public.device_pair_codes
   where machid = p_machid
   for update;

  if not found or v_row.expires_at < now() then
    return jsonb_build_object('ok', false, 'error', 'no_code');
  end if;

  if v_row.code_hash is distinct from
     encode(sha256(convert_to(p_machid::text || ':' || coalesce(trim(p_code), ''), 'UTF8')), 'hex')
  then
    -- Пятая ошибка сжигает код: 6 цифр на 5 попыток — шанс подбора 1 к 200 000,
    -- дальше владелец выпускает новый.
    if v_row.attempts + 1 >= 5 then
      delete from public.device_pair_codes where machid = p_machid;
      return jsonb_build_object('ok', false, 'error', 'too_many_attempts');
    end if;
    update public.device_pair_codes set attempts = attempts + 1 where machid = p_machid;
    return jsonb_build_object('ok', false, 'error', 'bad_code');
  end if;

  delete from public.device_pair_codes where machid = p_machid;

  -- Каждая привязка выдаёт НОВЫЕ канал и ключ: прежняя плата этой машины
  -- остаётся в мёртвом канале со старым ключом и больше ничего не получит.
  v_topic := gen_random_uuid();
  v_key   := public._rand_hex(2);

  insert into public.device_rt (machid, topic, key, device_id, paired_at)
  values (p_machid, v_topic, v_key, nullif(trim(p_device_id), ''), now())
  on conflict (machid) do update
     set topic     = excluded.topic,
         key       = excluded.key,
         device_id = excluded.device_id,
         paired_at = excluded.paired_at;

  return jsonb_build_object('ok', true, 'topic', v_topic, 'key', v_key);
end;
$$;

revoke execute on function public.device_pair(bigint, text, text) from public;
grant  execute on function public.device_pair(bigint, text, text) to anon, authenticated;

comment on function public.device_pair(bigint, text, text) is
  'Привязка платы esp-rt по коду из панели. Верный код -> {ok, topic, key} и '
  'машина переходит на Realtime-путь оплаты. Код одноразовый, пять неверных '
  'попыток его сжигают.';


create or replace function public.unpair_device(
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

  delete from public.device_rt         where machid = p_machid;
  delete from public.device_pair_codes where machid = p_machid;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.unpair_device(bigint) from public, anon;
grant  execute on function public.unpair_device(bigint) to authenticated;

comment on function public.unpair_device(bigint) is
  'Отвязывает плату: машина возвращается на старый путь оплаты (MQTT + '
  'complete-order), привязанная плата теряет канал.';


-- Панели нужен topic, чтобы слушать Presence своих плат. Ключ подписи сюда не
-- попадает.
create or replace function public.my_device_rt()
returns table (machid bigint, topic uuid, paired_at timestamptz)
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select d.machid, d.topic, d.paired_at
    from public.device_rt d
    join public.micromarkets m on m.id = d.machid
   where m.owner_id = (select auth.uid())
      or coalesce((auth.jwt() -> 'app_metadata' ->> 'is_superadmin')::boolean, false);
$$;

revoke execute on function public.my_device_rt() from public, anon;
grant  execute on function public.my_device_rt() to authenticated;


-- ── 3. Статус двери у продажи ────────────────────────────────────────────
-- На Realtime-пути продажа пишется в момент code=1 (деньги уже списаны), а
-- дверь открывается после. door_status фиксирует, чем это кончилось:
--   pending — продажа записана, open отправлен;
--   opened  — плата подтвердила открытие;
--   failed  — плата на связи, но замок не сработал;
--   no_ack  — подтверждения не пришло.
-- Всё, что было до этой миграции, и всё, что идёт через complete-order
-- (там дверь открывается по 200 после записи), — 'opened'.
alter table public.sales
  add column if not exists door_status text not null default 'opened',
  add column if not exists door_at timestamptz,
  add column if not exists order_id text,
  add column if not exists stock_restored_at timestamptz;

alter table public.sales drop constraint if exists sales_door_status_check;
alter table public.sales add constraint sales_door_status_check
  check (door_status in ('pending', 'opened', 'failed', 'no_ack'));

create index if not exists sales_order_id_idx
  on public.sales (order_id) where order_id is not null;
create index if not exists sales_door_pending_idx
  on public.sales (created_at) where door_status = 'pending';

comment on column public.sales.door_status is
  'pending | opened | failed | no_ack. failed и no_ack — «деньги списаны, '
  'дверь не открылась»: панель показывает их владельцу для ручного возврата.';
comment on column public.sales.order_id is
  'pending_orders.orderid, из которого записана продажа (static-QR).';


-- ── 4. finalize_paid_order(p_orderid, p_door_status) ─────────────────────
-- Новый параметр с default: вызов {p_orderid} из complete-order не меняется.
-- Старую сигнатуру удаляем, а не оставляем рядом: две перегрузки с общим
-- первым аргументом PostgREST не различит.
drop function if exists public.finalize_paid_order(text);

create or replace function public.finalize_paid_order(
  p_orderid     text,
  p_door_status text default 'opened'
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_order   public.pending_orders%rowtype;
  v_sale_id uuid;
  v_item    jsonb;
  v_pid     uuid;
  v_qty     int;
  v_price   numeric;
  v_name    text;
begin
  if p_door_status not in ('pending', 'opened') then
    raise exception 'bad door status %', p_door_status using errcode = '22023';
  end if;

  -- Захват и чтение одним оператором (см. 20260825120000): второй
  -- одновременный вызов получит not found и уйдёт в ветку 'already'.
  update public.pending_orders
     set status = 'completed'
   where orderid = p_orderid
     and status  = 'pending'
  returning * into v_order;

  if not found then
    if exists (select 1 from public.pending_orders where orderid = p_orderid) then
      return jsonb_build_object('status', 'already');
    end if;
    return jsonb_build_object('status', 'unknown');
  end if;

  insert into public.sales (micromarket_id, amount, status, payment_id, order_id, door_status, door_at)
  values (v_order.micromarket_id, v_order.amount, 'completed', v_order.torderid, v_order.orderid,
          p_door_status, case when p_door_status = 'opened' then now() end)
  returning id into v_sale_id;

  for v_item in
    select value from jsonb_array_elements(coalesce(v_order.cart, '[]'::jsonb))
  loop
    v_pid := (v_item->>'id')::uuid;
    v_qty := greatest(coalesce((v_item->>'count')::int, 1), 0);
    -- Цена из корзины, по которой списали деньги, а не текущая (см.
    -- 20260921130000).
    v_price := coalesce((v_item->>'price')::numeric, 0);

    v_name := null;
    select name into v_name
    from public.inventory
    where id = v_pid and micromarket_id = v_order.micromarket_id;
    if not found then
      v_pid := null;
    end if;

    insert into public.sales_items (sale_id, product_id, product_name, price, quantity)
    values (v_sale_id, v_pid, v_name, v_price, v_qty);

    update public.inventory
       set stock = greatest(coalesce(stock, 0) - v_qty, 0)
     where id = v_pid
       and micromarket_id = v_order.micromarket_id;
  end loop;

  return jsonb_build_object('status', 'completed', 'sale_id', v_sale_id);
end;
$$;

revoke execute on function public.finalize_paid_order(text, text) from public, anon, authenticated;
grant  execute on function public.finalize_paid_order(text, text) to service_role;


-- Итог открытия двери. Из pending — в любой итог; из no_ack — только в
-- opened: запоздалое подтверждение доказывает, что дверь открылась.
create or replace function public.set_sale_door_status(
  p_orderid text,
  p_status  text
) returns int
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_n int;
begin
  if p_status not in ('opened', 'failed', 'no_ack') then
    raise exception 'bad door status %', p_status using errcode = '22023';
  end if;
  update public.sales
     set door_status = p_status,
         door_at     = now()
   where order_id = p_orderid
     and (door_status = 'pending'
          or (door_status = 'no_ack' and p_status = 'opened'));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke execute on function public.set_sale_door_status(text, text) from public, anon, authenticated;
grant  execute on function public.set_sale_door_status(text, text) to service_role;


-- Страховка на случай, когда фон create-payment убили до подтверждения:
-- продажа осталась бы в pending навсегда. Окно оплаты длится ~75 с, так что
-- 3 минуты в pending — это точно «ответа не будет». Крона нет (pg_net снят
-- в 20260817120000), поэтому зовёт create-payment в начале каждого платежа.
create or replace function public.sweep_door_pending()
returns int
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_n int;
begin
  update public.sales
     set door_status = 'no_ack',
         door_at     = now()
   where door_status = 'pending'
     and created_at < now() - interval '3 minutes';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke execute on function public.sweep_door_pending() from public, anon, authenticated;
grant  execute on function public.sweep_door_pending() to service_role;


-- Владелец возвращает товар на остаток у продажи, где дверь не открылась.
-- Автоматически не делаем: при no_ack дверь могла открыться, а подтверждение
-- потеряться. Один раз на продажу.
create or replace function public.restore_sale_stock(
  p_sale_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_super boolean := coalesce(
    (auth.jwt() -> 'app_metadata' ->> 'is_superadmin')::boolean, false);
  v_sale  public.sales%rowtype;
  v_owner uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;
  if not found then
    raise exception 'sale not found' using errcode = '22023';
  end if;
  select owner_id into v_owner from public.micromarkets where id = v_sale.micromarket_id;
  if not v_super and v_owner is distinct from v_uid then
    raise exception 'not your machine' using errcode = '42501';
  end if;
  if v_sale.door_status not in ('failed', 'no_ack') then
    raise exception 'door opened for this sale' using errcode = '22023';
  end if;
  if v_sale.stock_restored_at is not null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  update public.inventory i
     set stock = coalesce(i.stock, 0) + si.quantity
    from public.sales_items si
   where si.sale_id = p_sale_id
     and si.product_id = i.id
     and i.micromarket_id = v_sale.micromarket_id;

  update public.sales set stock_restored_at = now() where id = p_sale_id;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.restore_sale_stock(uuid) from public, anon;
grant  execute on function public.restore_sale_stock(uuid) to authenticated;


-- ── 5. get_order_status со статусом двери ────────────────────────────────
-- Витрина ждёт 'completed', чтобы показать успех. На Realtime-пути заказ
-- становится completed в момент оплаты, а дверь ещё закрыта, поэтому:
--   paid        — оплачено, открываем;
--   completed   — дверь открыта (и все старые/complete-order продажи);
--   door_failed — деньги списаны, дверь не открылась;
--   expired     — окно оплаты закрылось без оплаты (автовозврат SmartVend).
create or replace function public.get_order_status(p_orderid text)
returns text
language sql
security definer
set search_path = public
as $$
  select case
           when po.status = 'completed' then coalesce(
             (select case s.door_status
                       when 'opened'  then 'completed'
                       when 'pending' then 'paid'
                       else 'door_failed'
                     end
                from sales s
               where s.order_id = po.orderid
               limit 1),
             'completed')
           else po.status
         end
    from pending_orders po
   where po.orderid = p_orderid;
$$;

revoke all on function public.get_order_status(text) from public;
grant execute on function public.get_order_status(text) to anon, authenticated;
