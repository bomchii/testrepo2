# Twoyi Web — loop v3 en GitHub Actions

Corre los experimentos del loop v3 (hacer **usable** Android 13 en el
navegador) en un runner GitHub-hosted en vez de en la VM local, que está
bloqueada por RAM (el host se come ~6,3 GB; libre ~550-650 MB; un boot
pica ~4,6 GB). El runner público (`ubuntu-latest`) tiene **4 vCPU,
16 GB RAM, 14 GB SSD** y es una VM nueva en cada corrida.

## Regla dura — nada de código de Twoyi en este repo

Este repo lleva **solo nuestro código**: el harness CDP, el servidor
`serve.py`, el aplicador de parches, las configs de experimentos G1–G9,
los scripts de descarga y el workflow YAML. El front-end
(`run.twoyi.app`, build con pack AOT) y la ROM (seed v107, 471 MB) se
**descargan en tiempo de ejecución** desde el release privado
`bomchii/resources` (o se restauran del cache de Actions) y nunca se
commitean (`mirror-v2/` está en `.gitignore`). Los artefactos que sube el workflow son solo salidas del
harness (`summary.json`, `console.jsonl`, capturas PNG).

## Qué hay

| Ruta | Qué es |
|---|---|
| `.github/workflows/twoyi-boot.yml` | Workflow: checkout, Node 24, Chrome, caché del seed y del front-end, descarga desde el release privado solo si no hay cache, experimento, verificación, artefactos |
| `scripts/descargar-resources.sh` | Baja el front-end o el seed desde el release privado `bomchii/resources` (tag `twoyi-v107`) con `GH_TOKEN`; verifica el SHA del tarball y el SHA interno (wasm / ROM) antes de extraer |
| `frontend-pin.txt` | Hash del build `rt/` que prueba el loop (hoy `5ff397fe8525b7d1`); es la clave del cache del front-end. Cambiarlo = descargar el build nuevo una vez y re-cachearlo |
| `tests/twoyi-fullboot-cdp.mjs` | Harness CDP (Chrome real, sin Playwright). La ruta de Chrome viene de `TWOYI_CHROME_PATH` |
| `scripts/serve.py` | Servidor local (COOP/COEP, rangos 206, reescribe `config.json` con seed/aot locales) |
| `scripts/opt-apply-patches.py` | Aplica los parches `{search, replace}` de la config al front-end |
| `scripts/descargar-frontend.sh` | Baja el front-end actual; verifica el SHA de `neo-web.wasm` contra el build pineado (`rt/5ff397fe8525b7d1`) |
| `scripts/descargar-seed.sh` | Baja el seed v107 (5 archivos, SHA verificado) |
| `scripts/run-experiment.sh` | Corre un experimento: copia el front-end, parche del detector (10% → 2%), parches de la config, servidor, harness |
| `experiments-v3/G1..G9/config.json` | Configs del loop v3 (misma cola que el loop local) |

## Lanzar un experimento (desde el agente del loop v3)

El PAT cifrado está en `~/workspace/user/files/.token-store/`; el helper
`~/workspace/user/files/token-helper.sh __askpass` lo descifra a stdout.
Nunca imprimirlo ni escribirlo en archivos.

```bash
export GH_TOKEN="$(~/workspace/user/files/token-helper.sh __askpass)"

# Lanzar (G1 = humo de 2 min; los demás = boot + stay 300 s + toque)
gh workflow run twoyi-boot.yml --repo bomchii/testrepo2 -f experiment=G1

# Esperar a que termine (~6-8 min para G1; ~30 min para un boot completo)
gh run watch --repo bomchii/testrepo2 $(gh run list --repo bomchii/testrepo2 --workflow twoyi-boot.yml --limit 1 --json databaseId -q '.[0].databaseId')

# Bajar los artefactos (summary, consola, capturas, logs)
mkdir -p /tmp/g1 && gh run download --repo bomchii/testrepo2 <RUN_ID> -n G1-resultados -D /tmp/g1
```

## Leer el resultado del G1 (humo)

Lo que importa es la línea `NEO_ENGINE requested=` en `console.jsonl`
(los primeros ~15 s tras pulsar Start) y las líneas `NEO_AOT`:

```bash
grep "NEO_ENGINE requested=" /tmp/g1/console.jsonl
grep -c "NEO_AOT" /tmp/g1/console.jsonl
python3 -c "import json; s=json.load(open('/tmp/g1/summary.json')); print(s.get('engineRequested')); print(s.get('engineStatsLast')); print(s.get('aotLines'))"
```

