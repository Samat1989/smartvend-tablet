# scripts/

Релизные скрипты проекта. **Python 3, только stdlib, Linux.**

Заменяют четыре PowerShell-скрипта, которые лежали в корне до переезда с
Windows. Python, а не bash, потому что пайплайны — это в основном арифметика
версий и аккуратные правки `pubspec.yaml` / `main.c` по месту, то есть ровно
то, что на bash получается хрупко.

| Файл | Заменяет | Что делает |
|---|---|---|
| `release_tablet.py` | `apps/tablet/scripts/release.ps1` | Релиз APK планшета |
| `release_fw.py` | `release-pulse.ps1` + `release-relay.ps1` | Релиз прошивки ESP32 |
| `make_web_flasher.py` | `make-web-flasher.ps1` | Браузерный флешер в `docs/flash/` |
| `_common.py` | — | Общее: git, gh, версии, ESP-IDF env |

## Использование

```bash
# Планшет: авто-бамп patch, сборка, тег, публикация в Supabase + GitHub
python3 scripts/release_tablet.py
python3 scripts/release_tablet.py --version 1.2.0 --notes "Fixes X"
python3 scripts/release_tablet.py --skip-build --no-push --draft
python3 scripts/release_tablet.py --no-github      # после миграции парка

# Прошивки (ESP-IDF подхватывается сам, активировать вручную не нужно)
python3 scripts/release_fw.py pulse -m "Add periodic OTA check"
python3 scripts/release_fw.py relay -m "..." --version 1.2.0
python3 scripts/release_fw.py pulse -m "..." --dry-run     # ничего не меняет

# Браузерный флешер
python3 scripts/make_web_flasher.py --commit --push
```

У каждого скрипта `--help` с полной документацией.

## Куда публикуются обновления планшета

С версии, где `UpdateService` читает манифест, планшеты берут обновления из
**Supabase Storage**, а не из GitHub Releases. Раскладка в бакете `updates`:

```
updates/tablet/manifest.json + app-<version>-armeabi-v7a.apk
updates/pulse/manifest.json  + pulse-mart-<version>.bin      (когда дойдёт)
updates/relay/manifest.json  + relay-mart-<version>.bin      (когда дойдёт)
```

Каждый поток получает свой путь и свой манифест — в отличие от репозитория
GitHub, где все три делили одно пространство тегов, и разделять их
приходилось префиксами и белым списком в коде.

`release_tablet.py` по умолчанию публикует **и туда, и в GitHub Releases**.
Это не перестраховка: планшет в поле узнает про манифест только из сборки,
доставленной по старому каналу. Когда все аппараты переедут — `--no-github`,
и репозиторий можно закрывать.

## Требования

**Supabase.** Secret key (`sb_secret_...`) в `.supabase_key` в корне —
Dashboard → Project Settings → API Keys → Secret keys. Файл gitignored, ключ
даёт полный доступ к проекту, обращаться как с паролем. Можно передать через
`SUPABASE_SECRET_KEY`. Бакет создаётся скриптом при первом запуске.

**GitHub.** Достаточно `gh auth login` — токен в файле не нужен. Если когда-то
понадобится запускать релиз с машины без keyring, положи fine-grained PAT
(Contents: read+write) в `.github_token` в корне, скрипты его подхватят сами.

**Планшет.** Flutter SDK + два gitignored-файла, которые переносятся руками:

```
apps/tablet/android/release.jks         # keystore
apps/tablet/android/key.properties      # пароль к нему, см. key.properties.example
```

JDK нужен только для sanity-check подписи; без него проверка пропускается с
предупреждением и релиз не блокируется (`sudo apt install default-jdk`, если
хочется её включить).

**Прошивки.** Установленный ESP-IDF. Скрипт сам находит его (`IDF_PATH` или
`~/esp/*/esp-idf`), запускает `export.sh` в подпроцессе и берёт готовое
окружение — `get_idf` из старого PowerShell-профиля больше не нужен.

## Чем отличается от старых .ps1

- ESP-IDF подключается сам, вместо `get_idf`.
- Прошивочные релизы идут через `gh release create`, а не через ручной вызов
  GitHub REST API с PAT (`Invoke-RestMethod`) — минус ~60 строк.
- Убраны ~40 строк обходов бага PowerShell 5.1, где stderr от `git`/`gh`
  превращался в фатальную ошибку.
- Проверка подписи APK — предупреждение, а не hard fail.
- `git push` идёт в текущую ветку, а не жёстко в `main`.
