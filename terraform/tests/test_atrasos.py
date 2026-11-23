"""Tests unitarios del handler de rrhh-atrasos (sin AWS, con un cliente SQS falso)."""

import base64
import contextlib
import importlib.util
import io
import json
import os
import sys
import unittest
import uuid
from datetime import datetime, timezone
from unittest import mock

# Los dos handlers se llaman handler.py: se carga este por ruta, nunca con sys.path + import handler,
# porque el módulo "handler" de stream_metrics podría estar ya en sys.modules.
_RUTA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lambda", "atrasos", "handler.py")
_spec = importlib.util.spec_from_file_location("atrasos_handler", _RUTA)
h = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(h)

AHORA = datetime(2026, 11, 3, 12, 0, tzinfo=timezone.utc)


def rec(obj):
    data = base64.b64encode(json.dumps(obj).encode()).decode()
    return {"kinesis": {"data": data}}


def marca(fechaHora, turno="08:00", tipo="ENTRADA", evento="ev-1"):
    payload = {"trabajadorId": "trab-secreto", "tipo": tipo, "fechaHora": fechaHora,
               "turnoHoraInicio": turno, "zona": "America/Santiago"}
    if turno is None:
        del payload["turnoHoraInicio"]
    return {"eventId": evento, "eventType": "asistencia.marca.registrada", "tenantId": "t1",
            "occurredAt": "2026-11-03T11:00:00Z", "aggregateId": "m1", "payload": payload}


class FakeSqs:
    def __init__(self, failed=None, raises=None):
        self.failed = failed or []
        self.raises = raises
        self.llamadas = []

    def send_message_batch(self, **kw):
        self.llamadas.append(kw)
        if self.raises is not None:
            raise self.raises
        fallidos = {f["Id"] for f in self.failed}
        return {"Successful": [{"Id": e["Id"]} for e in kw["Entries"] if e["Id"] not in fallidos],
                "Failed": self.failed}


