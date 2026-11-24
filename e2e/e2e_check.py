#!/usr/bin/env python3
"""Prueba de punta a punta del sistema desplegado (HTTP API + Cognito + microservicios + SQS + Kinesis).

Recorre los flujos que se muestran en la demo, con usuarios reales de Cognito, y verifica:
  1. Autenticación: login con contraseña en Cognito y claims de tenant y rol en el idToken.
  2. Aislamiento por tenant: la empresa B no ve trabajadores, marcas ni ausencias de la empresa A.
  3. Roles: un Trabajador no lista trabajadores ni evalúa su propia ausencia.
  4. Asistencia: marca de entrada y su listado.
  5. Ausencias y SQS: solicitud, aprobación y aviso al trabajador por notifications (evento por SQS).
  6. Streaming: marca tardía -> Kinesis rrhh-events -> Lambda rrhh-atrasos -> SQS -> aviso de atraso.
  7. Contratos: "mi contrato" del trabajador.
  8. Errores: sin token 401 y ruta inexistente 404.

Solo usa la biblioteca estándar. Las contraseñas se leen de variables de entorno y nunca se imprimen.

Variables obligatorias:
  E2E_API_URL            salida http_api_url de Terraform (sin / final)
  E2E_COGNITO_CLIENT_ID  salida cognito_client_id
  E2E_ADMIN_A_EMAIL / E2E_ADMIN_A_PASSWORD   Admin de RRHH de la empresa A
  E2E_TRAB_A_EMAIL  / E2E_TRAB_A_PASSWORD    Trabajador de la empresa A (con custom:trabajador_id)
  E2E_ADMIN_B_EMAIL / E2E_ADMIN_B_PASSWORD   Admin de RRHH de la empresa B
Opcionales:
  AWS_REGION (us-east-1), E2E_ESPERA_SQS_S (90), E2E_ESPERA_STREAMING_S (150), E2E_SIN_STREAMING=1

Uso: python3 e2e/e2e_check.py      (sale con 0 si todo pasa, 1 si algo falla, 2 si falta configuración)
"""
from __future__ import annotations

import base64
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass, field
from zoneinfo import ZoneInfo

ZONA = ZoneInfo("America/Santiago")  # la misma zona que usa rrhh-asistencia
TOLERANCIA_MIN = 5                    # TOLERANCIA_MINUTOS de la Lambda rrhh-atrasos


# ---------------------------------------------------------------- utilidades puras (con tests)

def claims_de(token: str) -> dict:
    """Payload de un JWT sin verificar la firma (la verifica el API Gateway)."""
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def turno_atrasado(ahora: dt.datetime, minutos_antes: int = 60) -> tuple[str, str]:
    """Horas HH:MM de un turno que empezó `minutos_antes` antes de `ahora`, en la zona de Chile.

    La marca de ahora queda tarde por más que la tolerancia. Si el inicio cae el día anterior se usa 00:00,
    y el fin es inicio + 8 h acotado a 23:59.
    """
    local = ahora.astimezone(ZONA)
    inicio = local - dt.timedelta(minutes=minutos_antes)
    if inicio.date() != local.date():
        inicio = local.replace(hour=0, minute=0)
    fin = min(inicio + dt.timedelta(hours=8), local.replace(hour=23, minute=59))
    return inicio.strftime("%H:%M"), fin.strftime("%H:%M")


def datos(respuesta: dict | list | None):
    """El campo `datos` de ApiResponse, o la respuesta tal cual si no viene envuelta."""
    if isinstance(respuesta, dict) and "datos" in respuesta:
        return respuesta["datos"]
    return respuesta


# ---------------------------------------------------------------- clientes HTTP

@dataclass
class Respuesta:
    status: int
    cuerpo: dict | list | None
    texto: str = ""


