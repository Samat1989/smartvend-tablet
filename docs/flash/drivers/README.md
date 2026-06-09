# Драйверы USB-UART для флешера

Кнопки на странице флешера (`../index.html`) ссылаются на **два файла в этой папке**.
Их нужно один раз скачать с официальных сайтов и положить сюда с точными именами:

| Чип | Имя файла (точно) | Откуда скачать |
|-----|-------------------|----------------|
| CP210x (Silicon Labs) | `CP210x.zip` | https://www.silabs.com/developers/usb-to-uart-bridge-vcp-drivers → «CP210x Universal Windows Driver» (zip) |
| CH340 / CH341 (WCH)   | `CH341SER.EXE` | https://www.wch-ic.com/downloads/CH341SER_EXE.html (кнопка Download) |

## Шаги
1. Скачайте оба файла по ссылкам выше.
2. Переименуйте/сохраните строго как `CP210x.zip` и `CH341SER.EXE` в этой папке
   (`docs/flash/drivers/`).
3. Закоммитьте и запушьте:
   ```powershell
   git add docs/flash/drivers
   git commit -m "web-flasher: add USB-UART drivers"
   git push
   ```
4. Через 1-2 минуты на странице флешера кнопки «CP210x» и «CH340/CH341» начнут
   скачивать эти файлы по клику.

## Почему файлы не в репозитории сразу
Это вендорские бинарники Silicon Labs / WCH — их кладёте вы вручную. Если не хотите
хранить их в git (≈8 МБ), можно вместо локальных файлов поменять ссылки в `index.html`
на официальные страницы загрузки — тогда папка `drivers/` не нужна.
