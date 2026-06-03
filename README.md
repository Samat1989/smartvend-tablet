# SmartVend — монорепо

Единый репозиторий продукта: приложения, прошивки и общий бэкенд Supabase
вокруг одного проекта Supabase `micromart`.

## Структура

```
apps/
  tablet/         Flutter — приложение планшета вендинга (основное, ex-m102_tester)
  admin/         Vite/TS веб — админка (деплой на Vercel, ex-customer_web)
  pos/            Android/Kotlin — POS-приложение
  provisioning/   Flutter — провижининг QR устройств
  mmd/            Flutter — клиент платы/устройства
  customer-qr/    (план) static QR веб для телефона клиента

firmware/
  esp-relay/      Прошивка ESP реле (ex-esp_relay_mart)

supabase/         ЕДИНЫЙ бэкенд проекта `micromart`
  migrations/     История схемы БД (SQL, по timestamp) — коммитим и пушим
  functions/      Edge-функции (оплаты, рефанды, cron)
  config.toml     Конфиг проекта Supabase

docs/             Документация и планы разработки
  refs/           Вендорские справочники (протоколы, API PDF)

tools/            Вспомогательные python-скрипты
hardware/         3D-модели и аппаратные файлы
release.ps1       Сборка/публикация APK планшета в GitHub Releases
```

## Supabase

- Сама БД и данные живут **в облаке** Supabase (проект `micromart`), не в репозитории.
- В репозитории — только исходники бэкенда: `migrations/`, `functions/`, `config.toml`.
  Их **нужно** коммитить и пушить (миграции = версионирование схемы).
- Секреты (`.env`, service_role, токены) — НЕ коммитим (см. `.gitignore`).

## Не в этом репозитории

- Старый прототип `micromarket_app` — в архиве (`C:\_archive\micromarket_backup_*.tar.gz`).
- Reverse-engineering сторонней прошивки/APK (apktool, jadx, дампы) — в
  `C:\_archive\research\` (не продукт, copyright-encumbered, не пушить).

## Деплой-заметки

- `apps/admin` (Vercel): после переезда в монорепо в настройках проекта Vercel
  нужно выставить **Root Directory = `apps/admin`**.
- `apps/tablet`: релиз через `release.ps1` (нужен `.github_token`, см. `.gitignore`).
