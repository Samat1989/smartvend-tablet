-- ============================================================
-- Удаление через RPC: у части операторов метод DELETE не доходит до базы
--
-- Что случилось. У одного из владельцев панель добавляла товары (29 строк в
-- products за один день), а сохранение правок падало с "TypeError: Failed to
-- fetch" — postgrest-js так оборачивает запрос, на который не было ответа
-- вообще. В базе это видно без логов: у всех 29 строк updated_at равен
-- created_at, притом что у полутора десятков других владельцев правки в те же
-- минуты ложились нормально. Значит дело не в RLS и не в сервере: insert()
-- ходит POST-ом и проходит, update() ходит PATCH-ом и не доходит. PATCH и
-- DELETE (и их CORS-preflight) режут корпоративные прокси, антивирусы с
-- проверкой HTTPS и часть расширений браузера — POST пускают все.
--
-- Для правок клиент выкручивается сам: повторяет тело upsert-ом, а это POST
-- (см. patchRow() в apps/web_app/src/Admin.jsx). Для удаления такого приёма
-- нет — DELETE у PostgREST только DELETE. Отсюда эти три функции: панель
-- зовёт их, когда обычный запрос не дошёл, и удаление уезжает POST-ом на
-- /rest/v1/rpc/<name>.
--
-- security invoker — намеренно, как и у adjust_inventory_stock: RLS владельца
-- продолжает действовать, и через эти функции нельзя достать чужую строку.
-- Поэтому же возвращается количество удалённых строк: ноль означает ровно то
-- же, что пустой ответ обычного DELETE, — строка есть, но RLS её не отдаёт,
-- либо её уже нет. Панель показывает на это «недостаточно прав».
--
-- Внешние ключи никуда не деваются: товар, на который ссылается inventory,
-- по-прежнему не удалится (products.id там ON DELETE RESTRICT), и 23503
-- доедет до клиента тем же кодом, что и раньше.
-- ============================================================

create or replace function public.delete_product(p_id uuid)
returns int
language plpgsql
security invoker
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_count int;
begin
  delete from public.products where id = p_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.delete_product(uuid) from public, anon;
grant  execute on function public.delete_product(uuid) to authenticated;

comment on function public.delete_product(uuid) is
  'Удаляет товар каталога и возвращает число удалённых строк (0 = RLS не '
  'отдала строку). Запасной путь для браузеров, из которых не уходит метод '
  'DELETE: RPC вызывается POST-ом. security invoker — RLS владельца '
  'применяется.';


create or replace function public.delete_inventory_item(p_id uuid)
returns int
language plpgsql
security invoker
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_count int;
begin
  delete from public.inventory where id = p_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.delete_inventory_item(uuid) from public, anon;
grant  execute on function public.delete_inventory_item(uuid) to authenticated;

comment on function public.delete_inventory_item(uuid) is
  'Удаляет позицию из аппарата и возвращает число удалённых строк. Запасной '
  'путь для браузеров, из которых не уходит метод DELETE. security invoker — '
  'RLS владельца применяется.';


create or replace function public.delete_category(p_id uuid)
returns int
language plpgsql
security invoker
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_count int;
begin
  delete from public.categories where id = p_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.delete_category(uuid) from public, anon;
grant  execute on function public.delete_category(uuid) to authenticated;

comment on function public.delete_category(uuid) is
  'Удаляет категорию и возвращает число удалённых строк. Запасной путь для '
  'браузеров, из которых не уходит метод DELETE. security invoker — RLS '
  'владельца применяется.';
