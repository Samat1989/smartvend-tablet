# SmartVend — отчёт об аудите безопасности

**Дата:** 2026-06-03
**Область:** `apps/tablet` (Flutter + Android kiosk), `apps/web_app` (React/Vite), Supabase (Postgres + Edge Functions)
**Метод:** статический анализ кода + проверка живого состояния прод-БД через Supabase MCP (только чтение) + multi-agent проход с адверсариальной верификацией каждой находки (47 агентов).
**Ветка:** `security-hardening` (исправлений ещё нет — это только отчёт).

---

## 1. Главное (Executive summary)

Вся модель безопасности проекта держится на одном предположении: **«нас защищает RLS»**. Это предположение корректно для роли `authenticated` (политики операторов правильно ограничены `owner_id = auth.uid()` — проверено эмпирически), **но не выполняется для роли `anon`**.

`anon`-ключ — это `publishable`-ключ, вшитый в APK планшета (`supabase_api.dart:16`) и в бандл web_app (`.env`). Он **публичный по дизайну** — любой может его извлечь. Поэтому всё, что разрешено роли `anon` в RLS, разрешено всему интернету. А роли `anon` сейчас разрешено слишком много.

**Корневая причина №1 (Critical):** политика `micromarkets` `anon SELECT USING(true)` отдаёт **все столбцы**, включая `secret` — ключ подписи платежей SmartVend. Любой может выкачать ключи подписи всех автоматов парка одним GET-запросом.

**Корневая причина №2 (High):** `anon` может писать в `inventory` / `sales` / `sales_items` **любого** автомата (проверка только «существует ли market», не «твой ли он»).

### Важный смягчающий контекст
- **Edge Functions не задеплоены** в проде (`list_edge_functions` пуст). Поэтому весь кластер находок по платёжным функциям (подмена цены на сервере, дубли продаж и т.д.) **сейчас не эксплуатируется** — это «спящие» дефекты, которые оживут при деплое функций.
- В проде сейчас работает планшет (`m102_tester`), пишущий напрямую через `anon` REST, и `customer_web` в режиме `VITE_ADMIN_ONLY=true` (витрина выпилена из бандла).
- Платёжный шлюз (`levending.smartvend.kz`) — внешняя граница доверия. Утечка `secret` позволяет подделывать подписанные запросы к шлюзу от имени любого автомата; деньги при этом идут на счёт оператора (не атакующего), но это полная компрометация платёжного credential и обход проверок (`set_machine_layout`).

---

## 1.5 Целевая архитектура (план владельца) и её влияние на фиксы

Единая БД Supabase обслуживает три канала, различаемых столбцом `micromarkets.kind`:

```
                      ┌─────────────────── Supabase (единая БД) ───────────────────┐
                      │  micromarkets (kind: vending | micromarket_static | tablet) │
                      │  inventory · sales · sales_items · products · categories    │
                      │  secret — ТОЛЬКО на сервере (не anon-читаем, не на телефоне) │
                      └─────────────────────────────────────────────────────────────┘
                          ▲ RPC (machid+secret)      ▲ service_role        ▲ authenticated
                          │  или device-token        │                     │ (owner_id=uid)
   ┌──────────────────────┴───┐   ┌──────────────────┴──────────┐   ┌──────┴───────────────┐
   │ ПЛАНШЕТ (vending)        │   │ STATIC_QR (без планшета)     │   │ web_app: ADMIN-панель │
   │ • оплата прямо в app     │   │ • QR на стикере = machid     │   │ • владелец логинится  │
   │ • подпись локально       │   │ • телефон открывает web_app  │   │ • добавляет товар     │
   │ • учёт товара/продаж     │   │ • web_app → Edge Functions   │   │ • смотрит продажи     │
   │   в Supabase             │   │ • EF по machid берёт secret  │   │                       │
   └──────────────────────────┘   │   СЕРВЕРНО, подписывает,     │   └───────────────────────┘
                                   │   ведёт продажи              │
                                   └──────────────────────────────┘
```

