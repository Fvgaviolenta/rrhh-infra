"""Tests de las utilidades puras de e2e_check.py (no tocan la red). Uso: python3 -m unittest discover -s e2e"""
import base64
import datetime as dt
import json
import unittest

from e2e_check import ZONA, claims_de, datos, turno_atrasado


def jwt(payload: dict) -> str:
    cuerpo = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    return f"e30.{cuerpo}.firma"


class ClaimsTest(unittest.TestCase):
    def test_lee_claims_sin_padding(self):
        c = claims_de(jwt({"custom:tenant_id": "t-1", "custom:role": "Trabajador", "x": "ab"}))
        self.assertEqual(c["custom:tenant_id"], "t-1")
        self.assertEqual(c["custom:role"], "Trabajador")


class TurnoAtrasadoTest(unittest.TestCase):
    def test_inicio_una_hora_antes_en_hora_de_chile(self):
        ahora = dt.datetime(2026, 11, 24, 15, 30, tzinfo=ZONA)
        self.assertEqual(turno_atrasado(ahora), ("14:30", "22:30"))

    def test_convierte_desde_utc(self):
        ahora = dt.datetime(2026, 11, 24, 18, 30, tzinfo=dt.timezone.utc)  # 15:30 en Chile (UTC-3 en verano)
        self.assertEqual(turno_atrasado(ahora)[0], "14:30")

    def test_temprano_en_la_manana_usa_medianoche(self):
        ahora = dt.datetime(2026, 11, 24, 0, 20, tzinfo=ZONA)
        self.assertEqual(turno_atrasado(ahora), ("00:00", "08:00"))

    def test_fin_no_pasa_de_medianoche(self):
        ahora = dt.datetime(2026, 11, 24, 23, 0, tzinfo=ZONA)
        self.assertEqual(turno_atrasado(ahora), ("22:00", "23:59"))

    def test_la_marca_queda_fuera_de_la_tolerancia(self):
        ahora = dt.datetime(2026, 11, 24, 9, 0, tzinfo=ZONA)
        inicio = dt.datetime.strptime(turno_atrasado(ahora)[0], "%H:%M").time()
        minutos = (ahora.hour * 60 + ahora.minute) - (inicio.hour * 60 + inicio.minute)
        self.assertGreater(minutos, 5)


class DatosTest(unittest.TestCase):
    def test_desenvuelve_api_response(self):
        self.assertEqual(datos({"codigo": 200, "datos": [1]}), [1])
        self.assertEqual(datos([1]), [1])
        self.assertIsNone(datos(None))


if __name__ == "__main__":
    unittest.main()
