#!/usr/bin/env python3
"""Datos de demo para e2e_check.py en un lab recién desplegado (sin login de Google).

Crea, sin datos reales de personas:
  - Empresa A: la semilla de identity (Empresa Demo SpA) con su Admin de RRHH admin.demo@rrhh.local.
  - Empresa B: Empresa Beta SpA y su Admin de RRHH admin.beta@rrhh.local (fila insertada por SQL en la
    EC2 de datos vía SSM, porque activar una empresa exige el AdminPlataforma, que solo entra con Google).
  - Trabajador A: ficha en trabajadores y cuenta Trabajador creada por identity (invitar + Cognito).
  - Un trabajador en B y un contrato en espera de firma para el trabajador A.

Las cuentas de admin se crean en Cognito con contraseña permanente; identity las vincula a su fila por
correo en el primer /auth/me y les escribe custom:tenant_id y custom:role. Es idempotente.

Al final escribe las variables E2E_* en el archivo indicado por E2E_ENV_FILE (por defecto ../.env.e2e,
ignorado por git). Las contraseñas no se imprimen.

Variables: E2E_API_URL, E2E_COGNITO_CLIENT_ID, E2E_USER_POOL_ID, E2E_DATA_INSTANCE_ID, AWS_REGION.
Requiere AWS CLI con credenciales del lab.
"""
from __future__ import annotations

import json
import os
import secrets
import string
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from e2e_check import claims_de, datos, http, login_cognito  # noqa: E402

TENANT_A = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
TENANT_B = "cccccccc-cccc-cccc-cccc-cccccccccccc"
ADMIN_A = "admin.demo@rrhh.local"
ADMIN_B = "admin.beta@rrhh.local"
TRAB_A = "trabajador.demo@rrhh.local"
TRAB_B = "trabajador.beta@rrhh.local"


def dv_rut(numero: int) -> str:
    """Dígito verificador módulo 11 de un RUT chileno."""
    suma, factor = 0, 2
    for d in reversed(str(numero)):
        suma += int(d) * factor
        factor = 2 if factor == 7 else factor + 1
    resto = 11 - suma % 11
    return {11: "0", 10: "K"}.get(resto, str(resto))


def rut(numero: int) -> str:
    return f"{numero}-{dv_rut(numero)}"


def aws(*args: str) -> dict:
    salida = subprocess.run(["aws", *args, "--output", "json"], check=True, capture_output=True, text=True).stdout
    return json.loads(salida) if salida.strip() else {}


def clave() -> str:
    base = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(16))
    return base + "Aa1!"


def sql_en_ec2(instance_id: str, region: str, sentencias: str) -> str:
    """Corre SQL en el contenedor mysql de la EC2 de datos con SSM Run Command."""
    comando = (
        "DB_PASSWORD=$(docker inspect mysql --format '{{range .Config.Env}}{{println .}}{{end}}' "
        "| sed -n 's/^MYSQL_PASSWORD=//p'); "
        f"docker exec -i -e MYSQL_PWD=\"$DB_PASSWORD\" mysql mysql -urrhh rrhh_db <<'SQL'\n{sentencias}\nSQL"
    )
    cmd = aws("ssm", "send-command", "--region", region, "--instance-ids", instance_id,
              "--document-name", "AWS-RunShellScript", "--parameters", json.dumps({"commands": [comando]}))
    cid = cmd["Command"]["CommandId"]
    for _ in range(30):
        time.sleep(2)
        try:
            inv = aws("ssm", "get-command-invocation", "--region", region, "--command-id", cid, "--instance-id", instance_id)
        except subprocess.CalledProcessError:
            continue
        if inv["Status"] in ("Success", "Failed", "Cancelled", "TimedOut"):
            if inv["Status"] != "Success":
                raise RuntimeError(f"SQL falló: {inv['StandardErrorContent'][:500]}")
            return inv["StandardOutputContent"]
    raise RuntimeError("SQL sin respuesta de SSM")


def cuenta_con_clave(pool: str, region: str, email: str, password: str, crear: bool) -> None:
    if crear:
        try:
            aws("cognito-idp", "admin-get-user", "--region", region, "--user-pool-id", pool, "--username", email)
        except subprocess.CalledProcessError:
            aws("cognito-idp", "admin-create-user", "--region", region, "--user-pool-id", pool, "--username", email,
                "--message-action", "SUPPRESS",
                "--user-attributes", f"Name=email,Value={email}", "Name=email_verified,Value=true")
    aws("cognito-idp", "admin-set-user-password", "--region", region, "--user-pool-id", pool,
        "--username", email, "--password", password, "--permanent")


def token_vinculado(api: str, region: str, client: str, email: str, password: str) -> str:
    """Login, /auth/me (vincula y escribe los claims) y un segundo login para que el token los traiga."""
    t = login_cognito(region, client, email, password)
    r = http("GET", f"{api}/api/v1/auth/me", t)
    if r.status != 200:
        raise RuntimeError(f"/auth/me de {email}: HTTP {r.status} {r.texto}")
    t = login_cognito(region, client, email, password)
    c = claims_de(t)
    if not c.get("custom:tenant_id"):
        raise RuntimeError(f"{email} sin custom:tenant_id tras /auth/me: {datos(r.cuerpo)}")
    return t


