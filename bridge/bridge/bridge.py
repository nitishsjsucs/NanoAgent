#!/usr/bin/env python3
"""
NanoAgent Bridge — connects a BLE/Serial NanoAgent device to Claude API.

The bridge receives RPC messages from NanoAgent running on embedded hardware,
forwards API calls to Claude, executes tools locally, and sends results back.

Also supports --exec-tool mode: receives a JSON command as argv[2], dispatches
to the appropriate handler, and prints JSON response to stdout.

Usage:
  # BLE mode (connect to NanoAgent ring/device):
  python bridge.py --ble

  # Serial mode (connect to NanoAgent dev board):
  python bridge.py --serial /dev/ttyUSB0

  # Unix socket mode (for desktop BLE simulation):
  python bridge.py --socket /tmp/nanoagent.sock

  # Direct tool execution (called by Zig IoT/robotics profiles):
  python bridge.py --exec-tool '{"action":"mqtt_publish","topic":"test","payload":"hello"}'
"""

import argparse
import asyncio
import json
import logging
import os
import struct
import subprocess
import sys
import time
import platform
import urllib.error
import urllib.request

try:
    import anthropic
except ImportError:
    anthropic = None

# ============================================================
# Tool Handlers (used by --exec-tool mode)
# ============================================================

ROBOT_LOG_PATH = os.path.expanduser("~/.nanoagent/robot_commands.log")


def handle_mqtt_publish(data):
    """Publish to an MQTT topic using paho-mqtt."""
    try:
        import paho.mqtt.client as mqtt
    except ImportError:
        return {"error": "paho-mqtt not installed. Run: pip install paho-mqtt"}

    topic = data.get("topic", "")
    payload = data.get("payload", "")
    broker = data.get("broker", "localhost")
    port = data.get("port", 1883)

    try:
        client = mqtt.Client()
        client.connect(broker, port, 60)
        result = client.publish(topic, payload)
        client.disconnect()
        return {
            "status": "published",
            "topic": topic,
            "payload_size": len(payload),
            "rc": result.rc,
        }
    except Exception as e:
        return {"error": f"MQTT publish failed: {e}"}


def handle_mqtt_subscribe(data):
    """Subscribe to an MQTT topic and wait for one message."""
    try:
        import paho.mqtt.client as mqtt
    except ImportError:
        return {"error": "paho-mqtt not installed. Run: pip install paho-mqtt"}

    topic = data.get("topic", "")
    timeout_ms = data.get("timeout_ms", 5000)
    broker = data.get("broker", "localhost")
    port = data.get("port", 1883)

    received = {"message": None}

    def on_message(client, userdata, msg):
        received["message"] = {
            "topic": msg.topic,
            "payload": msg.payload.decode("utf-8", errors="replace"),
            "qos": msg.qos,
        }

    try:
        client = mqtt.Client()
        client.on_message = on_message
        client.connect(broker, port, 60)
        client.subscribe(topic)
        client.loop_start()
        deadline = time.time() + (timeout_ms / 1000.0)
        while received["message"] is None and time.time() < deadline:
            time.sleep(0.05)
        client.loop_stop()
        client.disconnect()

        if received["message"]:
            return {"status": "received", **received["message"]}
        else:
            return {"status": "timeout", "topic": topic, "timeout_ms": timeout_ms}
    except Exception as e:
        return {"error": f"MQTT subscribe failed: {e}"}


def handle_http_request(data):
    """Make an HTTP request using urllib (stdlib, no deps)."""
    import urllib.request
    import urllib.error

    method = data.get("method", "GET")
    url = data.get("url", "")
    body = data.get("body", "")
    headers = data.get("headers", {})

    if not url:
        return {"error": "Missing 'url'"}

    try:
        body_bytes = body.encode("utf-8") if body else None
        req = urllib.request.Request(url, data=body_bytes, method=method)
        for k, v in headers.items():
            req.add_header(k, v)
        if body and "Content-Type" not in headers:
            req.add_header("Content-Type", "application/json")

        with urllib.request.urlopen(req, timeout=30) as resp:
            resp_body = resp.read().decode("utf-8", errors="replace")
            return {
                "status": resp.status,
                "headers": dict(resp.headers),
                "body": resp_body[:65536],  # Cap at 64KB
            }
    except urllib.error.HTTPError as e:
        return {
            "status": e.code,
            "error": str(e.reason),
            "body": e.read().decode("utf-8", errors="replace")[:65536],
        }
    except Exception as e:
        return {"error": f"HTTP request failed: {e}"}


