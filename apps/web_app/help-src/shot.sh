#!/usr/bin/env bash
# Снимает экран подключённого планшета и кладёт кадр в инструкцию.
#
#   bash apps/web_app/help-src/shot.sh tablet-dispense
#
# Кадр уезжает в help-src/img-raw/<имя>.png (чистый исходник), после чего
# annotate.py перерисовывает public/help/img — с выносками, если для этого
# имени заданы координаты, и без них, если нет.
set -euo pipefail

ADB="${ADB:-$HOME/Android/Sdk/platform-tools/adb}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

name="${1:-}"
if [ -z "$name" ]; then
  echo "укажите имя кадра, например: bash $0 tablet-dispense" >&2
  exit 1
fi
name="${name%.png}"

"$ADB" exec-out screencap -p > "$HERE/img-raw/$name.png"
python3 "$HERE/annotate.py" >/dev/null
size=$(python3 - "$HERE/img-raw/$name.png" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read(33)
print('%dx%d' % struct.unpack('>II', d[16:24]))
PY
)
echo "$name.png — $size, лежит в img-raw и в public/help/img"
