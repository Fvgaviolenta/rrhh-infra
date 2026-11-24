"""Tests de las utilidades puras de e2e_consola.py (no tocan la red). Uso: python3 -m unittest discover -s e2e"""
import unittest

from e2e_consola import es_bloqueo_por_suspension, rutas_de_plataforma


class BloqueoTest(unittest.TestCase):
    def test_403_con_el_mensaje_es_suspension(self):
        self.assertTrue(es_bloqueo_por_suspension(403, '{"mensaje":"La empresa está suspendida"}'))

    def test_403_sin_el_mensaje_no_es_suspension(self):
        self.assertFalse(es_bloqueo_por_suspension(403, '{"mensaje":"No autorizado para este recurso"}'))

    def test_otro_status_no_es_suspension(self):
        self.assertFalse(es_bloqueo_por_suspension(200, "La empresa está suspendida"))


class RutasTest(unittest.TestCase):
    def test_rutas_de_plataforma(self):
        rutas = rutas_de_plataforma("t-1")
        self.assertEqual(rutas[0], "/api/v1/plataforma/tenants/t-1/usuarios")
        self.assertEqual(len(rutas), 5)


if __name__ == "__main__":
    unittest.main()
