"""Genera docs/Informe-CaribeShop.pdf a partir de docs/INFORME-SOPORTE.md, README.md y evidencias/.

Uso: python docs/generar_informe.py        (requiere: pip install markdown; Microsoft Edge o Chrome)
"""
import os
import pathlib
import re
import subprocess
import sys

import markdown

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
EVID = ROOT / "evidencias"

soporte = (DOCS / "INFORME-SOPORTE.md").read_text(encoding="utf-8")
readme = (ROOT / "README.md").read_text(encoding="utf-8")


def section(md, start, end=None):
    i = md.index(start)
    j = md.index(end, i + len(start)) if end else len(md)
    return md[i:j].strip()


def demote(md, n=0):
    return md


# --- Fragmentos reutilizados -------------------------------------------------
mermaid = section(readme, "```mermaid", "| Decisión |")
decisiones = section(readme, "| Decisión |", "## 2. Estructura")
trazabilidad = section(soporte, "## 2. Tabla de trazabilidad", "## 3.")
histeresis = section(soporte, "## 3. Escalamiento", "## 4.")
sla = section(soporte, "## 4. SLA compuesto", "## 5.")
riesgos = section(soporte, "## 5. Tabla de riesgos", "## 6. Costo")
costos = section(soporte, "## 6. Costo mensual", "## 6.1")
resultados = section(soporte, "## 6.1 Resultados", "## 7.")
respuestas = section(soporte, "## 7. Respuestas", "## 8. Guion")


def img(path, caption, width="100%"):
    rel = os.path.relpath(path, DOCS).replace("\\", "/")
    return f'\n<figure><img src="{rel}" style="width:{width}"><figcaption>{caption}</figcaption></figure>\n'


# Gráficos dentro de los resultados
resultados = resultados.replace(
    "Gráfico: `evidencias/p1-capacidad.png`.",
    "Gráfico en la figura 2." + img(EVID / "p1-capacidad.png", "Figura 2. P1.1 — usuarios, RPS y p95 de una instancia", "92%"),
)
resultados = resultados.replace(
    "Gráfico alineado en el tiempo (usuarios, RPS, p95, instancias y CPU): `evidencias/p1-escalonada.png`.",
    "La figura 3 alinea en el tiempo usuarios, RPS, p95 (Locust) con instancias y CPU (Azure Monitor)."
    + img(EVID / "p1-escalonada.png", "Figura 3. P1.2 — carga vs. instancias: scale-out a las 19:28-19:29 y scale-in a las 19:43-19:45 (UTC)", "92%"),
)

# Renumerar encabezados del soporte (## n. -> secciones del informe)
def retitle(md, new):
    return re.sub(r"^## .*$", f"## {new}", md, count=1, flags=re.M)


cuerpo = "\n\n".join([
    "## 1. Contexto y objetivo\n\n"
    "CaribeShop (Cartagena) sufrió dos caídas en la campaña anterior: una por saturación durante una promoción y otra por "
    "la falla de su única máquina virtual. Una auditoría encontró además la contraseña de la base de datos en el repositorio "
    "y el puerto SSH abierto a Internet. Este informe documenta la plataforma construida en Azure, **completamente como "
    "código (Terraform) y con un pipeline DevSecOps**, que es segura, escala automáticamente y sigue funcionando ante la "
    "falla de un componente, junto con la evidencia empírica obtenida con pruebas de carga, de falla y de seguridad sobre "
    "el despliegue real (23-nov-2026, región `centralus`, suscripción Azure for Students).",
    "## 2. Arquitectura y decisiones de diseño\n\n" + mermaid
    + '\n<p class="cap">Figura 1. Arquitectura desplegada</p>\n\n' + decisiones
    + "\n\n" + retitle(histeresis, "2.1 Justificación de la histéresis del autoscale").replace("## 2.1", "### 2.1"),
    retitle(trazabilidad, "3. Tabla de trazabilidad (requisito → Terraform → evidencia)"),
    retitle(sla, "4. SLA compuesto"),
    retitle(resultados, "5. Resultados de las pruebas P1, P2 y P3"),
    retitle(riesgos, "6. Riesgos aceptados (incluye cada `#checkov:skip`)"),
    retitle(costos, "7. Costo mensual estimado y efecto del autoscale"),
    retitle(respuestas, "8. Respuestas a las preguntas de análisis"),
])
# Referencias internas -> secciones/anexos de este informe
cuerpo = cuerpo.replace("y `docs/INFORME-SOPORTE.md` §3", "y la sección 2.1")
cuerpo = cuerpo.replace("Tabla §5 de este documento", "Sección 6 de este informe")
for n in range(1, 9):
    cuerpo = cuerpo.replace(f"captura `0{n}`", f"anexo A{n}")
