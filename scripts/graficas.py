#!/usr/bin/env python3
"""
Gráficos para el informe (P1).

  python scripts/graficas.py capacidad  <stats_history.csv> <salida.png>
  python scripts/graficas.py escalonada <stats_history.csv> <salida.png> <observed-capacity.json> [cpu.json]

'escalonada' alinea en el mismo eje de tiempo: usuarios, RPS, p95 (Locust) e instancias
observadas por el autoscale + CPU del VMSS (Azure Monitor). Requiere matplotlib.
"""
import csv
import datetime as dt
import json
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402


def load_locust(path):
    rows = []
    for r in csv.DictReader(open(path, encoding="utf-8")):
        if r.get("Name") != "Aggregated":
            continue
        try:
            rows.append({
                "t": dt.datetime.fromtimestamp(int(r["Timestamp"]), dt.timezone.utc),
                "users": int(r["User Count"]),
                "rps": float(r["Requests/s"]),
                "fails": float(r["Failures/s"]),
                "p95": float(r["95%"]) if r["95%"] not in ("N/A", "") else None,
            })
        except (KeyError, ValueError):
            continue
    return rows


def load_metric(path):
    data = json.load(open(path, encoding="utf-8"))
    pts = []
    for ts in data["value"][0]["timeseries"]:
        for p in ts["data"]:
            val = p.get("maximum", p.get("average"))
            if val is not None:
                pts.append((dt.datetime.fromisoformat(p["timeStamp"].replace("Z", "+00:00")), val))
    return sorted(pts)


def capacity_report(rows):
    """RPS máximo sostenible: mejor RPS medio por escalón de usuarios con p95 <= 1000 ms."""
    by_users = {}
    for r in rows:
        if r["p95"] is None or r["users"] == 0:
            continue
        by_users.setdefault(r["users"], []).append(r)
    best = None
    print(f"{'usuarios':>8} {'rps_medio':>10} {'p95_max_ms':>11}")
    for users in sorted(by_users):
        grp = by_users[users][3:] or by_users[users]  # descarta la transición del escalón
        rps = sum(x["rps"] for x in grp) / len(grp)
        p95 = max(x["p95"] for x in grp)
        print(f"{users:>8} {rps:>10.1f} {p95:>11.0f}")
        if p95 <= 1000:
            best = (users, rps, p95)
    if best:
        print(f"\n==> Capacidad de 1 instancia: ~{best[1]:.1f} RPS con {best[0]} usuarios (p95 {best[2]:.0f} ms)")
    return best


def main():
    mode, src, out = sys.argv[1], sys.argv[2], sys.argv[3]
    rows = load_locust(src)
    if not rows:
        sys.exit("sin filas 'Aggregated' en el CSV (¿se usó --csv-full-history?)")
    t = [r["t"] for r in rows]

    n = 3 if mode == "capacidad" else 4
    fig, ax = plt.subplots(n, 1, figsize=(12, 2.6 * n), sharex=True)
    ax[0].plot(t, [r["users"] for r in rows], color="#555")
    ax[0].set_ylabel("usuarios")
    ax[1].plot(t, [r["rps"] for r in rows], label="RPS", color="#1f6feb")
    ax[1].plot(t, [r["fails"] for r in rows], label="fallos/s", color="#d1242f")
    ax[1].set_ylabel("peticiones/s")
    ax[1].legend(loc="upper left")
    ax[2].plot(t, [r["p95"] for r in rows], color="#9a6700")
    ax[2].axhline(1000, ls="--", color="#d1242f", lw=1, label="1 s")
    ax[2].set_ylabel("p95 (ms)")
    ax[2].legend(loc="upper left")

    if mode == "capacidad":
        capacity_report(rows)
        fig.suptitle("P1.1 - Capacidad de una instancia")
    else:
        cap = load_metric(sys.argv[4])
        ax[3].step([p[0] for p in cap], [p[1] for p in cap], where="post", color="#1a7f37", label="instancias (ObservedCapacity)")
        ax[3].set_ylabel("instancias")
        ax[3].set_ylim(0, max(p[1] for p in cap) + 1)
        if len(sys.argv) > 5:
            cpu = load_metric(sys.argv[5])
            ax3b = ax[3].twinx()
            ax3b.plot([p[0] for p in cpu], [p[1] for p in cpu], color="#8250df", alpha=0.7, label="CPU %")
            ax3b.axhline(70, ls=":", color="#8250df", lw=1)
            ax3b.axhline(30, ls=":", color="#8250df", lw=1)
            ax3b.set_ylabel("CPU % (70/30)")
            ax3b.set_ylim(0, 100)
        ax[3].legend(loc="upper left")
        fig.suptitle("P1.2 - Prueba escalonada: carga vs. instancias (scale-out / scale-in)")

    for a in ax:
        a.grid(alpha=0.3)
    ax[-1].xaxis.set_major_formatter(mdates.DateFormatter("%H:%M", tz=dt.timezone.utc))
    ax[-1].set_xlabel("hora (UTC)")
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    print(f"gráfico: {out}")


if __name__ == "__main__":
    main()
