"""Unit tests for the loadgen tenant popularity weights.

Run: python3 -m unittest discover -s load -p 'test_*.py' -v
"""
import importlib
import os
import unittest
from unittest import mock

import loadgen  # importing must not start the load loop


def reload_with_zipf(value):
    """Re-import loadgen with ZIPF_S set to value (None means unset)."""
    env = {k: v for k, v in os.environ.items() if k != "ZIPF_S"}
    if value is not None:
        env["ZIPF_S"] = value
    with mock.patch.dict(os.environ, env, clear=True):
        return importlib.reload(loadgen)


class TenantWeightsTest(unittest.TestCase):
    def tearDown(self):
        reload_with_zipf(None)

    def test_default_matches_original_weights(self):
        mod = reload_with_zipf(None)
        original = [1.0 / (k + 1) for k in range(mod.N_TENANTS)]
        self.assertEqual(mod.ZIPF_S, 1.0)
        self.assertEqual(mod.TENANT_WEIGHTS, original)

    def test_explicit_one_matches_original_weights(self):
        mod = reload_with_zipf("1")
        original = [1.0 / (k + 1) for k in range(mod.N_TENANTS)]
        self.assertEqual(mod.TENANT_WEIGHTS, original)

    def test_zipf_2_hottest_tenant_share(self):
        mod = reload_with_zipf("2")
        self.assertEqual(mod.N_TENANTS, 12)
        share = mod.TENANT_WEIGHTS[0] / sum(mod.TENANT_WEIGHTS)
        # 1 / sum(1/k^2 for k in 1..12) = 0.639 of tenant traffic,
        # against 0.322 at the default exponent.
        self.assertAlmostEqual(share, 0.639, places=3)
        default = loadgen.tenant_weights(12, 1.0)
        self.assertAlmostEqual(default[0] / sum(default), 0.322, places=3)

    def test_bad_value_fails_at_startup(self):
        for bad in ("abc", "", "-1", "nan", "inf"):
            with self.subTest(value=bad):
                with self.assertRaises(SystemExit) as ctx:
                    reload_with_zipf(bad)
                self.assertIn("ZIPF_S", str(ctx.exception.code))
                self.assertIn(repr(bad), str(ctx.exception.code))

    def test_parse_rejects_bad_values(self):
        for bad in ("abc", "", "-0.5", "nan", "inf"):
            with self.subTest(value=bad):
                with self.assertRaises(ValueError):
                    loadgen.parse_zipf_s(bad)
        self.assertEqual(loadgen.parse_zipf_s("2"), 2.0)
        self.assertEqual(loadgen.parse_zipf_s("1.5"), 1.5)


if __name__ == "__main__":
    unittest.main()