def trabajador(api: str, token: str, email: str, nombre: str, apellido: str, numero_rut: int) -> str:
    r = http("GET", f"{api}/api/v1/trabajadores", token)
    for t in datos(r.cuerpo) or []:
        if t.get("email") == email:
            return t["id"]
    r = http("POST", f"{api}/api/v1/trabajadores", token,
             {"nombre": nombre, "apellido": apellido, "rut_trabajador": rut(numero_rut), "email": email,
              "dias_vacaciones_disponibles": 15, "activo": True})
    if r.status != 201:
        raise RuntimeError(f"crear trabajador {email}: HTTP {r.status} {r.texto}")
    return datos(r.cuerpo)["id"]


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
    destino = Path(os.environ.get("E2E_ENV_FILE", Path(__file__).resolve().parent.parent / ".env.e2e"))

    print("1. Empresa B y su admin (SQL vía SSM)")
    print(sql_en_ec2(instancia, region, f"""
INSERT IGNORE INTO identity_tenant (id, nombre_empresa, rut_empresa, pais, activo, creado_en, slug, estado, razon_social)
VALUES ('{TENANT_B}', 'Empresa Beta SpA', '{rut(77777777)}', 'Chile', TRUE, NOW(), 'empresa-beta-spa', 'ACTIVO', 'Empresa Beta SpA');
INSERT IGNORE INTO identity_usuario (id, tenant_id, email, rol, activo, creado_en, estado, nombre)
VALUES ('cccccccc-cccc-cccc-cccc-ccccccccc001', '{TENANT_B}', '{ADMIN_B}', 'Admin de RRHH', TRUE, NOW(), 'ACTIVO', 'Admin Beta');
SELECT id, slug, estado FROM identity_tenant;""").strip())

    print("2. Cuentas de admin en Cognito y vínculo por /auth/me")
    claves = {ADMIN_A: clave(), ADMIN_B: clave(), TRAB_A: clave()}
    for email in (ADMIN_A, ADMIN_B):
        cuenta_con_clave(pool, region, email, claves[email], crear=True)
    ta = token_vinculado(api, region, client, ADMIN_A, claves[ADMIN_A])
    tb = token_vinculado(api, region, client, ADMIN_B, claves[ADMIN_B])
    print(f"   admin A: {claims_de(ta).get('custom:role')} en {claims_de(ta).get('custom:tenant_id')}")
    print(f"   admin B: {claims_de(tb).get('custom:role')} en {claims_de(tb).get('custom:tenant_id')}")

    print("3. Fichas de trabajadores")
    trab_a = trabajador(api, ta, TRAB_A, "Trabajador", "Demo", 12345678)
    trabajador(api, tb, TRAB_B, "Trabajadora", "Beta", 11222333)
    print(f"   trabajador A: {trab_a}")

    print("4. Cuenta Trabajador de A (identity la crea en Cognito)")
    r = http("POST", f"{api}/api/v1/usuarios/invitar", ta,
             {"email": TRAB_A, "trabajador_id": trab_a, "nombre": "Trabajador Demo", "rol": "Trabajador",
              "crear_en_cognito": True})
    if r.status not in (200, 201) and "ya existe" not in r.texto:
        raise RuntimeError(f"invitar: HTTP {r.status} {r.texto}")
    cuenta_con_clave(pool, region, TRAB_A, claves[TRAB_A], crear=False)
    tt = token_vinculado(api, region, client, TRAB_A, claves[TRAB_A])
    ct = claims_de(tt)
    print(f"   trabajador A: {ct.get('custom:role')}, ficha {ct.get('custom:trabajador_id')}")

    print("5. Contrato en espera de firma para el trabajador A")
    r = http("GET", f"{api}/api/v1/contratos/mio", tt)
    if (datos(r.cuerpo) or {}).get("estado") not in (None, "SIN_CONTRATO"):
        print(f"   ya existe: {(datos(r.cuerpo) or {}).get('estado')}")
    else:
        campos = datos(http("GET", f"{api}/api/v1/contratos/plantilla/campos", ta).cuerpo) or []
        valores = {}
        for c in campos:
            if str(c.get("responsable", "")).upper() != "RRHH":
                continue
            nombre, tipo = c["clave"], str(c.get("tipo", "")).upper()
            if nombre == "rrhh_fecha_termino":
                continue  # contrato indefinido: el servicio pone "Indefinido"
            valores[nombre] = {"FECHA": "2026-12-01", "NUMERO": "900000", "ENTERO": "42"}.get(tipo) \
                or ("Indefinido" if "Indefinido" in (c.get("opciones") or []) else (c.get("opciones") or [None])[0]) \
                or f"Demo {c.get('etiqueta') or nombre}"
        r = http("POST", f"{api}/api/v1/contratos/emitir", ta, {"trabajador_id": trab_a, "campos": valores})
        print(f"   emitir: HTTP {r.status} {'' if r.status == 201 else r.texto}")

    destino.write_text("".join([
        f"export E2E_API_URL={api}\n", f"export E2E_COGNITO_CLIENT_ID={client}\n",
        f"export E2E_ADMIN_A_EMAIL={ADMIN_A}\n", f"export E2E_ADMIN_A_PASSWORD='{claves[ADMIN_A]}'\n",
        f"export E2E_TRAB_A_EMAIL={TRAB_A}\n", f"export E2E_TRAB_A_PASSWORD='{claves[TRAB_A]}'\n",
        f"export E2E_ADMIN_B_EMAIL={ADMIN_B}\n", f"export E2E_ADMIN_B_PASSWORD='{claves[ADMIN_B]}'\n",
    ]))
    destino.chmod(0o600)
    print(f"\nVariables E2E_* escritas en {destino}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