def handle_robot_cmd(data):
    """
    Handle a robot command (pose/velocity/gripper).
    In simulator mode, logs to file and returns success.
    # TODO: Plug in real ROS/hardware bindings here.
    # For ROS2: use rclpy to publish to /cmd_vel, /joint_states, /gripper_command
    # For direct hardware: use serial/CAN bus communication to motor controllers
    """
    cmd_type = data.get("type", "unknown")
    params = data.get("params", {})

    os.makedirs(os.path.dirname(ROBOT_LOG_PATH), exist_ok=True)
    with open(ROBOT_LOG_PATH, "a") as f:
        f.write(json.dumps({
            "timestamp": time.time(),
            "type": cmd_type,
            "params": params,
        }) + "\n")

    return {
        "status": "executed",
        "mode": "simulator",
        "type": cmd_type,
        "message": f"Robot command '{cmd_type}' logged (simulator mode)",
    }


def handle_estop(data):
    """
    Emergency stop handler.
    # TODO: In real hardware mode, this should:
    # 1. Send immediate stop to all motor controllers
    # 2. Engage physical brakes if available
    # 3. Publish to /emergency_stop topic (ROS)
    """
    os.makedirs(os.path.dirname(ROBOT_LOG_PATH), exist_ok=True)
    with open(ROBOT_LOG_PATH, "a") as f:
        f.write(json.dumps({
            "timestamp": time.time(),
            "type": "ESTOP",
            "reason": data.get("reason", "manual"),
        }) + "\n")

    return {
        "status": "estop_activated",
        "mode": "simulator",
        "message": "Emergency stop activated (simulator mode)",
    }


