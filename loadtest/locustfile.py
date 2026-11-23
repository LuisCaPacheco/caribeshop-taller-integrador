"""
CaribeShop - pruebas de carga (P1 / P2) con Locust.

Perfiles (variable de entorno LOAD_PROFILE):
  * step      (por defecto, P1.2): escalonado >= 25 min: subida, carga sostenida y bajada.
  * capacity  (P1.1): rampa lenta +5 usuarios/min para hallar el límite de 1 instancia (p95 > 1 s).
  * moderate  (P2): carga constante moderada para las pruebas de falla.
  * Sin perfil (LOAD_PROFILE=none): control manual con -u / -r / -t.

Ejemplo:
  LOAD_PROFILE=step locust -f loadtest/locustfile.py --host http://<fqdn> \
      --headless --csv evidencias/p1-escalonada --csv-full-history \
      --html evidencias/p1-escalonada.html
"""
import os

from locust import HttpUser, LoadTestShape, between, events, task

WORK_MS = int(os.environ.get("WORK_MS", "40"))
PROFILE = os.environ.get("LOAD_PROFILE", "step").lower()


class Shopper(HttpUser):
    """Usuario que navega la tienda. Cada vista hace trabajo de CPU real en el servidor."""

    wait_time = between(0.5, 1.5)

    @task(6)
    def home(self):
        self.client.get("/?json", name="/")

    @task(3)
    def product(self):
        # Simula una vista de producto más costosa (render + consultas)
        self.client.get(f"/work?ms={WORK_MS}", name="/work")

    @task(1)
    def health(self):
        self.client.get("/health", name="/health")


# ---------------------------------------------------------------- perfiles
class StepShape(LoadTestShape):
    """P1.2 - 28 min: subida escalonada, meseta, bajada. Cada tupla = (fin_en_s, usuarios, spawn_rate)."""

    # Dimensionado con P1.1: 1 instancia sostiene ~145 RPS (p95 <= 1 s); cada usuario genera ~1 RPS.
    # El pico (~300 RPS) supera el 70 % de CPU de 2 instancias -> scale-out a 3.
    stages = [
        (120, 30, 5),     # 0-2 min    calentamiento
        (300, 120, 5),    # 2-5 min    subida 1
        (480, 240, 5),    # 5-8 min    subida 2  -> CPU > 70 %: se espera scale-out
        (1080, 300, 5),   # 8-18 min   carga sostenida (pico)
        (1380, 100, 5),   # 18-23 min  bajada
        (1680, 10, 5),    # 23-28 min  valle -> CPU < 30 % 10 min: se espera scale-in
    ]

    def tick(self):
        t = self.get_run_time()
        for end, users, rate in self.stages:
            if t < end:
                return users, rate
        return None


class CapacityShape(LoadTestShape):
    """P1.1 - rampa lenta: +5 usuarios por minuto hasta 300 (máx. 60 min)."""

    step_users = int(os.environ.get("STEP_USERS", "5"))
    step_seconds = int(os.environ.get("STEP_SECONDS", "60"))
    max_users = int(os.environ.get("MAX_USERS", "300"))

    def tick(self):
        t = self.get_run_time()
        if t > 3600:
            return None
        users = min(self.max_users, self.step_users * (int(t // self.step_seconds) + 1))
        return users, self.step_users


class ModerateShape(LoadTestShape):
    """P2 - carga moderada constante (por defecto 40 usuarios, 15 min)."""

    users = int(os.environ.get("USERS", "40"))
    duration = int(os.environ.get("DURATION", "900"))

    def tick(self):
        if self.get_run_time() > self.duration:
            return None
        return self.users, 10


# Locust usa la ÚNICA subclase de LoadTestShape definida en el módulo:
# se eliminan las que no correspondan al perfil elegido.
_shapes = {"step": StepShape, "capacity": CapacityShape, "moderate": ModerateShape}
for _name, _cls in list(_shapes.items()):
    if _name != PROFILE:
        del globals()[_cls.__name__]
del _shapes, _name, _cls


# ---------------------------------------------- p95 en vivo para P1.1
@events.init.add_listener
def _on_init(environment, **_kwargs):
    if PROFILE != "capacity" or environment.runner is None:
        return
    import gevent

    stop_after = int(os.environ.get("STOP_AFTER_BREACHES", "8"))  # 8 x 15 s = 2 min sobre 1 s

    def watch_p95():
        breaches = 0
        while True:
            gevent.sleep(15)
            stats = environment.stats.total
            if stats.num_requests < 50:
                continue
            p95 = stats.get_current_response_time_percentile(0.95) or 0
            users = environment.runner.user_count
            print(f"[capacity] usuarios={users} rps={stats.current_rps:.1f} p95_actual={p95:.0f} ms", flush=True)
            if p95 > 1000:
                breaches += 1
                print(f"[capacity] p95 > 1 s con {users} usuarios -> límite alcanzado (~{stats.current_rps:.1f} RPS)", flush=True)
                if stop_after and breaches >= stop_after:
                    print("[capacity] p95 > 1 s sostenido: fin de la rampa", flush=True)
                    environment.runner.quit()
                    return
            else:
                breaches = 0

    gevent.spawn(watch_p95)