cuerpo = re.sub(r"captura `0(\d)-[a-z0-9-]+\.png`", lambda m: f"anexo A{m.group(1)}", cuerpo)
cuerpo = re.sub(r"captura `0(\d)`", lambda m: f"anexo A{m.group(1)}", cuerpo)
cuerpo = cuerpo.replace("captura 06-autoscale-historial-ejecucion.png", "anexo A6")
# Subsecciones del soporte -> ###
cuerpo = cuerpo.replace("\n### P1.1", "\n### 5.1 P1.1").replace("\n### P1.2", "\n### 5.2 P1.2")
cuerpo = cuerpo.replace("\n### P2 Pruebas de falla", "\n### 5.3 P2 Pruebas de falla")
cuerpo = cuerpo.replace("\n### E4 Reparación", "\n### 5.4 E4 Reparación").replace("\n### P3 Pruebas", "\n### 5.5 P3 Pruebas")
cuerpo = cuerpo.replace("\n### Hallazgos", "\n### 5.6 Hallazgos")
for k in range(1, 7):
    cuerpo = cuerpo.replace(f"\n### P{k}. ", f"\n### 8.{k} ")

anexos = ["## Anexo A. Capturas del portal de Azure"]
for f, cap in [
    ("01-grupo-recursos.png", "A1. Grupo de recursos rg-caribeshop-prod desplegado por Terraform"),
    ("02-nsg-reglas.png", "A2. S2 — NSG de mínimo privilegio: entrada solo HTTP y sondas del LB; salida solo AzureKeyVault"),
    ("03-keyvault-firewall.png", "A3. S3 — Firewall del Key Vault: solo snet-app (service endpoint) e IP del operador"),
    ("04-kql-keyvault-secretget.png", "A4. S6 — KQL en Log Analytics: SecretGet por la identidad administrada del VMSS"),
    ("05-vmss-instancias-zonas-scaleout.png", "A5. E1/E3 — Tres instancias sanas durante el scale-out de P1.2"),
    ("06-autoscale-historial-ejecucion.png", "A6. E3 — Historial de ejecución del autoscale (scale up 14:28, scale down 14:43, hora local)"),
    ("07-sonda-health-probe-status.png", "A7. E2 — Health Probe Status por instancia: 10.20.1.5 cae a 0 % tras la falla lógica"),
    ("08-alertas-disparadas.png", "A8. E5 — Alertas disparadas: sonda < 100 % (Sev1) y denegaciones de Azure Policy"),
    ("09-pr1-checkov-bloquea.png", "A9. D1 — PR #1 (abría SSH a Internet) bloqueado por el job «checkov (bloqueante)»: CKV_AZURE_10"),
]:
    anexos.append(img(EVID / "capturas" / f, cap, "100%"))
anexos.append(
    "## Anexo B. Archivos de evidencia\n\nTodos en la carpeta `evidencias/` del repositorio: reportes HTML y CSV de Locust "
    "(`p1-capacidad*`, `p1-escalonada*`, `p2-falla-logica*`, `p2-falla-abrupta*`), métricas exportadas de Azure Monitor "
    "(`p1-observed-capacity.json`, `p1-vmss-cpu.json`, `p1-lb-dipavailability.json`), historial del autoscale, salidas de las "
    "pruebas de seguridad (`p3-*`), reparación automática (`e4-reparacion-automatica.txt`), alertas (`e5-alertas-disparadas.txt`) "
    "y los registros de `terraform apply`."
)

portada = """
<section class="portada">
<p class="inst">Universidad Tecnológica de Bolívar<br>Infraestructura para TI</p>
<h1>Taller integrador</h1>
<h2>Plataforma segura, escalable y altamente disponible<br>Caso CaribeShop</h2>
<p class="sub">Azure · Terraform · GitHub Actions · Checkov · Locust</p>
<table class="meta">
<tr><td>Integrantes</td><td>______________________________<br>______________________________<br>______________________________</td></tr>
<tr><td>Repositorio</td><td>https://github.com/LuisCaPacheco/caribeshop-taller-integrador</td></tr>
<tr><td>Video</td><td>https://youtu.be/______</td></tr>
<tr><td>Fecha</td><td>Noviembre de 2026</td></tr>
</table>
</section>
"""