**Единый принцип безопасности этой схемы:** `secret` — backend-only credential. Ни телефон покупателя, ни браузер не должны его получать. Клиент доказывает идентичность серверу (`machid`+`secret` для планшета, `machid` для static_qr), а сервер сверяет/использует secret внутри.

Этот принцип **подтверждает** фикс F1 и уточняет рекомендации:

- **Планшет (vending):** secret уже приходит при pairing (оператор вводит руками → secure storage) и используется для локальной подписи. Читать `secret` из БД через `anon` планшету **не нужно** — текущий `select=id,secret` в `verifyPairing` нужен лишь для сверки. Заменяем на RPC `verify_pairing(machid, secret) → bool`. Записи продаж/товара — через `SECURITY DEFINER` RPC (`record_sale`/`upsert_inventory`), валидирующую secret внутри и пишущую только строки своего автомата.
- **static_qr (телефон):** QR содержит `machid` (публичный — нормально). Телефон шлёт `machid` в Edge Function; **функция под `service_role` сама достаёт secret, подписывает оплату и ведёт продажи**. Secret не покидает сервер. Edge-функцию обязательно писать с серверным пересчётом цены (F4) и идемпотентностью (F17); текущие версии ссылаются на удалённые объекты (F19) — деплой как есть нельзя.
- **Admin-панель:** уже корректна (`authenticated`, `owner_id = auth.uid()`). Подтверждено эмпирически — чужих данных владелец не видит.

**Открытое решение:** механизм авторизации записей планшета — `SECURITY DEFINER` RPC (рекомендуется: не требует деплоя функций, устойчивее к обрывам связи) либо общие Edge Functions. На состав находок не влияет, влияет на P0-миграцию. Опционально — отдельный device-token при pairing, развязывающий запись-в-БД и платёжный secret.

---

## 2. Сводная таблица находок (после дедупликации)

| # | Severity | Находка | Компонент | Статус в проде |
|---|----------|---------|-----------|----------------|
| F1 | 🔴 **Critical** | `anon` читает `micromarkets.secret` — ключ подписи платежей всего парка | supabase-db / cross | **активна** |
| F2 | 🟠 **High** | `anon` переписывает inventory/цены/остатки и вбрасывает фейковые продажи в любой автомат | supabase-db / cross | **активна** |
| F3 | 🟠 **High** | Секрет и сервис-PIN в открытом виде в SharedPreferences; PIN по умолчанию `1234` | tablet | **активна** |
| F4 | 🟠 **High** | Цена заказа берётся из клиентской корзины без серверной перепроверки | supabase-edge / web_app | спящая (функции не задеплоены) |
| F5 | 🟡 **Medium** | `set_machine_layout` обходится: secret, который он проверяет, читаем `anon`'ом | supabase-db | **активна** |
| F6 | 🟡 **Medium** | Сервис-PIN без лимита попыток / блокировки (brute-force при физ. доступе) | tablet | **активна** |
| F7 | 🟡 **Medium** | «Выход в Android» роняет lock-task в полные Настройки; единственный барьер — слабый PIN | tablet | **активна** |
| F8 | 🟡 **Medium** | `verify_jwt=true` удовлетворяется публичным anon-ключом → не даёт авторизации | supabase-edge | спящая |
| F9 | 🟡 **Medium** | Публичный bucket `product-images`: любой authenticated перезаписывает чужие картинки | supabase-db | **активна** |
| F10 | 🟡 **Medium** | Две пересекающиеся anon-INSERT политики на `sales_items` — выигрывает слабая | supabase-db | **активна** |
| F11 | 🔵 Low | Широкие табличные GRANT'ы для `anon` (INSERT/UPDATE/DELETE/TRUNCATE на всё) | supabase-db | латентная |
| F12 | 🔵 Low | `categories`: `OR owner_id IS NULL` даёт любому authenticated править общие категории (4/4 строки бесхозные) | supabase-db | **активна** |
| F13 | 🔵 Low | `anon` может вставлять draft-товары (спам каталога) | supabase-db | **активна** (часть штатного flow) |
| F14 | 🔵 Low | `pg_net` в схеме `public` (латентный SSRF-усилитель) | supabase-db | латентная |
| F15 | 🔵 Low | Отключена защита от утёкших паролей в Auth | supabase | **активна** |
| F16 | 🔵 Low | APK-автообновление без проверки хэша/подписи (supply-chain) | tablet | **активна** (требует физ./pipeline-доступа) |
| F17 | 🔵 Low | Нет идемпотентности при финализации платежа (дубли продаж) | supabase-edge | спящая (функции + таблицы удалены) |
| F18 | 🔵 Low | `process_kiosk_sale`: обход secret-auth + доверие клиентским суммам | supabase-edge | спящая (не задеплоена) |
| F19 | 🔵 Low | Спящие edge-функции ссылаются на удалённые объекты БД (опасны при редеплое) | supabase-edge | латентная |
| F20 | 🔵 Low | Диспенс гейтится только кодом статуса polling, не подтверждённой суммой | tablet | **активна** |
| F21 | 🔵 Low | USB-протокол платы без аутентификации (free vend при физ. доступе к USB) | tablet | hardware |
| F22 | 🔵 Low | Debug-панель платежа показывает поля запроса (orderid/randstr/sign) на экране киоска | tablet | **активна** |
| F23 | 🔵 Low | `VITE_ADMIN_ONLY` — клиентский флаг, не граница безопасности | web_app | hardening |
| F24 | 🔵 Low | Нет security-заголовков / CSP в `vercel.json` | web_app | hardening |
| F25 | ⚪ Info | Нет `network_security_config` / cleartext не запрещён явно | tablet | hardening |
| F26 | ⚪ Info | CORS `*` на функциях (CORS не ограничивает вызов — defense-in-depth) | supabase-edge | hardening |
| F27 | ⚪ Info | Anon-ключ в бандле (by design; риск — в слабом RLS) | web_app | by design |

