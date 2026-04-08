"""Tests for mcp_bridge.py — tool discovery, namespacing, routing, cleanup."""
import asyncio
import unittest
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from mcp_bridge import MCPBridge, shutdown_mcp_bridge
import mcp_bridge as mcp_mod


class TestMCPBridgeConfig(unittest.TestCase):
    def test_empty_bridge(self):
        bridge = MCPBridge()
        self.assertEqual(bridge.list_tools(), [])
        self.assertEqual(bridge.list_servers(), [])
        self.assertEqual(bridge.get_tool_definitions(), [])

    def test_has_tool_false(self):
        bridge = MCPBridge()
        self.assertFalse(bridge.has_tool("nonexistent"))

    def test_load_config_missing_file(self):
        bridge = MCPBridge()
        bridge.load_config("/nonexistent/path.json")
        self.assertEqual(bridge._config, {})

    def test_load_config_valid(self):
        import tempfile, json
        cfg = {"mcpServers": {"test": {"command": "echo", "args": ["hi"]}}}
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(cfg, f)
            f.flush()
            bridge = MCPBridge()
            bridge.load_config(f.name)
            os.unlink(f.name)
        self.assertIn("test", bridge._config.get("mcpServers", {}))


class TestMCPBridgeAsync(unittest.TestCase):
    def test_call_unknown_tool(self):
        bridge = MCPBridge()
        result = asyncio.run(
            bridge.call_tool("nonexistent__tool", {})
        )
        self.assertIn("error", result)
        self.assertIn("Unknown MCP tool", result["error"])

    def test_call_disconnected_server(self):
        bridge = MCPBridge()
        bridge._tools["srv__tool"] = ("srv", "tool", {"name": "srv__tool"})
        result = asyncio.run(
            bridge.call_tool("srv__tool", {})
        )
        self.assertIn("error", result)
        self.assertIn("not connected", result["error"])

    def test_namespacing(self):
        bridge = MCPBridge()
        bridge._tools["myserver__read_file"] = ("myserver", "read_file", {
            "name": "myserver__read_file",
            "description": "Read a file",
            "inputSchema": {},
        })
        self.assertTrue(bridge.has_tool("myserver__read_file"))
        self.assertFalse(bridge.has_tool("read_file"))
        defs = bridge.get_tool_definitions()
        self.assertEqual(len(defs), 1)
        self.assertEqual(defs[0]["name"], "myserver__read_file")


class TestMCPSingleton(unittest.TestCase):
    def test_shutdown_noop_when_not_started(self):
        mcp_mod._mcp_bridge = None
        mcp_mod._mcp_loop = None
        shutdown_mcp_bridge()  # should not raise
        self.assertIsNone(mcp_mod._mcp_bridge)


if __name__ == "__main__":
    unittest.main()