html_body = markdown.markdown(cuerpo, extensions=["tables", "fenced_code"])
html_body = re.sub(r'<pre><code class="language-mermaid">(.*?)</code></pre>',
                   lambda m: '<div class="mermaid">' + m.group(1).replace("&gt;", ">").replace("&lt;", "<").replace("&quot;", '"').replace("&amp;", "&") + "</div>",
                   html_body, flags=re.S)
html_anexos = markdown.markdown("\n\n".join(anexos), extensions=["tables"])

css = """
@page { size: A4; margin: 1.5cm 1.6cm 1.6cm 1.6cm; }
body { font-family: 'Segoe UI', Calibri, Arial, sans-serif; font-size: 9.6pt; line-height: 1.38; color: #1b1f24; }
h1, h2, h3 { color: #0b3c5d; }
h2 { font-size: 13.5pt; border-bottom: 2px solid #0b3c5d; padding-bottom: 2px; margin: 16px 0 6px; page-break-after: avoid; }
h3 { font-size: 11pt; margin: 12px 0 4px; page-break-after: avoid; }
p { margin: 4px 0 6px; text-align: justify; }
table { border-collapse: collapse; width: 100%; margin: 6px 0 10px; font-size: 8.4pt; page-break-inside: auto; }
th, td { border: 1px solid #c9d1d9; padding: 3px 5px; vertical-align: top; text-align: left; }
th { background: #e8f0f7; }
tr { page-break-inside: avoid; }
code { font-family: Consolas, monospace; font-size: 8.2pt; background: #f2f4f7; padding: 0 2px; border-radius: 2px; }
pre { background: #f6f8fa; border: 1px solid #d0d7de; padding: 6px 8px; font-size: 8.2pt; white-space: pre-wrap; page-break-inside: avoid; }
pre code { background: none; }
figure { margin: 8px 0; text-align: center; page-break-inside: avoid; }
figure img { border: 1px solid #d0d7de; }
figcaption, .cap { font-size: 8.4pt; color: #57606a; text-align: center; margin-top: 2px; }
.mermaid { text-align: center; margin: 6px 0; }
.mermaid svg { max-width: 100%; max-height: 520px; }
blockquote { border-left: 3px solid #0b3c5d; margin: 6px 0; padding: 2px 10px; color: #444; background: #f6f8fa; }
.portada { height: 25cm; display: flex; flex-direction: column; justify-content: center; text-align: center; page-break-after: always; }
.portada h1 { font-size: 30pt; margin: 10px 0; } .portada h2 { font-size: 16pt; border: 0; font-weight: 500; }
.portada .inst { font-size: 13pt; color: #0b3c5d; } .portada .sub { color: #57606a; margin-bottom: 40px; text-align: center; }
.portada table.meta { width: 70%; margin: 0 auto; font-size: 10.5pt; } .portada table.meta td { border: 0; padding: 6px; }
.portada table.meta td:first-child { font-weight: 600; color: #0b3c5d; width: 30%; text-align: right; }
.anexos { page-break-before: always; } .anexos figure { page-break-inside: avoid; margin-bottom: 14px; }
"""

html = f"""<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Informe CaribeShop</title>
<style>{css}</style>
<script src="https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js"></script>
</head><body>
{portada}
{html_body}
<div class="anexos">{html_anexos}</div>
<script>mermaid.initialize({{startOnLoad:true, theme:'neutral', flowchart:{{useMaxWidth:true}}}});</script>
</body></html>"""

out_html = DOCS / "informe.html"
out_html.write_text(html, encoding="utf-8")

browser = None
for cand in [r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
             r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
             r"C:\Program Files\Google\Chrome\Application\chrome.exe", "google-chrome", "chromium"]:
    if os.path.exists(cand) or not cand.endswith(".exe"):
        browser = cand
        break
pdf = DOCS / "Informe-CaribeShop.pdf"
subprocess.run([browser, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                "--virtual-time-budget=15000", f"--print-to-pdf={pdf}", out_html.as_uri()], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(f"PDF: {pdf}")
