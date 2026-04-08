"""
Webhook channel — simple HTTP POST server.

Uses stdlib http.server, no external dependencies.
Accepts POST with JSON body: {"text": "...", "sender_id": "..."}
Returns JSON response: {"text": "..."}
"""

import asyncio
import json
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Optional

from . import Channel, IncomingMessage, MessageHandler

logger = logging.getLogger("NanoAgent.webhook")


class WebhookChannel(Channel):
    """HTTP webhook channel — accepts POST requests with messages."""

    name = "webhook"

    def __init__(
        self,
        host: str = "0.0.0.0",
        port: int = 8080,
        auth_token: Optional[str] = None,
    ):
        self.host = host
        self.port = port
        self.auth_token = auth_token
        self._server: Optional[HTTPServer] = None
        self._running = False

    async def start(self, on_message: MessageHandler) -> None:
        loop = asyncio.get_event_loop()
        channel = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                logger.debug(format, *args)

            def do_POST(self):
                # Auth check
                if channel.auth_token:
                    auth_header = self.headers.get("Authorization", "")
                    if auth_header != f"Bearer {channel.auth_token}":
                        self.send_response(401)
                        self.end_headers()
                        self.wfile.write(b'{"error":"unauthorized"}')
                        return

                content_length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(content_length)

                try:
                    data = json.loads(body)
                except json.JSONDecodeError:
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(b'{"error":"invalid JSON"}')
                    return

                text = data.get("text", "")
                if not text:
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(b'{"error":"missing text field"}')
                    return

                msg = IncomingMessage(
                    channel="webhook",
                    channel_id="webhook",
                    sender_id=data.get("sender_id", "webhook"),
                    text=text,
                )

                # Run the async handler from the sync context
                future = asyncio.run_coroutine_threadsafe(
                    on_message(msg), loop
                )
                try:
                    response_text = future.result(timeout=120)
                except Exception as exc:
                    logger.exception("Webhook handler error")
                    response_text = f"[error] {exc}"

                response_body = json.dumps({"text": response_text}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(response_body)

            def do_GET(self):
                """Health check endpoint."""
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"status":"ok","channel":"webhook"}')

        self._server = HTTPServer((self.host, self.port), Handler)
        self._running = True
        logger.info("Webhook channel started: http://%s:%d", self.host, self.port)

        # Run the blocking server in a thread
        await loop.run_in_executor(None, self._serve_loop)

    def _serve_loop(self):
        while self._running:
            self._server.handle_request()

    async def send(self, channel_id: str, text: str) -> None:
        # Webhook responses are sent inline in do_POST, so this is a no-op
        # for the synchronous request/response pattern.
        pass

    async def stop(self) -> None:
        self._running = False
        if self._server:
            self._server.shutdown()
            self._server = None
