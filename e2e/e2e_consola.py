#!/usr/bin/env python3
"""Prueba de punta a punta de la consola de plataforma (ADR-020) en el lab, sin login de Google.

Cubre los pasos 2, 3 y 5 de la verificación de la spec con un OperadorSaaS de contraseña (más el mensaje del paso 4
en la app): alcance por grupo en identity y en los cuatro servicios con ruta de plataforma, cambio de rol visible en
el siguiente login, mensaje al Admin de RRHH, suspensión con un token previo bloqueado en los seis servicios y login
rechazado, y reactivación. Deja el lab como estaba: Gamma ACTIVO, trabajador.gamma como Trabajador y el grupo de
prueba borrado (también si algo falla a la mitad). Usa solo empresas y cuentas ficticias (seed_demo.py y
seed_empresas_extra.py); no imprime contraseñas.

Variables: E2E_API_URL, E2E_COGNITO_CLIENT_ID, E2E_USER_POOL_ID, E2E_DATA_INSTANCE_ID, AWS_REGION y
E2E_EXTRA_ENV_FILE (contraseñas de Gamma que escribe seed_empresas_extra.py; por defecto ../.env.demo-extra).
"""
from __future__ import annotations

import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from e2e_check import Informe, claims_de, datos, esperar, http, login_cognito  # noqa: E402

DEMO = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
BETA = "cccccccc-cccc-cccc-cccc-cccccccccccc"
GAMMA = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
OPERADOR = "operador.consola@rrhh.local"
OPERADOR_ID = "0bea0000-0000-4000-8000-0000000000c1"
GRUPO_ID = "0bea0000-0000-4000-8000-0000000000e2"
ADMIN_GAMMA = "admin.gamma@rrhh.local"
TRAB_GAMMA = "trabajador.gamma@rrhh.local"
RUTAS_EMPRESA = ["/api/v1/auth/me", "/api/v1/trabajadores", "/api/v1/contratos", "/api/v1/turnos",
                 "/api/v1/solicitudes-ausencia", "/api/v1/notificaciones"]
SUSPENDIDA = "La empresa est"


def es_bloqueo_por_suspension(status: int, texto: str) -> bool:
    """403 del filtro de suspensión: otro 403 (rol sin permiso) no cuenta."""
    return status == 403 and SUSPENDIDA in (texto or "")


def rutas_de_plataforma(tenant_id: str) -> list[str]:
    base = f"/api/v1/plataforma/tenants/{tenant_id}"
    return [f"{base}/{recurso}" for recurso in ("usuarios", "trabajadores", "contratos", "ausencias", "notificaciones")]


