-- ============================================================
-- Удаление товара из аппарата больше не стирает историю продаж
--
-- Что нашлось. У аппарата 4000005 за 2–21 сентября 89 продаж из 300 (29%)
-- не имеют НИ ОДНОЙ строки в sales_items. У 74 из них сумма ненулевая — всего
-- 44 640 ₸ — статус 'completed' и номер платежа на месте: покупатель заплатил,
-- деньги в выручке владельца учтены, а что именно продали — неизвестно.
-- У остальных двадцати двух аппаратов таких продаж нет вовсе.
--
-- Почему это удаление, а не сбой записи. Доля пустых чеков падает по мере
-- приближения к сегодня: 92% у продаж от 02.09, 84% от 03.09, 40% от 05.09 и
-- 0–5% за последние четыре дня. Сбой записи давал бы ровную долю; убывание
-- означает, что позиции исчезают из УЖЕ записанных продаж со временем — чем
-- старее продажа, тем больше шансов, что её товар успели удалить. Сходится и
-- остальное: суммы у чеков правильные, а complete_sale считает сумму по
-- позициям и при нуле позиций записал бы 0 — значит в момент завершения
-- продажи строки были. Плюс во всей базе нет ни одной позиции с product_id
-- IS NULL, то есть связь не обнулялась, а строка исчезала целиком.
--
-- Диагноз: sales_items.product_id ссылается на inventory(id) с ON DELETE
-- CASCADE, и удаление позиции из аппарата уносит строки всех её прошлых
-- продаж. DDL этих таблиц в репозитории нет — их заводили в дашборде до того,
-- как появились миграции, — поэтому блок ниже не предполагает текущее правило,
-- а читает его из pg_constraint и печатает в NOTICE, прежде чем переписать.
--
-- Правильное поведение — SET NULL: строка чека переживает удаление товара,
-- теряя только ссылку. Панель к этому готова с самого начала
-- (`item.inventory?.name || t('deleted_product')`, apps/web_app/src/Admin.jsx)
-- — эта ветка просто никогда не срабатывала, потому что строки не оставалось.
--
-- Одной ссылки мало: без названия в чеке осталась бы безымянная сумма. Поэтому
-- добавляется снимок имени на момент продажи. Цена снимком была с самого
-- начала (sales_items.price), имя — нет.
--
-- Чего это НЕ чинит: 15 пустых чеков с нулевой суммой на том же аппарате.
-- Там позиций не было и в момент завершения — либо выдача не начиналась, либо
-- record_sale_item не доехал; восстанавливать нечего. И уже стёртые строки не
-- воскрешают: их нет.
-- ============================================================

-- ---- 1. Снимок названия в строке чека ----------------------------------
alter table public.sales_items
  add column if not exists product_name text;

comment on column public.sales_items.product_name is
  'Название товара на момент продажи. Снимок, а не ссылка: inventory-строку '
  'могут удалить или переименовать, и чек обязан пережить это так же, как '
  'переживает изменение цены (price здесь снимком был всегда).';

-- Заполняем для тех строк, у которых ссылка ещё жива. Для уже осиротевших
-- продаж восстанавливать нечего — там нет и самой строки чека.
update public.sales_items si
   set product_name = i.name
  from public.inventory i
 where i.id = si.product_id
   and si.product_name is null;

-- ---- 2. Правило внешнего ключа: CASCADE -> SET NULL --------------------
do $$
declare
  v_con     text;
  v_rule    "char";
  v_notnull boolean;
begin
  select con.conname, con.confdeltype
    into v_con, v_rule
  from pg_constraint con
  where con.conrelid  = 'public.sales_items'::regclass
    and con.confrelid = 'public.inventory'::regclass
    and con.contype   = 'f';

  if v_con is null then
    raise exception
      'У sales_items нет внешнего ключа на inventory — схема не та, из которой '
      'исходит эта миграция. Разберитесь руками, прежде чем накатывать.';
  end if;

  -- В лог миграции: что здесь было на самом деле. Это единственное место, где
  -- прежнее правило вообще фиксируется письменно.
  raise notice
    'sales_items.% : правило ON DELETE было "%" (c=CASCADE, n=SET NULL, r=RESTRICT, a=NO ACTION)',
    v_con, v_rule;

  -- SET NULL физически невозможен, пока колонка NOT NULL: удаление товара
  -- падало бы с ошибкой вместо того, чтобы обнулить ссылку.
  select a.attnotnull into v_notnull
  from pg_attribute a
  where a.attrelid = 'public.sales_items'::regclass
    and a.attname  = 'product_id';

  if v_notnull then
    execute 'alter table public.sales_items alter column product_id drop not null';
  end if;

  if v_rule = 'n' then
    raise notice 'Правило уже SET NULL — ключ не трогаем.';
  else
    execute format('alter table public.sales_items drop constraint %I', v_con);
    execute format(
      'alter table public.sales_items add constraint %I '
      'foreign key (product_id) references public.inventory(id) on delete set null',
      v_con);
  end if;
