# Типы машин и схемы оплаты

Документ описывает разделение системы на два **разных** типа продающих устройств и identity-модель, на которой они работают. Зафиксирован 2026-05-29 при проектировании static-QR флоу для веб-приложения `apps/web_app`.

> Карта компонентов верхнего уровня — в [system_architecture.md](system_architecture.md). Этот документ углубляется в платёжные потоки и identity-модель.

---

## Два типа машин в одной БД

| | **Vending (motor)** | **Static-QR micromart** |
|---|---|---|
| Аппаратура | M109E control board + моторы-спирали | ESP relay + электрозамок ([firmware/esp-relay](../firmware/esp-relay/)) |
| Приложение на машине | `apps/tablet` (Android/Flutter) | **нет приложения** — только ESP-реле |
| Тип товара | Снэки/напитки в моторных спиралях | Свободно на полке за замком |
| Что значит «выдача» | Мотор крутится, light-curtain ловит падение товара | Замок открывается, покупатель сам берёт |
| Кто инициирует платёж | Планшет `apps/tablet` (вызывает LV API напрямую) | Edge-функция (вызывается с телефона покупателя по QR) |
| Кто узнаёт об оплате | Планшет сам polling'ит LV gateway | Бэкэнд: webhook или cron от LV |
| Условие «сделка завершена» | Мотор подтвердил выдачу → бэкэнд закрывает платёж в LV | LV подтвердил оплату → бэкэнд **сразу** закрывает, без подтверждения от машины |
| Как машина узнаёт «открой/выдай» | Сама же инициировала, dispense immediately после своего polling'а | **MQTT-сообщение от бэкэнда** после события оплаты |
| `micromarkets.kind` | `'vending'` | `'micromarket_static'` (третье значение `'micromarket_tablet'` — legacy default для старых строк) |

Эти два потока **намеренно разделены**: их объединение в одной кодовой ветке в прошлом создавало ошибки (один тип ждал подтверждения от машины, другой нет — на static-QR это означало незакрытые платежи).

---

## Identity-модель (три роли)

| Identity | Где работает | Как авторизуется | Что может |
|---|---|---|---|
| **Owner** | `apps/web_app` (режим админки) | Supabase Auth: `signInWithPassword(email, password)` | Видит свои машины (`owner_id = auth.uid()`), правит каталог/инвентарь/цены, читает продажи |
| **Kiosk** (только для vending) | `apps/tablet` на планшете внутри машины | Supabase Auth: `signInWithPassword('kiosk-{machid}@local.smartvend', secret)` — один раз при пэйринге | Пишет `sales`/`sales_items` для **своей** машины (`kiosk_user_id = auth.uid()`), правит свой `inventory.stock` после выдачи |
| **Customer** (для static-QR) | `apps/web_app` (режим витрины) в браузере телефона, открыт по статическому QR | **Никак** — anon role, без логина | Читает каталог. **В БД не пишет вообще** — все мутации происходят в edge-функциях с service_role после редиректа в Каспи |

У static-QR машины **нет планшета** → нет third identity, которая нуждается в Supabase Auth. ESP32 relay не работает с Supabase напрямую — он слушает MQTT-брокер и щёлкает реле по сообщениям. Авторизуется в брокере отдельно (mTLS или username/password), Supabase его не видит.

---

## Поток оплаты, static-QR

```
┌──────────────┐
│ QR-наклейка  │  https://customer.example.kz/?marketId=3001000
│ на машине    │
└──────┬───────┘
       │ Скан камерой телефона
       ▼
┌──────────────────────────────────────────────────────────────┐
│ Customer SPA в браузере телефона (anon JWT)                  │
│                                                              │
│   1. Прочитал каталог (anon SELECT на inventory/products)    │
│   2. Локальная корзина (state в React)                       │
│   3. Tap "Оплатить":                                         │
│        supabase.functions.invoke('checkout-qr', {            │
│          marketId, items:[{inventoryId, qty}]                │
│        })                                                    │
│   4. Получил {paymentUrl}                                    │
│   5. window.location = paymentUrl  ──→  Kaspi app           │
│   6. ─── Браузер больше не нужен. Покупатель закрывает. ──── │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ Edge Function checkout-qr (service_role)                     │
│                                                              │
│   • SELECT price, micromarket_id FROM inventory              │
│       WHERE id IN (items.inventoryId)                        │
│       AND micromarket_id = $marketId                         │
│     ← цена с сервера, не из тела запроса                     │
│                                                              │
│   • INSERT INTO pending_orders (orderid, market_id,          │
│       cart_data_server, total, status='pending')             │
│                                                              │
│   • SELECT secret FROM micromarkets WHERE id = $marketId     │
│     ← service_role читает то, что anon не может              │
│                                                              │
│   • Подписывает запрос в LV, шлёт fetch(),                   │
│     получает paymentUrl                                      │
│   • RETURN {paymentUrl, orderid}                             │
└──────────────────────────────────────────────────────────────┘

         ── Kaspi обрабатывает платёж ──
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│ LV/SmartVend → НАШ БЭКЭНД                                    │
│                                                              │
│   Вариант A (предпочтительный): webhook                      │
│     POST /lv-webhook от smartvend.kz                         │
│     • verify signature                                       │
│     • UPDATE pending_orders SET status='paid'                │
│     • INSERT INTO sales (...)                                │
│     • publish MQTT: machines/{machid}/unlock                 │
│                                                              │
│   Вариант B (если webhook не доступен): edge-cron            │
│     Раз в N сек poll'ит LV для pending_orders.status=pending │
│     То же действие, что в A                                  │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ MQTT broker (внешний)                                        │
│   Topic: machines/{machid}/unlock                            │
│   Subscriber: ESP32 relay внутри статик-QR машины            │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ ESP32 relay                                                  │
│   Получил MQTT → щёлкает реле → замок открывается            │
│   Покупатель забирает товар → закрывает дверцу               │
└──────────────────────────────────────────────────────────────┘
```

