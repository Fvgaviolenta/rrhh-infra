"""Tests unitarios del handler de rrhh-stream-metrics (sin AWS)."""

import base64
import contextlib
import io
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lambda", "stream_metrics"))

from handler import build_metrics, lambda_handler  # noqa: E402

NOW = 1700000123456
MIN0 = 1699999980000  # minuto de 1700000000.0


def rec(obj, arrival=1700000000.0):
    data = base64.b64encode(json.dumps(obj).encode()).decode()
    return {"kinesis": {"data": data, "approximateArrivalTimestamp": arrival}}


def ev(tipo, tenant):
    return {
        "eventId": "e-1",
        "eventType": tipo,
        "tenantId": tenant,
        "occurredAt": "2023-11-14T22:13:20Z",
        "aggregateId": "m-1",
        "payload": {"trabajadorId": "c91d-secreto", "tipo": "ENTRADA"},
    }


class BuildMetricsTest(unittest.TestCase):
    def test_counts_events_by_tenant_and_type(self):
        docs = build_metrics([rec(ev("asistencia.marca.registrada", "t1")),
                              rec(ev("asistencia.marca.registrada", "t1")),
                              rec(ev("asistencia.editada", "t1"))], NOW)
        por = {(d["TenantId"], d["EventType"]): d for d in docs}
        self.assertEqual(por[("t1", "asistencia.marca.registrada")]["Eventos"], 2)
        self.assertEqual(por[("t1", "asistencia.editada")]["Eventos"], 1)
        for d in docs:
            cw = d["_aws"]["CloudWatchMetrics"][0]
            self.assertEqual(cw["Namespace"], "RRHH/Streaming")
            self.assertEqual(cw["Dimensions"], [["EventType"], ["TenantId", "EventType"]])
            self.assertEqual(cw["Metrics"], [{"Name": "Eventos", "Unit": "Count"}])
            self.assertEqual(d["_aws"]["Timestamp"], MIN0)

    def test_metrics_use_the_arrival_minute(self):
        docs = build_metrics([rec(ev("asistencia.marca.registrada", "t1"), 1700000000.5),
                              rec(ev("asistencia.marca.registrada", "t1"), 1700000065.0)], NOW)
        self.assertEqual(sorted(d["_aws"]["Timestamp"] for d in docs), [1699999980000, 1700000040000])

    def test_missing_arrival_uses_processing_minute(self):
        r1 = rec(ev("asistencia.marca.registrada", "t1"))
        del r1["kinesis"]["approximateArrivalTimestamp"]
        r2 = rec(ev("asistencia.marca.registrada", "t1"), "1700000000")
        docs = build_metrics([r1, r2], NOW)
        self.assertEqual([(d["_aws"]["Timestamp"], d["Eventos"]) for d in docs], [(1700000100000, 2)])

    def test_empty_batch_produces_no_metrics(self):
        self.assertEqual(build_metrics([], NOW), [])

    def test_non_json_record_counts_as_invalid(self):
        malos = [{"kinesis": {"data": base64.b64encode(b"no-json").decode()}},
                 {"kinesis": {"data": "%%no-base64%%"}}]
        docs = build_metrics(malos, NOW)
        self.assertEqual(len(docs), 1)
        self.assertEqual(docs[0]["EventosInvalidos"], 2)
        self.assertEqual(docs[0]["_aws"]["CloudWatchMetrics"][0]["Dimensions"], [[]])
        self.assertEqual(docs[0]["_aws"]["CloudWatchMetrics"][0]["Metrics"],
                         [{"Name": "EventosInvalidos", "Unit": "Count"}])

    def test_missing_or_non_string_fields_count_as_invalid(self):
        sin_tipo = ev("asistencia.marca.registrada", "t1")
        del sin_tipo["eventType"]
        docs = build_metrics([rec(sin_tipo), rec(ev(5, "t1")), rec(ev("asistencia.editada", "")),
                              rec(ev("asistencia.editada", None)), rec(ev("", "t1"))], NOW)
        self.assertEqual([d.get("EventosInvalidos") for d in docs], [5])

    def test_metrics_never_carry_the_payload(self):
        out = json.dumps(build_metrics([rec(ev("asistencia.marca.registrada", "t1"))], NOW))
        self.assertNotIn("c91d-secreto", out)
        self.assertNotIn("payload", out)


class LambdaHandlerTest(unittest.TestCase):
    def test_handler_prints_one_line_per_doc_and_returns_counts(self):
        evento = {"Records": [rec(ev("asistencia.marca.registrada", "t1")),
                              rec(ev("asistencia.marca.registrada", "t1")),
                              {"kinesis": {"data": "%%"}}]}
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            res = lambda_handler(evento, None)
        self.assertEqual(res, {"procesados": 2, "invalidos": 1})
        lineas = buf.getvalue().strip().splitlines()
        self.assertEqual(len(lineas), 2)
        self.assertTrue(all("_aws" in json.loads(linea) for linea in lineas))


if __name__ == "__main__":
    unittest.main()
