"""
NanoAgent WhatsApp Channel.

Uses the official WhatsApp Business Cloud API (Meta).
Receives messages via webhook, sends via Graph API.

Requires: Meta Business verification + WhatsApp Business account.
Config: whatsapp.phone_number_id, whatsapp.access_token,
        whatsapp.verify_token, whatsapp.webhook_port
"""

import asyncio
import json
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler
from functools import partial

from . import Channel, IncomingMessage, MessageHandler

logger = logging.getLogger("nanoagent.channels.whatsapp")

# WhatsApp Cloud API base URL
GRAPH_API = "https://graph.facebook.com/v21.0"


class WhatsAppChannel(Channel):
    """WhatsApp Business Cloud API channel."""

    name = "whatsapp"

    def __init__(self, phone_number_id="", access_token="",
                 verify_token="nanoagent", webhook_port=8081):
        self._phone_number_id = phone_number_id
        self._access_token = access_token
        self._verify_token = verify_token
        self._webhook_port = webhook_port
        self._server = None
        self._on_message = None

    async def start(self, on_message: MessageHandler) -> None:
        if not self._phone_number_id or not self._access_token:
            logger.error("WhatsApp phone_number_id and access_token required")
            return

        self._on_message = on_message
        loop = asyncio.get_running_loop()

        handler_cls = partial(_WhatsAppHandler,
                              channel=self,
                              loop=loop)
        self._server = HTTPServer(("0.0.0.0", self._webhook_port), handler_cls)
        logger.info("WhatsApp webhook listening on port %d", self._webhook_port)

        # Run HTTP server in executor thread
        await loop.run_in_executor(None, self._server.serve_forever)

    def _get_conn(self):
        """Get or create a persistent HTTPS connection to Graph API."""
        import http.client
        if not hasattr(self, "_conn") or self._conn is None:
            self._conn = http.client.HTTPSConnection("graph.facebook.com")
        return self._conn

    def _send_sync(self, channel_id, text):
        """Synchronous send with connection reuse (runs in executor)."""
        path = f"/v21.0/{self._phone_number_id}/messages"
        payload = json.dumps({
            "messaging_product": "whatsapp",
            "to": channel_id,
            "type": "text",
            "text": {"body": text},
        })
        headers = {
            "Authorization": f"Bearer {self._access_token}",
            "Content-Type": "application/json",
        }
        try:
            conn = self._get_conn()
            conn.request("POST", path, payload, headers)
            resp = conn.getresponse()
            resp.read()  # drain response to allow reuse
            if resp.status >= 400:
                logger.error("WhatsApp send HTTP %d", resp.status)
        except Exception:
            self._conn = None  # reset on error
            logger.exception("WhatsApp send failed")

    async def send(self, channel_id: str, text: str) -> None:
        """Send a text message via WhatsApp Cloud API."""
        await asyncio.get_running_loop().run_in_executor(
            None, self._send_sync, channel_id, text
        )

    async def stop(self) -> None:
        if self._server:
            self._server.shutdown()

    async def _handle_incoming(self, sender_id, text):
        """Process an incoming WhatsApp message."""
        if not self._on_message:
            return
        msg = IncomingMessage(
            channel="whatsapp",
            channel_id=sender_id,
            sender_id=sender_id,
            text=text,
        )
        await self._on_message(msg)


class _WhatsAppHandler(BaseHTTPRequestHandler):
    """HTTP handler for WhatsApp webhook."""

    def __init__(self, *args, channel=None, loop=None, **kwargs):
        self._channel = channel
        self._loop = loop
        super().__init__(*args, **kwargs)

    def do_GET(self):
        """Webhook verification (Meta sends GET with challenge)."""
        from urllib.parse import urlparse, parse_qs
        params = parse_qs(urlparse(self.path).query)

        mode = params.get("hub.mode", [None])[0]
        token = params.get("hub.verify_token", [None])[0]
        challenge = params.get("hub.challenge", [None])[0]

        if mode == "subscribe" and token == self._channel._verify_token:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write((challenge or "").encode())
        else:
            self.send_response(403)
            self.end_headers()

    def do_POST(self):
        """Receive incoming WhatsApp messages."""
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        self.send_response(200)
        self.end_headers()

        try:
            data = json.loads(body)
            # Extract messages from webhook payload
            for entry in data.get("entry", []):
                for change in entry.get("changes", []):
                    value = change.get("value", {})
                    for message in value.get("messages", []):
                        if message.get("type") == "text":
                            sender = message.get("from", "")
                            text = message.get("text", {}).get("body", "")
                            if sender and text:
                                asyncio.run_coroutine_threadsafe(
                                    self._channel._handle_incoming(sender, text),
                                    self._loop,
                                )
        except Exception:
            logger.exception("Failed to parse WhatsApp webhook")

    def log_message(self, format, *args):
        """Suppress default HTTP server logging."""
        logger.debug(format, *args)
