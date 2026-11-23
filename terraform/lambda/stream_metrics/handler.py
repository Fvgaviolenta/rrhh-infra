"""rrhh-stream-metrics: cuenta los registros de los streams rrhh-events y rrhh-api-telemetry
y los publica en CloudWatch.

Los eventos de negocio (rrhh-events) se agrupan por minuto de llegada, empresa y tipo de
evento (métrica Eventos). Los registros de telemetría de APIs (rrhh-api-telemetry,
tipo == "api.request") se agrupan por minuto, servicio, clase de status y empresa
(métrica Requests) y por minuto, servicio y plantilla de ruta (métrica Latencia, con la
lista de latencias del minuto). Se escribe un documento EMF (Embedded Metric Format) por
grupo en stdout: CloudWatch Logs crea las métricas solo, sin llamar a PutMetricData.

El timestamp de cada métrica es el minuto de llegada (approximateArrivalTimestamp),
no el de proceso, para que un lote reintentado o atrasado caiga en su minuto real.

Nunca se escribe el payload del evento (trae trabajadorId; DOC/inventario-datos.md). La
telemetría no trae datos personales: solo servicio, método, plantilla de ruta, status,
latencia y tenantId.
Un registro malo no levanta excepción: se cuenta en EventosInvalidos, porque un error
haría que Lambda reintente el lote completo.
"""

import base64
import binascii
import json
import time
from collections import Counter

NAMESPACE = "RRHH/Streaming"

_DIMENSIONES_EVENTOS = [["EventType"], ["TenantId", "EventType"]]
_DIMENSIONES_REQUESTS = [["Servicio"], ["Servicio", "StatusClass"], ["TenantId"]]
_DIMENSIONES_LATENCIA = [["Servicio"], ["Servicio", "Ruta"]]
_MAX_VALORES_EMF = 100
_SIN_TENANT = "sin-tenant"


def _minuto_ms(segundos: float) -> int:
    return int(segundos // 60) * 60 * 1000


def _decodificar(record: dict) -> dict | None:
    """Devuelve el sobre JSON del registro, o None si no es base64 de un objeto JSON."""
    try:
        crudo = base64.b64decode(record["kinesis"]["data"], validate=True)
        sobre = json.loads(crudo)
    except (KeyError, TypeError, ValueError, binascii.Error):
        return None
    return sobre if isinstance(sobre, dict) else None


def _texto(valor) -> bool:
    return isinstance(valor, str) and bool(valor)


def _entero(valor) -> bool:
    return isinstance(valor, int) and not isinstance(valor, bool)


def _evento(sobre: dict) -> tuple[str, str] | None:
    """Devuelve (tenantId, eventType) o None si el sobre no es un evento de negocio válido."""
    tenant = sobre.get("tenantId")
    tipo = sobre.get("eventType")
    if not _texto(tenant) or not _texto(tipo):
        return None
    return tenant, tipo


def _telemetria(sobre: dict) -> tuple[str, str, str, str, int] | None:
    """Devuelve (servicio, ruta, status_class, tenant, latencia_ms) o None si es inválido."""
    servicio = sobre.get("servicio")
    ruta = sobre.get("ruta")
    status = sobre.get("status")
    latencia = sobre.get("latenciaMs")
    if not _texto(servicio) or not _texto(ruta):
        return None
    if not _entero(status) or not 100 <= status <= 599:
        return None
    if not _entero(latencia) or latencia < 0:
        return None
    tenant = sobre.get("tenantId")
    return servicio, ruta, f"{status // 100}xx", tenant if _texto(tenant) else _SIN_TENANT, latencia


def _llegada(record: dict, now_ms: int) -> float:
    kinesis = record.get("kinesis") if isinstance(record, dict) else None
    t = kinesis.get("approximateArrivalTimestamp") if isinstance(kinesis, dict) else None
    if isinstance(t, (int, float)) and not isinstance(t, bool):
        return float(t)
    return now_ms / 1000


def _doc(minuto: int, dimensiones: list, nombre: str, unidad: str, campos: dict) -> dict:
    return {
        "_aws": {
            "Timestamp": minuto,
            "CloudWatchMetrics": [{
                "Namespace": NAMESPACE,
                "Dimensions": dimensiones,
                "Metrics": [{"Name": nombre, "Unit": unidad}],
            }],
        },
        **campos,
    }


def build_metrics(records: list[dict], now_ms: int) -> list[dict]:
    conteo = Counter()
    requests = Counter()
    latencias = {}
    invalidos = 0
    for record in records:
        sobre = _decodificar(record) if isinstance(record, dict) else None
        if sobre is None:
            invalidos += 1
            continue
        if sobre.get("tipo") == "api.request":
            tel = _telemetria(sobre)
            if tel is None:
                invalidos += 1
                continue
            servicio, ruta, clase, tenant, latencia = tel
            minuto = _minuto_ms(_llegada(record, now_ms))
            requests[(minuto, servicio, clase, tenant)] += 1
            latencias.setdefault((minuto, servicio, ruta), []).append(latencia)
            continue
        clave = _evento(sobre)
        if clave is None:
            invalidos += 1
            continue
        tenant, tipo = clave
        conteo[(_minuto_ms(_llegada(record, now_ms)), tenant, tipo)] += 1

    docs = []
    for (minuto, tenant, tipo), n in conteo.items():
        docs.append(_doc(minuto, _DIMENSIONES_EVENTOS, "Eventos", "Count",
                         {"EventType": tipo, "TenantId": tenant, "Eventos": n}))
    for (minuto, servicio, clase, tenant), n in requests.items():
        docs.append(_doc(minuto, _DIMENSIONES_REQUESTS, "Requests", "Count",
                         {"Servicio": servicio, "StatusClass": clase, "TenantId": tenant, "Requests": n}))
    for (minuto, servicio, ruta), valores in latencias.items():
        for i in range(0, len(valores), _MAX_VALORES_EMF):
            docs.append(_doc(minuto, _DIMENSIONES_LATENCIA, "Latencia", "Milliseconds",
                             {"Servicio": servicio, "Ruta": ruta, "Latencia": valores[i:i + _MAX_VALORES_EMF]}))
    if invalidos:
        docs.append(_doc(_minuto_ms(now_ms / 1000), [[]], "EventosInvalidos", "Count",
                         {"EventosInvalidos": invalidos}))
    return docs


def lambda_handler(event: dict, context: object) -> dict:
    docs = build_metrics(event.get("Records", []), int(time.time() * 1000))
    procesados = 0
    invalidos = 0
    for doc in docs:
        print(json.dumps(doc))
        procesados += doc.get("Eventos", 0) + doc.get("Requests", 0)
        invalidos += doc.get("EventosInvalidos", 0)
    return {"procesados": procesados, "invalidos": invalidos}
