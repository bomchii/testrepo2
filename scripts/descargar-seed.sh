#!/usr/bin/env bash
# Descarga el seed v107 de Twoyi Web (ROM Android 13) en
# mirror-v2/seed.twoyi.app/v107-gles-r1-f5a887c7/. Solo 5 archivos: el
# tar de la ROM (471 MB) + 4 manifiestos. El seed NO cambia (v107); este
# script se salta entero cuando actions/cache lo restaura (key seed-v107).
# El contenido es el mismo que sirve el espejo local (hash verificado).
# Uso: bash scripts/descargar-seed.sh [destino]
# (por defecto mirror-v2/seed.twoyi.app/v107-gles-r1-f5a887c7)
set -euo pipefail
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
SEED="https://seed.twoyi.app/v107-gles-r1-f5a887c7"
DEST="${1:-mirror-v2/seed.twoyi.app/v107-gles-r1-f5a887c7}"
EXPECTED_SHA="fd96c489a27d5fe027cbea43b6f1f02164f81d87c0a907d6711be03623e33e9d"
EXPECTED_BYTES=471289100
mkdir -p "$DEST"
for f in rom.json launch-env.json seed.index metadata.sqlite; do
  echo "GET $SEED/$f -> $DEST/$f"
  curl -sfL -A "$UA" -o "$DEST/$f" "$SEED/$f"
  sleep 2
done
echo "Descargando $SEED/rom.tar.gz -> $DEST/rom.tar.gz (reanudable, 3 reintentos)"
curl -L -C - --retry 3 --retry-delay 60 -A "$UA" -o "$DEST/rom.tar.gz" "$SEED/rom.tar.gz"
ACTUAL_BYTES=$(stat -c%s "$DEST/rom.tar.gz")
echo "Tamano descargado: $ACTUAL_BYTES (esperado $EXPECTED_BYTES)"
[ "$ACTUAL_BYTES" = "$EXPECTED_BYTES" ] || { echo "ERROR: tamano de rom.tar.gz no coincide" >&2; exit 1; }
ACTUAL_SHA=$(sha256sum "$DEST/rom.tar.gz" | awk '{print $1}')
echo "SHA esperado: $EXPECTED_SHA"
echo "SHA obtenido: $ACTUAL_SHA"
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || { echo "ERROR: el hash de rom.tar.gz NO coincide" >&2; exit 1; }
ls -la "$DEST"
echo "OK: seed v107 integro."
