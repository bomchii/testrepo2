#!/usr/bin/env bash
# Descarga el front-end ACTUAL de run.twoyi.app (build con AOT + --jit)
# en mirror-v2/run.twoyi.app. SOLO descarga: no commitea nada (mirror-v2/
# esta en .gitignore; es codigo cerrado de Twoyi, nunca va al repo publico).
# neo-web.wasm se verifica contra el SHA del build contra el que se
# verificaron los parches de los experimentos (rt/5ff397fe8525b7d1): si
# cambia, se falla en voz alta en vez de correr experimentos sobre un
# build distinto.
# Pausas de 2 s entre peticiones (Cloudflare hace 429 tras ~10 rapidas).
# Uso: bash scripts/descargar-frontend.sh
set -euo pipefail
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
FRONT="mirror-v2/run.twoyi.app"
# Build contra el que se verificaron los parches de los experimentos G1-G9.
# OJO: run.twoyi.app redespliega a menudo (el build anterior,
# rt/16dba2d9d93b1a75, ya da 404); si el SHA cambia, se falla en voz alta
# y hay que revisar los parches antes de correr.
EXPECTED_WASM_SHA="cdcf0b76f0abe047e4cb12bf2f5725c08e5d8e5c9e4dd92e8c6fd01204cae99e"
EXPECTED_WASM_BYTES=11298874
mkdir -p "$FRONT/rt" "$FRONT/aot" "$FRONT"
get() { # get URL DESTINO (falla en voz alta con diagnostico)
  echo "GET $1 -> $2"
  if curl -sfL -A "$UA" -o "$2" "$1"; then
    sleep 2
    return 0
  fi
  echo "AVISO: curl fallo para $1; diagnostico (sin -f):" >&2
  curl -sL -A "$UA" -o /tmp/diag-body.txt -w "HTTP %{http_code} (url efectiva %{url_effective})\n" "$1" || true
  echo "--- cabeceras ---" >&2
  curl -sIL -A "$UA" "$1" | head -20 || true
  echo "--- cuerpo (primeros 500 B) ---" >&2
  head -c 500 /tmp/diag-body.txt || true
  echo >&2
  rm -f /tmp/diag-body.txt
  exit 1
}
get "https://run.twoyi.app/" "$FRONT/index.html"
RT=$(grep -oE 'rt/[0-9a-f]{16,64}/neo-web\.js' "$FRONT/index.html" | head -1 | cut -d/ -f2 || true)
[ -n "$RT" ] || { echo "FALLO: no se encontro el hash rt/ en index.html (redespliegue?)" >&2; exit 1; }
echo "Build rt/: $RT"
get "https://run.twoyi.app/config.json" "$FRONT/config.json"
# config.json del build nuevo: {seedUrl, aotUrls:[...]} (el formato viejo
# tenia aotUrl como cadena; se aceptan los dos, con prioridad al array).
AOT_URL=$(python3 -c "import json; c=json.load(open('$FRONT/config.json')); u=c.get('aotUrls') or ([c['aotUrl']] if c.get('aotUrl') else []); print(u[0] if u else '')" || true)
[ -n "$AOT_URL" ] || { echo "FALLO: config.json sin aotUrl" >&2; exit 1; }
echo "aotUrl: $AOT_URL"
get "https://run.twoyi.app/sw.js" "$FRONT/sw.js"
# download.js existia en el build 16dba pero el sitio ya no lo sirve
# (404 en rt/5ff397fe8525b7d1) y el index.html nuevo no lo referencia:
# descarga opcional, se sigue sin el.
if ! curl -sfL -A "$UA" -o "$FRONT/download.js" "https://run.twoyi.app/download.js"; then
  echo "AVISO: download.js no existe en este build (404); se sigue sin el"
  rm -f "$FRONT/download.js"
fi
get "https://run.twoyi.app/manifest.webmanifest" "$FRONT/manifest.webmanifest"
get "https://run.twoyi.app/icon.svg" "$FRONT/icon.svg"
get "https://run.twoyi.app/icon-192.png" "$FRONT/icon-192.png"
get "https://run.twoyi.app/icon-512.png" "$FRONT/icon-512.png"
get "https://run.twoyi.app/og-image.jpg" "$FRONT/og-image.jpg"
get "https://run.twoyi.app/robots.txt" "$FRONT/robots.txt"
get "https://run.twoyi.app/sitemap.xml" "$FRONT/sitemap.xml"
get "https://run.twoyi.app/warm.js" "$FRONT/warm.js"
mkdir -p "$FRONT/rt/$RT"
get "https://run.twoyi.app/rt/$RT/neo-web.js" "$FRONT/rt/$RT/neo-web.js"
get "https://run.twoyi.app/rt/$RT/neo-web.wasm" "$FRONT/rt/$RT/neo-web.wasm"
# rt/bin/dalvikvm64 existia en el build anterior pero el nuevo no lo
# sirve (404) y nada del front-end lo descarga (solo aparece como
# etiqueta de un boton y como ruta DENTRO del invitado). Descarga
# opcional: si vuelve a existir, se baja; si no, se sigue sin el.
if ! curl -sfL -A "$UA" -o "$FRONT/rt/bin/dalvikvm64" "https://run.twoyi.app/rt/bin/dalvikvm64"; then
  echo "AVISO: rt/bin/dalvikvm64 no existe en este build (404); se sigue sin el"
  rm -f "$FRONT/rt/bin/dalvikvm64"
fi
sleep 2
echo "--- pack AOT ---"
get "https://run.twoyi.app$AOT_URL" "$FRONT$AOT_URL"
echo "--- verificacion ---"
WASM_BYTES=$(stat -c%s "$FRONT/rt/$RT/neo-web.wasm")
WASM_SHA=$(sha256sum "$FRONT/rt/$RT/neo-web.wasm" | awk '{print $1}')
AOT_BYTES=$(stat -c%s "$FRONT$AOT_URL")
AOT_SHA=$(sha256sum "$FRONT$AOT_URL" | awk '{print $1}')
AOT_HASH_PREFIX=$(basename "$AOT_URL" .wasm)
echo "neo-web.wasm: $WASM_BYTES B sha256=$WASM_SHA"
echo "pack AOT ($AOT_URL): $AOT_BYTES B sha256=$AOT_SHA"
[ "$WASM_BYTES" = "$EXPECTED_WASM_BYTES" ] || { echo "AVISO: neo-web.wasm cambio de tamano (esperado $EXPECTED_WASM_BYTES)" >&2; }
if [ "$WASM_SHA" != "$EXPECTED_WASM_SHA" ]; then
  echo "FALLO: neo-web.wasm NO es el build rt/5ff397fe8525b7d1 contra el que se verificaron los parches." >&2
  echo "El sitio redesplego: hay que revisar los parches de experiments-v3/ antes de correr." >&2
  exit 1
fi
[ "$AOT_BYTES" -gt 1000000 ] || { echo "FALLO: pack AOT sospechosamente pequeno ($AOT_BYTES B)" >&2; exit 1; }
# El nombre del pack ES el prefijo de su SHA-256 (16 hex): verificacion
# autoconsistente que sobrevive a redespliegues.
[ "${AOT_SHA:0:16}" = "$AOT_HASH_PREFIX" ] || { echo "FALLO: el SHA del pack AOT no coincide con su nombre ($AOT_SHA vs $AOT_HASH_PREFIX)" >&2; exit 1; }
find "$FRONT" -type f | sort
du -sh mirror-v2
echo "OK: front-end descargado y verificado."
