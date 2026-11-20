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
**descargan en tiempo de ejecución** desde el sitio oficial (URLs
públicas, sin auth) y nunca se commitean (`mirror-v2/` está en
`.gitignore`). Los artefactos que sube el workflow son solo salidas del
harness (`summary.json`, `console.jsonl`, capturas PNG).

## Qué hay

| Ruta | Qué es |
|---|---|
| `.github/workflows/twoyi-boot.yml` | Workflow: checkout, Node 24, Chrome, caché del seed, descarga del front-end, experimento, verificación, artefactos |
| `tests/twoyi-fullboot-cdp.mjs` | Harness CDP (Chrome real, sin Playwright). La ruta de Chrome viene de `TWOYI_CHROME_PATH` |
| `scripts/serve.py` | Servidor local (COOP/COEP, rangos 206, reescribe `config.json` con seed/aot locales) |
| `scripts/opt-apply-patches.py` | Aplica los parches `{search, replace}` de la config al front-end |
| `scripts/descargar-frontend.sh` | Baja el front-end actual; verifica el SHA de `neo-web.wasm` contra el build `rt/1e56ecde9f337f28` |
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
  esas copias no existen en el runner. `run-experiment.sh` falla en voz
  alta en vez de correr con la ROM original. Hay que construir la copia
  en el runner antes (procedimiento en el informe `rom-build-prop.md`
  del proyecto local) o lanzar G7/G9 en local.
- **El SHA de `neo-web.wasm` está fijado** al build actual
  (`rt/16dba2d9d93b1a75`, wasm 11.217.644 B, SHA-256
  `7bfcf6f3…dce9dc3e`; pack AOT `/aot/ab41ad1ebf108da6.wasm`,
  75.031.139 B). `run.twoyi.app` redespliega a menudo (el build
  anterior, `rt/1e56ecde9f337f28`, ya da 404): si el SHA cambia,
  `descargar-frontend.sh` falla en voz alta y hay que actualizar el
  pin y revisar los parches de `experiments-v3/` antes de correr.
  `config.json` del build actual usa `aotUrls` (array); `serve.py`
  emite `aotUrl` y `aotUrls` en la config reescrita. `rt/bin/dalvikvm64`
  ya no lo sirve el sitio y nada lo descarga: la descarga es opcional.
- El front-end se descarga en cada corrida (~85 MB + pausas de 2 s por
  el rate-limit de Cloudflare); el seed va por `actions/cache`
  (key `seed-v107-fd96c489`, 10 GB por repo).
- Coste: repo público → Actions es gratuito e ilimitado en runners
  estándar. Cada corrida G1 ≈ 6-8 min; un boot completo ≈ 30 min.
