# M109E Вендинг — Flutter-приложение для планшета

Замена заводского Android-приложения для снэк-вендинга на плате **M109E** (M102-совместимая). Поток оплаты — **Kaspi QR через SmartVend**, бэкенд — **Supabase**.

## Что приложение делает

1. **Спариться с аппаратом** при первом запуске — оператор вводит `machid` + `secret` (валидируются по таблице `micromarkets` в Supabase)
2. **Подгрузить каталог** товаров из Supabase по `machid`, привязка товар↔мотор хранится в колонке `inventory.motor_id`
3. **Принять оплату** — клиент собирает корзину → планшет формирует QR через `levending.smartvend.kz/payment_request` → опрашивает статус каждые 3 сек
4. **Выдать товар** — после успешной оплаты последовательно крутит моторы по `motor_id` через RS485 (USB-Serial адаптер CH340/FTDI)
5. **Записать продажу** в `sales` + `sales_items` со статусом `dispensed=true/false` для каждой позиции, списать остатки в `inventory.stock`
6. **Управлять климатом** — заводской алгоритм охлаждения (5-мин прогрев вентилятора, ±4°C гистерезис, авто-отдых компрессора при 60 мин непрерывной работы)
7. **Скрытый сервисный режим** — 5 быстрых тапов на лого → PIN (по умолчанию `1234`) → меню: тест моторов, климат, редактор товаров, смена PIN, сброс пэйринга

## Архитектура

```
lib/
  main.dart                — корень приложения, провайдеры, _Router (PairingScreen | HomeScreen)
  board/
    board_client.dart      — драйвер M109E поверх USB-Serial: 20-байт фреймы, CRC-16, watchdog связи
  models/
    motor_layout.dart      — карта 6×6 моторов (label "001"..."056" ↔ motor 99..44)
    product.dart           — товар + слот
    cart.dart              — корзина + результат выдачи
    climate_config.dart    — режимы холодильника (off/cooling/heating)
  services/
    device_storage.dart    — SharedPreferences (machid, secret, PIN, язык)
    supabase_api.dart      — REST к Supabase (inventory, sales, sales_items, micromarkets)
    payment_service.dart   — SmartVend Kaspi QR (SHA-1 sign, polling, UTC timestamp)
    vending_service.dart   — корзина + загрузка каталога + оркестрация выдачи
    climate_controller.dart — заводской алгоритм холодильника (см. docs/03_PERIPHERALS_AND_CONFIG.md)
    strings.dart           — i18n RU/KZ/EN, локализация кодов M102 poll-результатов
  screens/
    pairing_screen.dart    — первый запуск: ввод machid + secret
    home_screen.dart       — каталог + плавающая корзина + maintenance overlay
    cart_screen.dart       — корзина → "Оплатить через Kaspi"
    payment_screen.dart    — QR + polling + "Подробнее" с диагностикой при сбое
    dispense_screen.dart   — пошаговая выдача с записью в sales + автообновление каталога
    service_pin_screen.dart — PIN-гейт сервисного режима
    service_menu_screen.dart — диагностический header (machid, board health, firmware ID) + плитки
    inventory_edit_screen.dart — список из 36 слотов, тап → редактор
    product_edit_screen.dart   — форма товара + кнопка «Тест мотора»
    climate_screen.dart    — настройка холодильника (уставка, режим)
    tester_screen.dart     — низкоуровневый тестер протокола (RUN/POLL/DO/raw)
android/
  app/src/main/
    AndroidManifest.xml    — kiosk-режим (HOME-категория, excludeFromRecents, WAKE_LOCK)
    kotlin/.../MainActivity.kt — immersive sticky, FLAG_KEEP_SCREEN_ON, lock-task best-effort
    kotlin/.../BootReceiver.kt — авто-запуск после включения питания
supabase/
  migrations/
    20260428120000_vending_motor_columns.sql  — добавляет motor_id/motor_type/curtain_mode/emoji + RPC decrement_stock
    20260428130000_inventory_anon_writes.sql  — RLS политики для INSERT/UPDATE/DELETE inventory от anon (планшет)
docs/
  PRODUCTION_PLAN.md       — план оставшихся доработок: refund, offline-кэш, dashboard владельца, UX-полировка
```

Заводская документация по протоколу M102 / lifecycle / периферии лежит в `c:\m109e\docs\` (01_PROTOCOL.md, 02_LIFECYCLE.md, 03_PERIPHERALS_AND_CONFIG.md, 04_MOTOR_LAYOUT.md).

## Запуск разработки

```bash
flutter pub get
flutter run                    # debug на подключённом планшете
flutter analyze                # должно быть No issues found
flutter build apk --release    # релизная сборка
```

Планшет должен быть с Android 5.0+ и USB OTG / USB-Host. На борту нужен FTDI или CH340 USB-RS485 адаптер.

## Подключение Supabase / Kaspi

Подставьте свои значения в [services/supabase_api.dart](lib/services/supabase_api.dart) (`SupabaseConfig.url`, `SupabaseConfig.anonKey`) и [services/payment_service.dart](lib/services/payment_service.dart) (`SmartVendConfig.paymentUrl`). По умолчанию указаны проект `cgvfhtvdtdjsyluhlcbq.supabase.co` и шлюз `levending.smartvend.kz`.

Перед первым запуском применить миграции в SQL Editor Supabase:
```sql
-- 1. Колонки + индексы для вендинга
\i supabase/migrations/20260428120000_vending_motor_columns.sql
-- 2. RLS политики для anon writes (необходимо для редактирования товаров с планшета)
\i supabase/migrations/20260428130000_inventory_anon_writes.sql
```

## Чек-лист установки на физический автомат

1. Собрать релизный APK (`flutter build apk --release`)
2. Установить на планшет (`flutter install` или ручное копирование APK)
3. Долгое нажатие «Домой» → выбрать «M109E Вендинг» → **Всегда** (приложение становится дефолтным лаунчером)
4. Опционально: `adb shell dpm set-device-owner kz.smartvend.m102_tester/.DeviceAdminReceiver` для жёсткого kiosk-режима (требует factory-reset)
5. В сервисном режиме сменить PIN с дефолтного `1234`
6. В Supabase создать запись `micromarkets` с `id` (число — будет machid) и `secret` (16 ASCII символов — appkey, выдаётся SmartVend)
7. На планшете ввести `id` + `secret` в окне пэйринга
8. В сервисе → «Товары и слоты» → привязать товары к моторам (44...99)
9. Положить иконку в `assets/icon/icon.png` (1024×1024 PNG) и запустить `dart run flutter_launcher_icons`

Полный план оставшихся доработок (отказо­устойчивость платежей, дашборд владельца, полировка клиентского UX) — в [docs/PRODUCTION_PLAN.md](docs/PRODUCTION_PLAN.md).