---

## 3. Критичные находки — подробно

### F1 — 🔴 Critical: `anon` читает `micromarkets.secret`

**Где:** RLS-политика `public.micromarkets` → `"Anon read micromarkets"` = `SELECT USING(true)`, без ограничения по столбцам. Используется как appkey в `supabase/functions/create-payment/index.ts:37`, `verify-payment/index.ts:47`, и клиентски в `apps/tablet/lib/services/payment_service.dart:209` (`_sign`).

**Суть.** `secret` — единственный конфиденциальный вход в подпись `SHA-1(sort([secret, randstr, timestamp]).join(''))`, авторизующую запросы к `levending.smartvend.kz`. PostgREST **не поддерживает column-level RLS**, поэтому любой держатель публичного anon-ключа делает:
```
GET /rest/v1/micromarkets?select=id,secret
apikey: sb_publishable_84RnaNCrFwxKicybxLGL2w_StEYpHnD
```
и получает ключ подписи **каждого** автомата. Проверено живьём: 4 строки, у всех `secret` непустой. Планшет сам ходит этим путём (`supabase_api.dart:59-60`), что доказывает работоспособность.

**Эксплуатация.** Извлечь anon-ключ из web-бандла/APK → выкачать `id,secret` всех автоматов → формировать валидные подписи к шлюзу от имени любой машины; обходить `set_machine_layout` (F5). Это компрометация платёжного credential в масштабе всего парка.

**Исправление.**
1. `REVOKE SELECT ON public.micromarkets FROM anon`.
2. Создать view `micromarkets_public` (только `id, name, kind, layout_json` — без `secret`), выдать `anon` SELECT только на view; клиент читает view.
3. Перенести подпись платежей полностью на сервер (edge function с `service_role`), не отдавать `secret` ни в RLS, ни в APK.
4. **Ротировать все `secret`** в SmartVend — их следует считать утёкшими.

---

### F2 — 🟠 High: кросс-тенантная запись inventory и вброс продаж

**Где:** политики `inventory` (`Anon insert/update ... (real market)`), `sales` (`Anon insert ... (real market)`), `sales_items`; пути планшета `apps/tablet/lib/services/supabase_api.dart:329-672`.

