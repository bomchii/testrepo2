#!/usr/bin/env bash
# Descarga el front-end ACTUAL de run.twoyi.app (build con AOT + --jit)
# en mirror-v2/run.twoyi.app. SOLO descarga: no commitea nada (mirror-v2/
# esta en .gitignore; es codigo cerrado de Twoyi, nunca va al repo publico).
# El hash del build (rt/...) se extrae del index.html descargado, asi que
# un redespliegue del JS no rompe la descarga; pero neo-web.wasm se
# verifica contra el SHA del build contra el que se verificaron los
# parches de los experimentos (rt/1e56ecde9f337f28): si cambia, se falla
# en voz alta en vez de correr experimentos sobre un build distinto.
# Pausas de 2 s entre peticiones (Cloudflare hace 429 tras ~10 rapidas).
# Uso: bash scripts/descargar-frontend.sh
set -euo pipefail
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
FRONT="mirror-v2/run.twoyi.app"
# Build contra el que se verificaron los parches de los experimentos G1-G9.
EXPECTED_WASM_SHA="df818bf563ce59a0cbbdde279ed3ff8173af37e339e0358866655b3fa93569eb"
EXPECTED_WASM_BYTES=10960502
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
RT=$(grep -oE 'rt/[0-9a-f]{32}/neo-web\.js' "$FRONT/index.html" | head -1 | cut -d/ -f2)
[ -n "$RT" ] || { echo "FALLO: no se encontro el hash rt/ en index.html (redespliegue?)" >&2; exit 1; }
echo "Build rt/: $RT"
get "https://run.twoyi.app/config.json" "$FRONT/config.json"
AOT_URL=$(python3 -c "import json;print(json.load(open('$FRONT/config.json')).get('aotUrl',''))")
[ -n "$AOT_URL" ] || { echo "FALLO: config.json sin aotUrl" >&2; exit 1; }
echo "aotUrl: $AOT_URL"
get "https://run.twoyi.app/sw.js" "$FRONT/sw.js"
get "https://run.twoyi.app/download.js" "$FRONT/download.js"
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
get "https://run.twoyi.app/rt/bin/dalvikvm64" "$FRONT/rt/bin/dalvikvm64"
echo "--- pack AOT ---"
get "https://run.twoyi.app$AOT_URL" "$FRONT$AOT_URL"
echo "--- verificacion ---"
WASM_BYTES=$(stat -c%s "$FRONT/rt/$RT/neo-web.wasm")
WASM_SHA=$(sha256sum "$FRONT/rt/$RT/neo-web.wasm" | awk '{print $1}')
AOT_BYTES=$(stat -c%s "$FRONT$AOT_URL")
echo "neo-web.wasm: $WASM_BYTES B sha256=$WASM_SHA"
echo "pack AOT ($AOT_URL): $AOT_BYTES B"
[ "$WASM_BYTES" = "$EXPECTED_WASM_BYTES" ] || { echo "AVISO: neo-web.wasm cambio de tamano (esperado $EXPECTED_WASM_BYTES)" >&2; }
if [ "$WASM_SHA" != "$EXPECTED_WASM_SHA" ]; then
  echo "FALLO: neo-web.wasm NO es el build rt/1e56ecde9f337f28 contra el que se verificaron los parches." >&2
  echo "El sitio redesplego: hay que revisar los parches de experiments-v3/ antes de correr." >&2
  exit 1
fi
[ "$AOT_BYTES" -gt 1000000 ] || { echo "FALLO: pack AOT sospechosamente pequeno ($AOT_BYTES B)" >&2; exit 1; }
find "$FRONT" -type f | sort
du -sh mirror-v2
echo "OK: front-end descargado y verificado."
