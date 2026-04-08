"""Tests for Discord, Slack, WhatsApp channel modules — construction, filtering, message flow."""
import asyncio
import json
import unittest
import os
import sys
from unittest.mock import AsyncMock, MagicMock, patch
from io import BytesIO

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from channels import IncomingMessage, MessageRouter


class TestMessageRouter(unittest.TestCase):
    def test_dispatch_calls_handler_and_send(self):
        handler = AsyncMock(return_value="response text")
        router = MessageRouter(handler)

        channel = MagicMock()
        channel.name = "test"
        channel.send = AsyncMock()
        router.register(channel)

        msg = IncomingMessage(channel="test", channel_id="ch1", sender_id="u1", text="hello")
        result = asyncio.run(router._dispatch(msg))

        handler.assert_called_once_with(msg)
        channel.send.assert_called_once_with("ch1", "response text")
        self.assertEqual(result, "response text")

    def test_dispatch_handles_handler_error(self):
        handler = AsyncMock(side_effect=RuntimeError("boom"))
        router = MessageRouter(handler)

        channel = MagicMock()
        channel.name = "test"
        channel.send = AsyncMock()
        router.register(channel)

        msg = IncomingMessage(channel="test", channel_id="ch1", sender_id="u1", text="hello")
        result = asyncio.run(router._dispatch(msg))

        self.assertIn("error", result)
        channel.send.assert_called_once()


class TestDiscordChannel(unittest.TestCase):
    def test_construction(self):
        from channels.discord import DiscordChannel
        ch = DiscordChannel(token="tok", allowed_guilds=["123"], allowed_channels=["456"])
        self.assertEqual(ch.name, "discord")
        self.assertEqual(ch._allowed_guilds, {"123"})
        self.assertEqual(ch._allowed_channels, {"456"})

    def test_send_splits_long_messages(self):
        from channels.discord import DiscordChannel
        ch = DiscordChannel()
        mock_channel = AsyncMock()
        mock_client = MagicMock()
        mock_client.get_channel.return_value = mock_channel
        ch._client = mock_client

        long_text = "x" * 4500
        asyncio.run(ch.send("123", long_text))
        self.assertEqual(mock_channel.send.call_count, 3)  # 2000 + 2000 + 500

    def test_send_short_message(self):
        from channels.discord import DiscordChannel
        ch = DiscordChannel()
        mock_channel = AsyncMock()
        mock_client = MagicMock()
        mock_client.get_channel.return_value = mock_channel
        ch._client = mock_client

        asyncio.run(ch.send("123", "short"))
        mock_channel.send.assert_called_once_with("short")

    def test_no_send_without_client(self):
        from channels.discord import DiscordChannel
        ch = DiscordChannel()
        asyncio.run(ch.send("123", "msg"))  # no crash


class TestSlackChannel(unittest.TestCase):
    def test_construction(self):
        from channels.slack import SlackChannel
        ch = SlackChannel(bot_token="xoxb-test", app_token="xapp-test", allowed_channels=["C1"])
        self.assertEqual(ch.name, "slack")
        self.assertEqual(ch._allowed_channels, {"C1"})

    def test_handle_event_strips_mention(self):
        from channels.slack import SlackChannel
        ch = SlackChannel()
        ch._on_message = AsyncMock()
        ch._allowed_channels = None

        event = {"channel": "C1", "user": "U1", "text": "<@BOT123> hello world"}
        say = AsyncMock()
        asyncio.run(ch._handle_event(event, say))

        msg = ch._on_message.call_args[0][0]
        self.assertEqual(msg.text, "hello world")
        self.assertEqual(msg.channel, "slack")

    def test_handle_event_respects_allowlist(self):
        from channels.slack import SlackChannel
        ch = SlackChannel(allowed_channels=["C_ALLOWED"])
        ch._on_message = AsyncMock()

        event = {"channel": "C_BLOCKED", "user": "U1", "text": "test"}
        say = AsyncMock()
        asyncio.run(ch._handle_event(event, say))
        ch._on_message.assert_not_called()


class TestWhatsAppChannel(unittest.TestCase):
    def test_construction(self):
        from channels.whatsapp import WhatsAppChannel
        ch = WhatsAppChannel(phone_number_id="123", access_token="tok")
        self.assertEqual(ch.name, "whatsapp")
        self.assertEqual(ch._phone_number_id, "123")

    def test_missing_config_logs_error(self):
        from channels.whatsapp import WhatsAppChannel
        ch = WhatsAppChannel()
        # start() should return without crashing when no config
        loop = asyncio.new_event_loop()
        loop.run_until_complete(ch.start(AsyncMock()))
        loop.close()

    def test_handle_incoming_calls_on_message(self):
        from channels.whatsapp import WhatsAppChannel
        ch = WhatsAppChannel(phone_number_id="123", access_token="tok")
        ch._on_message = AsyncMock()
        asyncio.run(
            ch._handle_incoming("+1234567890", "hello")
        )
        msg = ch._on_message.call_args[0][0]
        self.assertEqual(msg.text, "hello")
        self.assertEqual(msg.sender_id, "+1234567890")
        self.assertEqual(msg.channel, "whatsapp")

    def test_webhook_verification(self):
        from channels.whatsapp import _WhatsAppHandler, WhatsAppChannel
        ch = WhatsAppChannel(verify_token="mytoken")
        # Simulate GET request for webhook verification
        handler = MagicMock(spec=_WhatsAppHandler)
        handler._channel = ch
        handler.path = "/?hub.mode=subscribe&hub.verify_token=mytoken&hub.challenge=abc123"
        handler.send_response = MagicMock()
        handler.send_header = MagicMock()
        handler.end_headers = MagicMock()
        handler.wfile = BytesIO()

        _WhatsAppHandler.do_GET(handler)
        handler.send_response.assert_called_with(200)
        self.assertEqual(handler.wfile.getvalue(), b"abc123")

    def test_webhook_rejects_bad_token(self):
        from channels.whatsapp import _WhatsAppHandler, WhatsAppChannel
        ch = WhatsAppChannel(verify_token="mytoken")
        handler = MagicMock(spec=_WhatsAppHandler)
        handler._channel = ch
        handler.path = "/?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=abc"
        handler.send_response = MagicMock()
        handler.end_headers = MagicMock()

        _WhatsAppHandler.do_GET(handler)
        handler.send_response.assert_called_with(403)


if __name__ == "__main__":
    unittest.main()
