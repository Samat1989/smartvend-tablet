-- ============================================================
-- Сервисное открытие замка без оплаты (пополнение, обслуживание)
--
-- До сих пор у микромаркета со статическим QR замок открывался ровно одним
-- способом: MQTT-событие «Processed order» от брокера SmartVend -> плата дёргает
-- complete-order -> открывает по HTTP 200. Оператор, приехавший пополнять
-- холодильник, программного способа открыть дверь не имел вообще — только
-- физический ключ.
--
-- Канала «бэкенд -> плата» в системе нет: таблицу commands удалили миграцией
-- 20260526180000 как мёртвую, и docs/system_architecture.md прямо фиксировал,
-- что сервисное открытие придётся заводить заново. Эта миграция — половина
-- такого канала со стороны БД.
--
-- МОДЕЛЬ ДОВЕРИЯ. MQTT-сообщение, которым бэкенд будит плату, — не команда, а
-- дверной звонок. Authority — строка в этой таблице:
--
--   1. Владелец жмёт кнопку в панели -> request_service_open вставляет заявку
--      со сроком жизни. Это единственное место, где решается «можно».
--   2. Бэкенд публикует пинок в наш MQTT-брокер, чтобы плата не ждала.
--   3. Плата по пинку зовёт edge-функцию service-open, та зовёт
--      claim_service_open, и замок открывается ТОЛЬКО по HTTP 200.
--
-- Отсюда: подделанный пинок ничего не открывает — заявки нет, ответ 404.
-- Поэтому же на весь парк хватает двух общих учёток брокера вместо учётки на
-- машину: подслушать чужой топик бесполезно.
--
-- ПОЧЕМУ НЕ ЧЕРЕЗ sales/pending_orders. Нулевая продажа была бы дешевле в
-- реализации, но она попадёт в выручку, в счётчики «сколько удалим вместе с
-- машиной» в device-admin и в оговорку про нулевые суммы из миграции
-- 20260826130000 (где нулевые sales — это баг, который чинили backfill'ом).
-- Сервисное открытие — не продажа и не платёж, поэтому у него своя таблица.
--
-- НЕ применено к прод — применять владельцу.
-- ============================================================

create table if not exists public.service_opens (
  id           uuid        primary key default gen_random_uuid(),
  machid       bigint      not null references public.micromarkets(id) on delete cascade,
  -- Кто нажал. Без FK на auth.users — ровно как micromarkets.owner_id: удаление
  -- аккаунта не должно ронять журнал того, что этот аккаунт когда-то делал.
  requested_by uuid        not null,
  -- Сколько держать замок открытым. Пополнение — это минуты, а не секунды
  -- покупательского окна, поэтому длительность выбирает оператор в панели.
  seconds      int         not null check (seconds between 10 and 600),
  requested_at timestamptz not null default now(),
  expires_at   timestamptz not null,
  claimed_at   timestamptz,
  status       text        not null default 'pending'
                           check (status in ('pending', 'claimed', 'expired'))
);

-- Единственный горячий запрос — «есть ли живая заявка для этой машины»,
-- его делает claim_service_open на каждый пинок.
create index if not exists service_opens_machid_status_idx
  on public.service_opens (machid, status, expires_at desc);

comment on table public.service_opens is
  'Журнал и очередь сервисных открытий замка без оплаты (пополнение, '
  'обслуживание). Строка в статусе pending — это разрешение открыть, выданное '
  'владельцем или суперадмином; плата забирает его через claim_service_open. '
  'К продажам отношения не имеет и в выручку не попадает.';

comment on column public.service_opens.expires_at is
  'После этого момента заявку забрать нельзя. Защищает от «нажал вчера, '
  'открылось сегодня», когда плата была офлайн и подключилась через сутки.';

comment on column public.service_opens.status is
  'pending — выдана и ещё не забрана; claimed — плата забрала (и, если была '
  'на связи, открыла); expired — вытеснена более новой заявкой на ту же '
  'машину. Отдельного перевода в expired по времени нет: строка с pending и '
  'просроченным expires_at означает «выдали, но никто не забрал», и это '
  'полезный факт журнала, а не мусор, который надо подчищать по крону.';

-- ── RLS ──────────────────────────────────────────────────────────────────
-- Владелец видит историю своих машин; суперадмин — всё. Писать напрямую
-- нельзя никому: и выдача, и захват идут через SECURITY DEFINER функции ниже,
-- иначе владелец мог бы вставить себе заявку на чужую машину.
alter table public.service_opens enable row level security;

drop policy if exists "Owner reads own service opens" on public.service_opens;
create policy "Owner reads own service opens"
  on public.service_opens for select
  to authenticated
  using (
    machid in (
      select id from public.micromarkets where owner_id = (select auth.uid())
    )
    or coalesce((auth.jwt() -> 'app_metadata' ->> 'is_superadmin')::boolean, false)
  );

revoke insert, update, delete on public.service_opens from anon, authenticated;

-- ── Выдача разрешения (панель) ───────────────────────────────────────────
-- Зовётся edge-функцией service-open-request клиентом с JWT вызывающего,
-- поэтому auth.uid() внутри — настоящий пользователь, а не service_role.
--
-- Права проверяются здесь, а не в UI: скрыть кнопку — это косметика (finding
-- F23 в docs/security-audit-2026-06.md про VITE_ADMIN_ONLY), а функция —
-- настоящая граница.
create or replace function public.request_service_open(
  p_machid  bigint,
  p_seconds int default 180
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
  v_id    uuid;
  v_sec   int := least(greatest(coalesce(p_seconds, 180), 10), 600);
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

  -- У вендинга нет замка — там моторные спирали. Заявка на такую машину не
  -- ошибка пользователя, а ошибка кода (кнопка не должна была отрисоваться),
  -- и молча положить её в таблицу значит спрятать баг.
  if v_kind = 'vending' then
    raise exception 'machine % has no lock (kind=%)', p_machid, v_kind
      using errcode = '22023';
  end if;

  -- Вытесняем прежние невыбранные заявки этой машины. Иначе оператор, нажавший
  -- кнопку трижды, пока плата была офлайн, получил бы три открытия подряд,
  -- когда та наконец подключится.
  update public.service_opens
     set status = 'expired'
   where machid = p_machid
     and status = 'pending';

  insert into public.service_opens
    (machid, requested_by, seconds, expires_at)
  values
    (p_machid, v_uid, v_sec, now() + interval '10 minutes')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'seconds', v_sec);
end;
$$;

revoke execute on function public.request_service_open(bigint, int) from public, anon;
grant  execute on function public.request_service_open(bigint, int) to authenticated;

comment on function public.request_service_open(bigint, int) is
  'Выдаёт разрешение открыть замок машины на p_seconds секунд. Владелец — '
  'только своей машины, суперадмин — любой. Гасит прежние невыбранные заявки '
  'той же машины, чтобы накопленные нажатия не открыли замок несколько раз '
  'подряд.';

-- ── Захват разрешения (плата через edge-функцию) ─────────────────────────
-- Атомарный клейм тем же приёмом, что finalize_paid_order (миграция
-- 20260825120000): update ... where status='pending' returning. Кто не выиграл
-- гонку — получает not found и уходит без открытия.
--
-- Идемпотентность здесь важнее, чем в оплатах: MQTT-пинок может продублироваться
-- (QoS 0 на переподключении), и без клейма плата открыла бы замок дважды.
create or replace function public.claim_service_open(
  p_machid bigint
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_row public.service_opens%rowtype;
begin
  update public.service_opens
     set status     = 'claimed',
         claimed_at = now()
   where id = (
     -- Ровно одна строка: самая свежая живая заявка. Подзапрос, а не
     -- `where machid=... and status='pending'`, потому что второй вариант
     -- забрал бы разом все накопленные заявки машины.
     select id from public.service_opens
      where machid  = p_machid
        and status  = 'pending'
        and expires_at > now()
      order by requested_at desc
      limit 1
      for update skip locked
   )
  returning * into v_row;

  if not found then
    return jsonb_build_object('ok', false);
  end if;

  return jsonb_build_object('ok', true, 'seconds', v_row.seconds, 'id', v_row.id);
end;
$$;

-- Только edge-функция. Клиенту тут делать нечего: функция не проверяет, кто
-- зовёт, — она уже доверяет тому, что разрешение выдано на шаге выше. Грант
-- для service_role явный по той же причине, что у finalize_paid_order: revoke
-- from public снимает и автоматический грант Supabase.
revoke execute on function public.claim_service_open(bigint) from public, anon, authenticated;
grant  execute on function public.claim_service_open(bigint) to service_role;

comment on function public.claim_service_open(bigint) is
  'Атомарно забирает самую свежую непросроченную заявку на сервисное открытие '
  'машины и возвращает {ok:true, seconds}. Повторный вызов вернёт {ok:false} — '
  'это и есть защита от дублей MQTT-пинка.';
