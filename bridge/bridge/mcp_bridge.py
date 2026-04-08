"""
NanoAgent MCP Client Bridge.

Connects to Model Context Protocol (MCP) servers, discovers their tools,
and routes tool calls from the agent through the appropriate server.

Config file: ~/.nanoagent/mcp_servers.json (Claude Desktop compatible format)

Example config:
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"]
    },
    "remote": {
      "transport": "http",
      "url": "http://localhost:8000/mcp"
    }
  }
}
"""

import asyncio
import json
import logging
import os

logger = logging.getLogger("nanoagent.mcp")


class MCPBridge:
    """Manages connections to multiple MCP servers and routes tool calls."""

    def __init__(self):
        self._servers = {}      # name -> MCPServerConnection
        self._tools = {}        # namespaced_name -> (server_name, original_name, schema)
        self._exit_stack = None
        self._config = {}

    def load_config(self, path=None):
        """Load MCP server config from JSON file."""
        if path is None:
            path = os.path.expanduser("~/.nanoagent/mcp_servers.json")
        if not os.path.exists(path):
            logger.info("No MCP config at %s", path)
            return
        try:
            with open(path, "r") as f:
                self._config = json.load(f)
            logger.info("Loaded MCP config: %d server(s)", len(self._config.get("mcpServers", {})))
        except Exception as e:
            logger.error("Failed to load MCP config: %s", e)

    async def start(self):
        """Connect to all configured MCP servers and discover tools."""
        try:
            from mcp import ClientSession, StdioServerParameters
            from mcp.client.stdio import stdio_client
        except ImportError:
            logger.warning("mcp package not installed. Run: pip install 'mcp>=1.26.0'")
            return

        try:
            from contextlib import AsyncExitStack
            self._exit_stack = AsyncExitStack()
            await self._exit_stack.__aenter__()
        except Exception as e:
            logger.error("Failed to create exit stack: %s", e)
            return

        servers_config = self._config.get("mcpServers", {})
        for name, server_cfg in servers_config.items():
            try:
                await self._connect_server(name, server_cfg)
            except Exception:
                logger.exception("Failed to connect MCP server: %s", name)

        logger.info("MCP bridge started: %d server(s), %d tool(s)",
                     len(self._servers), len(self._tools))

    async def _connect_server(self, name, server_cfg):
        """Connect to a single MCP server (stdio or HTTP)."""
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client

        transport_type = server_cfg.get("transport", "stdio")

        if transport_type == "stdio":
            command = server_cfg.get("command", "")
            args = server_cfg.get("args", [])
            env = {**os.environ, **server_cfg.get("env", {})}

            server_params = StdioServerParameters(
                command=command,
                args=args,
                env=env,
            )

            transport = await self._exit_stack.enter_async_context(
                stdio_client(server_params)
            )
            read_stream, write_stream = transport
            session = await self._exit_stack.enter_async_context(
                ClientSession(read_stream, write_stream)
            )
            await session.initialize()

        elif transport_type == "http":
            try:
                from mcp.client.streamable_http import streamablehttp_client
            except ImportError:
                logger.warning("Streamable HTTP not available in this mcp version for %s", name)
                return

            url = server_cfg.get("url", "")
            transport = await self._exit_stack.enter_async_context(
                streamablehttp_client(url)
            )
            read_stream, write_stream, _ = transport
            session = await self._exit_stack.enter_async_context(
                ClientSession(read_stream, write_stream)
            )
            await session.initialize()

        else:
            logger.warning("Unknown MCP transport type '%s' for server '%s'", transport_type, name)
            return

        self._servers[name] = session

        # Discover tools from this server
        tools_result = await session.list_tools()
        for tool in tools_result.tools:
            namespaced = f"{name}__{tool.name}"
            self._tools[namespaced] = (name, tool.name, {
                "name": namespaced,
                "description": tool.description or f"MCP tool from {name}",
                "inputSchema": tool.inputSchema,
            })
            logger.info("Registered MCP tool: %s", namespaced)

    async def stop(self):
        """Disconnect from all MCP servers."""
        if self._exit_stack:
            await self._exit_stack.aclose()
            self._exit_stack = None
        self._servers.clear()
        self._tools.clear()

    def get_tool_definitions(self):
        """Return tool definitions suitable for LLM tool list."""
        return [schema for _, _, schema in self._tools.values()]

    def has_tool(self, name):
        """Check if a namespaced tool name is an MCP tool."""
        return name in self._tools

    async def call_tool(self, namespaced_name, arguments):
        """Call an MCP tool by its namespaced name. Returns result dict."""
        if namespaced_name not in self._tools:
            return {"error": f"Unknown MCP tool: {namespaced_name}"}

        server_name, original_name, _ = self._tools[namespaced_name]
        session = self._servers.get(server_name)
        if not session:
            return {"error": f"MCP server '{server_name}' not connected"}

        try:
            result = await session.call_tool(original_name, arguments)
            # Extract text content from result
            parts = []
            for content in result.content:
                if hasattr(content, "text"):
                    parts.append(content.text)
                elif hasattr(content, "data"):
                    parts.append(f"[binary: {len(content.data)} bytes]")
                else:
                    parts.append(str(content))
            return {"result": "\n".join(parts), "isError": result.isError}
        except Exception as e:
            return {"error": f"MCP tool call failed: {e}"}

    def list_tools(self):
        """Return list of all MCP tool names."""
        return list(self._tools.keys())

    def list_servers(self):
        """Return list of connected server names."""
        return list(self._servers.keys())


# Synchronous wrapper for --exec-tool mode
_mcp_bridge = None
_mcp_loop = None


def _get_or_create_bridge():
    """Lazily create and start the MCP bridge singleton."""
    global _mcp_bridge, _mcp_loop
    if _mcp_bridge is None:
        _mcp_bridge = MCPBridge()
        _mcp_bridge.load_config()
        _mcp_loop = asyncio.new_event_loop()
        _mcp_loop.run_until_complete(_mcp_bridge.start())
    return _mcp_bridge, _mcp_loop


def handle_mcp_call(data):
    """Handle an MCP tool call from --exec-tool mode."""
    tool_name = data.get("tool", "")
    arguments = data.get("arguments", {})
    bridge, loop = _get_or_create_bridge()
    return loop.run_until_complete(bridge.call_tool(tool_name, arguments))


def handle_mcp_list_tools(data):
    """List all available MCP tools."""
    bridge, loop = _get_or_create_bridge()
    definitions = bridge.get_tool_definitions()
    return {"tools": definitions, "count": len(definitions)}


def shutdown_mcp_bridge():
    """Clean up the sync singleton bridge and event loop."""
    global _mcp_bridge, _mcp_loop
    if _mcp_bridge and _mcp_loop:
        _mcp_loop.run_until_complete(_mcp_bridge.stop())
        _mcp_loop.close()
        _mcp_bridge = None
        _mcp_loop = None
