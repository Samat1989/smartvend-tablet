-- Общие категории (Снеки, Напитки, Еда, Другое: owner_id IS NULL) остаются у
-- всех владельцев по умолчанию, но больше не меняются и не удаляются: старая
-- политика "Owner manages own categories" разрешала USING owner_id IS NULL
-- любому authenticated (F12 из docs/security-audit-2026-06.md). Личные
-- категории по-прежнему видит и правит только владелец.
-- Анонимное чтение не трогаем: планшет читает таблицу анонимным ключом.

drop policy if exists "Owner manages own categories" on public.categories;
drop policy if exists "Read own and default categories" on public.categories;
drop policy if exists "Owner inserts own categories" on public.categories;
drop policy if exists "Owner updates own categories" on public.categories;
drop policy if exists "Owner deletes own categories" on public.categories;

create policy "Read own and default categories"
  on public.categories for select to authenticated
  using (owner_id = (select auth.uid()) or owner_id is null);

create policy "Owner inserts own categories"
  on public.categories for insert to authenticated
  with check (owner_id = (select auth.uid()));

create policy "Owner updates own categories"
  on public.categories for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create policy "Owner deletes own categories"
  on public.categories for delete to authenticated
  using (owner_id = (select auth.uid()));
