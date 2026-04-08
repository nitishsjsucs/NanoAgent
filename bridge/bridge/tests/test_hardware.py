"""Tests for hardware.py — rate limiting, allowlist, simulator mode."""
import json
import os
import tempfile
import time
import unittest

# Ensure bridge package is importable
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import hardware


class TestPinAllowlist(unittest.TestCase):
    def setUp(self):
        hardware._allowed_pins = None
        hardware._gpio_chip = "gpiochip0"

    def test_all_pins_allowed_when_no_config(self):
        hardware._allowed_pins = set()  # empty = all allowed
        self.assertTrue(hardware._check_pin_allowed(17))

    def test_pin_in_allowlist(self):
        hardware._allowed_pins = {17, 18, 27}
        self.assertTrue(hardware._check_pin_allowed(17))

    def test_pin_not_in_allowlist(self):
        hardware._allowed_pins = {17, 18, 27}
        self.assertFalse(hardware._check_pin_allowed(4))

    def test_config_loads_chip_name(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump({"allowed_pins": [1, 2], "gpio_chip": "gpiochip4"}, f)
            f.flush()
            hardware._allowed_pins = None
            orig = os.path.expanduser
            os.path.expanduser = lambda _: f.name
            try:
                hardware._load_config()
            finally:
                os.path.expanduser = orig
                os.unlink(f.name)
        self.assertEqual(hardware._gpio_chip, "gpiochip4")
        self.assertEqual(hardware._allowed_pins, {1, 2})


class TestRateLimit(unittest.TestCase):
    def setUp(self):
        hardware._write_timestamps.clear()

    def test_allows_under_limit(self):
        for _ in range(hardware.MAX_WRITES_PER_SEC):
            self.assertTrue(hardware._check_rate_limit(5))

    def test_blocks_over_limit(self):
        for _ in range(hardware.MAX_WRITES_PER_SEC):
            hardware._check_rate_limit(5)
        self.assertFalse(hardware._check_rate_limit(5))

    def test_different_pins_independent(self):
        for _ in range(hardware.MAX_WRITES_PER_SEC):
            hardware._check_rate_limit(5)
        self.assertTrue(hardware._check_rate_limit(6))


class TestSimulatorMode(unittest.TestCase):
    def setUp(self):
        hardware._allowed_pins = set()  # allow all

    def test_gpio_read_simulated(self):
        result = hardware.handle_gpio_read({"pin": 17})
        self.assertTrue(result.get("simulated"))
        self.assertEqual(result["pin"], 17)
        self.assertEqual(result["value"], 0)

    def test_gpio_write_simulated(self):
        result = hardware.handle_gpio_write({"pin": 17, "value": 1})
        self.assertTrue(result.get("simulated"))
        self.assertEqual(result["value"], 1)

    def test_gpio_write_missing_params(self):
        result = hardware.handle_gpio_write({"pin": 17})
        self.assertIn("error", result)

    def test_gpio_read_missing_pin(self):
        result = hardware.handle_gpio_read({})
        self.assertIn("error", result)

    def test_gpio_list_simulated(self):
        result = hardware.handle_gpio_list({})
        self.assertTrue(result.get("simulated"))
        self.assertEqual(result["chip"], "simulated")
        self.assertEqual(len(result["pins"]), 28)

    def test_gpio_write_blocked_by_allowlist(self):
        hardware._allowed_pins = {1, 2}
        result = hardware.handle_gpio_write({"pin": 17, "value": 1})
        self.assertIn("error", result)
        self.assertIn("allowlist", result["error"])

    def test_i2c_read_simulated(self):
        result = hardware.handle_i2c_read({"addr": 0x48, "length": 2})
        self.assertTrue(result.get("simulated"))
        self.assertEqual(len(result["data"]), 2)

    def test_spi_transfer_simulated(self):
        result = hardware.handle_spi_transfer({"data": [0x01, 0x02]})
        self.assertTrue(result.get("simulated"))
        self.assertEqual(len(result["response"]), 2)


if __name__ == "__main__":
    unittest.main()
