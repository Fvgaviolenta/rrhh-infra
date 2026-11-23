"""rrhh-atrasos: detecta las marcas de ENTRADA tardías del stream rrhh-events y las avisa por SQS.

Por cada registro `asistencia.marca.registrada` de tipo ENTRADA con `turnoHoraInicio`, compara la
hora local de la marca (`fechaHora` en UTC llevada a `zona`) con el inicio del turno más
TOLERANCIA_MINUTOS, en la fecha local de la marca. Si llegó tarde, envía a la cola
SQS_EVENTS_QUEUE_URL un sobre `asistencia.atraso.detectado` cuyo `eventId` es un uuid5 del
`eventId` de la marca: el mismo registro reintentado da el mismo aviso y notifications lo
deduplica con `processed_event`.

Una falla de SQS levanta excepción para que el event source mapping reintente el lote (y lo
parta con bisect). Un registro malformado se descarta sin excepción y solo se cuenta: un error
haría reintentar el lote completo. El log nunca lleva el payload (trae trabajadorId;
DOC/inventario-datos.md). El aviso no lleva nombres ni RUT.
"""

import base64
import binascii
import json
import os
import re
import uuid
from collections.abc import Mapping
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

EVENTO_MARCA = "asistencia.marca.registrada"
EVENTO_ATRASO = "asistencia.atraso.detectado"
TOLERANCIA_DEFAULT = 5
LOTE_SQS = 10  # máximo de entradas de SendMessageBatch

_HORA = re.compile(r"([01]\d|2[0-3]):[0-5]\d")


class RegistroInvalido(ValueError):
    """El registro no trae los campos que el detector necesita, o los trae de otro tipo."""


class EnvioFallido(RuntimeError):
    """SendMessageBatch respondió con entradas en Failed."""


def tolerancia_minutos(env: Mapping[str, str]) -> int:
    """Minutos de tolerancia desde TOLERANCIA_MINUTOS; sin la variable, 5. Vacía, no entera o negativa: ValueError."""
    if "TOLERANCIA_MINUTOS" not in env:
        return TOLERANCIA_DEFAULT
    valor = env["TOLERANCIA_MINUTOS"]
    if not valor or not valor.isascii() or not valor.isdigit():
        raise ValueError(f"TOLERANCIA_MINUTOS debe ser un entero >= 0, no {valor!r}")
    return int(valor)


# Se evalúa al cargar el módulo: una tolerancia mal configurada hace fallar el arranque de la función.
TOLERANCIA = tolerancia_minutos(os.environ)


def _texto(valor, campo: str) -> str:
    if not isinstance(valor, str) or not valor:
        raise RegistroInvalido(f"{campo} ausente o de otro tipo")
    return valor


def _es_entrada(marca) -> bool:
    payload = marca.get("payload") if isinstance(marca, dict) else None
    return (isinstance(marca, dict) and marca.get("eventType") == EVENTO_MARCA
            and isinstance(payload, dict) and payload.get("tipo") == "ENTRADA")


def _sin_turno(marca) -> bool:
    return _es_entrada(marca) and "turnoHoraInicio" not in marca["payload"]


