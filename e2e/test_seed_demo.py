import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from seed_demo import dv_rut, rut  # noqa: E402


class DvRutTest(unittest.TestCase):
    def test_digitos_conocidos(self):
        self.assertEqual(dv_rut(76123456), "0")  # la semilla de identity (V5 corrige el 7 por 0)
        self.assertEqual(dv_rut(12345678), "5")
        self.assertEqual(dv_rut(11111111), "1")

    def test_k_y_formato(self):
        self.assertEqual(dv_rut(10000013), "K")
        self.assertEqual(rut(12345678), "12345678-5")


if __name__ == "__main__":
    unittest.main()
