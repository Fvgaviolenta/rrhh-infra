"""rrhh-stream-metrics: cuenta los eventos del stream rrhh-events y los publica en CloudWatch.

Cada lote de Kinesis se agrupa por minuto de llegada al stream, empresa y tipo de
evento, y se escribe un documento EMF (Embedded Metric Format) por grupo en stdout:
CloudWatch Logs crea las métricas solo, sin llamar a PutMetricData.

El timestamp de cada métrica es el minuto de llegada (approximateArrivalTimestamp),
no el de proceso, para que un lote reintentado o atrasado caiga en su minuto real.

Nunca se escribe el payload del evento (trae trabajadorId; DOC/inventario-datos.md).
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


def _minuto_ms(segundos: float) -> int:
    return int(segundos // 60) * 60 * 1000


def _decodificar(record: dict):
    """Devuelve (tenantId, eventType) o None si el registro no es un evento válido."""
    try:
        crudo = base64.b64decode(record["kinesis"]["data"], validate=True)
        sobre = json.loads(crudo)
    except (KeyError, TypeError, ValueError, binascii.Error):
        return None
    if not isinstance(sobre, dict):
        return None
    tenant = sobre.get("tenantId")
    tipo = sobre.get("eventType")
    if not isinstance(tenant, str) or not tenant or not isinstance(tipo, str) or not tipo:
        return None
    return tenant, tipo


def _llegada(record: dict, now_ms: int) -> float:
    kinesis = record.get("kinesis") if isinstance(record, dict) else None
    t = kinesis.get("approximateArrivalTimestamp") if isinstance(kinesis, dict) else None
    if isinstance(t, (int, float)) and not isinstance(t, bool):
        return float(t)
    return now_ms / 1000


def build_metrics(records: list[dict], now_ms: int) -> list[dict]:
    conteo = Counter()
    invalidos = 0
    for record in records:
        clave = _decodificar(record) if isinstance(record, dict) else None
        if clave is None:
            invalidos += 1
            continue
        tenant, tipo = clave
        conteo[(_minuto_ms(_llegada(record, now_ms)), tenant, tipo)] += 1

    docs = []
    for (minuto, tenant, tipo), n in conteo.items():
        docs.append({
            "_aws": {
                "Timestamp": minuto,
                "CloudWatchMetrics": [{
                    "Namespace": NAMESPACE,
                    "Dimensions": _DIMENSIONES_EVENTOS,
                    "Metrics": [{"Name": "Eventos", "Unit": "Count"}],
                }],
            },
            "EventType": tipo,
            "TenantId": tenant,
            "Eventos": n,
        })
    if invalidos:
        docs.append({
            "_aws": {
                "Timestamp": _minuto_ms(now_ms / 1000),
                "CloudWatchMetrics": [{
                    "Namespace": NAMESPACE,
                    "Dimensions": [[]],
                    "Metrics": [{"Name": "EventosInvalidos", "Unit": "Count"}],
                }],
            },
            "EventosInvalidos": invalidos,
        })
    return docs


def lambda_handler(event: dict, context: object) -> dict:
    docs = build_metrics(event.get("Records", []), int(time.time() * 1000))
    procesados = 0
    invalidos = 0
    for doc in docs:
        print(json.dumps(doc))
        procesados += doc.get("Eventos", 0)
        invalidos += doc.get("EventosInvalidos", 0)
    return {"procesados": procesados, "invalidos": invalidos}
