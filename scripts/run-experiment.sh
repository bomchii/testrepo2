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
# G7/G9 piden una ROM reempaquetada (seed.copy): las copias YA EXISTEN
# como assets en el release privado bomchii/resources (seed-v107-mod1.tar.gz
# y seed-v107-mod2.tar.gz); el workflow las descarga a mirror-v2/ antes de
# correr. Aqui solo se resuelve cual servir y se pasan los preboot gates
# (portados de scripts/opt-run-v3.sh del proyecto local): si un gate falla,
# el experimento NO corre con la ROM original ni registra un falso resultado.
SEED_COPY=$(python3 -c "import json;print(json.load(open('$CFG')).get('seed',{}).get('copy',''))")
[ -d "$ROOT/mirror-v2/run.twoyi.app" ] || { echo "FALLO: falta mirror-v2/run.twoyi.app (corre scripts/descargar-frontend.sh primero)" >&2; exit 1; }
[ -d "$ROOT/mirror-v2/seed.twoyi.app" ] || { echo "FALLO: falta mirror-v2/seed.twoyi.app (corre scripts/descargar-seed.sh primero)" >&2; exit 1; }

WORK="$ROOT/work/$EXP"
RUN_DIR="$ROOT/runs/$EXP"
rm -rf "$WORK" "$RUN_DIR"
mkdir -p "$WORK" "$RUN_DIR"
cp -r "$ROOT/mirror-v2/run.twoyi.app" "$WORK/run.twoyi.app"
# Servido del seed: por defecto mirror-v2/seed.twoyi.app (seed original
# v107); si la config trae seed.copy se sirve la COPIA descargada del
# release privado, con los preboot gates obligatorios: el sha del
# rom.tar.gz servido debe diferir del original y files/1182 debe contener
# cada linea del cambio. Si un gate falla, el script sale 1 y el
# experimento NO se registra como lever probado.
if [ -n "$SEED_COPY" ]; then
  case "$SEED_COPY" in
    mirror/seed-v107-mod1) SEED_DIR="$ROOT/mirror-v2/seed-v107-mod1" ;;
    mirror/seed-v107-mod2) SEED_DIR="$ROOT/mirror-v2/seed-v107-mod2" ;;
    *) echo "FALLO: seed.copy desconocida: $SEED_COPY" >&2; exit 1 ;;
  esac
  [ -d "$SEED_DIR" ] || { echo "FALLO: falta $SEED_DIR (el workflow debe descargar seed-modN desde resources antes de correr $EXP)" >&2; exit 1; }
  ln -sfn "$SEED_DIR" "$WORK/seed.twoyi.app"
  python3 - "$CFG" "$WORK" <<'PY'
import hashlib, json, os, re, sys, tarfile
cfg_path, work = sys.argv[1], sys.argv[2]
cfg = json.load(open(cfg_path))
seed = cfg.get("seed", {})
copy_rel = seed.get("copy", "")
orig_sha = "fd96c489a27d5fe027cbea43b6f1f02164f81d87c0a907d6711be03623e33e9d"
seed_dir = os.path.join(work, "seed.twoyi.app")
real = os.path.realpath(seed_dir)
print(f"GATE seed dir real: {real}")
if copy_rel and os.path.basename(copy_rel) not in real:
    print(f"GATE FAIL: el seed servido no es la copia {copy_rel}")
    sys.exit(1)
vers = [d for d in os.listdir(seed_dir) if os.path.isdir(os.path.join(seed_dir, d))]
if len(vers) != 1:
    print(f"GATE FAIL: versiones en el seed servido: {vers}")
    sys.exit(1)
tar = os.path.join(seed_dir, vers[0], "rom.tar.gz")
sha = hashlib.sha256(open(tar, "rb").read()).hexdigest()
print(f"GATE sha servido:  {sha}")
print(f"GATE sha original: {orig_sha}")
if sha == orig_sha:
    print("GATE FAIL: el rom.tar.gz servido es el ORIGINAL (stock)")
    sys.exit(1)
# Si la config trae el sha prebuilt de la copia, exigirlo exacto.
prebuilt_sha = (seed.get("prebuilt") or {}).get("rom_sha256", "")
if prebuilt_sha and sha != prebuilt_sha:
    print(f"GATE FAIL: sha servido != prebuilt de la config ({prebuilt_sha})")
    sys.exit(1)