**Суть.** Предикат всех anon-write политик — `EXISTS(SELECT 1 FROM micromarkets m WHERE m.id = <row>.micromarket_id)`, т.е. «market существует». У роли `anon` нет идентичности, поэтому привязать запись к «своему» автомату политика не может. Авторы миграции сами это задокументировали как «Phase C долг» (`20260526160000:28-32`).

**Эксплуатация.** С публичным ключом:
```
PATCH /rest/v1/inventory?micromarket_id=eq.<любой>  {"price":1}   // или {"stock":0}
POST  /rest/v1/sales  {"micromarket_id":<жертва>,"amount":...,"status":"completed"}
```
→ обнулить/задрать цены и остатки любого конкурента, заDoSить продажи, отравить отчётность и refund-логику в дашборде оператора. Аутентификация и оплата не нужны.

**Исправление.** Реализовать Phase C: записи inventory/sales — через `SECURITY DEFINER` RPC, валидирующую `(machid, secret)` серверно (secret не должен быть anon-читаемым — см. F1) и ограничивающую запись строками этого автомата; затем `REVOKE INSERT/UPDATE/DELETE` на `inventory`/`sales`/`sales_items` у `anon`.

---

### F3 — 🟠 High: секрет и сервис-PIN в открытом виде; PIN = `1234`

**Где:** `apps/tablet/lib/services/device_storage.dart:9,10,20,38,120-134`; `service_pin_screen.dart:26-37`.

**Суть.** `machid`, `secret`, `service_pin` лежат в незашифрованном XML `shared_preferences` в песочнице приложения. `service_pin` по умолчанию `1234` и не принуждается к смене. `flutter_secure_storage`/Keystore не используется (нет в `pubspec.yaml`). `allowBackup` не отключён.

**Эксплуатация.** Рутованный/ADB-планшет или извлечение бэкапа → cleartext `secret` и PIN из `/data/data/kz.smartvend.m102_tester/shared_prefs/*.xml`. Без рута — дефолтный `1234` открывает сервис-режим физически.

**Исправление.** `flutter_secure_storage` (Keystore) для `secret`+`service_pin`; принудительная смена PIN при первом pairing с запретом `1234`; `android:allowBackup=false`. В идеале `secret` вообще не хранить на клиенте — подпись на сервере (закрывает и F1).

---

### F4 — 🟠 High: серверу доверяют цену из клиентской корзины *(спящая)*

**Где:** `create-payment/index.ts:38-39` (`totalCents` из `items[].price`), `verify-payment/index.ts:86,101-109` (amount и `sales_items.price` из клиентской `cartItems`, плюс команда открытия двери); `apps/web_app/src/App.jsx:197-205`.

**Суть.** Ни одна функция не перечитывает авторитетную цену из `inventory`/`products`. Сумма к списанию и записи продаж берутся из тела запроса.

**Эксплуатация (когда функции задеплоены).** В devtools/прокси выставить `price=1` для товара за 5000 ₸ → шлюз списывает ~1 ₸, дверь открывается, остаток списывается, товар уходит почти бесплатно. Второй независимый путь к тому же результату уже активен сегодня через F2 (переписать `inventory.price` напрямую).

**Исправление.** На сервере игнорировать клиентские цены: по `product_id` + `micromarket_id` брать актуальную цену/остаток из БД, пересчитывать total, проверять сток, списывать только серверную сумму. В `verify-payment` не принимать `cartItems` из тела — читать `pending_orders.cart_data` и сверять с суммой, подтверждённой шлюзом.

---

## 4. Medium / Low / Info

Полные технические обоснования каждой — в JSON-результате прохода; здесь суть и фикс.

