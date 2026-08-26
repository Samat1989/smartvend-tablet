-- ============================================================
-- Бэкфилл продаж, записанных с amount = 0 при непустом чеке
--
-- Причина — гонка в планшете, не в базе. dispense_screen.dart писал позиции
-- чека через unawaited(recordSaleItem(...)), а сразу за циклом делал
-- await completeSale(...). Если запрос complete_sale доезжал до Supabase
-- раньше незавершённой вставки, он суммировал пустой набор:
--
--   select coalesce(sum(price * quantity) filter (where dispensed), 0)
--
-- и писал amount = 0. Вставка приходила секундой позже — оставалась продажа
-- на 0 ₸ с товаром на 750 ₸ внутри. Деньги при этом списаны и товар выдан:
-- врал только отчёт.
--
-- Планшет починен (позиции собираются в pendingItemWrites и ожидаются перед
-- completeSale). Здесь чинятся строки, попавшие в прод до этого: 6 продаж на
-- двух аппаратах, 5600 ₸ мимо выручки владельца.
--
-- Идемпотентна: после первого прогона под условие amount = 0 эти строки уже
-- не подпадают.
-- ============================================================

update public.sales s
   set amount = t.correct_amount
  from (
    select si.sale_id,
           sum(si.price * si.quantity) filter (where si.dispensed) as correct_amount
    from public.sales_items si
    group by si.sale_id
  ) t
 where t.sale_id = s.id
   and s.amount = 0
   and s.status = 'completed'
   -- Ноль при всех невыданных позициях — это правда, а не ошибка: клиенту
   -- вернули деньги, продавать было нечего. Трогаем только те продажи, где
   -- товар реально выдан.
   and t.correct_amount > 0;
