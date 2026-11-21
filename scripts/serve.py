#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Twoyi Web — servidor local offline PERFECTO (solo stdlib, cero dependencias).

Por que NO vale `python3 -m http.server` a secas:
  * No envia COOP/COEP -> `crossOriginIsolated === false` ->
    `SharedArrayBuffer is not defined` y el boton de arranque se
    deshabilita (index.html:559-563, y neoRun() lanza en index.html:406).
  * SimpleHTTPRequestHandler IGNORA `Range`: devuelve 200 con el archivo
    entero. download.js exige 206 en rangos de 8 MiB x 6 en vuelo
    (download.js:12-13,26-27) y WasmFS exige longitud exacta del rango
    (neo-web.js, __wasmfs_create_fetch_backend_js). Un 200 ante un Range
    es fallo duro en ambos caminos, no hay degradacion.
  * No garantiza `Content-Type: application/wasm` exacto, ni
    `Accept-Ranges`, ni 416, ni If-Range, ni Cache-Control correcto.

Lo que hace ESTE servidor, verificado contra el codigo real en
mirror/run.twoyi.app/ (index.html 647 lineas, sw.js, download.js,
neo-web.js) y contra RFC 9110:
  1. Un solo origen para front-end + seed:
       /                              -> mirror/run.twoyi.app/index.html
       /rt/... /sw.js /download.js    -> mirror/run.twoyi.app/...
       /seed/v107-gles-r1-f5a887c7/*  -> mirror/seed.twoyi.app/v107.../*
       /seed/*                        -> alias al seed anterior
       /config.json                   -> REESCRITO en vivo con el seedUrl
                                          local (ver abajo). Sin esto el
                                          front-end pediria el seed remoto
                                          https://seed.twoyi.app, cuyo CORS
                                          solo permite https://run.twoyi.app,
                                          y el offline seria imposible.
     ?seed= sigue teniendo prioridad en la pagina (index.html:240-251),
     asi que tambien puedes abrir http://127.0.0.1:8080/?seed=<tu-seed>.
  2. COOP: same-origin + COEP: require-corp + CORP: same-origin en TODAS
     las respuestas, incluidos errores 404/416 y HEAD/OPTIONS.
     Valores literales de sw.js:10-14. Sin una de las dos primeras no hay
     aislamiento. El SW las inyecta solo para respuestas mismo origen SIN
     Range (sw.js:91), asi que no hay que confiarse en el fallback.
  3. MIME exacto: .wasm -> application/wasm (sin charset), .js ->
     text/javascript, .json -> application/json, .webmanifest ->
     application/manifest+json, .tar.gz -> application/gzip.
     instantiateStreaming() rechaza cualquier otro MIME para .wasm.
  4. Rangos RFC 9110, un solo rango por peticion (lo unico que Twoyi usa):
       bytes=a-b   -> 206, Content-Range: bytes a-b/total
       bytes=a-    -> 206 hasta el final
       bytes=-N    -> 206, ultimos N bytes
       fuera de rango -> 416, Content-Range: bytes */total
       multi-rango (coma) -> 416 (documentado; Twoyi nunca lo envia,
         y sw.js tampoco lo acepta: /^bytes=(\\d+)-(\\d*)$/)
       sintaxis invalida -> se ignora el rango, 200 entero
       If-Range con ETag/fecha distinta -> se ignora el rango, 200 entero
       HEAD -> mismos headers que GET, sin cuerpo
       Accept-Ranges: bytes en TODAS las respuestas a archivos.
     Streaming por bloques de 256 KiB con seek(), sin cargar el archivo
     en RAM (el ROM son 471 MB; un read() entero seria un disparate).
  5. ETag barato (tamano+mtime, sin hashear 471 MB por peticion),
     Last-Modified, 304 con If-None-Match / If-Modified-Since.
  6. CORS para el caso de seed en otro origen (aunque aqui es mismo
     origen): OPTIONS -> 204, Allow-Origin (eco del Origin o *),
     Allow-Methods GET/HEAD/OPTIONS, Allow-Headers Range/If-Range,
     Expose-Headers Content-Length/Content-Range/Accept-Ranges/ETag.
     Sin exponer Content-Range, el JS no puede leer que trozo recibio.
  7. Cache-Control: no-cache en index.html / sw.js / config.json
     (deben revalidar siempre); public, max-age=31536000, immutable
     en /rt/<hash>/, rom.tar.gz, seed.index, metadata.sqlite, files/*.
  8. ThreadingHTTPServer, HTTP/1.1 (keep-alive para los 6 rangos
     paralelos), daemon_threads, bind 127.0.0.1 por defecto (localhost
     es contexto seguro; una IP LAN en http:// NO lo es para SW/SAB).
  9. /__health__ (solo diagnostico): JSON con version, seed, archivos
     y si existe rom.tar.gz. La app nunca lo pide.

Uso:
  python3 scripts/serve.py
  # sirve http://127.0.0.1:8080/  (front-end + seed en el mismo origen)
  python3 scripts/serve.py --port 8080 --host 127.0.0.1
  python3 scripts/serve.py --root mirror
  python3 scripts/serve.py --seed-url http://127.0.0.1:8081/v107-gles-r1-f5a887c7
  python3 scripts/serve.py --no-rewrite-config   # sirve config.json tal cual (remoto; NO offline)
  python3 scripts/serve.py --self-test            # arranca en puerto efimero, corre checks, sale

Luego abre http://127.0.0.1:8080/ en Chrome/Edge de escritorio,
pulsa arrancar, deja que descargue/desempaquete el ROM una vez
(~1,26 GB libres en el navegador). Los arranques siguientes ya son
offline: sw.js sirve el ROM desde Cache Storage.

NO es un servidor de produccion (la propia doc de http.server lo dice).
Es para uso local personal. Bind 127.0.0.1, nunca 0.0.0.0 sin necesidad.
"""
from __future__ import annotations

import argparse
import email.utils
import hashlib
import html
import json
import mimetypes
import os
import re
import shutil
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

# ---------------------------------------------------------------------------
# Constantes verificadas contra el codigo / rom.json (19-11-2026)
# ---------------------------------------------------------------------------
SEED_VERSION = "v107-gles-r1-f5a887c7"
RUNTIME_HASH = "9a2915b6d0c30c93"
ROM_BYTES = 471289100
ROM_SHA256 = "fd96c489a27d5fe027cbea43b6f1f02164f81d87c0a907d6711be03623e33e9d"
ROM_FILES = 1801
ROM_RAW_BYTES = 1093035394
WASM_SHA256 = "2c925964078f9ff682c687d39f87f11558df8c57c331d245f39687cda17da99a"
WASM_BYTES = 5415178
CHUNK = 8 << 20          # download.js:12  (8.388.608 B por peticion)
PARALLEL = 6             # download.js:13  (6 peticiones en vuelo)

BUF_SIZE = 256 * 1024    # bloques de streaming

# MIME explicito: nunca fiarse de /etc/mime.types del sistema.
MIME = {
    ".html": "text/html; charset=utf-8",
    ".htm": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json",
    ".webmanifest": "application/manifest+json",
    ".wasm": "application/wasm",          # EXACTO, sin charset (instantiateStreaming)
    ".tar.gz": "application/gzip",
    ".gz": "application/gzip",
    ".sqlite": "application/octet-stream",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".txt": "text/plain; charset=utf-8",
    ".xml": "application/xml",
    ".ico": "image/x-icon",
}
mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/manifest+json", ".webmanifest")

# Un solo rango: bytes=a-b | bytes=a- | bytes=-N   (sw.js acepta solo este patron)
RANGE_RE = re.compile(r"bytes=(\d*)-(\d*)\s*$")
# If-Range puede ser ETag entre comillas o fecha HTTP
CACHE_NO_CACHE = {"index.html", "sw.js", "config.json"}

# ---------------------------------------------------------------------------
# Utilidades de rangos (RFC 9110)
# ---------------------------------------------------------------------------

def parse_range(header: str, size: int):
    """Devuelve (start, end) inclusivos, None si fuera de rango (->416),
    o 'ignore' si la sintaxis es invalida / multi-rango es 416.
    Multi-rango se devuelve como ('multi',) para que el llamador de 416."""
    if "," in header:
        return ("multi",)
    m = RANGE_RE.match(header.strip())
    if not m:
        return "ignore"
    s, e = m.groups()
    if s == "" and e == "":
        return "ignore"
    if s == "":  # sufijo: bytes=-N
        n = int(e)
        if n == 0:
            return "ignore"
        start, end = max(0, size - n), size - 1
    else:
        start = int(s)
        end = int(e) if e else size - 1
        end = min(end, size - 1)
    if size == 0 or start >= size or start > end:
        return None
    return (start, end)


def make_etag(size: int, mtime_ns: int) -> str:
    # Barato: sin hashear el archivo. Suficiente para If-Range local.
    return f'"{size:x}-{mtime_ns:x}"'


def http_date(timestamp: float) -> str:
    return email.utils.formatdate(timestamp, usegmt=True)


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------

class TwoyiHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "TwoyiOffline/2.0"
    # -- configurado por el main() via atributos de clase --
    root_dir = ""          # carpeta mirror/ (contiene run.twoyi.app/ y seed.twoyi.app/)
    seed_url_override = ""  # si se pasa --seed-url, config.json usa ese valor
    aot_url_override = ""   # si se pasa --aot-url, config.json incluye ese aotUrl (build nuevo con pack AOT)
    image_url_override = ""  # si se pasa --image-url, config.json incluye ese imageUrl (N3: EROFS local)
    rewrite_config = True

    # -- estado por peticion --
    _range = None          # (start, end) o None
    _file = None           # file object abierto por send_head()
    _iso_sent = False

    # ---- helpers de cabeceras ----
    def end_headers(self):
        # COOP/COEP/CORP + CORS en TODAS las respuestas, incluidos errores.
        # Se hace aqui (y no solo en send_head) porque send_error() tambien
        # pasa por end_headers(), y un 404/416 sin COOP/COEP romperia el
        # aislamiento si el navegador lo cacheara como documento.
        if not self._iso_sent:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header("Cross-Origin-Resource-Policy", "same-origin")
            origin = self.headers.get("Origin")
            self.send_header("Access-Control-Allow-Origin", origin if origin else "*")
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Range, If-Range, Content-Type")
            self.send_header("Access-Control-Expose-Headers",
                             "Content-Length, Content-Range, Accept-Ranges, ETag")
            self._iso_sent = True
        super().end_headers()

    def _reset(self):
        self._range = None
        self._file = None
        self._iso_sent = False

    def log_message(self, fmt, *args):
        # Robusto: si el stderr es un pipe cerrado (p. ej. el proceso que
        # lanzo el servidor murio), un BrokenPipeError aqui no debe matar
        # el hilo que sirve la peticion.
        try:
            sys.stderr.write(f"[{time.strftime('%H:%M:%S')}] {self.address_string()} "
                             f"{self.command} {self.path} — {fmt % args}\n")
            sys.stderr.flush()
        except (BrokenPipeError, OSError):
            pass

    def handle_error(self, request, client_address):
        # Igual que log_message: un error de socket al cerrar no debe
        # tumbar el servidor entero con un traceback a un pipe roto.
        try:
            super().handle_error(request, client_address)
        except (BrokenPipeError, OSError):
            pass

    # ---- resolucion de rutas ----
    def _resolve(self, raw_path: str):
        """Devuelve (fs_path, kind) o (None, 'health'|'config'|'notfound').
        kind: 'front' | 'seed' | 'health' | 'config'"""
        parsed = urlparse(raw_path)
        # Normalizar // -> / (WasmFS construye <base>//files/N)
        path = re.sub(r"/{2,}", "/", unquote(parsed.path))
        if not path.startswith("/"):
            path = "/" + path
        if path in ("/__health__", "/__health__/", "/__twoyi_server__"):
            return None, "health"
        if path == "/config.json":
            return None, "config"
        # Alias /seed/* -> seed dir (fallback de seedBase(): '/seed')
        if path == "/seed" or path.startswith("/seed/"):
            rest = path[len("/seed"):].lstrip("/")
            # /seed/v107.../...  o  /seed/rom.json (sin version)
            if rest.startswith(SEED_VERSION + "/"):
                rest = rest[len(SEED_VERSION) + 1:]
            elif rest.startswith(SEED_VERSION):
                rest = ""
            fs = os.path.join(self.root_dir, "seed.twoyi.app", SEED_VERSION, rest) \
                if rest else os.path.join(self.root_dir, "seed.twoyi.app", SEED_VERSION)
            return fs, "seed"
        if path.startswith("/seed-"):
            return None, "notfound"
        # /seed/<version> explicito tambien se acepta como /seed/...
        if path.startswith(f"/seed/{SEED_VERSION}/"):
            rest = path[len(f"/seed/{SEED_VERSION}/"):]
            return os.path.join(self.root_dir, "seed.twoyi.app", SEED_VERSION, rest), "seed"
        # Resto: front-end
        rest = path.lstrip("/")
        if rest == "" or rest.endswith("/"):
            rest = (rest + "index.html") if rest else "index.html"
        fs = os.path.join(self.root_dir, "run.twoyi.app", rest)
        return fs, "front"

    @staticmethod
    def _safe(fs_path: str, *bases: str) -> bool:
        real = os.path.realpath(fs_path)
        return any(real == os.path.realpath(b) or
                   real.startswith(os.path.realpath(b) + os.sep) for b in bases)

    def _content_type(self, fs_path: str) -> str:
        # .tar.gz tiene doble extension: mirarlo antes que .gz
        if fs_path.endswith(".tar.gz"):
            return MIME[".tar.gz"]
        ext = os.path.splitext(fs_path)[1].lower()
        if ext in MIME:
            return MIME[ext]
        guessed, _ = mimetypes.guess_type(fs_path)
        return guessed or "application/octet-stream"

    def _cache_control(self, fs_path: str, kind: str) -> str:
        base = os.path.basename(fs_path)
        if base in CACHE_NO_CACHE:
            return "no-cache"
        if kind == "seed":
            return "public, max-age=31536000, immutable"
        if "/rt/" in fs_path.replace(os.sep, "/") or fs_path.endswith(".wasm"):
            return "public, max-age=31536000, immutable"
        return "no-cache"

    # ---- cuerpo principal: send_head ----
    def send_head(self):
        """Resuelve, valida, envia status+headers. Devuelve file object o None.
        Guarda el rango en self._range para copyfile()."""
        self._reset()
        fs_path, kind = self._resolve(self.path)
        if kind == "health":
            body = json.dumps({
                "ok": True,
                "server": "TwoyiOffline/2.0",
                "seed_version": SEED_VERSION,
                "runtime": RUNTIME_HASH,
                "rom": {
                    "bytes": ROM_BYTES,
                    "sha256": ROM_SHA256,
                    "files": ROM_FILES,
                    "raw_bytes": ROM_RAW_BYTES,
                    "present": os.path.exists(os.path.join(
                        self.root_dir, "seed.twoyi.app", SEED_VERSION, "rom.tar.gz")),
                },
                "wasm": {"bytes": WASM_BYTES, "sha256": WASM_SHA256},
            }, indent=2).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self._health_body = body
            return "health"
        if kind == "config":
            host = self.headers.get("Host", "127.0.0.1:8080")
            if self.seed_url_override:
                seed_url = self.seed_url_override.rstrip("/")
            elif self.rewrite_config:
                seed_url = f"http://{host}/seed/{SEED_VERSION}"
            else:
                seed_url = f"https://seed.twoyi.app/{SEED_VERSION}"
            cfg_out = {"seedUrl": seed_url}
            # Build nuevo: el front-end lee config.json {seedUrl, aotUrls}
            # (array; el formato viejo usaba aotUrl como cadena). Sin
            # aotUrls el pack AOT NO se descarga (aotPack() devuelve null
            # salvo ?aot=on, que buscaria un aot.json inexistente). El
            # runner pasa --aot-url y verifica que config.json lo contenga
            # antes del harness. Se emiten las dos claves por compatibilidad.
            if self.aot_url_override:
                cfg_out["aotUrl"] = self.aot_url_override
                cfg_out["aotUrls"] = [self.aot_url_override]
            # N3: la imagen EROFS del sistema (--image <url> en el boot).
            # Sin imageUrl el motor arranca del arbol del seed (N1/N2); con
            # imageUrl lee los bloques de /system por rangos (image_fetch.js).
            if self.image_url_override:
                cfg_out["imageUrl"] = self.image_url_override
            body = (json.dumps(cfg_out) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self._health_body = body
            return "config"
        if kind == "notfound" or fs_path is None:
            self.send_error(404, "File not found")
            return None
        # Directorio -> index.html
        if os.path.isdir(fs_path):
            fs_path = os.path.join(fs_path, "index.html")
        front_base = os.path.join(self.root_dir, "run.twoyi.app")
        seed_base = os.path.join(self.root_dir, "seed.twoyi.app", SEED_VERSION)
        if not self._safe(fs_path, front_base, seed_base,
                          os.path.join(self.root_dir, "run.twoyi.app"),
                          os.path.join(self.root_dir, "seed.twoyi.app")):
            self.send_error(403, "Forbidden")
            return None
        if not os.path.isfile(fs_path):
            self.send_error(404, "File not found")
            return None
        try:
            f = open(fs_path, "rb")
        except OSError:
            self.send_error(404, "File not found")
            return None
        st = os.fstat(f.fileno())
        size = st.st_size
        etag = make_etag(size, st.st_mtime_ns)
        last_mod = http_date(st.st_mtime)
        ctype = self._content_type(fs_path)
        cache = self._cache_control(fs_path, kind)

        # 304: If-None-Match / If-Modified-Since (solo sin Range)
        range_hdr = self.headers.get("Range")
        if range_hdr is None:
            inm = self.headers.get("If-None-Match")
            if inm and (inm.strip() == "*" or etag in inm):
                self.send_response(304)
                self.send_header("ETag", etag)
                self.send_header("Last-Modified", last_mod)
                self.send_header("Cache-Control", cache)
                self.end_headers()
                f.close()
                return None
            ims = self.headers.get("If-Modified-Since")
            if ims:
                try:
                    ims_ts = email.utils.parsedate_to_datetime(ims).timestamp()
                    if int(st.st_mtime) <= int(ims_ts):
                        self.send_response(304)
                        self.send_header("ETag", etag)
                        self.send_header("Last-Modified", last_mod)
                        self.send_header("Cache-Control", cache)
                        self.end_headers()
                        f.close()
                        return None
                except (TypeError, ValueError, OverflowError):
                    pass

        # Rangos
        if range_hdr is not None:
            # If-Range: si el ETag/fecha no coincide, ignorar el rango -> 200
            if_range = self.headers.get("If-Range")
            if if_range:
                if_range = if_range.strip()
                ok = False
                if if_range.startswith('"'):
                    ok = (if_range == etag)
                else:
                    try:
                        ok = int(st.st_mtime) <= int(
                            email.utils.parsedate_to_datetime(if_range).timestamp())
                    except (TypeError, ValueError, OverflowError):
                        ok = False
                if not ok:
                    range_hdr = None  # cae al 200 entero de abajo
            if range_hdr is not None:
                parsed = parse_range(range_hdr, size)
                if parsed == "ignore":
                    range_hdr = None  # sintaxis invalida -> 200 entero
                elif parsed == ("multi",) or parsed is None:
                    # Multi-rango o fuera de rango -> 416
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("ETag", etag)
                    self.send_header("Last-Modified", last_mod)
                    self.send_header("Cache-Control", cache)
                    self.end_headers()
                    f.close()
                    return None
                else:
                    start, end = parsed
                    length = end - start + 1
                    self.send_response(206)
                    self.send_header("Content-Type", ctype)
                    self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                    self.send_header("Content-Length", str(length))
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("ETag", etag)
                    self.send_header("Last-Modified", last_mod)
                    self.send_header("Cache-Control", cache)
                    self.end_headers()
                    self._range = (start, end)
                    self._file = f
                    return f
        # 200 entero
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(size))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", etag)
        self.send_header("Last-Modified", last_mod)
        self.send_header("Cache-Control", cache)
        self.end_headers()
        self._file = f
        return f

    def copyfile(self, source, outputfile):
        # source es el file object de send_head() (o el body de health/config)
        if isinstance(source, str) and source in ("health", "config"):
            outputfile.write(self._health_body)
            return
        if self._range is not None:
            start, end = self._range
            source.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = source.read(min(BUF_SIZE, remaining))
                if not chunk:
                    break
                outputfile.write(chunk)
                remaining -= len(chunk)
        else:
            shutil.copyfileobj(source, outputfile, length=BUF_SIZE)

    # ---- verbos ----
    def do_GET(self):
        try:
            f = self.send_head()
            if f is None:
                return
            try:
                if isinstance(f, str):
                    self.copyfile(f, self.wfile)
                else:
                    self.copyfile(f, self.wfile)
            finally:
                if not isinstance(f, str):
                    f.close()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_HEAD(self):
        try:
            f = self.send_head()
            if f is not None and not isinstance(f, str):
                f.close()
            # health/config en HEAD: send_head ya envio headers, sin cuerpo. Correcto.
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_OPTIONS(self):
        self._reset()
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

    def do_POST(self):
        self._reset()
        self.send_error(405, "Method Not Allowed")

    # Silenciar la version en errores (no filtrar nada util)
    def send_error(self, code, message=None, explain=None):
        # send_error llama a send_response + Content-Type/Length + end_headers,
        # y end_headers() anade COOP/COEP/CORP/CORS. No hay que hacer nada mas.
        super().send_error(code, message, explain)


def make_server(host: str, port: int, root: str, seed_url: str, rewrite: bool,
                aot_url: str = "", image_url: str = ""):
    handler = TwoyiHandler
    handler.root_dir = os.path.abspath(root)
    handler.seed_url_override = seed_url
    handler.aot_url_override = aot_url
    handler.image_url_override = image_url
    handler.rewrite_config = rewrite
    httpd = ThreadingHTTPServer((host, port), handler)
    httpd.daemon_threads = True
    return httpd


def self_test(root: str) -> int:
    """Arranca en puerto efimero y corre checks con urllib. Devuelve 0 si todo OK."""
    import urllib.request
    import urllib.error
    httpd = make_server("127.0.0.1", 0, root, "", True)
    port = httpd.server_address[1]
    import threading
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    base = f"http://127.0.0.1:{port}"
    fails = []

    def check(name, cond, detail=""):
        print(f"{'PASS' if cond else 'FAIL'}  {name}  {detail}")
        if not cond:
            fails.append(name)

    def req(path, headers=None, method="GET"):
        r = urllib.request.Request(base + path, headers=headers or {}, method=method)
        try:
            with urllib.request.urlopen(r, timeout=10) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()
        except Exception as e:  # noqa
            return None, {}, str(e).encode()

    try:
        s, h, b = req("/")
        check("index 200 + COOP/COEP/CORP",
              s == 200 and h.get("Cross-Origin-Opener-Policy") == "same-origin"
              and h.get("Cross-Origin-Embedder-Policy") == "require-corp"
              and h.get("Cross-Origin-Resource-Policy") == "same-origin",
              f"status={s} len={len(b)}")
        check("index tamano 36410", len(b) == 36410, f"len={len(b)}")
        s, h, b = req("/rt/9a2915b6d0c30c93/neo-web.wasm")
        check("wasm MIME exacto", h.get("Content-Type") == "application/wasm",
              f"ct={h.get('Content-Type')}")
        check("wasm hash", hashlib.sha256(b).hexdigest() == WASM_SHA256)
        check("wasm magic \\0asm", b[:4] == b"\x00asm")
        s, h, b = req("/config.json")
        cfg = json.loads(b)
        check("config.json apunta al seed local",
              cfg.get("seedUrl", "").startswith(base + "/seed/" + SEED_VERSION),
              f"seedUrl={cfg.get('seedUrl')}")
        s, h, b = req("/seed/v107-gles-r1-f5a887c7/rom.json")
        check("rom.json", s == 200 and json.loads(b)["bytes"] == ROM_BYTES)
        # Rangos sobre el ROM
        for hdr, exp_status, exp_range, exp_len in [
            ("bytes=0-0", 206, f"bytes 0-0/{ROM_BYTES}", 1),
            ("bytes=0-1", 206, f"bytes 0-1/{ROM_BYTES}", 2),
            ("bytes=0-8388607", 206, f"bytes 0-8388607/{ROM_BYTES}", 8388608),
            ("bytes=471289000-", 206, f"bytes 471289000-471289099/{ROM_BYTES}", 100),
            ("bytes=-1024", 206, f"bytes 471288076-471289099/{ROM_BYTES}", 1024),
        ]:
            s, h, b = req("/seed/v107-gles-r1-f5a887c7/rom.tar.gz",
                          headers={"Range": hdr})
            check(f"rango {hdr}",
                  s == exp_status and h.get("Content-Range") == exp_range
                  and int(h.get("Content-Length", -1)) == exp_len and len(b) == exp_len,
                  f"status={s} cr={h.get('Content-Range')} len={len(b)}")
        s, h, b = req("/seed/v107-gles-r1-f5a887c7/rom.tar.gz",
                      headers={"Range": "bytes=471289100-"})
        check("rango fuera -> 416", s == 416 and h.get("Content-Range") == f"bytes */{ROM_BYTES}",
              f"status={s} cr={h.get('Content-Range')}")
        s, h, b = req("/seed/v107-gles-r1-f5a887c7/rom.tar.gz",
                      headers={"Range": "bytes=0-99,200-299"})
        check("multi-rango -> 416 (documentado)", s == 416, f"status={s}")
        s, h, b = req("/", method="HEAD")
        check("HEAD sin cuerpo", s == 200 and len(b) == 0 and h.get("Content-Length") == "36410")
        s, h, b = req("/no-existe-xyz")
        check("404 con COOP/COEP", s == 404 and h.get("Cross-Origin-Opener-Policy") == "same-origin",
              f"status={s}")
        s, h, b = req("/seed/v107-gles-r1-f5a887c7/rom.tar.gz", method="OPTIONS")
        check("OPTIONS 204 + CORS", s == 204, f"status={s}")
        s, h, b = req("/__health__")
        check("health JSON", s == 200 and json.loads(b).get("ok") is True)
        # Alias /seed/rom.json (fallback de seedBase)
        s, h, b = req("/seed/rom.json")
        check("alias /seed/rom.json", s == 200 and json.loads(b)["bytes"] == ROM_BYTES)
        # Doble barra //files/ (WasmFS construye <base>//files/N)
        s, h, b = req("/seed//v107-gles-r1-f5a887c7//rom.json")
        check("doble barra normalizada", s == 200, f"status={s}")
    finally:
        httpd.shutdown()
        httpd.server_close()
    print(f"\n{'TODO OK' if not fails else 'FALLOS: ' + ', '.join(fails)} "
          f"({len(fails)} fallos)")
    return 1 if fails else 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Twoyi Web offline — servidor Python perfecto (stdlib, sin dependencias)")
    ap.add_argument("--host", default="127.0.0.1",
                    help="bind (por defecto 127.0.0.1; localhost es contexto seguro)")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--root", default=None,
                    help="carpeta mirror/ (por defecto: ../mirror junto a este script, "
                         "o mirror/ en el cwd)")
    ap.add_argument("--seed-url", default="",
                    help="seedUrl fijo para config.json (por defecto: http://<host>:<puerto>/seed/<version>)")
    ap.add_argument("--aot-url", default="",
                    help="aotUrl para config.json (build nuevo con pack AOT; "
                         "por defecto: sin aotUrl, el pack no se descarga)")
    ap.add_argument("--image-url", default="",
                    help="imageUrl para config.json (N3: imagen EROFS local; "
                         "por defecto: sin imageUrl, el boot usa el arbol del seed)")
    ap.add_argument("--no-rewrite-config", action="store_true",
                    help="sirve config.json tal cual (seed remoto; NO offline)")
    ap.add_argument("--self-test", action="store_true",
                    help="arranca en puerto efimero, corre checks y sale")
    args = ap.parse_args(argv)

    # Resolver root: junto al script, o en cwd
    candidates = []
    if args.root:
        candidates.append(args.root)
    candidates.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mirror"))
    candidates.append(os.path.join(os.getcwd(), "mirror"))
    candidates.append(os.path.join(os.getcwd(), "twoyi-offline", "mirror"))
    root = None
    for c in candidates:
        if os.path.isdir(os.path.join(c, "run.twoyi.app")):
            root = os.path.abspath(c)
            break
    if root is None:
        print("No encuentro mirror/run.twoyi.app. Pasa --root <carpeta mirror/>.",
              file=sys.stderr)
        print(f"Buscado en: {candidates}", file=sys.stderr)
        return 2

    if args.self_test:
        return self_test(root)

    httpd = make_server(args.host, args.port, root, args.seed_url,
                        rewrite=not args.no_rewrite_config,
                        aot_url=args.aot_url, image_url=args.image_url)
    print(f"Twoyi Web offline — sirviendo {root}")
    print(f"  Front-end: http://{args.host}:{args.port}/")
    print(f"  Seed local: http://{args.host}:{args.port}/seed/{SEED_VERSION}/")
    print(f"  Health: http://{args.host}:{args.port}/__health__")
    print(f"  ROM: {ROM_BYTES} bytes, {ROM_FILES} archivos "
          f"(presente: {os.path.exists(os.path.join(root, 'seed.twoyi.app', SEED_VERSION, 'rom.tar.gz'))})")
    print("  COOP: same-origin | COEP: require-corp | CORP: same-origin")
    print("  Ctrl+C para parar. Abre la URL en Chrome/Edge de escritorio.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nParado.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
