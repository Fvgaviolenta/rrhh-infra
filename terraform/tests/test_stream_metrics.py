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


def tel(servicio="asistencia", ruta="/api/v1/asistencia/marcas/{id}", status=200, latencia=12, tenant="t1", **extra):
    return {"tipo": "api.request", "servicio": servicio, "metodo": "GET", "ruta": ruta, "status": status,
            "latenciaMs": latencia, "tenantId": tenant, "ocurridoEn": "2023-11-14T22:13:20Z", **extra}


def docs_de(docs, metrica):
    return [d for d in docs if metrica in d]


class TelemetriaTest(unittest.TestCase):
    def test_requests_por_servicio_clase_y_tenant(self):
        docs = build_metrics([rec(tel()), rec(tel()), rec(tel(status=404)),
                              rec(tel(ruta="SIN_RUTA", status=404, tenant=None))], NOW)
        req = {(d["Servicio"], d["StatusClass"], d["TenantId"]): d for d in docs_de(docs, "Requests")}
        self.assertEqual({k: d["Requests"] for k, d in req.items()},
                         {("asistencia", "2xx", "t1"): 2, ("asistencia", "4xx", "t1"): 1, ("asistencia", "4xx", "sin-tenant"): 1})
        for d in req.values():
            cw = d["_aws"]["CloudWatchMetrics"][0]
            self.assertEqual(cw["Namespace"], "RRHH/Streaming")
            self.assertEqual(cw["Dimensions"], [["Servicio"], ["Servicio", "StatusClass"], ["TenantId"]])
            self.assertEqual(cw["Metrics"], [{"Name": "Requests", "Unit": "Count"}])
            self.assertEqual(d["_aws"]["Timestamp"], MIN0)
        self.assertEqual(docs_de(docs, "EventosInvalidos"), [])

    def test_status_class_por_centena(self):
        docs = build_metrics([rec(tel(status=s)) for s in (101, 200, 302, 499, 503, 599)], NOW)
        self.assertEqual(sorted(d["StatusClass"] for d in docs_de(docs, "Requests")), ["1xx", "2xx", "3xx", "4xx", "5xx"])

    def test_latencia_lleva_los_valores_del_minuto(self):
        docs = build_metrics([rec(tel(latencia=5)), rec(tel(latencia=0)), rec(tel(latencia=900)),
                              rec(tel(ruta="/api/v1/asistencia/marcas", latencia=7))], NOW)
        lat = {d["Ruta"]: d for d in docs_de(docs, "Latencia")}
        self.assertEqual(sorted(lat["/api/v1/asistencia/marcas/{id}"]["Latencia"]), [0, 5, 900])
        self.assertEqual(lat["/api/v1/asistencia/marcas"]["Latencia"], [7])
        cw = lat["/api/v1/asistencia/marcas"]["_aws"]["CloudWatchMetrics"][0]
        self.assertEqual(cw["Dimensions"], [["Servicio"], ["Servicio", "Ruta"]])
        self.assertEqual(cw["Metrics"], [{"Name": "Latencia", "Unit": "Milliseconds"}])
        self.assertEqual(lat["/api/v1/asistencia/marcas"]["Servicio"], "asistencia")
        self.assertNotIn("TenantId", lat["/api/v1/asistencia/marcas"])

    def test_latencia_se_reparte_en_documentos_de_100(self):
        docs = build_metrics([rec(tel(latencia=i)) for i in range(250)], NOW)
        tamanos = sorted(len(d["Latencia"]) for d in docs_de(docs, "Latencia"))
        self.assertEqual(tamanos, [50, 100, 100])
        self.assertEqual(sorted(v for d in docs_de(docs, "Latencia") for v in d["Latencia"]), list(range(250)))
        self.assertEqual([d["Requests"] for d in docs_de(docs, "Requests")], [250])

    def test_telemetria_usa_el_minuto_de_llegada(self):
        docs = build_metrics([rec(tel(), 1700000000.5), rec(tel(), 1700000065.0)], NOW)
        self.assertEqual(sorted(d["_aws"]["Timestamp"] for d in docs_de(docs, "Latencia")), [1699999980000, 1700000040000])
        self.assertEqual(sorted(d["_aws"]["Timestamp"] for d in docs_de(docs, "Requests")), [1699999980000, 1700000040000])

    def test_telemetria_mal_formada_cuenta_como_invalida(self):
        sin_servicio = tel()
        del sin_servicio["servicio"]
        malos = [sin_servicio, tel(servicio=""), tel(servicio=5), tel(ruta=None), tel(ruta=""),
                 tel(status="200"), tel(status=True), tel(status=99), tel(status=600),
                 tel(latencia="12"), tel(latencia=-1), tel(latencia=True), tel(latencia=1.5)]
        docs = build_metrics([rec(m) for m in malos], NOW)
        self.assertEqual([d.get("EventosInvalidos") for d in docs], [13])

    def test_tenant_ausente_o_vacio_es_sin_tenant(self):
        sin_clave = tel()
        del sin_clave["tenantId"]
        docs = build_metrics([rec(tel(tenant=None)), rec(tel(tenant="")), rec(tel(tenant=5)), rec(sin_clave)], NOW)
        self.assertEqual([(d["TenantId"], d["Requests"]) for d in docs_de(docs, "Requests")], [("sin-tenant", 4)])

    def test_negocio_y_telemetria_en_el_mismo_lote(self):
        docs = build_metrics([rec(ev("asistencia.marca.registrada", "t1")), rec(tel())], NOW)
        self.assertEqual([d["Eventos"] for d in docs_de(docs, "Eventos")], [1])
        self.assertEqual([d["Requests"] for d in docs_de(docs, "Requests")], [1])
        self.assertEqual(docs_de(docs, "EventosInvalidos"), [])

    def test_handler_suma_requests_en_procesados(self):
        evento = {"Records": [rec(tel()), rec(tel(status=500)), rec(ev("asistencia.editada", "t1"))]}
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            res = lambda_handler(evento, None)
        self.assertEqual(res, {"procesados": 3, "invalidos": 0})
        self.assertTrue(all("_aws" in json.loads(linea) for linea in buf.getvalue().strip().splitlines()))


if __name__ == "__main__":
    unittest.main()
