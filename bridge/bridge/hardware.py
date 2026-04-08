"""
NanoAgent Hardware Abstraction — GPIO, I2C, SPI tools.

Provides hardware control tools that work across platforms:
- Linux SBCs (Raspberry Pi, etc.): via libgpiod / gpiod Python bindings
- macOS / other: simulator mode (logs commands)

Safety: pin allowlist in config, rate limiting on writes.
"""

import json
import logging
import os
import platform
import time

logger = logging.getLogger("nanoagent.hardware")

# Rate limiting: max writes per second per pin
_write_timestamps = {}
MAX_WRITES_PER_SEC = 10

# Config state (loaded lazily)
_allowed_pins = None
_gpio_chip = "gpiochip0"


def _load_config():
    """Load hardware config from ~/.nanoagent/hardware.json."""
    global _allowed_pins, _gpio_chip
    config_path = os.path.expanduser("~/.nanoagent/hardware.json")
    if os.path.exists(config_path):
        try:
            with open(config_path, "r") as f:
                cfg = json.load(f)
            _allowed_pins = set(cfg.get("allowed_pins", []))
            _gpio_chip = cfg.get("gpio_chip", "gpiochip0")
            logger.info("Hardware config loaded: %d allowed pins, chip=%s", len(_allowed_pins), _gpio_chip)
        except Exception as e:
            logger.warning("Failed to load hardware config: %s", e)


def _check_pin_allowed(pin):
    """Check if a pin is in the allowlist (if configured)."""
    global _allowed_pins
    if _allowed_pins is None:
        _load_config()
    if _allowed_pins and pin not in _allowed_pins:
        return False
    return True


def _check_rate_limit(pin):
    """Rate-limit writes to prevent hardware damage."""
    now = time.time()
    key = str(pin)
    timestamps = _write_timestamps.get(key, [])
    # Keep only timestamps from the last second
    timestamps = [t for t in timestamps if now - t < 1.0]
    if len(timestamps) >= MAX_WRITES_PER_SEC:
        return False
    timestamps.append(now)
    _write_timestamps[key] = timestamps
    return True


def _is_linux():
    return platform.system() == "Linux"


def handle_gpio_read(data):
    """Read a GPIO pin value."""
    pin = data.get("pin")
    if pin is None:
        return {"error": "pin required"}

    if not _check_pin_allowed(pin):
        return {"error": f"pin {pin} not in allowlist"}

    if _is_linux():
        try:
            import gpiod
            chip = gpiod.Chip(_gpio_chip)
            line = chip.get_line(pin)
            line.request(consumer="nanoagent", type=gpiod.LINE_REQ_DIR_IN)
            value = line.get_value()
            line.release()
            return {"pin": pin, "value": value}
        except ImportError:
            return {"error": "gpiod not installed. Run: pip install gpiod"}
        except Exception as e:
            return {"error": f"GPIO read failed: {e}"}
    else:
        # Simulator mode
        logger.info("[SIM] gpio_read pin=%s", pin)
        return {"pin": pin, "value": 0, "simulated": True}


def handle_gpio_write(data):
    """Write a value to a GPIO pin."""
    pin = data.get("pin")
    value = data.get("value")
    if pin is None or value is None:
        return {"error": "pin and value required"}

    if not _check_pin_allowed(pin):
        return {"error": f"pin {pin} not in allowlist"}

    if not _check_rate_limit(pin):
        return {"error": f"rate limit exceeded for pin {pin}"}

    if _is_linux():
        try:
            import gpiod
            chip = gpiod.Chip(_gpio_chip)
            line = chip.get_line(pin)
            line.request(consumer="nanoagent", type=gpiod.LINE_REQ_DIR_OUT)
            line.set_value(int(value))
            line.release()
            return {"pin": pin, "value": int(value), "status": "ok"}
        except ImportError:
            return {"error": "gpiod not installed. Run: pip install gpiod"}
        except Exception as e:
            return {"error": f"GPIO write failed: {e}"}
    else:
        logger.info("[SIM] gpio_write pin=%s value=%s", pin, value)
        return {"pin": pin, "value": int(value), "status": "ok", "simulated": True}


def handle_gpio_list(data):
    """List available GPIO pins."""
    if _is_linux():
        try:
            import gpiod
            chip = gpiod.Chip(_gpio_chip)
            pins = []
            for i in range(chip.num_lines):
                line = chip.get_line(i)
                pins.append({
                    "pin": i,
                    "name": line.name or f"GPIO{i}",
                    "consumer": line.consumer or "",
                    "direction": "in" if not line.is_used else "used",
                })
            return {"chip": _gpio_chip, "pins": pins}
        except ImportError:
            return {"error": "gpiod not installed. Run: pip install gpiod"}
        except Exception as e:
            return {"error": f"GPIO list failed: {e}"}
    else:
        # Simulator: return fake GPIO layout
        logger.info("[SIM] gpio_list")
        return {
            "chip": "simulated",
            "pins": [
                {"pin": i, "name": f"GPIO{i}", "consumer": "", "direction": "in"}
                for i in range(28)  # RPi-like layout
            ],
            "simulated": True,
        }


def handle_i2c_read(data):
    """Read from an I2C device."""
    bus = data.get("bus", 1)
    addr = data.get("addr")
    register = data.get("register", 0)
    length = data.get("length", 1)

    if addr is None:
        return {"error": "addr required"}

    if _is_linux():
        try:
            import smbus2
            with smbus2.SMBus(bus) as i2c:
                result = i2c.read_i2c_block_data(addr, register, length)
            return {"bus": bus, "addr": addr, "register": register, "data": result}
        except ImportError:
            return {"error": "smbus2 not installed. Run: pip install smbus2"}
        except Exception as e:
            return {"error": f"I2C read failed: {e}"}
    else:
        logger.info("[SIM] i2c_read bus=%s addr=0x%02x reg=%s len=%s", bus, addr, register, length)
        return {
            "bus": bus, "addr": addr, "register": register,
            "data": [0] * length, "simulated": True,
        }


def handle_spi_transfer(data):
    """Transfer data over SPI."""
    bus = data.get("bus", 0)
    device = data.get("device", 0)
    send_data = data.get("data", [])
    speed = data.get("speed", 500000)

    if _is_linux():
        try:
            import spidev
            spi = spidev.SpiDev()
            spi.open(bus, device)
            spi.max_speed_hz = speed
            response = spi.xfer2(send_data)
            spi.close()
            return {"bus": bus, "device": device, "response": response}
        except ImportError:
            return {"error": "spidev not installed. Run: pip install spidev"}
        except Exception as e:
            return {"error": f"SPI transfer failed: {e}"}
    else:
        logger.info("[SIM] spi_transfer bus=%s dev=%s data=%s", bus, device, send_data)
        return {
            "bus": bus, "device": device,
            "response": [0] * len(send_data), "simulated": True,
        }
