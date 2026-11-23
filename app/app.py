#!/usr/bin/env python3
"""
CaribeShop - aplicación de demostración (solo librería estándar de Python).

Sin dependencias externas a propósito: las instancias NO tienen salida a Internet
(egress filtrado, S2), así que no pueden hacer `pip install`. Solo hablan con:
  * IMDS (169.254.169.254): metadatos de la instancia y token de la identidad administrada
  * Key Vault (etiqueta AzureKeyVault, vía service endpoint): lectura del secreto (S3)

Endpoints (D3):
  GET /                      -> página/JSON con instancia, zona y algo de trabajo de CPU
  GET /health                -> 200 "ok" | 503 si se simuló una falla (sonda del LB, E2/E4)
  GET /secret-check          -> huella del secreto (longitud + SHA-256 truncado), NUNCA el valor
  GET /simulate-failure      -> marca la instancia como no sana N segundos (solo IP del operador)
  GET /simulate-failure?seconds=0 -> se "cura" antes de tiempo (solo IP del operador)
  GET /work?ms=50            -> trabajo de CPU configurable (pruebas de carga)
"""
import hashlib
import json
import logging
import multiprocessing
import os
import signal
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("APP_PORT", "80"))
# socketserver usa listen(5) por defecto: con ráfagas de conexiones nuevas la cola SYN se llena,
# el kernel retransmite el SYN-ACK a 1 s y aparecen latencias de +1 s / +3 s. Se amplía la cola.
ThreadingHTTPServer.request_queue_size = int(os.environ.get("LISTEN_BACKLOG", "1024"))
KV_NAME = os.environ.get("KV_NAME", "")
SECRET_NAME = os.environ.get("SECRET_NAME", "db-password")
OPERATOR_IP = os.environ.get("OPERATOR_IP", "")
IMDS = "http://169.254.169.254/metadata"
KV_API_VERSION = "7.4"
SECRET_CACHE_TTL = 300  # s: evita llamar a Key Vault en cada petición
DEFAULT_WORK_MS = int(os.environ.get("DEFAULT_WORK_MS", "20"))
MAX_WORK_MS = 500
MAX_FAILURE_SECONDS = 1800
# Keep-alive: se reutiliza la conexión (menos handshakes TCP), pero se cierra cada N peticiones
# para que el Load Balancer redistribuya la carga hacia instancias nuevas (scale-out / reparación).
MAX_REQUESTS_PER_CONN = int(os.environ.get("MAX_REQUESTS_PER_CONN", "50"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s caribeshop %(message)s",
)
log = logging.getLogger("caribeshop")

_state_lock = threading.Lock()
# Compartido entre procesos (prefork): la falla simulada afecta a TODA la instancia
_unhealthy_until = multiprocessing.Value("d", 0.0, lock=True)
_secret_cache = {"fingerprint": None, "length": None, "fetched_at": 0.0, "error": None}
_instance_cache = {}


# ----------------------------------------------------------------- IMDS
def _imds_get(path, params, timeout=2.0):
    url = f"{IMDS}/{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"Metadata": "true"})
    # IMDS no debe pasar por un proxy
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def instance_info():
    """Nombre, zona y tamaño de la instancia. Cacheado; si IMDS falla se reintenta como máximo cada 60 s
    (nunca bloquear cada petición esperando a IMDS)."""
    now = time.time()
    if _instance_cache and (_instance_cache.get("_ok") or now < _instance_cache.get("_retry_at", 0)):
        return _instance_cache
    info = {"hostname": socket.gethostname(), "zone": "desconocida", "vm_name": None, "vm_size": None,
            "_ok": False, "_retry_at": now + 60}
    try:
        data = _imds_get("instance/compute", {"api-version": "2021-02-01"})
        info.update(
            zone=data.get("zone") or "sin-zona",
            vm_name=data.get("name"),
            vm_size=data.get("vmSize"),
            location=data.get("location"),
            _ok=True,
        )
    except (urllib.error.URLError, OSError, ValueError) as exc:
        log.warning("IMDS no disponible para metadatos: %s", type(exc).__name__)
    _instance_cache.update(info)
    return _instance_cache


def managed_identity_token(resource="https://vault.azure.net"):
    data = _imds_get(
        "identity/oauth2/token",
        {"api-version": "2018-02-01", "resource": resource},
        timeout=5.0,
    )
    return data["access_token"]


# ------------------------------------------------------------ Key Vault
def fingerprint(value):
    """Huella segura: longitud + primeros 12 hex de SHA-256. Irreversible y no revela el valor."""
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()
    return {"length": len(value), "sha256_prefix": digest[:12]}


def read_secret_fingerprint(force=False):
    """Lee el secreto con la identidad administrada y guarda SOLO su huella en memoria."""
    now = time.time()
    with _state_lock:
        cached = dict(_secret_cache)
    if not force and cached["fingerprint"] and now - cached["fetched_at"] < SECRET_CACHE_TTL:
        return cached, True

    result = {"fingerprint": None, "length": None, "fetched_at": now, "error": None}
    if not KV_NAME:
        result["error"] = "KV_NAME no configurado"
    else:
        try:
            token = managed_identity_token()
            url = f"https://{KV_NAME}.vault.azure.net/secrets/{SECRET_NAME}?api-version={KV_API_VERSION}"
            req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
            with urllib.request.urlopen(req, timeout=5.0) as resp:
                body = json.loads(resp.read().decode("utf-8"))
            secret_value = body["value"]
            fp = fingerprint(secret_value)
            del secret_value, body  # no se conserva el valor
            result.update(fingerprint=fp["sha256_prefix"], length=fp["length"])
            log.info("secreto '%s' leido desde Key Vault (huella=%s)", SECRET_NAME, fp["sha256_prefix"])
        except urllib.error.HTTPError as exc:
            # Nunca registrar cuerpos de respuesta: podrían contener datos sensibles
            result["error"] = f"Key Vault respondió HTTP {exc.code}"
        except (urllib.error.URLError, OSError, KeyError, ValueError) as exc:
            result["error"] = f"no se pudo leer el secreto: {type(exc).__name__}"
        if result["error"]:
            log.warning("lectura de secreto fallida: %s", result["error"])

    with _state_lock:
        _secret_cache.update(result)
    return result, False


# ---------------------------------------------------------------- salud
def is_healthy():
    with _unhealthy_until.get_lock():
        return time.time() >= _unhealthy_until.value


def set_unhealthy(seconds):
    with _unhealthy_until.get_lock():
        _unhealthy_until.value = time.time() + seconds
        return _unhealthy_until.value


def cpu_work(ms):
    """Trabajo de CPU real (hashing) para que el autoscale por CPU tenga señal."""
    deadline = time.perf_counter() + ms / 1000.0
    h = b"caribeshop"
    rounds = 0
    while time.perf_counter() < deadline:
        for _ in range(200):
            h = hashlib.sha256(h).digest()
        rounds += 1
    return rounds


# --------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "CaribeShop/1.0"
    sys_version = ""
    protocol_version = "HTTP/1.1"  # keep-alive
    timeout = 15                   # cierra conexiones ociosas

    def setup(self):
        super().setup()
        self._served = 0

    # -- utilidades
    def _client_ip(self):
        # El LB Standard preserva la IP de origen del cliente
        return self.client_address[0]

    def _send(self, code, payload, content_type="application/json"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", f"{content_type}; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Instance", instance_info()["hostname"])
        self._served += 1
        if self._served >= MAX_REQUESTS_PER_CONN or not is_healthy():
            # Al fallar /health también se cierran las conexiones vivas: el LB solo saca de
            # rotación los flujos NUEVOS, así que los clientes se reconectan a instancias sanas.
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Sin ruido de la sonda; nunca se registran cabeceras (Authorization) ni cuerpos
        if self.path.startswith("/health"):
            return
        log.info("%s %s", self._client_ip(), fmt % args)

    # -- rutas
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        route = parsed.path.rstrip("/") or "/"

        if route == "/":
            return self._index(qs)
        if route == "/health":
            return self._health()
        if route == "/secret-check":
            return self._secret_check(qs)
        if route == "/simulate-failure":
            return self._simulate_failure(qs)
        if route == "/work":
            return self._work(qs)
        return self._send(404, {"error": "no encontrado"})

    def _index(self, qs):
        rounds = cpu_work(DEFAULT_WORK_MS)
        info = instance_info()
        wants_json = "json" in qs or "application/json" in self.headers.get("Accept", "")
        data = {
            "app": "CaribeShop",
            "mensaje": "Bienvenido a CaribeShop - temporada alta",
            "instancia": info["hostname"],
            "zona": info["zone"],
            "vm_size": info.get("vm_size"),
            "sano": is_healthy(),
            "cpu_rounds": rounds,
        }
        if wants_json:
            return self._send(200, data)
        html = (
            "<!doctype html><html lang='es'><head><meta charset='utf-8'><title>CaribeShop</title>"
            "<style>body{font-family:system-ui;margin:3rem;background:#f4f9fb;color:#0b3c49}"
            ".card{background:#fff;padding:1.5rem 2rem;border-radius:12px;max-width:560px;"
            "box-shadow:0 2px 8px #0002}code{background:#eef;padding:2px 6px;border-radius:4px}</style>"
            "</head><body><div class='card'><h1>CaribeShop</h1>"
            f"<p>Atendido por <code>{data['instancia']}</code> en la zona <code>{data['zona']}</code></p>"
            "<p>Endpoints: <code>/health</code> <code>/secret-check</code> <code>/work?ms=50</code></p>"
            "</div></body></html>"
        ).encode("utf-8")
        return self._send(200, html, "text/html")

    def _health(self):
        if is_healthy():
            return self._send(200, b"ok", "text/plain")
        return self._send(503, b"unhealthy (simulado)", "text/plain")

    def _secret_check(self, qs):
        res, from_cache = read_secret_fingerprint(force="refresh" in qs)
        info = instance_info()
        if res["error"]:
            return self._send(502, {
                "instancia": info["hostname"],
                "secreto": SECRET_NAME,
                "leido": False,
                "error": res["error"],
            })
        return self._send(200, {
            "instancia": info["hostname"],
            "zona": info["zone"],
            "key_vault": KV_NAME,
            "secreto": SECRET_NAME,
            "leido": True,
            "metodo": "identidad administrada (IMDS) -> Key Vault REST",
            "longitud": res["length"],
            "sha256_truncado": res["fingerprint"],
            "desde_cache": from_cache,
            "nota": "El valor del secreto nunca se muestra ni se registra.",
        })

    def _simulate_failure(self, qs):
        client = self._client_ip()
        if not OPERATOR_IP or client != OPERATOR_IP:
            log.warning("simulate-failure rechazado desde %s", client)
            return self._send(403, {"error": "solo el operador puede simular fallas"})
        try:
            seconds = int(qs.get("seconds", ["600"])[0])
        except ValueError:
            return self._send(400, {"error": "seconds debe ser entero"})
        seconds = max(0, min(seconds, MAX_FAILURE_SECONDS))
        until = set_unhealthy(seconds)
        host = instance_info()["hostname"]
        log.warning("FALLA SIMULADA en %s durante %ss", host, seconds)
        return self._send(200, {
            "instancia": host,
            "health": "503" if seconds else "200",
            "segundos": seconds,
            "hasta_epoch": round(until, 1),
        })

    def _work(self, qs):
        try:
            ms = int(qs.get("ms", [str(DEFAULT_WORK_MS)])[0])
        except ValueError:
            ms = DEFAULT_WORK_MS
        ms = max(0, min(ms, MAX_WORK_MS))
        rounds = cpu_work(ms)
        return self._send(200, {"instancia": instance_info()["hostname"], "ms": ms, "rounds": rounds})


def _serve(server):
    # Precarga de la huella: deja evidencia en AZKVAuditLogs desde el arranque (S6)
    threading.Thread(target=read_secret_fingerprint, daemon=True).start()
    server.serve_forever()


def main():
    """Prefork: un proceso por vCPU comparte el mismo socket.

    Python tiene GIL: con un solo proceso una VM de 2 vCPU nunca pasaría de ~50 % de CPU
    y el autoscale (umbral 70 %) jamás se dispararía. Con N procesos la CPU real refleja la carga.
    """
    instance_info()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    workers = int(os.environ.get("WORKERS", "0")) or (os.cpu_count() or 1)
    log.info("CaribeShop escuchando en :%s (kv=%s, workers=%s)", PORT, KV_NAME or "-", workers)

    if workers <= 1 or not hasattr(os, "fork"):
        _serve(server)
        return

    children = set()

    def spawn():
        pid = os.fork()
        if pid == 0:
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            try:
                _serve(server)
            finally:
                os._exit(0)
        children.add(pid)

    def stop(signum, _frame):
        for pid in list(children):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    for _ in range(workers):
        spawn()
    while True:  # el padre supervisa y reemplaza workers caídos
        pid, _status = os.wait()
        children.discard(pid)
        log.warning("worker %s terminó; reiniciando", pid)
        spawn()


if __name__ == "__main__":
    main()