Браузер покупателя в этой цепи участвует только в шагах 1–5. После редиректа в Каспи телефон может быть выключен, разряжен, выкинут — машина откроется по MQTT-сообщению, не зависящему от устройства покупателя. Поэтому в `apps/web_app/src/App.jsx` для QR-флоу **не нужен** ни `signInAnonymously()`, ни polling `verify-payment`, ни persistence в `localStorage` — каталог + корзина + один invoke + редирект.

---

## Поток оплаты, vending (motor)

В отличие от static-QR, vending-машина **сама знает** о платеже:

```
Покупатель у машины (планшет apps/tablet):
  • Выбирает товар на тач-экране
  • Tap "Оплатить" → apps/tablet сам:
      • POST к LV API (подписывает с machid + secret из flutter_secure_storage)
      • Получает QR/twocode
      • Показывает QR на экране планшета
  • Покупатель сканирует QR с телефона → платит в Kaspi
  • apps/tablet polling'ит LV /payment_result каждые N сек
  • Когда LV отдаёт code=1:
      • Шлёт M102-команду на M109E controller через USB-serial
      • Мотор крутится, light-curtain подтверждает падение товара
      • apps/tablet отчитывается обратно в LV: «выдано»
      • LV окончательно закрывает платёж
      • apps/tablet пишет в Supabase: sales + sales_items + декремент stock
```

Здесь Supabase узнаёт о продаже **постфактум** через apps/tablet (authenticated как kiosk-user). Бэкэнд не участвует в payment-флоу — он только хранит результат.

---

## Что это меняет в security-модели

Главное последствие разделения — **поверхность атаки для anon-ключа сужается радикально**:

- На static-QR флоу нет ни одной DB-записи от anon (всё через edge с service_role).
- На vending флоу записи идут от authenticated kiosk-user через RLS по `kiosk_user_id`.
- Текущие широко открытые policies `"Anon insert sales (real market)"`, `"Anon update inventory (real market)"` (audit findings E1–E5) уходят полностью — никто их не использует.
- Утечка `micromarkets.secret` через anon SELECT (E4/C1) закрывается column-grant'ом, потому что:
  - vending: apps/tablet верифицирует секрет через `auth.signInWithPassword`, а не через прямой SELECT.
  - static-QR: секрет нужен только edge-функции, та работает с service_role.

См. полный аудит безопасности в memory `project_supabase_security_state` (legacy-проект `c--m109e`) — закроется ≥80% находок одной этой архитектурной перепрошивкой.

---

## TBD до начала имплементации static-QR

1. **LV → бэкэнд**: webhook (предпочтительно) или наш cron-poll? Зависит от поддержки в `LE third-party QR payment API_V2.3.pdf`.
2. **MQTT-брокер**: где хостится (self-hosted EMQX/mosquitto, HiveMQ Cloud, AWS IoT)? Как auth для ESP32 (mTLS-cert vs username/pwd)? Topic-схема.
3. **Идемпотентность**: что если LV пришлёт webhook дважды или cron два раза заметит ту же оплату? UNIQUE-constraint на `sales.payment_id`.
4. **Refund-флоу для static-QR**: если ESP32 ответил `ack=fail` или вообще не ответил (замок сгорел, Wi-Fi пропал) — как инициируется возврат? У vending это решается с light-curtain'ом, здесь нужен явный механизм.
5. **`micromarkets.kind`** — значение для static-QR зафиксировано как `'micromarket_static'` (миграция `20260508120000_micromarkets_kind.sql`, CHECK `('micromarket_tablet','micromarket_static','vending')`).
6. **Provisioning new machine**: edge-функция `provision_kiosk` для vending должна создавать auth-user. Для static-QR — не должна (планшета нет), но должна выдать MQTT-creds для ESP32. Два разных кода.

---

## Связанные документы

- memory: customer_web architecture — что уже умеет SPA (ныне `apps/web_app`); в memory legacy-проекта `c--m109e`
- memory: m102_tester Supabase writes — инвентарь REST-запросов vending-планшета (ныне `apps/tablet`); в memory legacy-проекта `c--m109e`
- [memory: Supabase security state](../../.claude/projects/c--m109e/memory/project_supabase_security_state.md) — полный аудит безопасности от 2026-05-29
- [LE third-party QR payment API_V2.3.pdf](refs/LE%20third-party%20QR%20payment%20API_V2.3.pdf) — спецификация LV gateway
- [system_architecture.md](system_architecture.md) — карта компонентов монорепо верхнего уровня