class AtrasosTest(unittest.TestCase):
    def test_entrada_dentro_de_tolerancia_no_genera_aviso(self):
        self.assertIsNone(h.detectar(marca("2026-11-03T11:05:00Z"), 5, AHORA))   # 08:05:00 local

    def test_entrada_tardia_genera_aviso_con_minutos_completos(self):
        self.assertEqual(h.detectar(marca("2026-11-03T11:05:01Z"), 5, AHORA)["payload"]["minutosAtraso"], 5)
        self.assertEqual(h.detectar(marca("2026-11-03T11:12:40Z"), 5, AHORA)["payload"]["minutosAtraso"], 12)

    def test_salida_sin_turno_o_editada_no_generan_aviso(self):
        self.assertIsNone(h.detectar(marca("2026-11-03T11:30:00Z", tipo="SALIDA"), 5, AHORA))
        self.assertIsNone(h.detectar(marca("2026-11-03T11:30:00Z", turno=None), 5, AHORA))
        editada = marca("2026-11-03T11:30:00Z")
        editada["eventType"] = "asistencia.editada"
        self.assertIsNone(h.detectar(editada, 5, AHORA))

    def test_hora_local_respeta_el_horario_de_verano(self):
        self.assertEqual(h.detectar(marca("2026-07-01T12:06:00Z"), 5, AHORA)["payload"]["minutosAtraso"], 6)    # UTC-4: 08:06
        self.assertEqual(h.detectar(marca("2026-11-03T12:06:00Z"), 5, AHORA)["payload"]["minutosAtraso"], 66)   # UTC-3: 09:06

    def test_tolerancia_desde_el_entorno(self):
        self.assertEqual(h.tolerancia_minutos({}), 5)
        self.assertEqual(h.tolerancia_minutos({"TOLERANCIA_MINUTOS": "0"}), 0)
        self.assertEqual(h.tolerancia_minutos({"TOLERANCIA_MINUTOS": "10"}), 10)
        for malo in ["", "abc", "-1", "2.5", " "]:
            with self.assertRaises(ValueError, msg=malo):
                h.tolerancia_minutos({"TOLERANCIA_MINUTOS": malo})
        self.assertEqual(h.detectar(marca("2026-11-03T11:00:30Z"), 0, AHORA)["payload"]["minutosAtraso"], 0)   # 08:00:30 es posterior a 08:00
        self.assertIsNone(h.detectar(marca("2026-11-03T11:00:00Z"), 0, AHORA))   # 08:00:00 en punto
        self.assertEqual(h.detectar(marca("2026-11-03T11:01:00Z"), 0, AHORA)["payload"]["minutosAtraso"], 1)

    def test_event_id_es_uuid5_de_la_marca(self):
        a = h.detectar(marca("2026-11-03T11:20:00Z"), 5, AHORA)
        b = h.detectar(marca("2026-11-03T11:20:00Z"), 5, AHORA)
        self.assertEqual(a["eventId"], str(uuid.uuid5(uuid.NAMESPACE_URL, "rrhh:asistencia.atraso.detectado:ev-1")))
        self.assertEqual(a["eventId"], b["eventId"])
        self.assertEqual(len(a["eventId"]), 36)
        self.assertEqual((a["eventType"], a["tenantId"], a["aggregateId"]), ("asistencia.atraso.detectado", "t1", "m1"))
        self.assertEqual(a["occurredAt"], "2026-11-03T12:00:00Z")
        self.assertEqual(a["payload"], {"trabajadorId": "trab-secreto", "fechaHora": "2026-11-03T11:20:00Z",
                                        "turnoHoraInicio": "08:00", "minutosAtraso": 20, "zona": "America/Santiago"})

    def test_registros_malformados_se_descartan_sin_excepcion(self):
        def con(**cambios):
            m = marca("2026-11-03T11:30:00Z")
            for k, v in cambios.items():
                (m["payload"] if k in m["payload"] or k == "turnoHoraInicio" else m)[k] = v
            return rec(m)
        sin_id = marca("2026-11-03T11:30:00Z")
        del sin_id["eventId"]
        malos = [{"kinesis": {"data": "%%"}}, {"kinesis": {"data": base64.b64encode(b"no-json").decode()}},
                 rec(sin_id), con(tenantId=5), con(fechaHora="ayer"), con(fechaHora="2026-11-03T11:05:00"),
                 con(zona="Marte/Olimpo"), con(turnoHoraInicio="8am"), con(turnoHoraInicio="25:00")]
        sqs = FakeSqs()
        with contextlib.redirect_stdout(io.StringIO()):
            res = h.lambda_handler({"Records": malos}, None, cliente=sqs)
        self.assertEqual(res, {"avisos": 0, "descartados": 9})
        self.assertEqual(sqs.llamadas, [])
        # spec S3: una ENTRADA sin turnoHoraInicio se cuenta como descartada; una SALIDA no
        with contextlib.redirect_stdout(io.StringIO()):
            res = h.lambda_handler({"Records": [rec(marca("2026-11-03T11:30:00Z", turno=None)),
                                                rec(marca("2026-11-03T11:30:00Z", tipo="SALIDA"))]}, None, cliente=sqs)
        self.assertEqual(res, {"avisos": 0, "descartados": 1})

    def test_envia_en_lotes_de_10_a_la_cola(self):
        sqs = FakeSqs()
        registros = [rec(marca("2026-11-03T11:30:00Z", evento=f"ev-{i}")) for i in range(23)]
        with mock.patch.dict(os.environ, {"SQS_EVENTS_QUEUE_URL": "https://sqs/q"}), contextlib.redirect_stdout(io.StringIO()):
            res = h.lambda_handler({"Records": registros}, None, cliente=sqs)
        self.assertEqual(res, {"avisos": 23, "descartados": 0})
        self.assertEqual([len(c["Entries"]) for c in sqs.llamadas], [10, 10, 3])
        self.assertTrue(all(c["QueueUrl"] == "https://sqs/q" for c in sqs.llamadas))
        self.assertEqual(json.loads(sqs.llamadas[0]["Entries"][0]["MessageBody"])["eventType"], "asistencia.atraso.detectado")

    def test_fallo_de_sqs_levanta_excepcion(self):
        with self.assertRaises(h.EnvioFallido):
            h.enviar(FakeSqs(failed=[{"Id": "0", "Code": "x"}]), "https://sqs/q", [h.detectar(marca("2026-11-03T11:30:00Z"), 5, AHORA)])
        with self.assertRaises(ConnectionError):
            h.enviar(FakeSqs(raises=ConnectionError("caída")), "https://sqs/q", [h.detectar(marca("2026-11-03T11:30:00Z"), 5, AHORA)])

    def test_log_no_lleva_el_payload_y_boto3_no_se_importa_al_cargar(self):
        with mock.patch.dict(os.environ, {"SQS_EVENTS_QUEUE_URL": "https://sqs/q"}), contextlib.redirect_stdout(io.StringIO()) as buf:
            h.lambda_handler({"Records": [rec(marca("2026-11-03T11:30:00Z"))]}, None, cliente=FakeSqs())
        self.assertNotIn("trab-secreto", buf.getvalue())
        self.assertNotIn("boto3", sys.modules)


if __name__ == "__main__":
    unittest.main()
