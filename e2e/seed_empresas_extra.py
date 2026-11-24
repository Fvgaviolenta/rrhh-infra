#!/usr/bin/env python3
"""Empresas ficticias extra para mostrar la consola de plataforma (datos de demo, sin personas reales).

  - Empresa Gamma SpA, ACTIVA: Admin de RRHH admin.gamma@rrhh.local y un Trabajador con cuenta
    (trabajador.gamma@rrhh.local), creado por el admin con la API como en el flujo real.
  - Empresa Delta SpA, PENDIENTE_ACTIVACION: la registra admin.delta@rrhh.local con POST /api/v1/tenants,
    como lo haría una persona nueva. El AdminPlataforma la activa o rechaza desde la consola.

La fila de Gamma se inserta por SQL (vía SSM) porque activar exige el AdminPlataforma, que solo entra con Google.
Es idempotente. Escribe las contraseñas en E2E_EXTRA_ENV_FILE (por defecto ../.env.demo-extra, ignorado por git).

Variables: E2E_API_URL, E2E_COGNITO_CLIENT_ID, E2E_USER_POOL_ID, E2E_DATA_INSTANCE_ID, AWS_REGION.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from e2e_check import claims_de, datos, http, login_cognito  # noqa: E402
from seed_demo import clave, cuenta_con_clave, rut, sql_en_ec2, token_vinculado, trabajador  # noqa: E402

TENANT_GAMMA = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
ADMIN_GAMMA = "admin.gamma@rrhh.local"
TRAB_GAMMA = "trabajador.gamma@rrhh.local"
ADMIN_DELTA = "admin.delta@rrhh.local"
RUT_DELTA = 79999999


def main() -> int:
    region = os.environ.get("AWS_REGION", "us-east-1")
    try:
        api = os.environ["E2E_API_URL"].rstrip("/")
        client = os.environ["E2E_COGNITO_CLIENT_ID"]
        pool = os.environ["E2E_USER_POOL_ID"]
        instancia = os.environ["E2E_DATA_INSTANCE_ID"]
    except KeyError as e:
        print(f"Falta la variable {e}", file=sys.stderr)
        return 2
    destino = Path(os.environ.get("E2E_EXTRA_ENV_FILE",
                                  Path(__file__).resolve().parent.parent / ".env.demo-extra"))
    claves = {ADMIN_GAMMA: clave(), TRAB_GAMMA: clave(), ADMIN_DELTA: clave()}

    print("1. Empresa Gamma (activa) y su admin")
    sql_en_ec2(instancia, region, f"""
INSERT IGNORE INTO identity_tenant (id, nombre_empresa, rut_empresa, pais, activo, creado_en, slug, estado, razon_social,
  giro, comuna, region)
VALUES ('{TENANT_GAMMA}', 'Empresa Gamma SpA', '{rut(78888888)}', 'Chile', TRUE, NOW(), 'empresa-gamma-spa', 'ACTIVO',
  'Empresa Gamma SpA', 'Servicios informáticos', 'Valparaíso', 'Valparaíso');
INSERT IGNORE INTO identity_usuario (id, tenant_id, email, rol, activo, creado_en, estado, nombre)
VALUES ('eeeeeeee-eeee-eeee-eeee-eeeeeeeee001', '{TENANT_GAMMA}', '{ADMIN_GAMMA}', 'Admin de RRHH', TRUE, NOW(), 'ACTIVO',
  'Admin Gamma');""")
    cuenta_con_clave(pool, region, ADMIN_GAMMA, claves[ADMIN_GAMMA], crear=True)
    tg = token_vinculado(api, region, client, ADMIN_GAMMA, claves[ADMIN_GAMMA])
    print(f"   admin Gamma: {claims_de(tg).get('custom:role')} en {claims_de(tg).get('custom:tenant_id')}")

    print("2. Trabajador de Gamma con cuenta")
    trab = trabajador(api, tg, TRAB_GAMMA, "Trabajadora", "Gamma", 13579246)
    r = http("POST", f"{api}/api/v1/usuarios/invitar", tg,
             {"email": TRAB_GAMMA, "trabajador_id": trab, "nombre": "Trabajadora Gamma", "rol": "Trabajador",
              "crear_en_cognito": True})
    if r.status not in (200, 201) and "ya existe" not in r.texto:
        raise RuntimeError(f"invitar: HTTP {r.status} {r.texto}")
    cuenta_con_clave(pool, region, TRAB_GAMMA, claves[TRAB_GAMMA], crear=False)
    tt = token_vinculado(api, region, client, TRAB_GAMMA, claves[TRAB_GAMMA])
    print(f"   trabajador Gamma: {claims_de(tt).get('custom:role')}, ficha {claims_de(tt).get('custom:trabajador_id')}")

    print("3. Empresa Delta registrada por API (queda pendiente de activación)")
    cuenta_con_clave(pool, region, ADMIN_DELTA, claves[ADMIN_DELTA], crear=True)
    td = login_cognito(region, client, ADMIN_DELTA, claves[ADMIN_DELTA])
    me = datos(http("GET", f"{api}/api/v1/auth/me", td).cuerpo) or {}
    if me.get("tenant_id"):
        print(f"   ya registrada: tenant {me.get('tenant_id')}, estado de la cuenta {me.get('estado')}")
    else:
        r = http("POST", f"{api}/api/v1/tenants", td, {
            "razon_social": "Empresa Delta SpA", "nombre_fantasia": "Empresa Delta", "rut_empresa": rut(RUT_DELTA),
            "giro": "Comercio al por menor", "codigo_actividad": "471100", "direccion_calle": "Avenida Ficticia",
            "direccion_numero": "1234", "comuna": "Concepción", "region": "Biobío",
            "email_contacto": ADMIN_DELTA, "telefono_contacto": "+56900000000",
            "representante_nombre": "Representante Delta", "representante_rut": rut(15555555),
            "acepta_terminos": True})
        print(f"   registro: HTTP {r.status} {(datos(r.cuerpo) or {}).get('estado') if r.status == 201 else r.texto}")

    destino.write_text("".join(f"{k}={v}\n" for k, v in claves.items()))
    destino.chmod(0o600)
    print(f"\nContraseñas en {destino}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