def handle_telemetry(data):
    """
    Return telemetry snapshot.
    In simulator mode, returns system stats as simulated robot telemetry.
    # TODO: In real hardware mode, read from:
    # - /joint_states topic (ROS)
    # - IMU sensor data
    # - Motor encoder feedback
    # - Battery management system
    """
    # psutil not required — using cross-platform alternatives below

    uptime_s = 0
    cpu_pct = 0.0
    mem_total = 0
    mem_used = 0

    try:
        # Cross-platform uptime
        if os.path.exists("/proc/uptime"):
            with open("/proc/uptime") as f:
                uptime_s = float(f.read().split()[0])
        else:
            # macOS: parse sysctl
            result = subprocess.run(
                ["sysctl", "-n", "kern.boottime"],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0:
                # Parse "{ sec = 1234567890, usec = 0 }"
                import re
                m = re.search(r"sec\s*=\s*(\d+)", result.stdout)
                if m:
                    uptime_s = time.time() - int(m.group(1))
    except Exception:
        pass

    try:
        # CPU: quick sample via os.getloadavg()
        load = os.getloadavg()
        cpu_pct = load[0] * 100.0 / os.cpu_count()
    except Exception:
        pass

    try:
        if platform.system() == "Darwin":
            result = subprocess.run(
                ["sysctl", "-n", "hw.memsize"],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0:
                mem_total = int(result.stdout.strip())
            # Approximate used memory via vm_stat
            result2 = subprocess.run(
                ["vm_stat"], capture_output=True, text=True, timeout=5
            )
            if result2.returncode == 0:
                import re
                pages_active = 0
                pages_wired = 0
                for line in result2.stdout.splitlines():
                    m = re.match(r"Pages active:\s+(\d+)", line)
                    if m: pages_active = int(m.group(1))
                    m = re.match(r"Pages wired down:\s+(\d+)", line)
                    if m: pages_wired = int(m.group(1))
                mem_used = (pages_active + pages_wired) * 4096
        elif os.path.exists("/proc/meminfo"):
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        mem_total = int(line.split()[1]) * 1024
                    elif line.startswith("MemAvailable:"):
                        mem_used = mem_total - int(line.split()[1]) * 1024
    except Exception:
        pass

    return {
        "mode": "simulator",
        "uptime_seconds": round(uptime_s, 1),
        "cpu_percent": round(cpu_pct, 1),
        "memory_total_bytes": mem_total,
        "memory_used_bytes": mem_used,
        "position": {"x": 0.0, "y": 0.0, "z": 0.0},
        "velocity": {"vx": 0.0, "vy": 0.0, "vz": 0.0},
        "gripper": 0.0,
        "estop": False,
        "status": "idle",
    }


def handle_web_search(data):
    """Perform a web search using DuckDuckGo HTML (no API key needed)."""
    query = data.get("query", "")
    max_results = data.get("max_results", 5)
    if not query:
        return {"error": "Missing 'query' parameter"}

    try:
        # Use DuckDuckGo HTML endpoint (no API key, no deps)
        encoded = urllib.request.quote(query)
        url = f"https://html.duckduckgo.com/html/?q={encoded}"
        req = urllib.request.Request(url, headers={
            "User-Agent": "NanoAgent/0.1.0 (AI Agent Runtime)",
        })
        with urllib.request.urlopen(req, timeout=15) as resp:
            html = resp.read().decode("utf-8", errors="replace")

        # Parse results from HTML (simple regex, no deps)
        import re
        results = []
        # DuckDuckGo HTML results are in <a class="result__a" href="...">title</a>
        # and <a class="result__snippet">snippet</a>
        links = re.findall(
            r'<a[^>]+class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>',
            html, re.DOTALL
        )
        snippets = re.findall(
            r'<a[^>]+class="result__snippet"[^>]*>(.*?)</a>',
            html, re.DOTALL
        )

        for i, (href, title) in enumerate(links[:max_results]):
            # Clean HTML tags from title and snippet
            clean_title = re.sub(r"<[^>]+>", "", title).strip()
            clean_snippet = ""
            if i < len(snippets):
                clean_snippet = re.sub(r"<[^>]+>", "", snippets[i]).strip()
            # DuckDuckGo wraps URLs in a redirect — extract the actual URL
            actual_url = href
            uddg_match = re.search(r"uddg=([^&]+)", href)
            if uddg_match:
                actual_url = urllib.request.unquote(uddg_match.group(1))
            results.append({
                "title": clean_title,
                "url": actual_url,
                "snippet": clean_snippet,
            })

        return {"query": query, "results": results, "count": len(results)}
    except Exception as e:
        return {"error": f"Web search failed: {e}"}


def handle_session_save(data):
    """Save conversation history to a JSON file."""
    session_id = data.get("session_id", "default")
    messages = data.get("messages", [])
    if not messages:
        return {"error": "No messages to save"}

    # Validate session_id (prevent path traversal)
    if ".." in session_id or "/" in session_id or "\\" in session_id:
        return {"error": "Invalid session_id"}

    session_dir = os.path.expanduser("~/.nanoagent/sessions")
    os.makedirs(session_dir, exist_ok=True)
    path = os.path.join(session_dir, f"{session_id}.json")

    try:
        with open(path, "w") as f:
            json.dump({"session_id": session_id, "messages": messages,
                       "saved_at": time.time()}, f, indent=2)
        return {"status": "saved", "session_id": session_id,
                "message_count": len(messages), "path": path}
    except Exception as e:
        return {"error": f"Session save failed: {e}"}


def handle_session_load(data):
    """Load conversation history from a JSON file."""
    session_id = data.get("session_id", "default")

    if ".." in session_id or "/" in session_id or "\\" in session_id:
        return {"error": "Invalid session_id"}

    path = os.path.join(os.path.expanduser("~/.nanoagent/sessions"),
                        f"{session_id}.json")
    try:
        with open(path, "r") as f:
            data = json.load(f)
        return {"status": "loaded", "session_id": session_id,
                "messages": data.get("messages", []),
                "message_count": len(data.get("messages", [])),
                "saved_at": data.get("saved_at")}
    except FileNotFoundError:
        return {"error": f"Session '{session_id}' not found"}
    except Exception as e:
        return {"error": f"Session load failed: {e}"}


def handle_session_list(data):
    """List all saved sessions."""
    session_dir = os.path.expanduser("~/.nanoagent/sessions")
    if not os.path.exists(session_dir):
        return {"sessions": []}

    sessions = []
    for fname in sorted(os.listdir(session_dir)):
        if fname.endswith(".json"):
            path = os.path.join(session_dir, fname)
            try:
                with open(path, "r") as f:
                    data = json.load(f)
                sessions.append({
                    "session_id": fname[:-5],
                    "message_count": len(data.get("messages", [])),
                    "saved_at": data.get("saved_at"),
                })
            except Exception:
                sessions.append({"session_id": fname[:-5], "error": "corrupt"})
    return {"sessions": sessions, "count": len(sessions)}


def handle_ota_check(data):
    """Check for OTA updates from GitHub releases."""
    repo = data.get("repo", "nanoagent/NanoAgent")
    current_version = data.get("current_version", "0.1.0")

    try:
        url = f"https://api.github.com/repos/{repo}/releases/latest"
        req = urllib.request.Request(url, headers={
            "User-Agent": "NanoAgent/0.1.0",
            "Accept": "application/vnd.github+json",
        })
        with urllib.request.urlopen(req, timeout=15) as resp:
            release = json.loads(resp.read().decode("utf-8"))

        tag = release.get("tag_name", "").lstrip("v")
        if not tag:
            return {"update_available": False, "reason": "No releases found"}

        # Simple version comparison (semver-like)
        def ver_tuple(v):
            parts = v.split(".")
            return tuple(int(p) for p in parts if p.isdigit())

        latest = ver_tuple(tag)
        current = ver_tuple(current_version)

        if latest <= current:
            return {"update_available": False, "current": current_version,
                    "latest": tag}

        # Find matching asset for this platform
        arch = platform.machine()
        system = platform.system().lower()
        assets = release.get("assets", [])
        matching = [a for a in assets
                    if system in a["name"].lower() and arch in a["name"].lower()]

        return {
            "update_available": True,
            "current": current_version,
            "latest": tag,
            "release_url": release.get("html_url", ""),
            "release_notes": release.get("body", "")[:2000],
            "assets": [{"name": a["name"], "url": a["browser_download_url"],
                        "size": a["size"]} for a in matching],
            "all_assets": [a["name"] for a in assets],
        }
    except Exception as e:
        return {"error": f"OTA check failed: {e}"}


def handle_ota_download(data):
    """Download an OTA update binary."""
    url = data.get("url", "")
    output_path = data.get("output_path", "")
    if not url or not output_path:
        return {"error": "Missing 'url' or 'output_path'"}

    # Security: only allow downloads from GitHub
    if not url.startswith("https://github.com/"):
        return {"error": "OTA downloads only allowed from github.com"}

    # Prevent path traversal
    output_path = os.path.abspath(output_path)
    if ".." in data.get("output_path", ""):
        return {"error": "Invalid output_path"}

    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "NanoAgent/0.1.0",
        })
        with urllib.request.urlopen(req, timeout=120) as resp:
            content = resp.read()

        import hashlib
        sha256 = hashlib.sha256(content).hexdigest()

        os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
        with open(output_path, "wb") as f:
            f.write(content)
        os.chmod(output_path, 0o755)

        return {
            "status": "downloaded",
            "path": output_path,
            "size": len(content),
            "sha256": sha256,
        }
    except Exception as e:
        return {"error": f"OTA download failed: {e}"}