for ch in seed.get("changes", []):
    m = re.search(r"'([^']+)'", ch.get("edit", ""))
    if not m:
        continue
    line = m.group(1)
    t = tarfile.open(tar)
    blob = t.extractfile(ch["blob"]).read()
    if (line + "\n").encode() not in blob:
        print(f"GATE FAIL: {ch['blob']} no contiene {line!r}")
        sys.exit(1)
    print(f"GATE OK: {ch['blob']} contiene {line!r} (x{blob.count(line.encode())})")
print("GATES DEL SEED OK")
PY
else
  ln -sfn "$ROOT/mirror-v2/seed.twoyi.app" "$WORK/seed.twoyi.app"
fi

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
# N3: imagen EROFS del sistema. La config trae "image": true; el workflow
# descarga system.erofs + image_fetch.js a mirror-v2/ (assets del release
# privado). Aqui se copian a la copia servida: la imagen a
# run.twoyi.app/image/v107.../system.erofs (serve.py la sirve por rangos
# como front) y el worker a run.twoyi.app/image_fetch.js (el glue lo carga
# con new URL("image_fetch.js", location.href); el tarball del front-end
# 5ff397fe NO lo trae). OJO: image_fetch.js es el del build ec4216c0
# (el del build pineado ya no esta en el sitio): si el protocolo del
# mailbox cambio entre builds, el boot fallara con IMAGE_FETCH y se vera.
IMAGE_URL=""
if [ "$(python3 -c "import json;print(json.load(open('$CFG')).get('image', False))")" = "True" ]; then
  IMG_SRC="$ROOT/mirror-v2/image/v107-gles-r1-f5a887c7/system.erofs"
  FETCH_SRC="$ROOT/mirror-v2/image_fetch.js"
  [ -f "$IMG_SRC" ] || { echo "FALLO: falta $IMG_SRC (el workflow debe descargar image desde resources antes de correr $EXP)" >&2; exit 1; }
  [ -f "$FETCH_SRC" ] || { echo "FALLO: falta $FETCH_SRC (el workflow debe descargar image desde resources antes de correr $EXP)" >&2; exit 1; }
  mkdir -p "$WORK/run.twoyi.app/image/v107-gles-r1-f5a887c7"
  cp "$IMG_SRC" "$WORK/run.twoyi.app/image/v107-gles-r1-f5a887c7/system.erofs"
  cp "$FETCH_SRC" "$WORK/run.twoyi.app/image_fetch.js"
  IMAGE_URL="http://127.0.0.1:8083/image/v107-gles-r1-f5a887c7/system.erofs"
  echo "Imagen EROFS: $IMG_SRC ($(du -h "$IMG_SRC" | cut -f1)) + image_fetch.js servidos"
fi
echo "Experimento: $EXP (pagina $PAGE, flags: ${FLAGS:-ninguno}, minutos: $MINUTES, stay: ${STAY}s, tap: $TAP, aotUrl: $AOT_URL${IMAGE_URL:+, imageUrl: $IMAGE_URL})"

python3 "$ROOT/scripts/serve.py" --port 8083 --root "$WORK" --aot-url "$AOT_URL" ${IMAGE_URL:+--image-url "$IMAGE_URL"} > "$RUN_DIR/server.log" 2>&1 &
SRV_PID=$!
# OJO: sin el `|| true`, el `wait` devuelve 143 (el servidor muere por
# SIGTERM) y el trap EXIT pisaria el exit 0 del script con 143: el job
# de Actions saldria "failure" aunque el experimento produjo datos.
trap 'kill $SRV_PID 2>/dev/null; wait $SRV_PID 2>/dev/null || true' EXIT
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
# Con imagen (N3) debe traer tambien imageUrl local.
python3 - "$AOT_URL" "$IMAGE_URL" <<'PY'
import json, sys, urllib.request
aot_url, image_url = sys.argv[1], sys.argv[2]
cfg = json.load(urllib.request.urlopen("http://127.0.0.1:8083/config.json", timeout=5))
assert cfg.get("seedUrl", "").startswith("http://127.0.0.1:8083/seed/"), cfg
assert cfg.get("aotUrls") == [aot_url], cfg
if image_url:
    assert cfg.get("imageUrl") == image_url, cfg
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