- **F5 (M)** `set_machine_layout` — проверка `p_secret` бессмысленна, т.к. `secret` anon-читаем (F1). Чинится вместе с F1; дополнительно убрать `anon EXECUTE`, перевести запись layout на authenticated/device-token.
- **F6 (M)** Сервис-PIN без throttling/lockout (`service_pin_screen.dart:26-37`). Добавить экспоненциальный backoff + блокировку после N попыток (счётчик в persistent storage), хранить соль-хэш, ≥6 цифр, логировать на бэкенд.
- **F7 (M)** `exitToAndroid` (`kiosk_bridge.dart:47-49`, `MainActivity.kt:128-140`) роняет lock-task в полные Настройки. Нет `DevicePolicyManager` user-restrictions (`DISALLOW_*`). Отдельный сильный admin-credential на это действие + user-restrictions, либо in-app Wi-Fi provisioning вместо Настроек.
- **F8 (M)** `verify_jwt` удовлетворяется публичным anon-ключом; функции не проверяют claims. Внутри функций валидировать владельца market; `cron-process-payments` закрыть на service-role/секрет.
- **F9 (M)** Bucket `product-images` `public=true`; политики `authenticated` INSERT/UPDATE без path/owner-скоупа (`Admin.jsx:503-516`). Скоупить `(storage.foldername(name))[1] = auth.uid()::text`, добавить `allowed_mime_types=['image/webp']`, `file_size_limit`, DELETE-политику с тем же скоупом; рассмотреть приватный bucket + signed URLs.
- **F10 (M)** Дублирующиеся anon-INSERT политики на `sales_items`; Postgres OR'ит → выигрывает `sale_id IS NOT NULL`. Удалить слабую политику; в идеале убрать anon-запись вовсе (см. F2).
- **F11 (L)** `anon`/`authenticated` держат `ALL` гранты на все таблицы (включая TRUNCATE). `REVOKE ALL`, выдать минимум; `FORCE ROW LEVEL SECURITY` на всех таблицах.
- **F12 (L)** `categories`: `USING (owner_id = auth.uid() OR owner_id IS NULL)`, и 4/4 строки бесхозные. Бэкфилл `owner_id`, убрать ветку `OR owner_id IS NULL`. *(Только authenticated; anon не затронут.)*
- **F13 (L)** `anon insert draft product` — спам orphan-черновиков. Это **штатный** flow (`createDraftProduct`, `supabase_api.dart:202-239`) — не удалять политику вслепую; завести machid+secret RPC / атрибуцию + rate-limit.
- **F14 (L)** `pg_net` в `public`; `anon`/`authenticated` имеют EXECUTE на `net.http_*` по дефолту (но схема `net` не выставлена в PostgREST → сейчас недостижимо). `ALTER EXTENSION pg_net SET SCHEMA extensions` + `REVOKE` на `net.*`.
- **F15 (L)** Включить leaked-password protection (HIBP), min-strength, MFA для операторов.
- **F16 (L)** APK-обновление (`update_service.dart:94-123`) без SHA-256/подписи. Поток ручной и PIN-гейтнутый, repo захардкожен, MITM блокируется same-signature правилом Android — поэтому Low. Публиковать SHA-256/detached signature и проверять в Dart; pin сертификата.
- **F17 (L)** Нет идемпотентности финализации (`verify-payment`/`complete-order`/`cron` дублируют sale+decrement). Спящая (функции и `pending_orders`/`decrement_stock` удалены). При редеплое: `UNIQUE(sales.payment_id)` + атомарный `UPDATE ... WHERE status='pending' RETURNING`.
- **F18 (L)** `process_kiosk_sale` — secret-auth обходится (F1) + доверие клиентским суммам + неатомарный stock-decrement. Не задеплоена и не вызывается. Либо удалить, либо при деплое — device-token вместо secret + атомарный `UPDATE ... WHERE stock>=qty`.
- **F19 (L)** Спящие функции ссылаются на удалённые `pending_orders`/`commands`/`decrement_stock`. `create-payment` списывает на шлюзе ДО падающего INSERT и глотает ошибку (`console.error`) → при редеплое «оплатил, записи нет». Удалить/перенести в `/attic`; убрать `functions.invoke` из `App.jsx`; CI-проверка ссылок на несуществующие объекты.
- **F20 (L)** Диспенс по коду polling, не по подтверждённой сумме (`payment_screen.dart:124-146`). Серверное подтверждение go/no-go, привязанное к orderid+amount.
- **F21 (L)** USB-протокол платы без auth; `m102Password` захардкожен (`board_client.dart:128-130`). Физический трогбоундари. Сузить auto-connect до точного CH340 VID/PID (убрать широкий fallback `knownUsbSerialVids`), физически защитить кабель/плату.
- **F22 (L)** Debug-панель платежа (`payment_service.dart:238-253`, `payment_screen.dart:614-642`) показывает поля запроса. Утечка незначительна (sign невосстановим, secret редактится), но убрать за PIN-гейт.
- **F23 (L)** `VITE_ADMIN_ONLY` (`main.jsx:15-33`) — клиентское роутирование, не граница. Защита `/admin` — серверно (RLS + role-claim).
- **F24 (L)** Нет CSP/X-Frame-Options/HSTS в `vercel.json`. Добавить заголовки (приоритет — `X-Frame-Options: DENY` против clickjacking админки; XSS-синков сейчас нет). Удалить мёртвый `src/counter.ts` (единственный `innerHTML`).
- **F25 (Info)** Нет `network_security_config.xml`. Платформенные дефолты уже блокируют cleartext/user-CA. Добавить явно + рассмотреть cert pinning для платёжного/обновляющего хостов.
- **F26 (Info)** CORS `*` не ограничивает вызов (это read-protection), credentials не отражаются. Defense-in-depth: эхо-allowlist Origin.
- **F27 (Info)** Anon-ключ в бандле — by design; риск целиком в слабом RLS (F1, F2).

