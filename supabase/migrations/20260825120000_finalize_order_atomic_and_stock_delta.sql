-- ============================================================
-- static_qr: атомарная финализация заказа + относительная правка остатка
--
-- Чинит три дефекта, найденных при ревью 25.08.2026. Первые два жили в двух
-- копиях — create-payment и complete-order дублировали финализацию слово в
-- слово, поэтому обе теперь зовут одну функцию.
--
-- 1. ПОТЕРЯ ПРОДАЖИ. Обе функции сначала помечали pending_orders.status =
--    'completed', и только потом писали sales. Между этими шагами деньги уже
--    списаны, а заказ больше не 'pending' — повторить некому. Любой сбой после
--    захвата (упавший insert, таймаут edge-функции, обрыв связи) означал: у
--    клиента деньги взяли, продажи нет нигде.
--
--    Здесь захват и запись — одна транзакция. Оборвалось на середине — не
--    закоммичено ничего, заказ остался 'pending', и его дозавершит следующая
--    попытка: цикл опроса в create-payment живёт ~90 секунд, плюс браузер
--    потом дёргает complete-order.
--
-- 2. ГОНКА ПРИ СПИСАНИИ. Было read-modify-write: select stock -> посчитать в
--    JS -> update stock = <абсолют>. Две оплаты одного товара, попавшие в одно
--    окно, теряли один декремент. Здесь `stock = stock - qty` одним
--    выражением — ровно как это давно делает планшетный record_sale_item.
--
-- 3. НЕПРОВЕРЕННЫЕ ОШИБКИ. Ошибка insert в sales_items внутри цикла не
--    проверялась: позиция молча пропадала при сохранённой продаже, сумма чека
--    переставала биться с составом. Внутри транзакции такая ошибка откатывает
--    всё, и заказ остаётся 'pending' для повтора.
--
-- НЕ применено к прод — применять владельцу.
-- ============================================================

-- Завершить оплаченный заказ: захватить, записать продажу, позиции и списать
-- остатки. Всё или ничего.
--
-- Возвращает jsonb со status:
--   'completed' + sale_id — записали мы
--   'already'             — кто-то успел раньше (повторный вызов, это норма)
--   'unknown'             — заказа с таким orderid нет
--
-- Вызывать ТОЛЬКО после подтверждённого захвата денег у платёжного шлюза:
-- функция не проверяет оплату, она фиксирует уже случившийся факт.
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

    insert into public.sales_items (sale_id, product_id, price, quantity)
    values (v_sale_id, v_pid, v_price, v_qty);

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

-- Только edge-функции. Клиенту тут делать нечего: функция фиксирует оплату,
-- ничего не проверяя, — вызвать её напрямую значило бы записать себе продажу
-- без денег.
--
-- Грант для service_role явный, а не по умолчанию: revoke from public снимает
-- и ту привилегию, которую Supabase раздаёт новым функциям автоматически, и
-- без строчки ниже обе edge-функции получили бы permission denied.
revoke execute on function public.finalize_paid_order(text) from public, anon, authenticated;
grant  execute on function public.finalize_paid_order(text) to service_role;

comment on function public.finalize_paid_order(text) is
  'Атомарно завершает оплаченный static_qr заказ: захват pending_orders, '
  'sales, sales_items и относительное списание остатков в одной транзакции. '
  'Вызывать только после подтверждённого захвата денег. Идемпотентна: '
  'повторный вызов вернёт status=already.';


-- Относительная правка остатка для панели владельца.
--
-- Кнопки «+1 / −1» в Admin.jsx считали stock из React-состояния, загруженного
-- при открытии страницы, и писали абсолютное значение. Окно — не миллисекунды,
-- а сколько панель открыта: пока оператор смотрит на «5», покупатель забирает
-- товар, в базе становится 4, оператор жмёт «+1» и пишет 6. Продажа затёрта.
--
-- security invoker — намеренно: RLS владельца на inventory продолжает
-- действовать, функция не даёт доступа к чужим строкам.
create or replace function public.adjust_inventory_stock(
  p_id    uuid,
  p_delta int
) returns int
language plpgsql
security invoker
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_stock int;
begin
  update public.inventory
     set stock = greatest(coalesce(stock, 0) + p_delta, 0)
   where id = p_id
  returning stock into v_stock;

  if not found then
    raise exception 'inventory row % not found or not visible', p_id
      using errcode = '22023';
  end if;

  return v_stock;
end;
$$;

revoke execute on function public.adjust_inventory_stock(uuid, int) from public, anon;
grant  execute on function public.adjust_inventory_stock(uuid, int) to authenticated;

comment on function public.adjust_inventory_stock(uuid, int) is
  'Прибавляет p_delta к inventory.stock одним выражением, не опускаясь ниже '
  'нуля. Для кнопок +/- в панели: абсолютная запись из устаревшего состояния '
  'затирала продажи, случившиеся с момента загрузки страницы. security '
  'invoker — RLS владельца применяется.';
