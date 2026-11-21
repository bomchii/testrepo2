# v64 — Android 16 en WASM, smoke en GitHub Actions

Plan B de Twoyi: medir si Android 16 arranca en v64 (speedyHKjournalist/v64)
en un runner GitHub-hosted (4 vCPU, 16 GB RAM), donde sí cabe la RAM que la
VM local no tiene.

## Workflow

`.github/workflows/v64-boot.yml` (solo `workflow_dispatch`, separado de
`twoyi-boot.yml`; el loop v3 no se toca):

1. Clona `speedyHKjournalist/v64 @ 6448e1f` en el runner. El código de v64
   **nunca** se commitea en testrepo2: solo este workflow y este README.
2. Toolchain: Node 24, rustc stable + `wasm32-unknown-unknown`, clang,
   nasm, OpenJDK 21 (Closure Compiler), unzip, python3.
3. `npm ci`, `make all` (x86 + libv86 + glbridge), `make
   build/v86-arm64.wasm build/v86-arm64-parallel.wasm`.
4. `node tools/a64_android.mjs --download`: baja la imagen Cuttlefish
   aosp_cf_arm64_only_phone 15581820 de ci.android.com (~1,06 GB, SHA-256
   + MD5 verificados por el script) y produce `build/a64-android/out/`
   (Image, initrd.img, disk.img disperso de 17,5 GB lógicos).
5. Smoke: `A64_ANDROID_TARGET=v86 A64_JIT=1 A64_PARALLEL=1 A64_CORES=4
   A64_ANDROID_WAIT=boot_completed A64_ANDROID_TIMEOUT=2700000 node
   tests/a64/android_boot.mjs` — sin Venus (SwiftShader en el invitado,
   sin Chrome). `A64_ANDROID_WAIT=boot_completed` es obligatorio: sin él
   el harness pasa en cuanto responde adbd, antes del boot completado.

## Lanzar

```bash
export GH_TOKEN="$(~/workspace/user/files/token-helper.sh __askpass)"
gh workflow run v64-boot.yml --repo bomchii/testrepo2
gh run watch --repo bomchii/testrepo2 $(gh run list --repo bomchii/testrepo2 --workflow v64-boot.yml --limit 1 --json databaseId -q '.[0].databaseId')
mkdir -p /tmp/v64 && gh run download --repo bomchii/testrepo2 <RUN_ID> -n v64-smoke -D /tmp/v64
```

## Leer el resultado

`build/a64-android/runs/v86-jit-par-1536m-4c/result.json` trae `marks`
(tiempos de cada hito: `boot_completed_adb` es el boot), `ms` total y
`metrics.max_rss_mib` (RSS pico del proceso Node en MiB). El job también
imprime el resumen en el log. `A64_ANDROID_BOOT_OK v86-jit-par-1536m-4c`
en el log = boot completado.

## Veredicto (condición de parada)

Cold boot > ~40 min o RSS > 6 GB → abandonar v64 como plan B. Referencias:
en un Mac, v64 tarda ~20 min en arrancar Android 16 con pico de RSS
4,9–5,9 GB; neo en la VM pobre bootea en ~4–5 min con RSS ~4,5 GB.
