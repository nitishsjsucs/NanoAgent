"""
Telegram channel — long-polling bot transport.

Refactored from the original TelegramTransport class in bridge.py.
Uses stdlib only (urllib), no external dependencies.
"""

import asyncio
import json
import logging
import urllib.error
import urllib.request

from . import Channel, IncomingMessage, MessageHandler

logger = logging.getLogger("NanoAgent.telegram")


class TelegramChannel(Channel):
    """Telegram Bot API channel using HTTP long-polling."""

    name = "telegram"

    BASE_URL = "https://api.telegram.org/bot{token}"

    def __init__(
        self,
        token: str,
        allowed_users: list[int] | None = None,
        poll_timeout: int = 30,
    ):
        self.token = token
        self.allowed_users = set(allowed_users) if allowed_users else None
        self.poll_timeout = poll_timeout
        self._api_base = self.BASE_URL.format(token=token)
        self._offset: int | None = None
        self._running = False

    # -- Telegram Bot API helpers --------------------------------

    def _api_call(self, method: str, payload: dict | None = None, timeout: int = 35):
        url = f"{self._api_base}/{method}"
        body = json.dumps(payload).encode("utf-8") if payload else None
        req = urllib.request.Request(
            url,
            data=body,
            method="POST" if body else "GET",
            headers={"Content-Type": "application/json"} if body else {},
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if not data.get("ok"):
                    logger.error("Telegram API error: %s", data)
                return data
        except urllib.error.HTTPError as exc:
            error_body = exc.read().decode("utf-8", errors="replace")
            logger.error("Telegram HTTP %d: %s", exc.code, error_body)
            return {"ok": False, "error": error_body}
        except (urllib.error.URLError, OSError) as exc:
            logger.error("Telegram network error: %s", exc)
            return {"ok": False, "error": str(exc)}

    def _get_updates(self) -> list[dict]:
        params: dict = {"timeout": self.poll_timeout}
        if self._offset is not None:
            params["offset"] = self._offset
        data = self._api_call("getUpdates", params, timeout=self.poll_timeout + 5)
        if not data.get("ok"):
            return []
        return data.get("result", [])

    # -- Channel interface ----------------------------------------

    async def start(self, on_message: MessageHandler) -> None:
        me = self._api_call("getMe")
        if not me.get("ok"):
            logger.error("Invalid Telegram bot token.")
            return
        bot_info = me.get("result", {})
        logger.info(
            "Telegram bot started: @%s (id=%s)",
            bot_info.get("username", "?"),
            bot_info.get("id", "?"),
        )
        if self.allowed_users:
            logger.info("Allowed users: %s", self.allowed_users)
        else:
            logger.warning("No allowed_users set — ALL Telegram users can interact.")

        self._running = True
        while self._running:
            try:
                updates = await asyncio.get_event_loop().run_in_executor(
                    None, self._get_updates
                )
            except Exception:
                logger.exception("Error fetching Telegram updates; retrying in 5s")
                await asyncio.sleep(5)
                continue

            for update in updates:
                self._offset = update.get("update_id", 0) + 1
                message = update.get("message")
                if not message:
                    continue
                text = message.get("text")
                if not text:
                    continue

                user = message.get("from", {})
                user_id = user.get("id")
                chat_id = message["chat"]["id"]

                if self.allowed_users and user_id not in self.allowed_users:
                    logger.warning("Blocked message from user_id=%s", user_id)
                    continue

                msg = IncomingMessage(
                    channel="telegram",
                    channel_id=str(chat_id),
                    sender_id=str(user_id),
                    text=text,
                )
                await on_message(msg)

    async def send(self, channel_id: str, text: str) -> None:
        if len(text) > 4096:
            text = text[:4093] + "..."
        await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: self._api_call(
                "sendMessage", {"chat_id": int(channel_id), "text": text}
            ),
        )

    async def stop(self) -> None:
        self._running = False
