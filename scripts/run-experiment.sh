#!/usr/bin/env bash
# Corre UN experimento del loop v3 de Twoyi en GitHub Actions (o en local,
# con las mismas variables). Espejo del corredor local scripts/opt-run-v3.sh
# sin la cola, el lock ni el piso de RAM (el runner de Actions tiene 16 GB):
# prepara la copia del front-end, aplica el parche del detector y los
# parches de la config, levanta serve.py y corre el harness CDP.
# Uso: bash scripts/run-experiment.sh <EXP>   (p. ej. G1)
# Requisitos previos (los hace el workflow): mirror-v2/run.twoyi.app y
# mirror-v2/seed.twoyi.app descargados; TWOYI_CHROME_PATH con el Chrome.
# Salida: runs/<EXP>/ (summary.json, console.jsonl, status.jsonl,
# chrome.log, server.log, shots/). Exit 0 si el experimento produjo datos
# (summary.json existe); 1 si el servidor/preflight fallo o el harness no
# corrio. El exit del harness (0 boot, 1 timeout, 2 crash) queda en
# runs/<EXP>/harness-exit.txt y en summary.json: para G1 (humo de 2 min)
# el timeout es lo ESPERADO, el exito es la linea NEO_ENGINE requested=.
set -euo pipefail
EXP="${1:?falta id de experimento (G1..G9)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$ROOT/experiments-v3/$EXP/config.json"
[ -f "$CFG" ] || { echo "FALLO: no existe $CFG" >&2; exit 1; }
# G7/G9 piden una ROM reempaquetada (seed.copy): en Actions esas copias
# no existen todavia; fallar en voz alta en vez de correr con la ROM
# original y registrar un falso resultado de la palanca.
SEED_COPY=$(python3 -c "import json;print(json.load(open('$CFG')).get('seed',{}).get('copy',''))")
if [ -n "$SEED_COPY" ]; then
  echo "FALLO: $EXP pide seed.copy=$SEED_COPY, que no existe en este runner." >&2
  echo "Hay que construir la copia reempaquetada en el runner antes de correr $EXP (ver README-ACTIONS.md)." >&2
  exit 1
fi
[ -d "$ROOT/mirror-v2/run.twoyi.app" ] || { echo "FALLO: falta mirror-v2/run.twoyi.app (corre scripts/descargar-frontend.sh primero)" >&2; exit 1; }
[ -d "$ROOT/mirror-v2/seed.twoyi.app" ] || { echo "FALLO: falta mirror-v2/seed.twoyi.app (corre scripts/descargar-seed.sh primero)" >&2; exit 1; }

WORK="$ROOT/work/$EXP"
RUN_DIR="$ROOT/runs/$EXP"
rm -rf "$WORK" "$RUN_DIR"
mkdir -p "$WORK" "$RUN_DIR"
cp -r "$ROOT/mirror-v2/run.twoyi.app" "$WORK/run.twoyi.app"
ln -sfn "$ROOT/mirror-v2/seed.twoyi.app" "$WORK/seed.twoyi.app"

# Parche del detector (loop v3): watchFirstFrame 10% -> 2%. El 10% solo
# lo superaba el dialogo blanco de ANR; con 2% el canvas visible se
# detecta tambien en invitados rapidos.
python3 - "$WORK/run.twoyi.app/index.html" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8", errors="surrogateescape").read()
old = "if (lit > px.length / 40)"
new = "if (lit > px.length / 200)"
n = t.count(old)
print(f"DETECTOR: '{old}' aparece {n} vez/veces en index.html")
if n != 1:
    print("DETECTOR FALLO: se esperaba exactamente 1 (umbral 10% -> 2%)")
    sys.exit(1)
open(p, "w", encoding="utf-8", errors="surrogateescape").write(t.replace(old, new))
print("DETECTOR OK: umbral watchFirstFrame 10% -> 2% (px.length/40 -> /200)")
PY

python3 "$ROOT/scripts/opt-apply-patches.py" --front-dir "$WORK/run.twoyi.app" --config "$CFG"