def handle_ota_apply(data):
    """Apply an OTA update by replacing the current binary and restarting."""
    new_binary = data.get("new_binary", "")
    current_binary = data.get("current_binary", "")
    if not new_binary or not current_binary:
        return {"error": "Missing 'new_binary' or 'current_binary'"}

    new_binary = os.path.abspath(new_binary)
    current_binary = os.path.abspath(current_binary)

    if not os.path.exists(new_binary):
        return {"error": f"New binary not found: {new_binary}"}

    try:
        # Verify the new binary is executable
        result = subprocess.run([new_binary, "--version"],
                                capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            return {"error": f"New binary failed --version check: {result.stderr}"}
        new_version = result.stdout.strip()

        # Backup current binary
        backup = current_binary + ".backup"
        if os.path.exists(current_binary):
            import shutil
            shutil.copy2(current_binary, backup)

        # Replace
        import shutil
        shutil.copy2(new_binary, current_binary)
        os.chmod(current_binary, 0o755)

        return {
            "status": "applied",
            "new_version": new_version,
            "backup": backup,
            "message": "Update applied. Restart NanoAgent to use the new version.",
        }
    except Exception as e:
        return {"error": f"OTA apply failed: {e}"}


# Dispatch table for --exec-tool mode
TOOL_HANDLERS = {
    "mqtt_publish": handle_mqtt_publish,
    "mqtt_subscribe": handle_mqtt_subscribe,
    "http_request": handle_http_request,
    "robot_cmd": handle_robot_cmd,
    "estop": handle_estop,
    "telemetry": handle_telemetry,
    "web_search": handle_web_search,
    "session_save": handle_session_save,
    "session_load": handle_session_load,
    "session_list": handle_session_list,
    "ota_check": handle_ota_check,
    "ota_download": handle_ota_download,
    "ota_apply": handle_ota_apply,
}

# MCP tool handlers (lazy-loaded)
try:
    from mcp_bridge import handle_mcp_call, handle_mcp_list_tools
    TOOL_HANDLERS["mcp_call"] = handle_mcp_call
    TOOL_HANDLERS["mcp_list_tools"] = handle_mcp_list_tools
except ImportError:
    pass

# Hardware/GPIO tool handlers
try:
    from hardware import (handle_gpio_read, handle_gpio_write, handle_gpio_list,
                          handle_i2c_read, handle_spi_transfer)
    TOOL_HANDLERS["gpio_read"] = handle_gpio_read
    TOOL_HANDLERS["gpio_write"] = handle_gpio_write
    TOOL_HANDLERS["gpio_list"] = handle_gpio_list
    TOOL_HANDLERS["i2c_read"] = handle_i2c_read
    TOOL_HANDLERS["spi_transfer"] = handle_spi_transfer
except ImportError:
    pass


def exec_tool_mode(json_str):
    """Parse JSON command, dispatch to handler, print JSON response."""
    try:
        data = json.loads(json_str)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"Invalid JSON: {e}"}))
        sys.exit(1)

    action = data.get("action", "")
    handler = TOOL_HANDLERS.get(action)

    if handler is None:
        print(json.dumps({"error": f"Unknown action: {action}"}))
        sys.exit(1)

    try:
        result = handler(data)
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)


# ============================================================
# Original Bridge (BLE/Serial/Socket)
# ============================================================

