#!/usr/bin/env python3
"""
Sonda externa para P2: consulta el LB cada INTERVAL segundos y registra en CSV
timestamp, código HTTP, latencia e instancia que respondió (cabecera X-Instance).

Con este CSV se mide:
  * cuándo la instancia "enferma" deja de recibir tráfico (última aparición de su hostname)
  * cuántas peticiones fallaron y el % de error durante la ventana de la falla
  * cuándo se recupera la capacidad (reaparece un hostname nuevo)

Uso:
  python scripts/monitor.py http://<fqdn> evidencias/p2-falla-logica-monitor.csv [intervalo_s] [duracion_max_s]
  python scripts/monitor.py --resumen evidencias/p2-falla-logica-monitor.csv [inicio_iso] [fin_iso]
Ctrl+C para detener.  Solo librería estándar.
"""
import csv
import datetime as dt
import sys
import time
import urllib.error
import urllib.request


def probe(url, timeout=3.0):
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(f"{url}/?json", timeout=timeout) as r:
            r.read()
            return r.status, r.headers.get("X-Instance", ""), (time.perf_counter() - t0) * 1000, ""
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("X-Instance", ""), (time.perf_counter() - t0) * 1000, "http"
    except Exception as e:  # timeout, reset, etc.
        return 0, "", (time.perf_counter() - t0) * 1000, type(e).__name__


def run(url, out, interval, max_s=0):
    with open(out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["ts_utc", "status", "instance", "latency_ms", "error"])
        print(f"monitoreando {url} -> {out} (Ctrl+C para terminar)")
        t_end = time.time() + max_s if max_s else None
        try:
            while t_end is None or time.time() < t_end:
                ts = dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds")
                status, inst, lat, err = probe(url)
                w.writerow([ts, status, inst, f"{lat:.1f}", err])
                f.flush()
                mark = "OK " if status == 200 else "ERR"
                print(f"{ts} {mark} {status} {inst:<22} {lat:7.1f} ms {err}")
                time.sleep(interval)
        except KeyboardInterrupt:
            pass
    summary(out)


def summary(path, start=None, end=None):
    rows = list(csv.DictReader(open(path, encoding="utf-8")))
    if start:
        rows = [r for r in rows if r["ts_utc"] >= start]
    if end:
        rows = [r for r in rows if r["ts_utc"] <= end]
    if not rows:
        print("sin datos en la ventana")
        return
    total = len(rows)
    errors = [r for r in rows if r["status"] != "200"]
    print("\n===== Resumen =====")
    print(f"ventana: {rows[0]['ts_utc']} -> {rows[-1]['ts_utc']}")
    print(f"peticiones: {total}  errores: {len(errors)}  % error: {100 * len(errors) / total:.2f} %")
    if errors:
        print(f"primer error: {errors[0]['ts_utc']}  último error: {errors[-1]['ts_utc']}")
    seen = {}
    for r in rows:
        if r["instance"]:
            seen.setdefault(r["instance"], [r["ts_utc"], r["ts_utc"]])[1] = r["ts_utc"]
    print("instancias vistas (primera / última respuesta):")
    for inst, (a, b) in sorted(seen.items(), key=lambda kv: kv[1][0]):
        print(f"  {inst:<24} {a}  ->  {b}")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--resumen":
        summary(sys.argv[2], *(sys.argv[3:5]))
    elif len(sys.argv) >= 3:
        run(sys.argv[1].rstrip("/"), sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 0.5,
            float(sys.argv[4]) if len(sys.argv) > 4 else 0)
    else:
        print(__doc__)
        sys.exit(1)
