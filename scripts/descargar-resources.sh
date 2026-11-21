#!/usr/bin/env bash
# Descarga el front-end, el seed o una ROM reempaquetada desde el release
# privado bomchii/resources (tag twoyi-v107) en vez del sitio oficial
# (que hace rate-limit 429).
# Uso: bash scripts/descargar-resources.sh frontend|seed|seed-mod1|seed-mod2|image
# Requiere GH_TOKEN en el entorno (en Actions: secrets.RESOURCES_TOKEN).
# Verifica el SHA del tarball y el SHA interno (wasm / ROM) antes de darlo
# por bueno; cualquier mismatch sale 1 sin dejar nada utilizable.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GH_TOKEN:?GH_TOKEN no definido (en Actions: secrets.RESOURCES_TOKEN)}"
TAG="twoyi-v107"
REPO="bomchii/resources"

# TMP antes del case: el caso `image` sale con exit 0 dentro del case y el
# trap EXIT usa $TMP (con set -u fallaria si aun no estuviera definido).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KIND="${1:-}"
case "$KIND" in
  frontend)
    ASSET="frontend-rt-5ff397fe8525b7d1.tar.gz"
    SHA="33b1fb17cf0cca7f5c84a037b7e991faab0a68bdc2b705653d34681eb4b9c438"
    CHECK_FILE="mirror-v2/run.twoyi.app/rt/5ff397fe8525b7d1/neo-web.wasm"
    CHECK_SHA="cdcf0b76f0abe047e4cb12bf2f5725c08e5d8e5c9e4dd92e8c6fd01204cae99e"
    ;;
  seed)
    ASSET="seed-v107.tar.gz"
    SHA="de2ec6ac29b9edb8ef0b10bbdeb639dc57151d3f8e9899dee8ebae13e92ad31d"
    CHECK_FILE="mirror-v2/seed.twoyi.app/v107-gles-r1-f5a887c7/rom.tar.gz"
    CHECK_SHA="fd96c489a27d5fe027cbea43b6f1f02164f81d87c0a907d6711be03623e33e9d"
    ;;
  seed-mod1)
    # G7: ROM con ro.hw_timeout_multiplier=5 (build.prop 4902 -> 4929 B).
    ASSET="seed-v107-mod1.tar.gz"
    SHA="2aea370e1c7dff6be33c93c51461a4b518fbc993077c67cfca759acd746d82b0"
    CHECK_FILE="mirror-v2/seed-v107-mod1/v107-gles-r1-f5a887c7/rom.tar.gz"
    CHECK_SHA="7c41136646017717e8df9bbb662d847e20f42851ade64438fd0899a76a9a9c55"
    ;;
  seed-mod2)
    # G9: ROM tanda RAM (low_ram + lmk Go + heap ART; build.prop 4902 -> 5110 B).
    ASSET="seed-v107-mod2.tar.gz"
    SHA="f7c2b0efcf7586e72650d03b44e2507017421d1e4b39970f7f0855c2b06a20d9"
    CHECK_FILE="mirror-v2/seed-v107-mod2/v107-gles-r1-f5a887c7/rom.tar.gz"
    CHECK_SHA="30ad0d134b5b52ea89a91599e52d733e6bba40ff3814a126d0c9f4d365805a30"
    ;;
  image)
    # N3: imagen EROFS del sistema (system.erofs 1.110.261.760 B, raw SHA
    # 3726687b...; en el release va el .gz, 471.439.944 B, SHA 7797ced6...)
    # + image_fetch.js del build ec4216c0 (el worker que sirve los bloques
    # de 1 MiB por rangos; el tarball del front-end 5ff397fe NO lo trae).
    # El .gz se descomprime en local; la verificacion es el tamano raw,
    # la magia EROFS (e2e1f5e0 en el offset 1024) y el SHA raw.
    mkdir -p mirror-v2/image/v107-gles-r1-f5a887c7
    gh release download "$TAG" --repo "$REPO" --pattern "system-erofs-v107.gz" --dir "$TMP"
    ACTUAL="$(sha256sum "$TMP/system-erofs-v107.gz" | awk '{print $1}')"
    [ "$ACTUAL" = "7797ced65dfd6bc92bcca18213923f6e77ccf6c881e543e7e29cabaf2fb37fab" ] \
      || { echo "ERROR: SHA del system.erofs.gz no coincide: $ACTUAL" >&2; exit 1; }
    gh release download "$TAG" --repo "$REPO" --pattern "image_fetch-ec4216c0.js" --dir "$TMP"
    ACTUAL="$(sha256sum "$TMP/image_fetch-ec4216c0.js" | awk '{print $1}')"
    [ "$ACTUAL" = "f2caf4fe553fae033dbe07c93ea9ff8504518845c71807cd4d9c010db021ed48" ] \
      || { echo "ERROR: SHA de image_fetch.js no coincide: $ACTUAL" >&2; exit 1; }
    cp "$TMP/image_fetch-ec4216c0.js" mirror-v2/image_fetch.js
    gzip -dc "$TMP/system-erofs-v107.gz" > mirror-v2/image/v107-gles-r1-f5a887c7/system.erofs
    python3 - <<'PY'
import hashlib
p = "mirror-v2/image/v107-gles-r1-f5a887c7/system.erofs"
d = open(p, "rb")
magic = d.read(2048)[1024:1028]
assert magic == bytes.fromhex("e2e1f5e0"), f"magia EROFS no coincide: {magic.hex()}"
d.seek(0)
h = hashlib.sha256()
n = 0
while True:
    b = d.read(1 << 22)
    if not b:
        break
    h.update(b)
    n += len(b)
assert n == 1110261760, f"tamano raw inesperado: {n}"
assert h.hexdigest() == "3726687b2ede14fdc9ea636647848caeb3044bb7fa538abd60104a4488a89bd7", \
    f"SHA raw no coincide: {h.hexdigest()}"
print(f"OK: system.erofs {n} B, magia EROFS, SHA raw verificado.")
PY
    echo "OK: image descargado desde resources y verificado."
    exit 0
    ;;
  *)
    echo "Uso: $0 frontend|seed|seed-mod1|seed-mod2|image" >&2
    exit 2
    ;;
esac

echo "GET $REPO@$TAG -> $ASSET"
gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --dir "$TMP"
ACTUAL="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"
[ "$ACTUAL" = "$SHA" ] || { echo "ERROR: SHA del tarball no coincide: $ACTUAL != $SHA" >&2; exit 1; }
mkdir -p mirror-v2
# --no-same-owner: el tarball guarda uid/gid de donde se empaqueto y en un
# contenedor sin CAP_CHOWN la extraccion falla al intentar restaurarlos.
tar --no-same-owner -xzf "$TMP/$ASSET" -C mirror-v2
ACTUAL2="$(sha256sum "$CHECK_FILE" | awk '{print $1}')"
[ "$ACTUAL2" = "$CHECK_SHA" ] || { echo "ERROR: SHA de $CHECK_FILE no coincide: $ACTUAL2 != $CHECK_SHA" >&2; exit 1; }
echo "OK: $KIND descargado desde resources y verificado."
