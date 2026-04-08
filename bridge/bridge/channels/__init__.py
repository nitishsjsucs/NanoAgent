"""
NanoAgent Multi-Channel Framework.

Provides a unified interface for receiving messages from various transports
(Telegram, MQTT, Webhook, WebSocket) and routing them through the agent.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Callable, Awaitable, Optional
import asyncio
import logging

logger = logging.getLogger("nanoagent.channels")


@dataclass
class IncomingMessage:
    """Normalized message from any channel."""
    channel: str          # Channel type name (e.g. "telegram", "webhook")
    channel_id: str       # Where to send the reply (chat_id, topic, etc.)
    sender_id: str        # Who sent it
    text: str             # Message content


# Callback type: receives IncomingMessage, returns response text
MessageHandler = Callable[[IncomingMessage], Awaitable[str]]


class Channel(ABC):
    """Abstract base for all message channels."""

    name: str = "base"

    @abstractmethod
    async def start(self, on_message: MessageHandler) -> None:
        """Start receiving messages. Calls on_message for each incoming message."""
        ...

    @abstractmethod
    async def send(self, channel_id: str, text: str) -> None:
        """Send a response to the given channel_id."""
        ...

    async def stop(self) -> None:
        """Gracefully shut down the channel. Override if cleanup needed."""
        pass


class MessageRouter:
    """Routes incoming messages from all channels through a handler and back."""

    def __init__(self, handler: MessageHandler):
        self._handler = handler
        self._channels: dict[str, Channel] = {}
        self._tasks: list[asyncio.Task] = []

    def register(self, channel: Channel) -> None:
        """Register a channel for message routing."""
        self._channels[channel.name] = channel
        logger.info("Registered channel: %s", channel.name)

    async def start_all(self) -> None:
        """Start all registered channels concurrently."""
        if not self._channels:
            logger.warning("No channels registered")
            return

        for channel in self._channels.values():
            task = asyncio.create_task(
                channel.start(self._dispatch),
                name=f"channel-{channel.name}",
            )
            self._tasks.append(task)
            logger.info("Started channel: %s", channel.name)

        # Wait for all channel tasks (they run forever until cancelled)
        await asyncio.gather(*self._tasks, return_exceptions=True)

    async def stop_all(self) -> None:
        """Stop all channels."""
        for task in self._tasks:
            task.cancel()
        for channel in self._channels.values():
            await channel.stop()
        self._tasks.clear()

    async def _dispatch(self, msg: IncomingMessage) -> str:
        """Route a message through the handler and send the response back."""
        logger.info(
            "[%s] from=%s: %s", msg.channel, msg.sender_id, msg.text[:80]
        )
        try:
            response = await self._handler(msg)
        except Exception as exc:
            logger.exception("Handler error for %s message", msg.channel)
            response = f"[error] {exc}"

        # Send response back through the originating channel
        channel = self._channels.get(msg.channel)
        if channel:
            try:
                await channel.send(msg.channel_id, response)
            except Exception:
                logger.exception("Failed to send response on %s", msg.channel)

        return response
