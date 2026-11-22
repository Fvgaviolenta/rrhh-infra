"""Tests de scripts/stream-load.sh en --dry-run (no llama a AWS)."""

import json
import os
import subprocess
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "stream-load.sh")


def correr(*args):
    env = {k: v for k, v in os.environ.items() if k != "STREAM_NAME"}
    return subprocess.run(["bash", SCRIPT, *args], capture_output=True, text=True, env=env, timeout=60)


class StreamLoadTest(unittest.TestCase):
    def test_dry_run_prints_batches_of_100(self):
        r = correr("--dry-run", "250")
        self.assertEqual(r.returncode, 0, r.stderr)
        lotes = [json.loads(linea) for linea in r.stdout.strip().splitlines()]
        self.assertEqual([len(b["Records"]) for b in lotes], [100, 100, 50])
        for b in lotes:
            self.assertEqual(b["StreamName"], "rrhh-events")
            for rec in b["Records"]:
                self.assertEqual(rec["PartitionKey"], "carga-prueba")
                data = json.loads(rec["Data"])
                self.assertEqual(data["eventType"], "asistencia.marca.registrada")
                self.assertEqual(data["tenantId"], "carga-prueba")
        ids = [json.loads(rec["Data"])["eventId"] for b in lotes for rec in b["Records"]]
        self.assertEqual(len(set(ids)), 250)

    def test_rejects_non_positive_total(self):
        for total in ["0", "-5", "abc", ""]:
            r = correr("--dry-run", total)
            self.assertNotEqual(r.returncode, 0, total)
            self.assertEqual(r.stdout, "", total)


if __name__ == "__main__":
    unittest.main()
