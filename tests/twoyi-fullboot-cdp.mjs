// Arranque COMPLETO de Android 13 en Chromium real (CDP, sin Playwright).
// Objetivo: probar si la VM aguanta el boot entero, con LOGS y CRASHLOGS
// para ver que se puede mejorar.
//   - Descarga del ROM (471 MB, rangos 206) + desempaquetado (1,09 GB)
//     en Cache Storage, luego init -> system_server -> SurfaceFlinger.
//   - Todo queda en tests/fullboot/:
//       console.jsonl   consola + pageerror + excepciones (con timestamp)
//       server.log      log de scripts/serve.py (cada peticion + rangos)
//       chrome.log      stderr de Chrome (errores, crashes, OOM)
//       status.jsonl    cada 10 s: texto de la pagina, RAM, RSS de Chrome,
//                       estado del SW, claves de Cache Storage
//       shots/shot-*.png  captura cada 30 s
//       crash/          si Chrome vuelca algo (Crashpad, dmesg OOM)
//       summary.json    resumen final al terminar
//   - Timeout: 15 min por defecto. No es un test con PASS/FAIL duro:
//     el exito es "pantalla de Android visible"; si no llega, el
//     resumen dice hasta donde llego y por que (cuota, OOM, crash,
//     timeout, error de la pagina).
// Uso:
//   node tests/twoyi-fullboot-cdp.mjs [http://127.0.0.1:8080] [minutos]
//   # sale 0 si Android arranco (canvas + texto de inicio), 1 si no,
//   # 2 si hubo crash de Chrome/pagina. Los logs quedan en tests/fullboot/.
import { spawn, execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const BASE = process.argv[2] || 'http://127.0.0.1:8080';
const MINUTES = parseFloat(process.argv[3] || '15');
// Variables de entorno para el corredor de optimizacion (scripts/opt-run.sh):
//   TWOYI_OUT: directorio de salida (defecto tests/fullboot)
//   TWOYI_PAGE: pagina a navegar, p. ej. '/?gpu=0' para modo software
//   TWOYI_CHROME_FLAGS: flags extra de Chrome separados por espacios
//   TWOYI_JS_FLAGS: flags V8 en una sola cadena, p. ej. "--no-liftoff --no-wasm-lazy-compilation" (va como un solo --js-flags=...)
//   TWOYI_EXP: id del experimento, para el summary
//   TWOYI_STAY_AFTER_BOOT: segundos extra tras BOOTED tomando capturas
//   TWOYI_TAP_TEST=1: tras el boot, un toque en el centro del canvas + captura (sonda de interaccion)
const OUT = process.env.TWOYI_OUT ? path.resolve(process.env.TWOYI_OUT) : path.join(__dirname, 'fullboot');
const PAGE = process.env.TWOYI_PAGE || '/';
const EXTRA_FLAGS = (process.env.TWOYI_CHROME_FLAGS || '').split(/\s+/).filter(Boolean);
const JS_FLAGS = process.env.TWOYI_JS_FLAGS || '';
const EXP_ID = process.env.TWOYI_EXP || '';
const SHOTS = path.join(OUT, 'shots');
const CRASH = path.join(OUT, 'crash');
fs.mkdirSync(SHOTS, { recursive: true });
fs.mkdirSync(CRASH, { recursive: true });
const CHROME = resolveChrome();
// Ruta de Chrome: TWOYI_CHROME_PATH (GitHub Actions: la que da
// browser-actions/setup-chrome), o el Chrome de esta VM, o lo que haya
// en el PATH (google-chrome, chromium). Nunca hardcodear el runner.
function resolveChrome() {
  if (process.env.TWOYI_CHROME_PATH) return process.env.TWOYI_CHROME_PATH;
  const local = '/home/hatch/.cache/ms-playwright/chromium-1255/chrome-linux64/chrome';
  if (fs.existsSync(local)) return local;
  for (const c of ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser']) {
    try { const p = execSync(`command -v ${c}`, { encoding: 'utf8' }).trim(); if (p) return p; } catch {}
  }
  return local;
}
const CHROME_PROC = `[${path.basename(CHROME)[0]}]${path.basename(CHROME).slice(1)}`;
let CHROME_VERSION = 'unknown';
try { CHROME_VERSION = execSync(`"${CHROME}" --version`, { encoding: 'utf8' }).trim(); } catch {}
const PORT = 9223;
const PROFILE = path.join(__dirname, '.chrome-profile-fullboot');

const sleep = ms => new Promise(r => setTimeout(r, ms));
const now = () => new Date().toISOString();
function logLine(file, obj) {
  fs.appendFileSync(file, JSON.stringify({ t: now(), ...obj }) + '\n');
}
function sysMem() {
  try {
    const m = fs.readFileSync('/proc/meminfo', 'utf8');
    const get = k => parseInt(m.match(new RegExp(`^${k}:\\s+(\\d+)`, 'm'))?.[1] || '0', 10);
    return { memAvailableMB: Math.round(get('MemAvailable') / 1024), memFreeMB: Math.round(get('MemFree') / 1024) };
  } catch { return {}; }
}
function chromeRssMB(pid) {
  // Suma de TODOS los procesos chrome (main + renderer + GPU + workers),
  // no solo el proceso principal: el WASM de Android vive en el renderer.
  try {
    const out = execSync(`ps -eo rss,args | grep '${CHROME_PROC}' | awk '{s+=$1} END {print s}'`, { encoding: 'utf8' });
    return Math.round(parseInt(out.trim() || '0', 10) / 1024);
  } catch { return null; }
}
// RSS desglosado por tipo de proceso Chrome: renderer (ahi vive el WASM),
// gpu-process (SwiftShader), browser (resto). Sin esto no se sabe QUE
// parte del pico hay que recortar. Devuelve {renderer, gpu, browser, total} en MB.
function chromeRssSplitMB() {
  try {
    const out = execSync(`ps -eo rss,args | grep '${CHROME_PROC}'`, { encoding: 'utf8' });
    const split = { renderer: 0, gpu: 0, browser: 0, total: 0 };
    for (const line of out.trim().split('\n')) {
      if (!line.trim()) continue;
      const m = line.trim().match(/^(\d+)\s+(.*)$/);
      if (!m) continue;
      const mb = parseInt(m[1], 10) / 1024;
      const args = m[2];
      split.total += mb;
      if (args.includes('--type=renderer')) split.renderer += mb;
      else if (args.includes('--type=gpu-process')) split.gpu += mb;
      else split.browser += mb;
    }
    for (const k of Object.keys(split)) split[k] = Math.round(split[k]);
    return split;
  } catch { return null; }
}

// Regimen (R1): estadisticas de un volcado `dumpsys gfxinfo framestats`.
// Cada fila CSV tiene 17+ columnas; FrameCompleted es la 13 (indice 13,
// nanosegundos del reloj monotono del invitado). El span de FrameCompleted
// entre la primera y la ultima fila es tiempo de invitado transcurrido en
// la ventana: dividido por el tiempo de pared de la ventana reset->volcado
// (anclas WALL_FS/WALL_FS2 del shell, epoch del invitado) da la velocidad
// del invitado en regimen (1,0 = tiempo real). R1 pasaba BEGIN->END del
// volcado (~1 s, solo imprimir) y el ratio salia basura (3,47).
// Las filas con FrameCompleted<=0 son huecos del anillo y se descartan.
function framestatsStats(rows, wallSpanS) {
  const comp = [];
  let jankVsync = 0, withVsync = 0;
  for (const row of rows) {
    const c = row.split(',').map(s => parseInt(s.trim(), 10));
    if (c.length < 14 || isNaN(c[13]) || c[13] <= 0) continue;
    comp.push(c[13]);
    if (!isNaN(c[1]) && c[1] > 0) { withVsync++; if (c[13] - c[1] > 16700000) jankVsync++; }
  }
  if (comp.length < 2) return { n: comp.length, guestSpanS: null, ratio: null, note: 'muy pocos frames validos' };
  comp.sort((a, b) => a - b);
  const guestSpanS = (comp[comp.length - 1] - comp[0]) / 1e9;
  const iv = [];
  for (let i = 1; i < comp.length; i++) iv.push((comp[i] - comp[i - 1]) / 1e6);
  iv.sort((a, b) => a - b);
  const pct = p => iv.length ? Math.round(iv[Math.min(iv.length - 1, Math.floor(p * iv.length))] * 10) / 10 : null;
  return {
    n: comp.length,
    guestSpanS: Math.round(guestSpanS * 10) / 10,
    wallSpanS: wallSpanS != null ? Math.round(wallSpanS * 10) / 10 : null,
    ratio: wallSpanS ? Math.round(guestSpanS / wallSpanS * 100) / 100 : null,
    p50ms: pct(0.5), p95ms: pct(0.95),
    pctOver16_7: Math.round(iv.filter(x => x > 16.7).length / iv.length * 1000) / 10,
    pctOver33_4: Math.round(iv.filter(x => x > 33.4).length / iv.length * 1000) / 10,
    jankVsyncPct: withVsync ? Math.round(jankVsync / withVsync * 1000) / 10 : null,
  };
}

// Sonda de boot (E11, corregida en E12): la pagina tiene DOS canvas en
// #display: #screen (360x640, modo software, display:none en modo GPU) y
// #gfxstream (720x1280, modo GPU, display:none en modo software). El primer
// `querySelector('canvas')` siempre devolvia #screen, que en modo GPU
// esta oculto por CSS: `visible` era false en E0/E5/E10 y el criterio
// de arranque no podia dispararse nunca, aunque Android ya renderizaba
// (captura E10 a 306 s: home + dialogo "System UI isn't responding").
// La sonda elige el canvas VISIBLE (el que realmente dibuja) y ademas
// exige que la pagina haya quitado el overlay, lo que index.html solo
// hace al detectar el primer frame no-negro (watchFirstFrame).
// BUG E11: estas dos const estaban declaradas DENTRO de getJson(), asi
// que en main() `evalJs(CANVAS_PROBE)` lanzaba ReferenceError en Node,
// 3 eval-fallos seguidos cortaban la corrida a los 39 s y se registro
// como "crash" cuando la pestana seguia viva. Deben vivir a nivel de
// modulo para que main() las vea.
const CANVAS_PROBE = `(() => { const cs = [...document.querySelectorAll('#display canvas')]; const c = cs.find(x => x.offsetWidth > 0) || cs[cs.length - 1] || null; if (!c) return null; return { w: c.width, h: c.height, visible: c.offsetWidth > 0, id: c.id }; })()`;
const OVERLAY_HIDDEN_PROBE = `(() => { const o = document.getElementById('overlay'); return !!o && o.style.display === 'none'; })()`;

async function getJson(p) {
  for (let i = 0; i < 100; i++) {
    try { const r = await fetch(`http://127.0.0.1:${PORT}${p}`); if (r.ok) return await r.json(); } catch {}
    await sleep(500);
  }
  throw new Error('sin respuesta CDP en ' + p);
}

let msgId = 0;
const pending = new Map();
function send(ws, method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++msgId;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error('CDP timeout ' + method)); } }, 20000);
  });
}

