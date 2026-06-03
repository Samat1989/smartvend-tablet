# SmartVend — монорепо

Единый репозиторий продукта: приложения, прошивки и общий бэкенд Supabase
вокруг одного проекта Supabase `micromart`.

## Структура

```
apps/
  tablet/         Flutter — планшет вендинга со спиралями (плата M109E/M102,
                  моторные спирали через USB-Serial). Сам проводит Kaspi QR
                  оплату и крутит моторы. (ex-m102_tester)
  web_app/        Vite/React веб (деплой на Vercel) — два режима в одном коде:
                    • админка владельца (каталог, цены, остатки, продажи)
                    • витрина покупателя, открывается при скане статического QR
                      на static-QR машине
                  (ex-customer_web / admin)
  mmd_diag/       Flutter — диагностический клиент платы/устройства (ex-mmd)

firmware/
  esp-relay/      Прошивка ESP-реле для static-QR машин: слушает MQTT,
                  щёлкает реле → открывает электрозамок (ex-esp_relay_mart)

supabase/         ЕДИНЫЙ бэкенд проекта `micromart`
  migrations/     История схемы БД (SQL, по timestamp) — коммитим и пушим
  functions/      Edge-функции (оплаты, рефанды, cron)
  config.toml     Конфиг проекта Supabase

docs/             Документация и планы разработки
  refs/           Вендорские справочники (протоколы, API PDF)

tools/            Вспомогательные python-скрипты
release.ps1       Сборка/публикация APK планшета в GitHub Releases
```

Два типа продающих машин (vending со спиралями и static-QR с замком) и
платёжные потоки подробно описаны в
[docs/system_architecture.md](docs/system_architecture.md) и
[docs/machine-types-and-payment-flows.md](docs/machine-types-and-payment-flows.md).

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

- `apps/web_app` (Vercel): в настройках проекта Vercel выставить
  **Root Directory = `apps/web_app`**.
- `apps/tablet`: релиз через `release.ps1` (нужен `.github_token`, см. `.gitignore`).
