"""
WebSocket channel — streaming gateway to the NanoAgent agent.

Spawns the Zig agent as a subprocess per message and streams stdout
back as WebSocket frames. Uses the `websockets` library (lazy import).

Wire protocol:
  → {"type": "message", "text": "fix the bug"}
  ← {"type": "text", "text": "Let me look at that..."}
  ← {"type": "done"}
"""

import asyncio
import json
import logging
import subprocess
from typing import Optional

from . import Channel, IncomingMessage, MessageHandler

logger = logging.getLogger("nanoagent.websocket")


class WebSocketChannel(Channel):
    """WebSocket server channel with subprocess-per-message agent execution."""

    name = "websocket"

    def __init__(
        self,
        host: str = "0.0.0.0",
        port: int = 8765,
        auth_token: Optional[str] = None,
        agent_binary: str = "nanoagent",
    ):
        self.host = host
        self.port = port
        self.auth_token = auth_token
        self.agent_binary = agent_binary
        self._server = None
        self._on_message: Optional[MessageHandler] = None

    async def start(self, on_message: MessageHandler) -> None:
        try:
            import websockets
        except ImportError:
            logger.error("websockets not installed. Run: pip install websockets")
            return

        self._on_message = on_message

        async def handler(ws):
            # Auth: check first message or query param
            if self.auth_token:
                # Check query string for token
                path = getattr(ws, "path", "") or ""
                if f"token={self.auth_token}" not in path:
                    # Wait for auth message
                    try:
                        first = await asyncio.wait_for(ws.recv(), timeout=10)
                        data = json.loads(first)
                        if data.get("type") == "auth" and data.get("token") == self.auth_token:
                            await ws.send(json.dumps({"type": "auth_ok"}))
                        else:
                            await ws.send(json.dumps({"type": "error", "text": "unauthorized"}))
                            await ws.close()
                            return
                    except Exception:
                        await ws.close()
                        return

            logger.info("WebSocket client connected: %s", ws.remote_address)

            try:
                async for raw in ws:
                    try:
                        data = json.loads(raw)
                    except json.JSONDecodeError:
                        await ws.send(json.dumps({"type": "error", "text": "invalid JSON"}))
                        continue

                    msg_type = data.get("type", "message")
                    text = data.get("text", "")

                    if msg_type == "ping":
                        await ws.send(json.dumps({"type": "pong"}))
                        continue

                    if not text:
                        await ws.send(json.dumps({"type": "error", "text": "missing text"}))
                        continue

                    # Stream the agent response
                    await self._stream_agent(ws, text)

            except Exception as exc:
                if "close" not in str(exc).lower():
                    logger.exception("WebSocket handler error")
            finally:
                logger.info("WebSocket client disconnected")

        self._server = await websockets.serve(handler, self.host, self.port)
        logger.info("WebSocket channel started: ws://%s:%d", self.host, self.port)

        # Keep running
        await asyncio.Future()  # Run forever

    async def _stream_agent(self, ws, text: str) -> None:
        """Spawn agent subprocess and stream output back via WebSocket."""
        try:
            proc = await asyncio.create_subprocess_exec(
                self.agent_binary, "-p", text,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            # Stream stdout line by line
            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                decoded = line.decode("utf-8", errors="replace").rstrip("\n")
                if decoded:
                    await ws.send(json.dumps({"type": "text", "text": decoded}))

            await proc.wait()

            # Send any stderr as error
            stderr = await proc.stderr.read()
            if stderr and proc.returncode != 0:
                await ws.send(json.dumps({
                    "type": "error",
                    "text": stderr.decode("utf-8", errors="replace")[:2000],
                }))

            await ws.send(json.dumps({"type": "done"}))

        except FileNotFoundError:
            await ws.send(json.dumps({
                "type": "error",
                "text": f"Agent binary not found: {self.agent_binary}",
            }))
            await ws.send(json.dumps({"type": "done"}))
        except Exception as exc:
            logger.exception("Agent subprocess error")
            await ws.send(json.dumps({"type": "error", "text": str(exc)}))
            await ws.send(json.dumps({"type": "done"}))

    async def send(self, channel_id: str, text: str) -> None:
        # WebSocket responses are sent inline during streaming
        pass

    async def stop(self) -> None:
        if self._server:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