async function main() {
  const t0 = Date.now();
  const deadline = t0 + MINUTES * 60 * 1000;
  const consoleFile = path.join(OUT, 'console.jsonl');
  const statusFile = path.join(OUT, 'status.jsonl');
  const serverLog = path.join(OUT, 'server.log');
  fs.writeFileSync(consoleFile, '');
  fs.writeFileSync(statusFile, '');
  const summary = { base: BASE, started: now(), minutes: MINUTES, chrome: CHROME_VERSION, chromePath: CHROME, events: [] };
  let wasmPeakMB = 0, rssPeakMB = 0, rssSplitPeak = null;
  let fpsSamples = [], guestMaxS = 0;
  // Regimen (R1): NEO_FPS del drag #fps-gpu + volcados framestats del invitado.
  const regime = { fps: null, gpuStatWindows: 0, fs: { FRAMESTATS: { rows: [], beginS: null, endS: null }, FRAMESTATS2: { rows: [], beginS: null, endS: null } }, tsAvgFps: [], wall: {}, geteventCount: null };
  let fsActive = null; // 'FRAMESTATS' | 'FRAMESTATS2' mientras dura un volcado
  let tsActive = null; // 'TIMESTATS' | 'TIMESTATS2' mientras dura su volcado
  const note = (ev, detail = '') => { summary.events.push({ t: now(), elapsed_s: Math.round((Date.now() - t0) / 1000), ev, detail: String(detail).slice(0, 500) }); console.log(`[${Math.round((Date.now() - t0) / 1000)}s] ${ev} ${detail}`.slice(0, 300)); };

  // Servidor (log a fichero, no a pipe: un pipe roto no debe tumbarlo)
  let serverProc = null;
  try {
    const r = await fetch(BASE + '/__health__');
    if (!r.ok) throw new Error('health no ok');
    note('server', 'ya corriendo en ' + BASE);
  } catch {
    const logFd = fs.openSync(serverLog, 'w');
    serverProc = spawn('python3', ['scripts/serve.py', '--port', '8080'], { cwd: ROOT, stdio: ['ignore', logFd, logFd] });
    for (let i = 0; i < 50; i++) {
      try { const r = await fetch(BASE + '/__health__'); if (r.ok) break; } catch {}
      await sleep(200);
    }
    note('server', 'arrancado, log en ' + serverLog);
  }

  // Chrome: perfil en disco persistente (cuota), Crashpad activado,
  // logging a fichero. --disable-dev-shm-usage porque /dev/shm es 794 MB.
  const chromeLog = fs.openSync(path.join(OUT, 'chrome.log'), 'w');
  const chrome = spawn(CHROME, [
    '--headless=new', '--no-sandbox', '--disable-dev-shm-usage',
    '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
    '--enable-logging=stderr', '--v=0',
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${PROFILE}`, ...(JS_FLAGS ? [`--js-flags=${JS_FLAGS}`] : []), ...EXTRA_FLAGS, 'about:blank',
  ], { stdio: ['ignore', chromeLog, chromeLog] });
  note('chrome', `lanzado pid=${chrome.pid}`);
  let crashed = false;
  chrome.on('exit', (code, signal) => { note('chrome-exit', `code=${code} signal=${signal}`); if (code !== 0 && code !== null) crashed = true; });

  let booted = false;
  try {
    const targets = await getJson('/json/list');
    const pageTarget = targets.find(t => t.type === 'page');
    const ws = new WebSocket(pageTarget.webSocketDebuggerUrl);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
    const consoleEvents = [];
    ws.onmessage = ev => {
      const m = JSON.parse(ev.data);
      if (m.id && pending.has(m.id)) { pending.get(m.id).resolve(m.result); pending.delete(m.id); return; }
      if (m.method === 'Runtime.consoleAPICalled') {
        const e = { kind: 'console', level: m.params.type, text: m.params.args.map(a => a.value ?? a.description ?? '').join(' ').slice(0, 1000) };
        logLine(consoleFile, e); consoleEvents.push(e);
        // Fluidez (2): "Boot is finished" de SurfaceFlinger marca el fin
        // del arranque en tiempo invitado; el instante de pared en que
        // aparece es el tiempo-real-hasta-boot.
        if (/Boot is finished/.test(e.text) && summary.bootFinishedWallS == null) {
          summary.bootFinishedWallS = Math.round((Date.now() - t0) / 1000);
          note('boot-finished', `invitado listo a los ${summary.bootFinishedWallS} s de pared`);
        }
        // Fluidez (2b): el reloj del invitado tambien vive en las lineas
        // de consola. El texto de la pagina se vacia tras el boot y
        // guestMaxS se congelaba; actualizarlo aqui lo mantiene vivo
        // durante el stay (es la velocidad real del invitado).
        for (const gm of e.text.matchAll(/\[\s*(\d+)\.\d+\]/g)) {
          const g = parseInt(gm[1], 10);
          if (g > guestMaxS) guestMaxS = g;
        }
        // Fluidez (2c): ultima muestra NEO_ENGINE_STATS (aot, evictions,
        // peak_bytes): el diagnostico del traductor, en el summary.
        // v3 (build nuevo): tambien aot_modules, aot_blocks y
        // coalesced_builds, que solo existen en el build con pack AOT.
        if (e.text.includes('NEO_ENGINE_STATS')) {
          const grab = (re) => { const mm = e.text.match(re); return mm ? parseInt(mm[1], 10) : null; };
          summary.engineStatsLast = { aot: grab(/aot=(\d+)/), aotEntries: grab(/aot_entries=(\d+)/), aotModules: grab(/aot_modules=(\d+)/), aotBlocks: grab(/aot_blocks=(\d+)/), coalescedBuilds: grab(/coalesced_builds=(\d+)/), builds: grab(/builds=(\d+)/), evictions: grab(/evictions=(\d+)/), cold: grab(/cold=(\d+)/), fallback: grab(/fallback=(\d+)/), peakBytes: grab(/peak_bytes=(\d+)/) };
        }
        // Fluidez (2d, v3): la linea NEO_ENGINE requested= (una vez al
        // arrancar) muestra solicitado vs efectivo de todos los knobs
        // (cache, chain, indice, aot, aot_modules, jit): la verificacion
        // de flags en 60 s, sin esperar al boot completo.
        if (e.text.includes('NEO_ENGINE requested=')) {
          summary.engineRequested = e.text.slice(0, 1000);
        }
        // Lineas NEO_AOT (warm del pack): ultimas 5, para saber si el pack
        // se compilo y calento antes del boot.
        if (e.text.startsWith('NEO_AOT')) {
          (summary.aotLines = summary.aotLines || []).push(e.text.slice(0, 300));
          if (summary.aotLines.length > 5) summary.aotLines.shift();
        }
        // Regimen (R1): NEO_FPS del drag #fps-gpu (frames posteados/s bajo
        // carga, la medida de fluidez del propio autor) y volcados
        // framestats/timestats del invitado (reloj monotono del guest).
        if (e.text.startsWith('NEO_FPS')) {
          const m = e.text.match(/posts=(\d+)\s+seconds=([\d.]+)\s+fps=([\d.]+)/);
          if (m) { regime.fps = { posts: parseInt(m[1], 10), seconds: parseFloat(m[2]), fps: parseFloat(m[3]), atS: Math.round((Date.now() - t0) / 1000) }; note('regime-fps', `NEO_FPS posts=${m[1]} seconds=${m[2]} fps=${m[3]}`); }
        }
        if (e.text.startsWith('NEO_GPU_STAT')) regime.gpuStatWindows++;
        const fsM = e.text.match(/^(FRAMESTATS2?|TIMESTATS2?)_(BEGIN|END)$/);
        if (fsM) {
          const key = fsM[1], kind = fsM[2];
          const atS = Math.round((Date.now() - t0) / 1000);
          if (key.startsWith('FRAMESTATS')) {
            if (kind === 'BEGIN') { fsActive = key; regime.fs[key].beginS = atS; regime.fs[key].rows = []; }
            else if (fsActive === key) { fsActive = null; regime.fs[key].endS = atS; note('framestats', `${key}: ${regime.fs[key].rows.length} filas, pared ${regime.fs[key].beginS}-${atS} s`); }
          } else {
            tsActive = kind === 'BEGIN' ? key : null;
          }
        } else if (fsActive && /^\d+,/.test(e.text)) {
          regime.fs[fsActive].rows.push(e.text);
        } else if (tsActive) {
          const tm = e.text.match(/averageFPS[:\s]+([\d.]+)/);
          if (tm) regime.tsAvgFps.push({ block: tsActive, fps: parseFloat(tm[1]) });
        }
        // Regimen (R1b): anclas de pared del shell (`echo MARK_BEGIN $(date +%s)`)
        // para medir las ventanas reset->volcado con el reloj del invitado.
        // El wallSpanS viejo (BEGIN->END del volcado, ~1 s, solo imprimir)
        // era basura (R1: ratio 3,47). No choca con FRAMESTATS_BEGIN/END
        // (esos no llevan numero) ni con NEO_FPS.
        const wallM = e.text.match(/^([A-Z0-9_]+)_(BEGIN|END) (\d+)$/);
        if (wallM) {
          const key = wallM[1], kind = wallM[2] === 'BEGIN' ? 'begin' : 'end';
          regime.wall[key] = { ...(regime.wall[key] || {}), [kind]: parseInt(wallM[3], 10) };
        }
        const gecM = e.text.match(/^GETEVENT_COUNT (\d+)$/);
        if (gecM) regime.geteventCount = parseInt(gecM[1], 10);
      }
      if (m.method === 'Runtime.exceptionThrown') {
        const d = m.params.exceptionDetails;
        const e = { kind: 'exception', text: (d.exception?.description || d.text || '').slice(0, 1000) };
        logLine(consoleFile, e); note('page-exception', e.text.slice(0, 200));
      }
      if (m.method === 'Inspector.targetCrashed') { crashed = true; note('TARGET-CRASHED', 'la pagina se estrello (renderer crash)'); }
      if (m.method === 'Log.entryAdded') {
        const e = m.params.entry;
        logLine(consoleFile, { kind: 'log', level: e.level, source: e.source, text: (e.text || '').slice(0, 1000), url: e.url || '' });
      }
    };
    const evalJs = async (expr) => {
      const r = await send(ws, 'Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
      if (r.exceptionDetails) throw new Error('eval fallo: ' + JSON.stringify(r.exceptionDetails).slice(0, 200));
      return r.result?.value;
    };
    await send(ws, 'Page.enable');
    await send(ws, 'Runtime.enable');
    await send(ws, 'Network.enable');
    await send(ws, 'Log.enable');

    await send(ws, 'Page.navigate', { url: BASE + PAGE });
    let isolated = false;
    for (let i = 0; i < 20; i++) { await sleep(1000); try { isolated = await evalJs('self.crossOriginIsolated'); if (isolated) break; } catch {} }
    note('isolated', String(isolated));
    if (!isolated) throw new Error('no crossOriginIsolated');

    // Contador de fluidez (1): rAF de la pagina. No mide los frames del
    // invitado (en modo GPU el canvas lo alimenta el compositor), pero si
    // la pagina se atasca el contador se para: es la senal de "vivo".
    try { await evalJs(`(() => { window.__fps = { n: 0, t0: performance.now() }; const tick = () => { window.__fps.n++; requestAnimationFrame(tick); }; requestAnimationFrame(tick); })()`); } catch {}

    // Click en Start — o auto-boot por hash (#fps-gpu, #boot, #boot-gpu,
    // #bench-art, #boot-gpu-logcat arrancan solos al cargar la pagina y
    // un segundo runCommand chocaria con el motor ya en marcha).
    const autoBootHash = await evalJs(`(() => { const h = location.hash; return ['#fps-gpu', '#boot', '#boot-gpu', '#bench-art', '#boot-gpu-logcat'].includes(h) ? h : ''; })()`).catch(() => '');
    let clicked;
    if (autoBootHash) {
      clicked = 'auto-boot';
      note('auto-boot', `hash ${autoBootHash}: la pagina arranca sola, sin click en Start`);
    } else {
      clicked = await evalJs(`(() => { const b = document.querySelector('button#start'); if (!b || b.disabled) return 'no-boton'; b.click(); return 'clicked'; })()`);
      note('click-start', clicked);
      if (clicked !== 'clicked') throw new Error('no se pudo pulsar Start: ' + clicked);
    }

    // Bucle de vigilancia hasta el deadline. Si la pagina se estrella,
    // no tiene sentido seguir evaluando 10 min con la pestana muerta:
    // a los 3 fallos seguidos de eval tras un crash, se corta el bucle
    // y se pasa a recoger crashlogs.
    let shotN = 0;
    let lastText = '';
    let evalFails = 0;
    while (Date.now() < deadline) {
      await sleep(10000);
      const elapsed = Math.round((Date.now() - t0) / 1000);
      let text = '', canvas = null, cacheKeys = [], overlayHidden = false;
      // Tamano real del heap WASM crecido. index.html guarda el modulo en
      // `liveModule` (let de ambito global: NO es window.liveModule, pero
      // Runtime.evaluate si ve los `let` globales por su nombre).
      let wasmMemMB = null;
      try { wasmMemMB = await evalJs(`(() => { try { const m = liveModule; if (!m || !m.wasmMemory) return null; return Math.round(m.wasmMemory.buffer.byteLength / 1048576); } catch (e) { return null; } })()`); } catch {}
      if (typeof wasmMemMB === 'number' && wasmMemMB > wasmPeakMB) wasmPeakMB = wasmMemMB;
      // Fluidez (1): fps de la pagina en esta ventana de 10 s.
      let fps = null;
      try { fps = await evalJs(`(() => { const f = window.__fps; if (!f) return null; const now = performance.now(); const dt = (now - f.t0) / 1000; const v = dt > 0 ? Math.round(f.n / dt * 10) / 10 : null; window.__fps = { n: 0, t0: now }; return v; })()`); } catch {}
      if (typeof fps === 'number') fpsSamples.push(fps);
      const rssSplit = chromeRssSplitMB();
      if (rssSplit && rssSplit.total > rssPeakMB) { rssPeakMB = rssSplit.total; rssSplitPeak = rssSplit; }
      try {
        text = await evalJs(`document.body.innerText.slice(0, 600)`);
        canvas = await evalJs(CANVAS_PROBE);
        overlayHidden = await evalJs(OVERLAY_HIDDEN_PROBE);
        cacheKeys = await evalJs(`caches.keys().catch(() => [])`);
        evalFails = 0;
      } catch (e) {
        note('eval-fallo', String(e).slice(0, 200));
        // Tras un crash, un solo eval fallido basta para cortar: cada
        // eval contra una pestana muerta tarda el timeout entero (E0
        // perdio 275 s en el apagado por esperar 3 fallos a 60 s).
        if (crashed || ++evalFails >= 3) { note(crashed ? 'corte-tras-crash' : 'corte-eval-fallos', crashed ? 'eval fallido tras crash, se recogen crashlogs' : '3 evals fallidos seguidos SIN crash de Chrome (fallo de sonda/harness, no del renderer); crashed queda false a proposito'); break; }
      }
      if (text !== lastText) { note('page-text', text.replace(/\n/g, ' | ').slice(0, 300)); lastText = text; }
      // Fluidez (3): reloj del invitado. Las lineas de log llevan
      // "[ 123.456]" en segundos de invitado; el maximo visto dividido
      // por el tiempo de pared es la velocidad real del invitado
      // (E0: 25 s de invitado a 230 s de pared = 0,11, lentisimo).
      for (const m of (text || '').matchAll(/\[\s*(\d+)\.\d+\]/g)) {
        const g = parseInt(m[1], 10);
        if (g > guestMaxS) guestMaxS = g;
      }
      logLine(statusFile, { elapsed_s: elapsed, text: (text || '').slice(0, 300), canvas, overlayHidden, cacheKeys, mem: sysMem(), chromeRssMB: chromeRssMB(chrome.pid), chromeRssSplitMB: rssSplit, wasmMemMB, fps, guestMaxS, chromeAlive: chrome.exitCode === null });
      // Captura cada 30 s
      if (elapsed % 30 < 10) {
        try {
          const shot = await send(ws, 'Page.captureScreenshot', { format: 'png' });
          fs.writeFileSync(path.join(SHOTS, `shot-${String(shotN).padStart(3, '0')}-${elapsed}s.png`), Buffer.from(shot.data, 'base64'));
          shotN++;
        } catch {}
      }
      // Senales de arranque: el canvas de Android visible + primer frame
      // no-negro (overlay quitado por la pagina) + texto sin "downloading"
      // y con algo de sistema. Criterio conservador: canvas grande visible
      // Y overlay quitado Y cache completa Y texto sin error.
      const downloading = /downloading|preparing|unpack/i.test(text || '');
      const hasError = /error:/i.test(text || '');
      if (canvas && canvas.visible && canvas.w >= 300 && overlayHidden && !downloading && !hasError && (cacheKeys || []).length > 0) {
        // Esperar 30 s mas para confirmar que se mantiene (no es un flash)
        await sleep(30000);
        const text2 = await evalJs(`document.body.innerText.slice(0, 300)`).catch(() => '');
        const canvas2 = await evalJs(CANVAS_PROBE).catch(() => null);
        const overlayHidden2 = await evalJs(OVERLAY_HIDDEN_PROBE).catch(() => false);
        if (canvas2 && canvas2.visible && overlayHidden2 && !/downloading|error:/i.test(text2 || '')) {
          booted = true;
          note('BOOTED', `canvas ${canvas2.id} ${canvas2.w}x${canvas2.h}, texto: ${(text2 || '').replace(/\n/g, ' | ').slice(0, 200)}`);
          // TWOYI_TAP_TEST=1: sonda de interaccion. Tras el boot, un toque
          // en el centro del canvas + captura 10 s despues: el analista
          // compara las fotos y dictamina si la UI responde al toque.
          if (process.env.TWOYI_TAP_TEST === '1') {
            try {
              const box = await evalJs(`(() => { const c = [...document.querySelectorAll('#display canvas')].find(x => x.offsetWidth > 0); if (!c) return null; const r = c.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`);
              if (box) {
                await send(ws, 'Input.dispatchMouseEvent', { type: 'mousePressed', x: box.x, y: box.y, button: 'left', clickCount: 1 });
                await send(ws, 'Input.dispatchMouseEvent', { type: 'mouseReleased', x: box.x, y: box.y, button: 'left', clickCount: 1 });
                note('tap', `toque en canvas ${Math.round(box.x)},${Math.round(box.y)}`);
                await sleep(10000);
                const shot = await send(ws, 'Page.captureScreenshot', { format: 'png' });
                fs.writeFileSync(path.join(SHOTS, `shot-tap-after-${Math.round((Date.now() - t0) / 1000)}s.png`), Buffer.from(shot.data, 'base64'));
                summary.tapTest = { clicked: true, atS: Math.round((Date.now() - t0) / 1000) };
              } else { summary.tapTest = { clicked: false, reason: 'sin canvas visible' }; }
            } catch (err) { summary.tapTest = { clicked: false, reason: String(err).slice(0, 200) }; }
          }
          // TWOYI_STAY_AFTER_BOOT=N: tras declarar BOOTED, quedarse N s
          // mas tomando capturas cada 10 s (foto de la pantalla de inicio
          // y prueba de estabilidad) antes de cerrar la corrida.
          const stayS = parseInt(process.env.TWOYI_STAY_AFTER_BOOT || '0', 10);
          if (stayS > 0) {
            note('stay', `quedandose ${stayS} s mas para foto/prueba de estabilidad`);
            const stayEnd = Date.now() + stayS * 1000;
            while (Date.now() < stayEnd) {
              await sleep(10000);
              try {
                const shot = await send(ws, 'Page.captureScreenshot', { format: 'png' });
                fs.writeFileSync(path.join(SHOTS, `shot-boot-${String(shotN).padStart(3, '0')}-${Math.round((Date.now() - t0) / 1000)}s.png`), Buffer.from(shot.data, 'base64'));
                shotN++;
              } catch {}
              if (chrome.exitCode !== null) { crashed = true; note('chrome-muerto-en-stay', `exitCode=${chrome.exitCode}`); break; }
            }
          }
          break;
        }
      }
      if (hasError) note('page-error-visible', (text || '').slice(0, 200));
      if (chrome.exitCode !== null) { crashed = true; note('chrome-muerto', `exitCode=${chrome.exitCode}`); break; }
    }
    if (!booted && Date.now() >= deadline) note('timeout', `sin arranque en ${MINUTES} min`);
    // Regimen (R1): guardar el log completo de la pagina (#out, con los
    // volcados framestats/timestats enteros) — console.jsonl corta cada
    // linea a 1000 caracteres y el texto de la pagina solo se registra
    // recortado en status.jsonl.
    try {
      const fullLog = await evalJs(`(() => { const o = document.getElementById('out'); return o && o.innerText ? o.innerText : document.body.innerText; })()`);
      if (fullLog) { fs.writeFileSync(path.join(OUT, 'page-log.txt'), fullLog); note('page-log', `guardado (${fullLog.length} chars)`); }
    } catch (e) { note('page-log-fallo', String(e).slice(0, 200)); }
    ws.close();
  } catch (e) {
    note('harness-error', String(e).slice(0, 500));
    summary.harnessError = String(e).slice(0, 500);
  } finally {
    // Crashlogs: Crashpad, dmesg OOM, y tamano del perfil
    try {
      const crashDir = path.join(PROFILE, 'Crashpad');
      if (fs.existsSync(crashDir)) {
        const files = [];
        const walk = d => { for (const f of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, f.name); if (f.isDirectory()) walk(p); else files.push(p); } };
        walk(crashDir);
        fs.writeFileSync(path.join(CRASH, 'crashpad-files.txt'), files.join('\n'));
        note('crashpad', `${files.length} archivos en ${crashDir}`);
      }
    } catch (e) { note('crashpad-error', String(e).slice(0, 200)); }
    try {
      const dmesg = execSync('dmesg 2>/dev/null | grep -i -E "oom|killed process|out of memory" | tail -20', { encoding: 'utf8' });
      if (dmesg.trim()) { fs.writeFileSync(path.join(CRASH, 'dmesg-oom.txt'), dmesg); note('dmesg-oom', dmesg.slice(0, 300)); }
      else note('dmesg-oom', 'sin lineas OOM en dmesg');
    } catch { note('dmesg-oom', 'dmesg no disponible'); }
    try {
      const du = execSync(`du -sh ${PROFILE} 2>/dev/null`, { encoding: 'utf8' });
      note('profile-size', du.trim());
    } catch {}
    try { if (serverProc) { const log = fs.readFileSync(serverLog, 'utf8'); const ranges206 = (log.match(/rom\.tar\.gz.*" 206/g) || []).length; note('server-ranges-206', String(ranges206)); } } catch {}
    chrome.kill();
    if (serverProc) serverProc.kill();
  }
  summary.finished = now();
  summary.elapsed_s = Math.round((Date.now() - t0) / 1000);
  summary.booted = booted;
  summary.crashed = crashed;
  summary.exp = EXP_ID;
  summary.wasmPeakMB = wasmPeakMB;
  summary.chromeRssPeakMB = rssPeakMB;
  summary.chromeRssSplitPeakMB = rssSplitPeak;
  // Fluidez: fps medio/minimo de la pagina, reloj maximo del invitado y
  // su ratio contra el tiempo de pared (1,0 = tiempo real).
  summary.fpsSamples = fpsSamples;
  summary.fpsAvg = fpsSamples.length ? Math.round(fpsSamples.reduce((a, b) => a + b, 0) / fpsSamples.length * 10) / 10 : null;
  summary.fpsMin = fpsSamples.length ? Math.min(...fpsSamples) : null;
  summary.guestMaxS = guestMaxS;
  summary.guestRatio = summary.elapsed_s ? Math.round(guestMaxS / summary.elapsed_s * 100) / 100 : null;
  // Regimen (R1): el guestRatio viejo es un ARTEFACTO (guestMaxS se congela
  // tras el boot porque los timestamps [N.NNN] dejan de aparecer); el
  // numero en regimen es regimeFps (drag #fps-gpu) + framestats (reloj
  // monotono del invitado). Ventana en regimen: 120 s de pared tras
  // boot-finished (dentro del stay de 300 s).
  summary.guestRatioNote = 'ARTEFACTO: guestMaxS se congela tras el boot; no usar como velocidad en regimen. Ver regimeFps y framestats.';
  summary.regimeWindowS = 120;
  summary.regimeWindow = summary.bootFinishedWallS != null ? { startS: summary.bootFinishedWallS, endS: summary.bootFinishedWallS + 120 } : null;
  summary.regimeFps = regime.fps;
  summary.gpuStatWindows = regime.gpuStatWindows;
  summary.wallMarkers = regime.wall || {};
  summary.geteventCount = regime.geteventCount;
  summary.framestats = {};
  for (const k of Object.keys(regime.fs)) {
    const b = regime.fs[k];
    // R1b: la ventana real es reset->volcado (anclas WALL_FS/WALL_FS2 del shell,
    // epoch del invitado); el BEGIN->END del volcado (~1 s, solo imprimir)
    // era basura (R1: ratio 3,47). Sin anclas, se usa el viejo como fallback.
    const wallKey = k === 'FRAMESTATS' ? 'WALL_FS' : 'WALL_FS2';
    const w = (regime.wall || {})[wallKey];
    const wallSpan = (w && w.begin != null && w.end != null) ? w.end - w.begin : (b.beginS != null && b.endS != null ? b.endS - b.beginS : null);
    summary.framestats[k] = b.rows.length ? framestatsStats(b.rows, wallSpan) : { n: 0, note: 'sin volcado' };
  }
  summary.timestatsAvgFps = regime.tsAvgFps;
  fs.writeFileSync(path.join(OUT, 'summary.json'), JSON.stringify(summary, null, 2));
  console.log(`\nRESULTADO: ${booted ? 'ANDROID ARRANCO' : crashed ? 'CRASH' : 'SIN ARRANQUE en ' + MINUTES + ' min'}`);
  console.log('Resumen:', path.join(OUT, 'summary.json'));
  process.exit(booted ? 0 : crashed ? 2 : 1);
}

main().catch(e => { console.error('ERROR fullboot:', e); process.exit(3); });