---

## 5. Что проверили и НЕ подтвердили (7 отклонённых находок)

Адверсариальная проверка отклонила как ложные/переоценённые:

1. **admin-no-role-gate** — *важно и обнадёживающе:* админка гейтится только наличием сессии, **но** политики для роли `authenticated` корректно скоупнуты `owner_id = auth.uid()`. Эмпирически: случайный authenticated-пользователь видит **0 строк** в micromarkets/sales/inventory. Permissive `USING(true)` политики — только для `anon`. Кросс-тенантной утечки данных через админку нет.
2. **service-role-blast-radius** — функции не задеплоены и ссылаются на удалённые объекты; service_role не даёт прироста сверх уже-публичного anon-пути.
3. **create-payment-charges-before-recording** — `payment_request` лишь инициирует сессию, списание происходит позже; primary-финализация клиентская, не зависит от `pending_orders`.
4. **exported-mainactivity-usb-attach** — `exported=true` обязателен для launcher; USB-фильтр ограничен CH340 VID/PID; intent-данные не парсятся. Хардненинг, не уязвимость.
5. **payment-state-localstorage-tamper** — атакующий правит свой же storage; capability не превышает уже-публичный anon-вызов.
6. **marketid-reflected-localstorage** — `marketId` это селектор машины, не токен авторизации; не open-redirect.
7. **edge-functions-not-deployed (как security)** — это надёжностный баг (витрина падает «закрыто»), не эксплуатируемая уязвимость.

---

## 6. Рекомендованный порядок исправлений

**Приоритет 0 — закрыть прямо сейчас (активны в проде, удалённо эксплуатируемы):**
- **F1** — убрать `secret` из anon-чтения (view + REVOKE) + ротация секретов. *Закрывает заодно F5.*
- **F2** — убрать anon-запись в inventory/sales/sales_items (RPC с device-auth). *Закрывает заодно F10, частично F18/F20.*

**Приоритет 1 — высокий риск, активны:**
- **F3** (secure storage + смена PIN), **F6** (lockout PIN), **F7** (kiosk-escape), **F9** (storage-политики).

**Приоритет 2 — перед деплоем функций / средний риск:**
- **F4, F8, F11, F12** + hardening БД (`FORCE RLS`, least-privilege гранты, **F14**, **F15**).

**Приоритет 3 — гигиена/hardening:**
- **F16, F17, F19, F22, F24, F25** + удаление мёртвого кода (F18/F19, `counter.ts`).

> Все изменения БД — отдельными миграциями в `supabase/migrations/`, сначала на ветке/preview-проекте Supabase, и каждое — согласовываем перед применением к проду.
