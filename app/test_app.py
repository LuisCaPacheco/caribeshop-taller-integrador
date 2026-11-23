"""Pruebas locales de la app (sin Azure). Ejecutar: python -m unittest discover -s app -v"""
import json
import os
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from unittest import mock

os.environ.setdefault("OPERATOR_IP", "127.0.0.1")
os.environ.setdefault("KV_NAME", "kv-prueba")

import app  # noqa: E402

VALOR_DE_PRUEBA = "S3cr3t-de-prueba-NO-real"


class FakeResp:
    def __init__(self, payload):
        self._b = json.dumps(payload).encode()

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class AppTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        app.OPERATOR_IP = "127.0.0.1"
        app._instance_cache.update(hostname="test-host", zone="1", vm_name="vm0", vm_size="Standard_B2ps_v2", _ok=True)
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def get(self, path):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=5) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    def setUp(self):
        app.set_unhealthy(0)

    def test_health_ok(self):
        self.assertEqual(self.get("/health"), (200, "ok"))

    def test_simulate_failure_then_recover(self):
        code, body = self.get("/simulate-failure?seconds=60")
        self.assertEqual(code, 200)
        self.assertEqual(self.get("/health")[0], 503)
        self.get("/simulate-failure?seconds=0")
        self.assertEqual(self.get("/health")[0], 200)

    def test_simulate_failure_forbidden_for_others(self):
        with mock.patch.object(app, "OPERATOR_IP", "10.9.9.9"):
            self.assertEqual(self.get("/simulate-failure")[0], 403)
        self.assertEqual(self.get("/health")[0], 200)

    def test_index_json(self):
        code, body = self.get("/?json")
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["zona"], "1")

    def test_secret_check_never_leaks_value(self):
        def fake_urlopen(req, timeout=None):
            return FakeResp({"value": VALOR_DE_PRUEBA})

        with mock.patch.object(app, "managed_identity_token", return_value="tok"), \
                mock.patch.object(app.urllib.request, "urlopen", side_effect=fake_urlopen), \
                self.assertLogs("caribeshop", level="INFO") as logs:
            res, _ = app.read_secret_fingerprint(force=True)
        self.assertIsNone(res["error"])
        self.assertEqual(res["length"], len(VALOR_DE_PRUEBA))
        self.assertNotIn(VALOR_DE_PRUEBA, json.dumps(res))
        self.assertFalse(any(VALOR_DE_PRUEBA in line for line in logs.output))

        code, body = self.get("/secret-check")
        self.assertEqual(code, 200)
        self.assertNotIn(VALOR_DE_PRUEBA, body)
        self.assertEqual(json.loads(body)["sha256_truncado"], app.fingerprint(VALOR_DE_PRUEBA)["sha256_prefix"])

    def test_work_bounded(self):
        code, body = self.get("/work?ms=99999")
        self.assertEqual(json.loads(body)["ms"], app.MAX_WORK_MS)

    def test_keepalive_and_rotation(self):
        import http.client
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        closes = 0
        for _ in range(app.MAX_REQUESTS_PER_CONN):
            c.request("GET", "/health")
            r = c.getresponse()
            r.read()
            if r.getheader("Connection") == "close":
                closes += 1
        self.assertEqual(closes, 1)  # solo la última petición cierra la conexión
        c.close()

    def test_404(self):
        self.assertEqual(self.get("/admin")[0], 404)


if __name__ == "__main__":
    unittest.main()
