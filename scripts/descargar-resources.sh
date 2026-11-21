#!/usr/bin/env bash
# Descarga el front-end, el seed o una ROM reempaquetada desde el release
# privado bomchii/resources (tag twoyi-v107) en vez del sitio oficial
# (que hace rate-limit 429).
# Uso: bash scripts/descargar-resources.sh frontend|seed|seed-mod1|seed-mod2
# Requiere GH_TOKEN en el entorno (en Actions: secrets.RESOURCES_TOKEN).
# Verifica el SHA del tarball y el SHA interno (wasm / ROM) antes de darlo
# por bueno; cualquier mismatch sale 1 sin dejar nada utilizable.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GH_TOKEN:?GH_TOKEN no definido (en Actions: secrets.RESOURCES_TOKEN)}"
TAG="twoyi-v107"
REPO="bomchii/resources"

KIND="${1:-}"
case "$KIND" in
  frontend)
    ASSET="frontend-rt-16dba2d9d93b1a75.tar.gz"
    SHA="5351827fb5087c42b749467e339a98845913f35ba937f65266a4acec1450e0cf"
    CHECK_FILE="mirror-v2/run.twoyi.app/rt/16dba2d9d93b1a75/neo-web.wasm"
    CHECK_SHA="7bfcf6f3fd987646c4195260b966a1e29df24f23971f1361f20947acdce9dc3e"
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
  *)
    echo "Uso: $0 frontend|seed|seed-mod1|seed-mod2" >&2
    exit 2
    ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
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