def main() -> int:
    from seed_demo import clave, cuenta_con_clave, sql_en_ec2  # importa boto/CLI solo al correr la prueba

    region = os.environ.get("AWS_REGION", "us-east-1")
    try:
        api = os.environ["E2E_API_URL"].rstrip("/")
        client = os.environ["E2E_COGNITO_CLIENT_ID"]
        pool = os.environ["E2E_USER_POOL_ID"]
        instancia = os.environ["E2E_DATA_INSTANCE_ID"]
    except KeyError as e:
        print(f"Falta la variable {e}", file=sys.stderr)
        return 2
    extra = Path(os.environ.get("E2E_EXTRA_ENV_FILE", Path(__file__).resolve().parent.parent / ".env.demo-extra"))
    claves = dict(l.strip().split("=", 1) for l in extra.read_text().splitlines() if "=" in l)

    def sql(s: str) -> str:
        return sql_en_ec2(instancia, region, s)

    inf = Informe()
    inf.seccion("Consola: operador de contraseña y grupo de prueba con Demo y Gamma")
    sql(f"""
INSERT IGNORE INTO identity_usuario (id, tenant_id, email, rol, activo, creado_en, estado, nombre)
VALUES ('{OPERADOR_ID}', NULL, '{OPERADOR}', 'OperadorSaaS', TRUE, NOW(), 'ACTIVO', 'Operador Consola');
INSERT IGNORE INTO identity_grupo_empresas (id, nombre, creado_en) VALUES ('{GRUPO_ID}', 'E2E consola', NOW());
INSERT IGNORE INTO identity_grupo_tenant (grupo_id, tenant_id) VALUES ('{GRUPO_ID}', '{DEMO}'), ('{GRUPO_ID}', '{GAMMA}');
INSERT IGNORE INTO identity_grupo_operador (grupo_id, usuario_id) VALUES ('{GRUPO_ID}', '{OPERADOR_ID}');""")
    clave_op = clave()
    cuenta_con_clave(pool, region, OPERADOR, clave_op, crear=True)
    http("GET", f"{api}/api/v1/auth/me", login_cognito(region, client, OPERADOR, clave_op))
    top = login_cognito(region, client, OPERADOR, clave_op)
    inf.check("token del operador con rol OperadorSaaS", claims_de(top).get("custom:role") == "OperadorSaaS")
    trab_id = None
    try:
        inf.seccion("Paso 2: alcance por grupo")
        r = http("GET", f"{api}/api/v1/plataforma/tenants", top)
        ids = {e["id"] for e in (datos(r.cuerpo) or [])}
        inf.check("la consola lista solo Demo y Gamma", r.status == 200 and ids == {DEMO, GAMMA}, f"HTTP {r.status}")
        for ruta in rutas_de_plataforma(GAMMA):
            inf.check(f"{ruta} -> 200", http("GET", f"{api}{ruta}", top).status == 200)
        for ruta in rutas_de_plataforma(BETA):
            r = http("GET", f"{api}{ruta}", top)
            inf.check(f"{ruta} -> 404", r.status == 404, f"HTTP {r.status}")

        inf.seccion("Paso 3: cambio de rol desde la plataforma")
        integrantes = datos(http("GET", f"{api}/api/v1/plataforma/tenants/{GAMMA}/usuarios", top).cuerpo) or []
        trab_id = next((u["id"] for u in integrantes if u.get("email") == TRAB_GAMMA), None)
        r = http("PATCH", f"{api}/api/v1/plataforma/tenants/{GAMMA}/usuarios/{trab_id}/rol", top, {"rol": "Jefatura"})
        inf.check("PATCH rol -> 200 Jefatura", r.status == 200 and (datos(r.cuerpo) or {}).get("rol") == "Jefatura", f"HTTP {r.status}")
        rol = claims_de(login_cognito(region, client, TRAB_GAMMA, claves[TRAB_GAMMA])).get("custom:role")
        inf.check("el siguiente login trae custom:role = Jefatura", rol == "Jefatura", f"custom:role={rol}")

        inf.seccion("Paso 4: mensaje al Admin de RRHH (en la app)")
        asunto = f"E2E consola {uuid.uuid4().hex[:6]}"
        r = http("POST", f"{api}/api/v1/plataforma/tenants/{GAMMA}/mensajes", top, {"asunto": asunto, "cuerpo": "Prueba e2e de la consola."})
        inf.check("POST mensajes -> 202", r.status == 202, f"HTTP {r.status}")
        tg = login_cognito(region, client, ADMIN_GAMMA, claves[ADMIN_GAMMA])
        visto = esperar(lambda: any(n.get("asunto") == asunto for n in (datos(http("GET", f"{api}/api/v1/notificaciones", tg).cuerpo) or [])), 60)
        inf.check("admin.gamma ve la notificación en la app (< 60 s)", bool(visto))

        inf.seccion("Paso 5: suspensión y reactivación")
        r = http("POST", f"{api}/api/v1/plataforma/tenants/{GAMMA}/suspender", top, {"motivo": "Prueba e2e de la consola"})
        inf.check("suspender -> 200 SUSPENDIDO", r.status == 200 and (datos(r.cuerpo) or {}).get("estado") == "SUSPENDIDO", f"HTTP {r.status}")
        inicio = time.monotonic()
        def bloqueado_en(ruta: str) -> bool:
            r = http("GET", f"{api}{ruta}", tg)
            return es_bloqueo_por_suspension(r.status, r.texto)

        for ruta in RUTAS_EMPRESA:
            bloqueado = esperar(lambda: bloqueado_en(ruta), 75)
            inf.check(f"token previo en {ruta} -> 403 suspendida", bool(bloqueado), f"a los {round(time.monotonic() - inicio, 1)} s")
        try:
            login_cognito(region, client, ADMIN_GAMMA, claves[ADMIN_GAMMA])
            inf.check("login de admin.gamma rechazado", False, "el login funcionó")
        except RuntimeError as e:
            inf.check("login de admin.gamma rechazado", "NotAuthorized" in str(e), str(e)[:80])
        r = http("POST", f"{api}/api/v1/plataforma/tenants/{GAMMA}/reactivar", top)
        inf.check("reactivar -> 200 ACTIVO", r.status == 200 and (datos(r.cuerpo) or {}).get("estado") == "ACTIVO", f"HTTP {r.status}")
        t2 = login_cognito(region, client, ADMIN_GAMMA, claves[ADMIN_GAMMA])
        inf.check("login y /auth/me de admin.gamma vuelven", http("GET", f"{api}/api/v1/auth/me", t2).status == 200)
    finally:
        http("POST", f"{api}/api/v1/plataforma/tenants/{GAMMA}/reactivar", top)
        if trab_id:
            http("PATCH", f"{api}/api/v1/plataforma/tenants/{GAMMA}/usuarios/{trab_id}/rol", top, {"rol": "Trabajador"})
        sql(f"""DELETE FROM identity_grupo_operador WHERE grupo_id = '{GRUPO_ID}';
DELETE FROM identity_grupo_tenant WHERE grupo_id = '{GRUPO_ID}';
DELETE FROM identity_grupo_empresas WHERE id = '{GRUPO_ID}';""")
        print("\nEstado final:", sql(f"SELECT estado FROM identity_tenant WHERE id = '{GAMMA}'; "
                                     f"SELECT rol FROM identity_usuario WHERE email = '{TRAB_GAMMA}';").split())

    total = len(inf.resultados)
    print(f"\nResultado: {total - inf.fallos} de {total} en PASS")
    return 1 if inf.fallos else 0


if __name__ == "__main__":
    sys.exit(main())