def http(metodo: str, url: str, token: str | None = None, cuerpo: dict | None = None,
         headers: dict | None = None) -> Respuesta:
    h = {"Accept": "application/json"}
    if headers:
        h.update(headers)
    data = None
    if cuerpo is not None:
        data = json.dumps(cuerpo).encode()
        h.setdefault("Content-Type", "application/json")
    if token:
        h["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, method=metodo, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            texto = r.read().decode("utf-8", "replace")
            status = r.status
    except urllib.error.HTTPError as e:
        texto = e.read().decode("utf-8", "replace")
        status = e.code
    try:
        parsed = json.loads(texto) if texto else None
    except json.JSONDecodeError:
        parsed = None
    return Respuesta(status, parsed, texto[:300])


def login_cognito(region: str, client_id: str, email: str, password: str) -> str:
    """idToken con USER_PASSWORD_AUTH (habilitado en el app client `spa`). Es el token que usa el frontend."""
    r = http("POST", f"https://cognito-idp.{region}.amazonaws.com/",
             cuerpo={"AuthFlow": "USER_PASSWORD_AUTH", "ClientId": client_id,
                     "AuthParameters": {"USERNAME": email, "PASSWORD": password}},
             headers={"Content-Type": "application/x-amz-json-1.1",
                      "X-Amz-Target": "AWSCognitoIdentityProviderService.InitiateAuth"})
    if r.status != 200 or not isinstance(r.cuerpo, dict):
        raise RuntimeError(f"login de {email} falló: HTTP {r.status} {r.texto}")
    if "ChallengeName" in r.cuerpo:
        raise RuntimeError(f"login de {email} pide {r.cuerpo['ChallengeName']}: "
                           "fija una contraseña permanente antes de correr la prueba")
    return r.cuerpo["AuthenticationResult"]["IdToken"]


# ---------------------------------------------------------------- registro de resultados

@dataclass
class Informe:
    resultados: list[tuple[str, bool, str]] = field(default_factory=list)

    def check(self, nombre: str, ok: bool, detalle: str = "") -> bool:
        self.resultados.append((nombre, ok, detalle))
        print(f"  [{'PASS' if ok else 'FAIL'}] {nombre}" + (f"  ({detalle})" if detalle else ""), flush=True)
        return ok

    def seccion(self, titulo: str) -> None:
        print(f"\n== {titulo}", flush=True)

    @property
    def fallos(self) -> int:
        return sum(1 for _, ok, _ in self.resultados if not ok)


def esperar(condicion, segundos: int, cada: float = 5.0):
    """Repite `condicion()` hasta que devuelva algo truthy o se acabe el tiempo; devuelve el último valor."""
    limite = time.monotonic() + segundos
    valor = condicion()
    while not valor and time.monotonic() < limite:
        time.sleep(cada)
        valor = condicion()
    return valor


# ---------------------------------------------------------------- la prueba

def main() -> int:
    requeridas = ["E2E_API_URL", "E2E_COGNITO_CLIENT_ID",
                  "E2E_ADMIN_A_EMAIL", "E2E_ADMIN_A_PASSWORD",
                  "E2E_TRAB_A_EMAIL", "E2E_TRAB_A_PASSWORD",
                  "E2E_ADMIN_B_EMAIL", "E2E_ADMIN_B_PASSWORD"]
    faltan = [v for v in requeridas if not os.environ.get(v)]
    if faltan:
        print("Faltan variables: " + ", ".join(faltan), file=sys.stderr)
        return 2
    api = os.environ["E2E_API_URL"].rstrip("/")
    region = os.environ.get("AWS_REGION", "us-east-1")
    espera_sqs = int(os.environ.get("E2E_ESPERA_SQS_S", "90"))
    espera_stream = int(os.environ.get("E2E_ESPERA_STREAMING_S", "150"))
    inf = Informe()
    url = lambda p: f"{api}{p}"  # noqa: E731

    # 1. Autenticación ---------------------------------------------------------
    inf.seccion("1. Autenticación con Cognito")
    tokens = {}
    for clave in ("ADMIN_A", "TRAB_A", "ADMIN_B"):
        try:
            tokens[clave] = login_cognito(region, os.environ["E2E_COGNITO_CLIENT_ID"],
                                          os.environ[f"E2E_{clave}_EMAIL"], os.environ[f"E2E_{clave}_PASSWORD"])
            inf.check(f"login {clave}", True)
        except RuntimeError as e:
            inf.check(f"login {clave}", False, str(e))
    if len(tokens) < 3:
        print("\nSin los tres logins no se puede seguir.")
        return 1
    ca, ct, cb = (claims_de(tokens[k]) for k in ("ADMIN_A", "TRAB_A", "ADMIN_B"))
    tenant_a, tenant_b = ca.get("custom:tenant_id"), cb.get("custom:tenant_id")
    trab_a = ct.get("custom:trabajador_id")
    inf.check("claims: admin A y trabajador A en la misma empresa", tenant_a and tenant_a == ct.get("custom:tenant_id"))
    inf.check("claims: empresa B distinta de A", tenant_b and tenant_b != tenant_a)
    inf.check("claims: roles", ca.get("custom:role") in ("Admin de RRHH", "SuperAdmin")
              and ct.get("custom:role") == "Trabajador", f"{ca.get('custom:role')} / {ct.get('custom:role')}")
    if not inf.check("claims: trabajador A vinculado a una ficha", bool(trab_a)):
        return 1
    A, T, Bt = tokens["ADMIN_A"], tokens["TRAB_A"], tokens["ADMIN_B"]

    r = http("GET", url("/api/v1/auth/me"), A)
    inf.check("identity /auth/me devuelve el tenant del token", r.status == 200
              and (datos(r.cuerpo) or {}).get("tenant_id") == tenant_a, f"HTTP {r.status}")

    # 8 (parte). Errores de borde ----------------------------------------------
    inf.seccion("2. API Gateway y errores")
    r = http("GET", url("/api/v1/trabajadores"))
    inf.check("sin token: 401 en el API Gateway", r.status == 401, f"HTTP {r.status}")
    r = http("GET", url("/api/v1/asistencia/no-existe"), A)
    inf.check("ruta inexistente: 404 (no 500)", r.status == 404, f"HTTP {r.status}")

    # 2-3. Trabajadores, aislamiento y roles ----------------------------------
    inf.seccion("3. Trabajadores: aislamiento por tenant y roles")
    r = http("GET", url("/api/v1/trabajadores"), A)
    lista = datos(r.cuerpo) or []
    inf.check("admin A lista trabajadores", r.status == 200 and isinstance(lista, list), f"HTTP {r.status}, {len(lista)}")
    inf.check("todos los trabajadores listados son de la empresa A",
              all(t.get("tenant_id") == tenant_a for t in lista) and len(lista) > 0)
    inf.check("la ficha del trabajador A está en la lista", any(t.get("id") == trab_a for t in lista))
    r = http("GET", url(f"/api/v1/trabajadores/{trab_a}"), Bt)
    inf.check("admin B no ve la ficha de un trabajador de A", r.status in (403, 404), f"HTTP {r.status}")
    r = http("GET", url("/api/v1/trabajadores"), T)
    inf.check("un Trabajador no lista trabajadores (403)", r.status == 403, f"HTTP {r.status}")
    r = http("GET", url(f"/api/v1/trabajadores/{trab_a}"), T)
    inf.check("un Trabajador ve su propia ficha", r.status == 200, f"HTTP {r.status}")

    # 6 (preparación). Turno que ya empezó, para que la marca llegue tarde -----
    inf.seccion("4. Asistencia: turno, marca y streaming de atrasos")
    marca_id = None
    stream_ok = os.environ.get("E2E_SIN_STREAMING") != "1"
    if stream_ok:
        inicio, fin = turno_atrasado(dt.datetime.now(dt.timezone.utc))
        r = http("POST", url("/api/v1/turnos"), A,
                 {"nombre": f"E2E atraso {inicio}", "hora_inicio": f"{inicio}:00", "hora_fin": f"{fin}:00"})
        turno_id = (datos(r.cuerpo) or {}).get("id")
        inf.check(f"admin A crea turno que empezó a las {inicio}", r.status == 201 and bool(turno_id), f"HTTP {r.status}")
        hoy = dt.datetime.now(ZONA).date().isoformat()
        r = http("POST", url("/api/v1/jornadas"), A, {"trabajador_id": trab_a, "turno_id": turno_id, "fecha": hoy})
        if r.status == 409 or (r.status == 400 and "ya tiene una jornada" in r.texto):
            # Segunda corrida del día: la regla de una jornada por día responde 400.
            inf.check("jornada de hoy", True, "ya existía: el atraso depende de su turno")
        else:
            inf.check("admin A asigna la jornada de hoy al trabajador A", r.status == 201, f"HTTP {r.status}")
    notif_admin_antes = {n.get("id") for n in (datos(http("GET", url("/api/v1/notificaciones"), A).cuerpo) or [])}

    # 4. Marca de entrada --------------------------------------------------------
    r = http("POST", url("/api/v1/asistencia/registro"), T, {"trabajador_id": trab_a, "tipo": "ENTRADA", "origen": "E2E"})
    if r.status == 409:
        # El trabajador ya marcó hoy: el admin registra la entrada por él (también publica el evento).
        r = http("POST", url("/api/v1/asistencia/registro"), A, {"trabajador_id": trab_a, "tipo": "ENTRADA", "origen": "E2E"})
        inf.check("marca de entrada (el trabajador ya había marcado; la registra el admin)", r.status == 201, f"HTTP {r.status}")
    else:
        inf.check("el trabajador A registra su entrada", r.status == 201, f"HTTP {r.status}")
    marca_id = (datos(r.cuerpo) or {}).get("id")
    r = http("POST", url("/api/v1/asistencia/registro"), T, {"trabajador_id": trab_a, "tipo": "ENTRADA", "origen": "E2E"})
    inf.check("segunda marca del día: 409", r.status == 409, f"HTTP {r.status}")
    ids_a = {m.get("id") for m in (datos(http("GET", url("/api/v1/marcas-asistencia"), A).cuerpo) or [])}
    ids_b = {m.get("id") for m in (datos(http("GET", url("/api/v1/marcas-asistencia"), Bt).cuerpo) or [])}
    inf.check("admin A ve la marca", marca_id in ids_a)
    inf.check("admin B no ve la marca", bool(marca_id) and marca_id not in ids_b)

    # 5. Ausencia: solicitud, reglas, aprobación y aviso por SQS --------------
    inf.seccion("5. Ausencias y notificaciones por SQS")
    notif_trab_antes = {n.get("id") for n in (datos(http("GET", url("/api/v1/notificaciones"), T).cuerpo) or [])}
    fecha = (dt.datetime.now(ZONA).date() + dt.timedelta(days=30)).isoformat()
    r = http("POST", url("/api/v1/solicitudes-ausencia"), T,
             {"fecha": fecha, "tipo": "Permiso administrativo", "motivo": f"E2E {uuid.uuid4().hex[:8]}"})
    sol = datos(r.cuerpo) or {}
    inf.check("el trabajador A solicita una ausencia (PENDIENTE)", r.status == 201 and sol.get("estado") == "PENDIENTE",
              f"HTTP {r.status}")
    sid = sol.get("id")
    r = http("PATCH", url(f"/api/v1/solicitudes-ausencia/{sid}"), T, {"estado": "APROBADO"})
    inf.check("el trabajador no puede aprobar su propia ausencia (403)", r.status == 403, f"HTTP {r.status}")
    r = http("PATCH", url(f"/api/v1/solicitudes-ausencia/{sid}"), Bt, {"estado": "APROBADO"})
    inf.check("admin B no puede evaluar la ausencia de A", r.status in (403, 404), f"HTTP {r.status}")
    r = http("PATCH", url(f"/api/v1/solicitudes-ausencia/{sid}"), A, {"estado": "APROBADO"})
    inf.check("admin A aprueba la ausencia", r.status == 200 and (datos(r.cuerpo) or {}).get("estado") == "APROBADO",
              f"HTTP {r.status}")

    def aviso_ausencia():
        nuevas = [n for n in (datos(http("GET", url("/api/v1/notificaciones"), T).cuerpo) or [])
                  if n.get("id") not in notif_trab_antes]
        return [n for n in nuevas if n.get("referencia_id") == sid or n.get("tipo_evento") == "ausencia.aprobada"]
    t0 = time.monotonic()
    aviso = esperar(aviso_ausencia, espera_sqs)
    inf.check("el trabajador recibe el aviso de ausencia aprobada (outbox -> SQS -> notifications)", bool(aviso),
              f"{time.monotonic() - t0:.0f} s" if aviso else f"nada en {espera_sqs} s")

    # 6. Streaming: aviso de atraso ---------------------------------------------
    if stream_ok:
        inf.seccion("6. Streaming: Kinesis -> Lambda rrhh-atrasos -> SQS -> notifications")

        def aviso_atraso():
            return [n for n in (datos(http("GET", url("/api/v1/notificaciones"), A).cuerpo) or [])
                    if n.get("id") not in notif_admin_antes and n.get("tipo_evento") == "asistencia.atraso.detectado"]
        t0 = time.monotonic()
        aviso = esperar(aviso_atraso, espera_stream)
        inf.check("admin A recibe el aviso de atraso de la marca", bool(aviso),
                  f"{time.monotonic() - t0:.0f} s: {aviso[0].get('asunto')}" if aviso else
                  f"nada en {espera_stream} s (¿el trabajador tiene jefatura? el aviso va a ella)")

    # 7. Contratos --------------------------------------------------------------
    inf.seccion("7. Contratos")
    r = http("GET", url("/api/v1/contratos/mio"), T)
    inf.check("el trabajador consulta su contrato", r.status == 200, f"HTTP {r.status}")
    r = http("GET", url("/api/v1/contratos"), Bt)
    otros = [c for c in (datos(r.cuerpo) or []) if c.get("tenant_id") != tenant_b]
    inf.check("admin B solo ve contratos de su empresa", r.status == 200 and not otros, f"HTTP {r.status}")

    print(f"\nResultado: {len(inf.resultados) - inf.fallos} de {len(inf.resultados)} verificaciones pasaron.")
    return 0 if inf.fallos == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