- **Éxito del humo**: `aot_modules > 0` en la línea `requested=` (el pack
  AOT real llega al motor; en el build viejo F1 dio `aot=1` pero
  `aot_modules=0`) + líneas `NEO_AOT` del warm.
- **Fallo**: sin línea `requested=` → el motor no arrancó o el servido
  falló (el paso de verificación del workflow ya falla en ese caso).
- Para G1 el `harness-exit.txt = 1` (timeout) es lo **esperado**: 2 min
  no dan para bootear; el humo solo verifica los flags.

Para un boot completo (G2+), el `summary.json` trae `booted`, `crashed`,
`guestRatio`, `guestMaxS`, `wasmPeakMB`, `chromeRssPeakMB`,
`engineStatsLast` y `aotLines`; las capturas en `shots/` muestran la
pantalla (el ANR se dictamina mirando la última foto).

## Limitaciones conocidas

- **G7 y G9 piden una ROM reempaquetada** (`seed.copy` en su config):
  las copias YA EXISTEN como assets del release privado
  `bomchii/resources` (tag `twoyi-v107`): `seed-v107-mod1.tar.gz`
  (G7, `ro.hw_timeout_multiplier=5`, rom sha `7c411366…`) y
  `seed-v107-mod2.tar.gz` (G9, tanda RAM, rom sha ver en
  `experiments-v3/G9/config.json` → `seed.prebuilt.rom_sha256`). El
  workflow las descarga solo cuando toca ese experimento
  (`descargar-resources.sh seed-mod1|seed-mod2`, con cache de Actions
  por sha) y `run-experiment.sh` sirve la copia con los preboot gates
  portados del corredor local (sha ≠ original + cada línea del cambio
  presente en `files/1182`); si un gate falla, el experimento no corre
  ni se registra como lever probado. Para crear una copia nueva (mod3…):
  construirla en local con el procedimiento de `rom-build-prop.md` §8
  (igual que `build-seed-mod2.sh`), empaquetarla como
  `seed-v107-modN.tar.gz` (top-level `seed-v107-modN/`), subirla al
  release, añadir el kind en `descargar-resources.sh`, los tres pasos
  condicionales en el workflow y el `prebuilt` en su config.
- **El SHA de `neo-web.wasm` está fijado** al build actual
  (`rt/5ff397fe8525b7d1`, wasm 11.298.874 B, SHA-256
  `cdcf0b76…cae99e`; pack AOT `/aot/ab41ad1ebf108da6.wasm`,
  75.031.139 B, mismo pack que el build anterior). `run.twoyi.app` redespliega a menudo (el build
  anterior, `rt/16dba2d9d93b1a75`, ya da 404): si el SHA cambia,
  `descargar-frontend.sh` falla en voz alta y hay que actualizar el
  pin y revisar los parches de `experiments-v3/` antes de correr.
  `config.json` del build actual usa `aotUrls` (array); `serve.py`
  emite `aotUrl` y `aotUrls` en la config reescrita. `rt/bin/dalvikvm64`
  ya no lo sirve el sitio y nada lo descarga: la descarga es opcional.
- **Ni el front-end ni el seed se descargan del sitio en las corridas**:
  van por `actions/cache` (keys `frontend-<hash de frontend-pin.txt>` y
  `seed-v107-fd96c489`) y, en cache-miss, se bajan del release privado
  `bomchii/resources` (tag `twoyi-v107`) con `scripts/descargar-resources.sh`
  y el token secreto `RESOURCES_TOKEN` — cero peticiones a
  `run.twoyi.app` / `seed.twoyi.app`, así que el rate-limit 429 de
  Cloudflare ya no puede tumbar una corrida. El save del cache es un
  paso explícito tras la descarga para que un archivo parcial o con
  SHA incorrecto nunca quede cacheado. El `GITHUB_TOKEN` por defecto
  solo ve `testrepo2`, por eso el workflow usa `RESOURCES_TOKEN` (un
  PAT con lectura sobre `bomchii/resources`, guardado como secreto
  del repo). Para adoptar un build nuevo del sitio: bajarlo con
  `scripts/descargar-frontend.sh` (actualizando `EXPECTED_WASM_SHA`),
  empaquetarlo en `frontend-rt-<hash>.tar.gz`, subirlo como asset al
  release `twoyi-v107` de `resources`, actualizar `frontend-pin.txt` +
  el SHA del tarball en `descargar-resources.sh`, y revisar los parches
  de `experiments-v3/`. Un redespliegue del sitio ya no rompe el loop:
  se sigue probando el build pineado.
- Coste: repo público → Actions es gratuito e ilimitado en runners
  estándar. Cada corrida G1 ≈ 6-8 min; un boot completo ≈ 30 min.