class NanoAgentBridge:
    def __init__(self, api_key: str, model: str = "claude-sonnet-4-5-20250929"):
        if anthropic is None:
            raise ImportError("pip install anthropic")
        self.client = anthropic.Anthropic(api_key=api_key)
        self.model = model

    def handle_message(self, data: bytes) -> bytes:
        """Process an RPC message and return the response."""
        msg = json.loads(data)
        msg_type = msg.get("type", "")

        if msg_type == "api":
            return self._handle_api(msg)
        elif msg_type == "tool":
            return self._handle_tool(msg)
        else:
            return json.dumps({"error": f"Unknown type: {msg_type}"}).encode()

    def _handle_api(self, msg: dict) -> bytes:
        """Forward API call to Claude and return response."""
        body = json.loads(msg.get("body", "{}"))

        try:
            response = self.client.messages.create(
                model=body.get("model", self.model),
                max_tokens=body.get("max_tokens", 8192),
                system=body.get("system", ""),
                tools=body.get("tools", []),
                messages=body.get("messages", []),
            )
            return json.dumps({
                "type": "api_result",
                "body": response.model_dump_json(),
            }).encode()
        except Exception as e:
            return json.dumps({
                "type": "api_result",
                "error": str(e),
            }).encode()

    def _handle_tool(self, msg: dict) -> bytes:
        """Execute a tool locally and return result."""
        name = msg.get("name", "")
        input_data = msg.get("input", {})
        if isinstance(input_data, str):
            input_data = json.loads(input_data)

        try:
            if name == "bash":
                result = subprocess.run(
                    input_data["command"],
                    shell=True,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                output = result.stdout
                if result.stderr:
                    output += f"\n--- stderr ---\n{result.stderr}"
                return json.dumps({
                    "type": "tool_result",
                    "output": output or "(no output)",
                    "is_error": result.returncode != 0,
                }).encode()

            elif name == "read_file":
                with open(input_data["path"], "r") as f:
                    content = f.read()
                return json.dumps({
                    "type": "tool_result",
                    "output": content or "(empty file)",
                    "is_error": False,
                }).encode()

            elif name == "write_file":
                path = input_data["path"]
                os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
                with open(path, "w") as f:
                    f.write(input_data["content"])
                return json.dumps({
                    "type": "tool_result",
                    "output": f"Wrote {len(input_data['content'])} bytes to {path}",
                    "is_error": False,
                }).encode()

            elif name == "search":
                search_path = input_data.get("path", ".")
                pattern = input_data["pattern"]
                result = subprocess.run(
                    ["grep", "-rn", "--", pattern, search_path],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                output = result.stdout
                lines = output.split("\n")
                if len(lines) > 100:
                    output = "\n".join(lines[:100]) + f"\n... ({len(lines)} total lines)"
                return json.dumps({
                    "type": "tool_result",
                    "output": output or "No matches found",
                    "is_error": False,
                }).encode()

            else:
                return json.dumps({
                    "type": "tool_result",
                    "output": f"Unknown tool: {name}",
                    "is_error": True,
                }).encode()

        except Exception as e:
            return json.dumps({
                "type": "tool_result",
                "output": str(e),
                "is_error": True,
            }).encode()


async def socket_server(bridge: NanoAgentBridge, path: str):
    """Unix socket server for desktop BLE simulation."""
    if os.path.exists(path):
        os.unlink(path)

    async def handle_client(reader, writer):
        print(f"[bridge] Device connected")
        try:
            while True:
                len_data = await reader.readexactly(2)
                msg_len = struct.unpack(">H", len_data)[0]
                msg_data = await reader.readexactly(msg_len)

                print(f"[bridge] <- {msg_data[:100]}...")

                response = bridge.handle_message(msg_data)

                print(f"[bridge] -> {response[:100]}...")

                writer.write(struct.pack(">H", len(response)))
                writer.write(response)
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionResetError):
            print(f"[bridge] Device disconnected")
        finally:
            writer.close()

    server = await asyncio.start_unix_server(handle_client, path=path)
    print(f"[bridge] Listening on {path}")
    print(f"[bridge] Waiting for NanoAgent device...")
    async with server:
        await server.serve_forever()


async def serial_bridge(bridge: NanoAgentBridge, port: str, baud: int = 115200):
    """Serial port bridge for UART-connected devices."""
    try:
        import serial as pyserial
    except ImportError:
        print("pip install pyserial")
        sys.exit(1)

    ser = pyserial.Serial(port, baud, timeout=None)
    print(f"[bridge] Connected to {port} @ {baud}")

    while True:
        len_data = ser.read(2)
        if len(len_data) < 2:
            continue
        msg_len = struct.unpack(">H", len_data)[0]
        msg_data = ser.read(msg_len)

        print(f"[bridge] <- {msg_data[:80]}...")

        response = bridge.handle_message(msg_data)

        print(f"[bridge] -> {response[:80]}...")

        ser.write(struct.pack(">H", len(response)))
        ser.write(response)


async def ble_bridge(bridge: NanoAgentBridge):
    """BLE bridge using bleak (scans for NanoAgent device)."""
    try:
        from bleak import BleakClient, BleakScanner
    except ImportError:
        print("pip install bleak")
        sys.exit(1)

    SERVICE_UUID = "0000pc01-0000-1000-8000-00805f9b34fb"
    TX_UUID = "0000pc02-0000-1000-8000-00805f9b34fb"
    RX_UUID = "0000pc03-0000-1000-8000-00805f9b34fb"

    print("[bridge] Scanning for NanoAgent BLE device...")
    device = await BleakScanner.find_device_by_filter(
        lambda d, ad: SERVICE_UUID.lower() in [s.lower() for s in (ad.service_uuids or [])],
        timeout=30.0,
    )

    if not device:
        print("[bridge] No NanoAgent device found")
        return

    print(f"[bridge] Found: {device.name} ({device.address})")

    async with BleakClient(device) as client:
        print(f"[bridge] Connected")

        response_data = bytearray()

        def notification_handler(sender, data):
            nonlocal response_data
            response = bridge.handle_message(bytes(data))
            response_data = bytearray(response)

        await client.start_notify(TX_UUID, notification_handler)

        while client.is_connected:
            if response_data:
                data = bytes(response_data)
                response_data = bytearray()

                mtu = 244
                for i in range(0, len(data), mtu):
                    chunk = data[i : i + mtu]
                    await client.write_gatt_char(RX_UUID, chunk)

            await asyncio.sleep(0.01)


# ============================================================
# Telegram Transport (stdlib-only, no external deps)
# ============================================================

logger = logging.getLogger("nanoagent.telegram")


class TelegramTransport:
    """Telegram Bot API transport using HTTP long-polling.

    Polls for incoming text messages, invokes the NanoAgent agent (via
    subprocess or the bridge's own API handler), and sends the response
    back to the originating Telegram chat.

    Security: only users whose numeric Telegram user-id appears in
    *allowed_users* may interact.  Messages from other users are silently
    ignored (a warning is logged).
    """

    BASE_URL = "https://api.telegram.org/bot{token}"

    def __init__(
        self,
        token: str,
        bridge: "NanoAgentBridge",
        allowed_users: list[int] | None = None,
    ):
        self.token = token
        self.bridge = bridge
        self.allowed_users = set(allowed_users) if allowed_users else None
        self._api_base = self.BASE_URL.format(token=token)
        self._offset: int | None = None

    # -- Telegram Bot API helpers --------------------------------

    def _api_call(self, method: str, payload: dict | None = None, timeout: int = 35):
        """Call a Telegram Bot API method and return the parsed JSON."""
        url = f"{self._api_base}/{method}"
        body = json.dumps(payload).encode("utf-8") if payload else None
        req = urllib.request.Request(
            url,
            data=body,
            method="POST" if body else "GET",
            headers={"Content-Type": "application/json"} if body else {},
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if not data.get("ok"):
                    logger.error("Telegram API error: %s", data)
                return data
        except urllib.error.HTTPError as exc:
            error_body = exc.read().decode("utf-8", errors="replace")
            logger.error("Telegram HTTP %d: %s", exc.code, error_body)
            return {"ok": False, "error": error_body}
        except (urllib.error.URLError, OSError) as exc:
            logger.error("Telegram network error: %s", exc)
            return {"ok": False, "error": str(exc)}

    def _get_updates(self, timeout: int = 30) -> list[dict]:
        """Long-poll for new updates from Telegram."""
        params: dict = {"timeout": timeout}
        if self._offset is not None:
            params["offset"] = self._offset
        data = self._api_call("getUpdates", params, timeout=timeout + 5)
        if not data.get("ok"):
            return []
        return data.get("result", [])

    def _send_message(self, chat_id: int, text: str) -> dict:
        """Send a text message to *chat_id*."""
        # Telegram caps message length at 4096 chars.
        if len(text) > 4096:
            text = text[:4093] + "..."
        return self._api_call("sendMessage", {"chat_id": chat_id, "text": text})

    # -- Message handling ----------------------------------------

    def _handle_text(self, chat_id: int, text: str) -> str:
        """Forward *text* through the bridge and return the agent reply."""
        msg_payload = json.dumps({
            "type": "api",
            "body": json.dumps({
                "messages": [{"role": "user", "content": text}],
                "max_tokens": 4096,
            }),
        }).encode("utf-8")
        try:
            raw_response = self.bridge.handle_message(msg_payload)
            resp = json.loads(raw_response)
            if resp.get("error"):
                return f"[error] {resp['error']}"
            body = json.loads(resp.get("body", "{}"))
            # Extract text blocks from the Claude response
            parts = []
            for block in body.get("content", []):
                if block.get("type") == "text":
                    parts.append(block["text"])
            return "\n".join(parts) if parts else "(no text in response)"
        except Exception as exc:
            logger.exception("Error processing message")
            return f"[bridge error] {exc}"

    # -- Main loop -----------------------------------------------

    def run(self):
        """Run the long-polling loop (blocking)."""
        # Validate the token on startup
        me = self._api_call("getMe")
        if not me.get("ok"):
            logger.error("Invalid Telegram bot token.")
            sys.exit(1)
        bot_info = me.get("result", {})
        logger.info(
            "Telegram bot started: @%s (id=%s)",
            bot_info.get("username", "?"),
            bot_info.get("id", "?"),
        )
        if self.allowed_users:
            logger.info("Allowed users: %s", self.allowed_users)
        else:
            logger.warning(
                "No --allowed-users set. ALL Telegram users can interact. "
                "This is a security risk."
            )

        while True:
            try:
                updates = self._get_updates(timeout=30)
            except KeyboardInterrupt:
                logger.info("Shutting down Telegram transport.")
                break
            except Exception:
                logger.exception("Error fetching updates; retrying in 5s")
                time.sleep(5)
                continue

            for update in updates:
                update_id = update.get("update_id", 0)
                # Advance offset so this update is not fetched again
                self._offset = update_id + 1

                message = update.get("message")
                if not message:
                    continue

                # Only handle plain text messages
                text = message.get("text")
                if not text:
                    continue

                user = message.get("from", {})
                user_id = user.get("id")
                chat_id = message["chat"]["id"]

                # Enforce allowlist
                if self.allowed_users and user_id not in self.allowed_users:
                    logger.warning(
                        "Blocked message from user_id=%s (not in allowlist)",
                        user_id,
                    )
                    continue

                logger.info(
                    "Message from user_id=%s chat_id=%s: %s",
                    user_id,
                    chat_id,
                    text[:80],
                )

                reply = self._handle_text(chat_id, text)
                self._send_message(chat_id, reply)


def load_channels_config() -> dict:
    """Load channel configuration from ~/.nanoagent/channels.json."""
    config_path = os.path.expanduser("~/.nanoagent/channels.json")
    if os.path.exists(config_path):
        try:
            with open(config_path, "r") as f:
                return json.load(f)
        except Exception as e:
            logging.warning("Failed to load channels.json: %s", e)
    return {}


async def serve_channels(bridge: "NanoAgentBridge", channel_names: list[str], config: dict):
    """Start the multi-channel message router."""
    from channels import MessageRouter, IncomingMessage

    # Start MCP bridge if configured
    mcp_bridge = None
    try:
        from mcp_bridge import MCPBridge
        mcp_bridge = MCPBridge()
        mcp_bridge.load_config()
        await mcp_bridge.start()
        if mcp_bridge.list_tools():
            logging.info("MCP tools available: %s", mcp_bridge.list_tools())
    except ImportError:
        logging.debug("MCP package not available")
    except Exception:
        logging.exception("Failed to start MCP bridge")

    async def handle_message(msg: IncomingMessage) -> str:
        """Route incoming message through the bridge."""
        msg_payload = json.dumps({
            "type": "api",
            "body": json.dumps({
                "messages": [{"role": "user", "content": msg.text}],
                "max_tokens": 4096,
            }),
        }).encode("utf-8")
        try:
            raw_response = bridge.handle_message(msg_payload)
            resp = json.loads(raw_response)
            if resp.get("error"):
                return f"[error] {resp['error']}"
            body = json.loads(resp.get("body", "{}"))
            parts = []
            for block in body.get("content", []):
                if block.get("type") == "text":
                    parts.append(block["text"])
            return "\n".join(parts) if parts else "(no text in response)"
        except Exception as exc:
            return f"[bridge error] {exc}"

    router = MessageRouter(handle_message)

    # Lazy imports for optional channels
    def _make_discord():
        from channels.discord import DiscordChannel
        return DiscordChannel(
            token=config.get("discord", {}).get("token", os.environ.get("DISCORD_BOT_TOKEN", "")),
            allowed_guilds=config.get("discord", {}).get("allowed_guilds"),
            allowed_channels=config.get("discord", {}).get("allowed_channels"),
        )

    def _make_slack():
        from channels.slack import SlackChannel
        return SlackChannel(
            bot_token=config.get("slack", {}).get("bot_token", os.environ.get("SLACK_BOT_TOKEN", "")),
            app_token=config.get("slack", {}).get("app_token", os.environ.get("SLACK_APP_TOKEN", "")),
            allowed_channels=config.get("slack", {}).get("allowed_channels"),
        )

    def _make_whatsapp():
        from channels.whatsapp import WhatsAppChannel
        return WhatsAppChannel(
            phone_number_id=config.get("whatsapp", {}).get("phone_number_id", os.environ.get("WHATSAPP_PHONE_NUMBER_ID", "")),
            access_token=config.get("whatsapp", {}).get("access_token", os.environ.get("WHATSAPP_ACCESS_TOKEN", "")),
            verify_token=config.get("whatsapp", {}).get("verify_token", os.environ.get("WHATSAPP_VERIFY_TOKEN", "nanoagent")),
            webhook_port=config.get("whatsapp", {}).get("webhook_port", 8081),
        )

    def _make_telegram():
        from channels.telegram import TelegramChannel
        return TelegramChannel(
            token=config.get("telegram", {}).get("token", os.environ.get("TELEGRAM_BOT_TOKEN", "")),
            allowed_users=config.get("telegram", {}).get("allowed_users"),
            poll_timeout=config.get("telegram", {}).get("poll_timeout", 30),
        )

    def _make_mqtt():
        from channels.mqtt import MqttChannel
        return MqttChannel(
            broker=config.get("mqtt", {}).get("broker", "localhost"),
            port=config.get("mqtt", {}).get("port", 1883),
            subscribe_topic=config.get("mqtt", {}).get("subscribe_topic", "nanoagent/in"),
            publish_topic=config.get("mqtt", {}).get("publish_topic", "nanoagent/out"),
        )

    def _make_webhook():
        from channels.webhook import WebhookChannel
        return WebhookChannel(
            host=config.get("webhook", {}).get("host", "0.0.0.0"),
            port=config.get("webhook", {}).get("port", 8080),
            auth_token=config.get("webhook", {}).get("auth_token"),
        )

    def _make_websocket():
        from channels.websocket import WebSocketChannel
        return WebSocketChannel(
            host=config.get("websocket", {}).get("host", "0.0.0.0"),
            port=config.get("websocket", {}).get("port", 8765),
            auth_token=config.get("websocket", {}).get("auth_token"),
            agent_binary=config.get("websocket", {}).get("agent_binary", "nanoagent"),
        )

    channel_registry = {
        "telegram": _make_telegram,
        "mqtt": _make_mqtt,
        "webhook": _make_webhook,
        "websocket": _make_websocket,
        "discord": _make_discord,
        "slack": _make_slack,
        "whatsapp": _make_whatsapp,
    }

    for name in channel_names:
        factory = channel_registry.get(name)
        if factory is None:
            logging.error("Unknown channel: %s (available: %s)", name, list(channel_registry.keys()))
            continue
        try:
            channel = factory()
            router.register(channel)
        except Exception:
            logging.exception("Failed to create channel: %s", name)

    try:
        await router.start_all()
    except KeyboardInterrupt:
        logging.info("Shutting down channels...")
    finally:
        await router.stop_all()
        if mcp_bridge:
            await mcp_bridge.stop()


def main():
    parser = argparse.ArgumentParser(description="NanoAgent Bridge")
    parser.add_argument("--socket", help="Unix socket path (simulation mode)")
    parser.add_argument("--serial", help="Serial port path")
    parser.add_argument("--baud", type=int, default=115200, help="Serial baud rate")
    parser.add_argument("--ble", action="store_true", help="BLE mode")
    parser.add_argument("--transport", choices=["telegram"], help="Transport mode")
    parser.add_argument("--token", help="Bot token (required for --transport telegram)")
    parser.add_argument(
        "--allowed-users",
        dest="allowed_users",
        help="Comma-separated Telegram user IDs allowed to interact",
    )
    parser.add_argument("--model", default="claude-sonnet-4-5-20250929")
    parser.add_argument("--exec-tool", dest="exec_tool", help="Execute a tool command (JSON string)")
    parser.add_argument("--serve", action="store_true", help="Start multi-channel server mode")
    parser.add_argument(
        "--channels",
        help="Comma-separated list of channels to enable (e.g. telegram,webhook,websocket)",
    )
    args = parser.parse_args()

    # --exec-tool mode: no API key needed, just dispatch and exit
    if args.exec_tool:
        exec_tool_mode(args.exec_tool)
        return

    # --serve mode: multi-channel server
    if args.serve:
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        )
        channel_names = [c.strip() for c in (args.channels or "webhook").split(",")]
        config = load_channels_config()

        api_key = os.environ.get("ANTHROPIC_API_KEY", "")
        if not api_key:
            print("Set ANTHROPIC_API_KEY environment variable")
            sys.exit(1)

        bridge = NanoAgentBridge(api_key=api_key, model=args.model)

        # Load plugins if available
        try:
            from plugins import discover_plugins
            plugins = discover_plugins()
            if plugins:
                TOOL_HANDLERS.update(plugins)
                logging.info("Loaded %d plugin(s): %s", len(plugins), list(plugins.keys()))
        except ImportError:
            pass

        asyncio.run(serve_channels(bridge, channel_names, config))
        return

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        print("Set ANTHROPIC_API_KEY environment variable")
        sys.exit(1)

    bridge = NanoAgentBridge(api_key=api_key, model=args.model)

    if args.transport == "telegram":
        if not args.token:
            print("--token is required for --transport telegram")
            sys.exit(1)
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        )
        allowed: list[int] | None = None
        if args.allowed_users:
            allowed = [int(uid.strip()) for uid in args.allowed_users.split(",")]
        tg = TelegramTransport(
            token=args.token,
            bridge=bridge,
            allowed_users=allowed,
        )
        tg.run()
    elif args.socket:
        asyncio.run(socket_server(bridge, args.socket))
    elif args.serial:
        asyncio.run(serial_bridge(bridge, args.serial, args.baud))
    elif args.ble:
        asyncio.run(ble_bridge(bridge))
    else:
        asyncio.run(socket_server(bridge, "/tmp/nanoagent.sock"))


if __name__ == "__main__":
    main()
