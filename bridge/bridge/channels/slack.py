"""
NanoAgent Slack Channel.

Uses slack-bolt library with Socket Mode (no public URL needed).
Responds to app mentions and direct messages.

Requires: pip install slack-bolt
Config: slack.bot_token, slack.app_token, slack.allowed_channels
"""

import asyncio
import logging

from . import Channel, IncomingMessage, MessageHandler

logger = logging.getLogger("nanoagent.channels.slack")


class SlackChannel(Channel):
    """Slack bot channel using slack-bolt with Socket Mode."""

    name = "slack"

    def __init__(self, bot_token="", app_token="", allowed_channels=None):
        self._bot_token = bot_token
        self._app_token = app_token
        self._allowed_channels = set(allowed_channels) if allowed_channels else None
        self._app = None

    async def start(self, on_message: MessageHandler) -> None:
        try:
            from slack_bolt.async_app import AsyncApp
            from slack_bolt.adapter.socket_mode.async_handler import AsyncSocketModeHandler
        except ImportError:
            logger.error("slack-bolt not installed. Run: pip install slack-bolt")
            return

        if not self._bot_token or not self._app_token:
            logger.error("Slack bot_token and app_token required for Socket Mode")
            return

        app = AsyncApp(token=self._bot_token)
        self._app = app
        self._on_message = on_message

        @app.event("app_mention")
        async def handle_mention(event, say):
            await self._handle_event(event, say)

        @app.event("message")
        async def handle_dm(event, say):
            # Only handle DMs (no subtype = regular message, channel_type = im)
            if event.get("channel_type") == "im" and not event.get("subtype"):
                await self._handle_event(event, say)

        handler = AsyncSocketModeHandler(app, self._app_token)
        await handler.start_async()

    async def _handle_event(self, event, say):
        channel_id = event.get("channel", "")
        user_id = event.get("user", "")
        text = event.get("text", "")

        # Channel allowlist
        if self._allowed_channels and channel_id not in self._allowed_channels:
            return

        # Strip bot mention from text
        import re
        text = re.sub(r"<@[A-Z0-9]+>\s*", "", text).strip()
        if not text:
            return

        msg = IncomingMessage(
            channel="slack",
            channel_id=channel_id,
            sender_id=user_id,
            text=text,
        )

        await self._on_message(msg)

    async def send(self, channel_id: str, text: str) -> None:
        if not self._app:
            return
        try:
            await self._app.client.chat_postMessage(channel=channel_id, text=text)
        except Exception:
            logger.exception("Failed to send Slack message")

    async def stop(self) -> None:
        pass  # Socket mode handler cleans up on process exit
