"""
NanoAgent Plugin Discovery and Loading.

Scans ~/.nanoagent/plugins/*.py for user-defined tools.
Each plugin must export:
  - TOOL_NAME: str — unique tool name
  - TOOL_DESCRIPTION: str — description for the LLM
  - TOOL_SCHEMA: dict — JSON schema for tool input
  - handle(data: dict) -> dict — tool handler function

Example plugin (~/.nanoagent/plugins/my_tool.py):

    TOOL_NAME = "my_custom_tool"
    TOOL_DESCRIPTION = "Does something custom."
    TOOL_SCHEMA = {"type": "object", "properties": {"input": {"type": "string"}}}

    def handle(data: dict) -> dict:
        return {"result": f"processed: {data.get('input', '')}"}
"""

import importlib.util
import logging
import os

logger = logging.getLogger("nanoagent.plugins")

REQUIRED_EXPORTS = {"TOOL_NAME", "handle"}
PLUGINS_DIR = os.path.expanduser("~/.nanoagent/plugins")

# Built-in tool names that plugins cannot override
BUILTIN_TOOLS = {
    "mqtt_publish", "mqtt_subscribe", "http_request", "robot_cmd",
    "estop", "telemetry", "web_search", "session_save", "session_load",
    "session_list", "ota_check", "ota_download", "ota_apply",
}


def discover_plugins() -> dict:
    """Scan plugins directory and return {tool_name: handler_fn} dict."""
    if not os.path.isdir(PLUGINS_DIR):
        return {}

    plugins = {}

    for fname in sorted(os.listdir(PLUGINS_DIR)):
        if not fname.endswith(".py") or fname.startswith("_"):
            continue

        path = os.path.join(PLUGINS_DIR, fname)
        try:
            plugin = _load_plugin(path)
            if plugin is None:
                continue

            tool_name = plugin.TOOL_NAME
            if tool_name in BUILTIN_TOOLS:
                logger.warning(
                    "Plugin %s tries to override built-in tool '%s' — skipped",
                    fname, tool_name,
                )
                continue

            if tool_name in plugins:
                logger.warning(
                    "Duplicate plugin tool name '%s' in %s — skipped",
                    tool_name, fname,
                )
                continue

            plugins[tool_name] = plugin.handle
            logger.info("Loaded plugin: %s (%s)", tool_name, fname)

        except Exception:
            logger.exception("Failed to load plugin: %s", fname)

    return plugins


def get_plugin_manifests() -> list[dict]:
    """Return tool definitions for all loaded plugins (for LLM system prompt)."""
    if not os.path.isdir(PLUGINS_DIR):
        return []

    manifests = []
    for fname in sorted(os.listdir(PLUGINS_DIR)):
        if not fname.endswith(".py") or fname.startswith("_"):
            continue

        path = os.path.join(PLUGINS_DIR, fname)
        try:
            plugin = _load_plugin(path)
            if plugin is None:
                continue
            if plugin.TOOL_NAME in BUILTIN_TOOLS:
                continue

            manifests.append({
                "name": plugin.TOOL_NAME,
                "description": getattr(plugin, "TOOL_DESCRIPTION", ""),
                "input_schema": getattr(plugin, "TOOL_SCHEMA", {
                    "type": "object", "properties": {}
                }),
            })
        except Exception:
            logger.exception("Failed to load plugin manifest: %s", fname)

    return manifests


def _load_plugin(path: str):
    """Load a single plugin module from path. Returns module or None."""
    fname = os.path.basename(path)
    module_name = f"nanoagent_plugin_{fname[:-3]}"

    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        logger.warning("Cannot load plugin: %s", fname)
        return None

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    # Validate required exports
    missing = REQUIRED_EXPORTS - set(dir(module))
    if missing:
        logger.warning(
            "Plugin %s missing required exports: %s — skipped",
            fname, missing,
        )
        return None

    if not callable(getattr(module, "handle", None)):
        logger.warning("Plugin %s: 'handle' is not callable — skipped", fname)
        return None

    return module