def detectar(marca: dict, tolerancia: int, ahora: datetime) -> dict | None:
    """Devuelve el aviso de atraso, o None si la marca no es una ENTRADA con turno o llegó a tiempo.

    Lanza RegistroInvalido si la marca no trae bien los campos que hacen falta para decidir.
    """
    if not isinstance(marca, dict):
        raise RegistroInvalido("el sobre no es un objeto JSON")
    payload = marca.get("payload")
    if marca.get("eventType") != EVENTO_MARCA:
        return None
    if not isinstance(payload, dict):
        raise RegistroInvalido("payload ausente o de otro tipo")
    if payload.get("tipo") != "ENTRADA" or "turnoHoraInicio" not in payload:
        return None

    event_id = _texto(marca.get("eventId"), "eventId")
    tenant_id = _texto(marca.get("tenantId"), "tenantId")
    aggregate_id = _texto(marca.get("aggregateId"), "aggregateId")
    trabajador_id = _texto(payload.get("trabajadorId"), "trabajadorId")
    fecha_hora = _texto(payload.get("fechaHora"), "fechaHora")
    zona = _texto(payload.get("zona"), "zona")
    turno = _texto(payload.get("turnoHoraInicio"), "turnoHoraInicio")

    # Solo un instante UTC explícito: una hora sin offset no se lee ni como local ni como UTC.
    if not fecha_hora.endswith("Z"):
        raise RegistroInvalido("fechaHora no es un instante UTC")
    try:
        instante = datetime.fromisoformat(fecha_hora)
    except ValueError as exc:
        raise RegistroInvalido("fechaHora no es ISO-8601") from exc
    try:
        tz = ZoneInfo(zona)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise RegistroInvalido("zona desconocida") from exc
    if not _HORA.fullmatch(turno):
        raise RegistroInvalido("turnoHoraInicio no es HH:mm")

    local = instante.astimezone(tz)
    hh, mm = (int(p) for p in turno.split(":"))
    inicio = datetime.combine(local.date(), time(hh, mm), tzinfo=local.tzinfo)
    if not local > inicio + timedelta(minutes=tolerancia):
        return None

    return {
        "eventId": str(uuid.uuid5(uuid.NAMESPACE_URL, f"rrhh:{EVENTO_ATRASO}:{event_id}")),
        "eventType": EVENTO_ATRASO,
        "tenantId": tenant_id,
        "occurredAt": ahora.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "aggregateId": aggregate_id,
        "payload": {
            "trabajadorId": trabajador_id,
            "fechaHora": fecha_hora,
            "turnoHoraInicio": turno,
            "minutosAtraso": int((local - inicio).total_seconds() // 60),
            "zona": zona,
        },
    }


def enviar(cliente, queue_url: str, avisos: list[dict]) -> None:
    """Envía los avisos en lotes de 10. Una entrada en Failed lanza EnvioFallido; las excepciones del cliente se propagan."""
    for desde in range(0, len(avisos), LOTE_SQS):
        lote = avisos[desde:desde + LOTE_SQS]
        respuesta = cliente.send_message_batch(
            QueueUrl=queue_url,
            Entries=[{"Id": str(i), "MessageBody": json.dumps(aviso)} for i, aviso in enumerate(lote)],
        )
        fallidos = respuesta.get("Failed") or []
        if fallidos:
            codigos = sorted({str(f.get("Code")) for f in fallidos})
            raise EnvioFallido(f"{len(fallidos)} de {len(lote)} avisos no llegaron a SQS: {codigos}")


def _cliente_sqs():
    import boto3  # dentro de la función: los tests corren sin boto3 instalado

    return boto3.client("sqs")


def _decodificar(record: dict):
    try:
        return json.loads(base64.b64decode(record["kinesis"]["data"], validate=True))
    except (KeyError, TypeError, ValueError, binascii.Error) as exc:
        raise RegistroInvalido("data no es base64 o JSON") from exc


def lambda_handler(event: dict, context: object, cliente=None) -> dict:
    avisos = []
    descartados = 0
    ahora = datetime.now(timezone.utc)
    for record in event.get("Records", []):
        try:
            marca = _decodificar(record)
            aviso = detectar(marca, TOLERANCIA, ahora)
        except RegistroInvalido:
            descartados += 1
            continue
        if aviso is not None:
            avisos.append(aviso)
        elif _sin_turno(marca):
            descartados += 1  # spec S3: una ENTRADA sin turnoHoraInicio se descarta y se cuenta
    if avisos:
        enviar(cliente or _cliente_sqs(), os.environ["SQS_EVENTS_QUEUE_URL"], avisos)
    resumen = {"avisos": len(avisos), "descartados": descartados}
    print(json.dumps(resumen))
    return resumen
