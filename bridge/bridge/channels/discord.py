"""
NanoAgent Discord Channel.

Uses discord.py library for bot integration. Responds to messages in allowed
guilds/channels, supports slash commands.

Requires: pip install discord.py
Config: discord.token, discord.allowed_guilds, discord.allowed_channels
"""

import asyncio
import logging

from . import Channel, IncomingMessage, MessageHandler

logger = logging.getLogger("nanoagent.channels.discord")


class DiscordChannel(Channel):
    """Discord bot channel using discord.py."""

    name = "discord"

    def __init__(self, token="", allowed_guilds=None, allowed_channels=None):
        self._token = token
        self._allowed_guilds = set(allowed_guilds) if allowed_guilds else None
        self._allowed_channels = set(allowed_channels) if allowed_channels else None
        self._client = None

    async def start(self, on_message_cb: MessageHandler) -> None:
        try:
            import discord
        except ImportError:
            logger.error("discord.py not installed. Run: pip install discord.py")
            return

        intents = discord.Intents.default()
        intents.message_content = True
        client = discord.Client(intents=intents)
        self._client = client

        @client.event
        async def on_ready():
            logger.info("Discord bot connected as %s", client.user)

        @client.event
        async def on_message(message):
            if message.author == client.user:
                return

            if self._allowed_guilds and message.guild:
                if str(message.guild.id) not in self._allowed_guilds:
                    return

            if self._allowed_channels:
                if str(message.channel.id) not in self._allowed_channels:
                    return

            is_dm = message.guild is None
            is_mention = client.user in message.mentions
            if not is_dm and not is_mention:
                return

            text = message.content
            if is_mention:
                text = text.replace(f"<@{client.user.id}>", "").strip()

            if not text:
                return

            msg = IncomingMessage(
                channel="discord",
                channel_id=str(message.channel.id),
                sender_id=str(message.author.id),
                text=text,
            )

            await on_message_cb(msg)

        if not self._token:
            logger.error("Discord bot token not configured")
            return

        await client.start(self._token)

    async def send(self, channel_id: str, text: str) -> None:
        if not self._client:
            return
        channel = self._client.get_channel(int(channel_id))
        if channel:
            if len(text) <= 2000:
                await channel.send(text)
            else:
                for i in range(0, len(text), 2000):
                    await channel.send(text[i:i+2000])

    async def stop(self) -> None:
        if self._client:
            await self._client.close()