end $$;

-- ---- 3. Писатели заполняют снимок --------------------------------------
-- Обе функции переопределяются целиком с ТОЙ ЖЕ сигнатурой: планшеты в парке
-- зовут их как есть, новый APK ради этого не нужен, а create or replace
-- сохраняет выданные ранее гранты.

create or replace function public.record_sale_item(
  p_machid         bigint,
  p_secret         text,
  p_sale_id        uuid,
  p_product_id     uuid,
  p_qty            int default 1,
  p_dispensed      boolean default true,
  p_result_code    int default null,
  p_result_message text default null
) returns void
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_price numeric;
  v_name  text;
begin
  perform public._assert_machine(p_machid, p_secret);

  if not exists (
    select 1 from public.sales
    where id = p_sale_id and micromarket_id = p_machid
  ) then
    raise exception 'sale % not found for machine %', p_sale_id, p_machid
      using errcode = '22023';
  end if;

  -- Имя берём тем же запросом, что и цену: это снимок на момент продажи, и
  -- переименование позиции задним числом чек уже не затронет.
  select price, name into v_price, v_name
  from public.inventory
  where id = p_product_id and micromarket_id = p_machid;
  if v_price is null then
    raise exception 'product % not in inventory of machine %', p_product_id, p_machid
      using errcode = '22023';
  end if;

  insert into public.sales_items
    (sale_id, product_id, product_name, price, quantity, dispensed, result_code, result_message)
  values
    (p_sale_id, p_product_id, v_name, v_price, coalesce(p_qty, 1), p_dispensed,
     p_result_code, p_result_message);

  if p_dispensed then
    update public.inventory
       set stock = greatest(coalesce(stock, 0) - coalesce(p_qty, 1), 0)
     where id = p_product_id and micromarket_id = p_machid;
  end if;
end;
$$;

comment on function public.record_sale_item(bigint, text, uuid, uuid, int, boolean, int, text) is
  'Записать позицию чека. Цена и название берутся с сервера снимком на момент '
  'продажи, остаток списывается только у выданного товара.';


create or replace function public.finalize_paid_order(
  p_orderid text
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
  -- Захват и чтение одним оператором: строка блокируется и переводится в
  -- 'completed', только если была 'pending'. Второй одновременный вызов
  -- получит not found и уйдёт в ветку 'already'.
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

  insert into public.sales (micromarket_id, amount, status, payment_id)
  values (v_order.micromarket_id, v_order.amount, 'completed', v_order.torderid)
  returning id into v_sale_id;

  for v_item in
    select value from jsonb_array_elements(coalesce(v_order.cart, '[]'::jsonb))
  loop
    v_pid := (v_item->>'id')::uuid;
    v_qty := greatest(coalesce((v_item->>'count')::int, 1), 0);

    -- Цена берётся из корзины, а НЕ перечитывается из inventory. Корзину
    -- собрал create-payment по серверным ценам, и именно по ней с клиента
    -- списали деньги. Перечитать сейчас — значит записать в чек цену, которой
    -- не было в момент оплаты, если владелец успел её поменять; тогда
    -- sum(price*quantity) перестанет сходиться с sales.amount.
    v_price := coalesce((v_item->>'price')::numeric, 0);

    -- Имя, в отличие от цены, в корзине не лежит — create-payment его туда не
    -- кладёт. Читаем текущее: для static-QR между заказом и оплатой проходят
    -- секунды, так что снимок честный.
    --
    -- Если товар успели удалить, ссылку обнуляем. Комментарий ниже с самого
    -- начала утверждал, что этот случай переживается, но внешний ключ ронял
    -- вставку раньше, чем дело доходило до списания: вся транзакция
    -- откатывалась, заказ навсегда оставался 'pending', а деньги с покупателя
    -- были уже взяты. Теперь чек записывается без ссылки — ровно так же, как
    -- выглядит любая позиция, товар которой удалили позже.
    v_name := null;
    select name into v_name
    from public.inventory
    where id = v_pid and micromarket_id = v_order.micromarket_id;
    if not found then
      v_pid := null;
    end if;

    insert into public.sales_items (sale_id, product_id, product_name, price, quantity)
    values (v_sale_id, v_pid, v_name, v_price, v_qty);

    -- Относительное списание, привязанное к своему аппарату. Если товар успели
    -- удалить между заказом и оплатой, обновится 0 строк — и это НЕ ошибка:
    -- деньги уже взяты, и ронять из-за этого всю транзакцию значит оставить
    -- оплаченный заказ висеть в 'pending' навсегда. Продажа записывается,
    -- списывать просто нечего.
    update public.inventory
       set stock = greatest(coalesce(stock, 0) - v_qty, 0)
     where id = v_pid
       and micromarket_id = v_order.micromarket_id;
  end loop;

  return jsonb_build_object('status', 'completed', 'sale_id', v_sale_id);
end;
$$;