PAGE=$(python3 -c "import json;print(json.load(open('$CFG')).get('page','/'))")
FLAGS=$(python3 -c "import json;print(json.load(open('$CFG')).get('chrome_flags',''))")
JSFLAGS=$(python3 -c "import json;print(json.load(open('$CFG')).get('js_flags',''))")
MINUTES=$(python3 -c "import json;print(json.load(open('$CFG')).get('minutes',20))")
STAY=$(python3 -c "import json;print(json.load(open('$CFG')).get('stay_after_boot',300))")
TAP=$(python3 -c "import json;print(json.load(open('$CFG')).get('tap_test',1))")
AOT_URL=$(python3 -c "import json; c=json.load(open('$ROOT/mirror-v2/run.twoyi.app/config.json')); u=c.get('aotUrls') or ([c['aotUrl']] if c.get('aotUrl') else []); print(u[0] if u else '')" || true)
[ -n "$AOT_URL" ] || { echo "FALLO: config.json descargado sin aotUrl" >&2; exit 1; }
echo "Experimento: $EXP (pagina $PAGE, flags: ${FLAGS:-ninguno}, minutos: $MINUTES, stay: ${STAY}s, tap: $TAP, aotUrl: $AOT_URL)"

python3 "$ROOT/scripts/serve.py" --port 8083 --root "$WORK" --aot-url "$AOT_URL" > "$RUN_DIR/server.log" 2>&1 &
SRV_PID=$!
trap 'kill $SRV_PID 2>/dev/null; wait $SRV_PID 2>/dev/null' EXIT
for i in $(seq 1 50); do
  if curl -sf http://127.0.0.1:8083/__health__ >/dev/null 2>&1; then break; fi
  sleep 0.2
done
if ! curl -sf http://127.0.0.1:8083/__health__ >/dev/null 2>&1; then
  echo "FALLO: el servidor no levanto en 8083" >&2
  exit 1
fi
# Pre-flight: config.json debe traer seedUrl local Y aotUrls local. Sin
# aotUrls el boot correria SIN el pack en silencio (aotPack() -> null).
python3 - "$AOT_URL" <<'PY'
import json, sys, urllib.request
aot_url = sys.argv[1]
cfg = json.load(urllib.request.urlopen("http://127.0.0.1:8083/config.json", timeout=5))
assert cfg.get("seedUrl", "").startswith("http://127.0.0.1:8083/seed/"), cfg
assert cfg.get("aotUrls") == [aot_url], cfg
print("CONFIG OK:", cfg)
PY
echo "Servidor levantado en :8083 (pid $SRV_PID)"

set +e
TWOYI_OUT="$RUN_DIR" TWOYI_PAGE="$PAGE" TWOYI_CHROME_FLAGS="$FLAGS" TWOYI_JS_FLAGS="$JSFLAGS" TWOYI_STAY_AFTER_BOOT="$STAY" TWOYI_TAP_TEST="$TAP" TWOYI_EXP="$EXP" \
  node "$ROOT/tests/twoyi-fullboot-cdp.mjs" http://127.0.0.1:8083 "$MINUTES"
HARNESS_EXIT=$?
set -e
echo "$HARNESS_EXIT" > "$RUN_DIR/harness-exit.txt"
echo "Harness termino con exit=$HARNESS_EXIT (0 boot, 1 timeout, 2 crash, 3 error)"
echo "--- NEO_ENGINE requested= (si existe) ---"
grep -h "NEO_ENGINE requested=" "$RUN_DIR/console.jsonl" | tail -2 || echo "SIN LINEA NEO_ENGINE requested= en console.jsonl"
echo "--- lineas NEO_AOT: $(grep -c 'NEO_AOT' "$RUN_DIR/console.jsonl" || true) ---"
if [ -f "$RUN_DIR/summary.json" ]; then
  echo "OK: experimento $EXP produjo datos en $RUN_DIR"
  exit 0
else
  echo "FALLO: el harness no produjo summary.json" >&2
  exit 1
fi
