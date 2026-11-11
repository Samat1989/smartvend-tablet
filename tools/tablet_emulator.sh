#!/usr/bin/env bash
# Создаёт (при необходимости) и запускает эмулятор, повторяющий планшет Shengma:
# Android 13 (API 33), 800x1280, 240 dpi, портрет.
# Использование: tools/tablet_emulator.sh [create|start]   (по умолчанию — start, создаёт при отсутствии)
set -euo pipefail

AVD_NAME="${AVD_NAME:-shengma_tab13}"
IMAGE="system-images;android-33;google_apis;x86_64"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
CMDLINE="$SDK/cmdline-tools/latest/bin"
AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"

# avdmanager требует Java; sdkmanager устарел и зависает — образ ставим через `android sdk install`
if ! command -v java >/dev/null 2>&1; then
  JDK="$(ls -d "$HOME"/.jdks/*/ 2>/dev/null | head -n1 || true)"
  [ -n "$JDK" ] && export JAVA_HOME="${JDK%/}" PATH="${JDK%/}/bin:$PATH"
fi
command -v java >/dev/null 2>&1 || { echo "Не найдена Java: задайте JAVA_HOME" >&2; exit 1; }

create() {
  if [ ! -d "$SDK/system-images/android-33/google_apis/x86_64" ]; then
    echo "Скачиваю образ $IMAGE (~1 ГБ)..."
    "$CMDLINE/android" sdk install "$IMAGE"
  fi
  echo no | "$CMDLINE/avdmanager" create avd -n "$AVD_NAME" -k "$IMAGE" -d pixel_c --force
  local cfg="$AVD_HOME/$AVD_NAME.avd/config.ini"
  sed -i '/^hw.lcd.\(width\|height\|density\)=/d;/^hw.keyboard=/d' "$cfg"
  printf 'hw.lcd.width=800\nhw.lcd.height=1280\nhw.lcd.density=240\nhw.keyboard=yes\n' >> "$cfg"
}

start() {
  [ -d "$AVD_HOME/$AVD_NAME.avd" ] || create
  exec "$SDK/emulator/emulator" -avd "$AVD_NAME" -no-snapshot
}

case "${1:-start}" in
  create) create ;;
  start)  start ;;
  *) echo "Использование: $0 [create|start]" >&2; exit 2 ;;
esac
