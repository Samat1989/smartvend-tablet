# relay-test — прошивка проверки управления реле

Минимальная ESP-IDF прошивка (таргет **esp32**) для проверки управления платой реле
по USB-serial с ПК. Пины и последовательность взяты из реверса штатной прошивки
(см. `../../esp32_dump/RELAY_CONTROL.md`).

## Что внутри
- `main/relay_test.c` — принимает текстовые команды по UART0 (115200) и дёргает GPIO.
- `relay_ctl.py` — Python-скрипт на ПК (pyserial), шлёт команды и печатает ответы.

Реле **защёлкивающееся (bistable)**: `DIR` (IO2) задаёт направление, импульс 50 мс
на `PULSE` (IO16) перебрасывает реле, ток после не нужен.

- CH0: DIR=**IO2**, PULSE=**IO16** (подтверждено дампом)
- CH1: DIR=IO4, PULSE=IO17 — **предположение**, проверьте командами `g`/`p`.

## Команды прошивки
```
on   <ch>          защёлкнуть ВКЛ   (ch 0/1)
off  <ch>          защёлкнуть ВЫКЛ  (ch 0/1)
open <ch> <sec>    ВКЛ, держать <sec> секунд, ВЫКЛ      напр: open 0 10
g    <pin> <0|1>   выставить уровень любого GPIO (прозвонка)
p    <pin> <ms>    импульс HIGH на GPIO в течение <ms>
pins               показать пины каналов
help               справка
```

Аргументы — это **числа**, угловые скобки не печатать. Примеры: `open 0 10`, `on 0`, `g 2 1`.

## Сборка и прошивка
> ⚠️ Прошивка ПЕРЕЗАПИШЕТ штатную прошивку SmartVend. Полный бэкап уже снят:
> `esp32_dump/flash_full.bin`. Откат: `python -m esptool --port COM9 write-flash 0 esp32_dump/flash_full.bin`

```bash
# в окружении ESP-IDF (export.ps1 / export.sh)
cd firmware/relay-test
idf.py set-target esp32
idf.py -p COM9 build flash
```

## Проверка с ПК
```bash
pip install pyserial
# закрыть idf.py monitor, чтобы освободить COM9
python relay_ctl.py --port COM9                 # интерактивно
python relay_ctl.py --selftest --hold 3         # CH0: ВКЛ -> 3с -> ВЫКЛ
python relay_ctl.py -c "g 2 1"                   # сырой тест пина IO2
```

### Как найти пины CH1 (если не IO4/IO17)
Слушайте щелчки реле и перебирайте кандидатов сырыми командами:
```
p 4 200     # импульс на IO4
p 17 200
g 2 1       # IO2 высоко
g 2 0
```
Найдя рабочую пару DIR/PULSE — впишите в `CH1_DIR` / `CH1_PULSE` в `relay_test.c`.
