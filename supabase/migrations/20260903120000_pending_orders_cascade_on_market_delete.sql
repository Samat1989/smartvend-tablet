-- ============================================================
-- Удаление аппарата больше не спотыкается о его прошлые заказы.
--
-- Панель обещает каскад прямым текстом: «Вместе с ним удалятся: продаж N,
-- позиций товара M» — и для sales с inventory это правда. А pending_orders
-- заводился (20260603210000) с обычным `references public.micromarkets(id)`,
-- то есть NO ACTION: любая строка, даже давно завершённая, держит машину.
--
-- На аппарате 5840 это выглядело так: 27 pending и 61 completed. Первые
-- останавливала проверка в device-admin с понятным «есть неоплаченные
-- заказы», а вторые не останавливал никто — DELETE доходил до базы и падал
-- с 23503, панель показывала «Не удалось удалить аппарат» и текст
-- constraint'а. Удалить машину, которая хоть раз что-то продала, было
-- нельзя вообще, и причина ниоткуда не читалась.
--
-- Каскад здесь честен по смыслу таблицы: pending_orders — это техническая
-- переписка с платёжным шлюзом, ключом по orderid, а не бухгалтерия.
-- История продаж живёт в sales и удаляется вместе с машиной осознанно, с
-- отдельным подтверждением и счётчиком в диалоге.
--
-- Аудит остальных ссылок на micromarkets (ожидаем 'c' — cascade):
--
--   select conrelid::regclass as tbl, conname, confdeltype
--   from pg_constraint
--   where confrelid = 'public.micromarkets'::regclass;
--
-- Applied to prod on 2026-09-04 (Supabase Management API, тем же токеном,
-- каким ходит MCP). Аудит до применения показал ровно одну проблемную
-- ссылку: pending_orders confdeltype='a', остальные три уже 'c'.
-- Деплой device-admin — отдельным шагом, порознь они не помогают.
-- ============================================================
alter table public.pending_orders
  drop constraint if exists pending_orders_micromarket_id_fkey;

alter table public.pending_orders
  add constraint pending_orders_micromarket_id_fkey
  foreign key (micromarket_id) references public.micromarkets(id)
  on delete cascade;

comment on constraint pending_orders_micromarket_id_fkey on public.pending_orders is
  'ON DELETE CASCADE: заказы шлюза уходят вместе с аппаратом. Свежие '
  'неоплаченные заказы защищает device-admin, а не этот констрейнт — '
  'см. проверку окна в supabase/functions/device-admin/index.ts.';
