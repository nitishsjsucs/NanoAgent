"""
MQTT channel — subscribe to a topic, publish responses.

Requires paho-mqtt (lazy import, graceful error if missing).
"""

import asyncio
import json
import logging

from . import Channel, IncomingMessage, MessageHandler

logger = logging.getLogger("NanoAgent.mqtt")


class MqttChannel(Channel):
    """MQTT pub/sub channel for IoT message routing."""

    name = "mqtt"

    def __init__(
        self,
        broker: str = "localhost",
        port: int = 1883,
        subscribe_topic: str = "NanoAgent/in",
        publish_topic: str = "NanoAgent/out",
        allowed_clients: list[str] | None = None,
    ):
        self.broker = broker
        self.port = port
        self.subscribe_topic = subscribe_topic
        self.publish_topic = publish_topic
        self.allowed_clients = set(allowed_clients) if allowed_clients else None
        self._client = None
        self._running = False

    async def start(self, on_message: MessageHandler) -> None:
        try:
            import paho.mqtt.client as mqtt
        except ImportError:
            logger.error("paho-mqtt not installed. Run: pip install paho-mqtt")
            return

        loop = asyncio.get_event_loop()

        def _on_mqtt_message(client, userdata, msg):
            try:
                payload = msg.payload.decode("utf-8", errors="replace")
                # Try to parse as JSON for structured messages
                try:
                    data = json.loads(payload)
                    text = data.get("text", payload)
                    sender_id = data.get("sender_id", "mqtt")
                except json.JSONDecodeError:
                    text = payload
                    sender_id = "mqtt"

                incoming = IncomingMessage(
                    channel="mqtt",
                    channel_id=msg.topic,
                    sender_id=sender_id,
                    text=text,
                )
                asyncio.run_coroutine_threadsafe(on_message(incoming), loop)
            except Exception:
                logger.exception("Error processing MQTT message")

        self._client = mqtt.Client()
        self._client.on_message = _on_mqtt_message
        self._client.connect(self.broker, self.port, 60)
        self._client.subscribe(self.subscribe_topic)
        self._client.loop_start()
        self._running = True
        logger.info(
            "MQTT channel started: %s:%d topic=%s",
            self.broker, self.port, self.subscribe_topic,
        )

        # Keep alive until stopped
        while self._running:
            await asyncio.sleep(1)

    async def send(self, channel_id: str, text: str) -> None:
        if self._client is None:
            logger.warning("MQTT client not connected, cannot send")
            return
        payload = json.dumps({"text": text, "topic": channel_id})
        self._client.publish(self.publish_topic, payload)

    async def stop(self) -> None:
        self._running = False
        if self._client:
            self._client.loop_stop()
            self._client.disconnect()
            self._client = None
