# SmartVend — монорепо

Приложения, прошивки и общий бэкенд Supabase вокруг одного проекта `micromart`.
Подробности: [README.md](README.md), [docs/system_architecture.md](docs/system_architecture.md).

## Два типа машин (не смешивать)

1. **Vending (моторный)** — спирали на плате M109E/M102, внутри планшет (`apps/tablet`), платёж и выдачу проводит сам планшет.
2. **Static-QR micromart** — полка/холодильник с электрозамком, без планшета; покупатель платит в веб-витрине, замок открывает бэкенд.

Потоки оплаты намеренно разделены: их объединение раньше приводило к незакрытым платежам. См. [docs/machine-types-and-payment-flows.md](docs/machine-types-and-payment-flows.md).

## Структура

- `apps/tablet` — Flutter, планшет вендинга (USB-Serial RS485, Kaspi QR, климат, сервисный режим).
- `apps/web_app` — Vite/React (Vercel): админка владельца + витрина покупателя. Инструкция `/help` — `src/help/` (markdown, 3 языка).
- `apps/mmd_diag` — Flutter, диагностика платы.
- `firmware/esp-rt` — новая прошивка замка (Supabase Realtime, Presence). `esp-relay` / `esp-pulse` — старые MQTT-прошивки, работают на своих аппаратах, не ломать.
- `supabase/` — `migrations/`, `functions/` (edge-функции, общий код в `_shared/`), `config.toml`.
- `scripts/` — релизные Python-скрипты (см. `scripts/README.md`); `tools/` — вспомогательные; `docs/` — документация, `docs/refs/` — вендорские справочники.

## Команды

- web_app (из `apps/web_app`): `npm run dev`, `npm run build`, `npm run lint`.
- Flutter-приложения (из `apps/tablet`, `apps/mmd_diag`): `flutter pub get`, `flutter analyze`, `flutter test`.
- Релиз планшета: `python3 scripts/release_tablet.py` (нужен `gh`, подпись — `apps/tablet/android/README_RELEASE_SIGNING.md`).
- Прошивка esp-rt: `firmware/esp-rt/build-pulse.sh`, `build-relay.sh`; публикация — `scripts/publish_esp_rt.py`, `scripts/release_fw.py`.

## Правила

- БД и данные живут в облаке; в git только `supabase/migrations` и `supabase/functions` — их коммитим.
- Не коммитить: секреты, `.env`, service_role, keystore, `*.apk`, декомпилированные исходники заводского APK (`snack_jadx/`, `snack_apktool/`).
- Секреты платёжных провайдеров и устройств — только в окружении Supabase, не в коде.

## Стиль

- Документация, комментарии и коммиты — на русском.
- Коммиты: `область: описание` (`tablet: …`, `esp-rt 1.1.6: …`, `web_app: …`); версии — `Bump version to X.Y.Z+N`.

## Куда смотреть

- [docs/known-issues.md](docs/known-issues.md), [docs/security-audit-2026-06.md](docs/security-audit-2026-06.md)
- [docs/tablet-micromarket.md](docs/tablet-micromarket.md), [docs/odengi-payment-kg.md](docs/odengi-payment-kg.md)
- [firmware/esp-rt/README.md](firmware/esp-rt/README.md), [apps/tablet/README.md](apps/tablet/README.md)
