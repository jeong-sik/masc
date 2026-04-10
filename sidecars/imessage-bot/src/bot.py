"""iMessage Gate Bot -- main event loop.

Polls chat.db for new inbound iMessages, dispatches to MASC gate-backed
keepers, and sends replies back via AppleScript.

Usage:
    python -m src.bot
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
from datetime import datetime, timezone
from pathlib import Path
from .config import get_config
from .gate_client import GateClient, GateResponse
from .imessage_bridge import InboundMessage, read_new_messages, send_message
from .status_store import ConnectorRuntimeStatus, StatusStore

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("imessage-gate-bot")

# Default keeper for MVP -- all inbound messages go to this keeper.
# Binding management can be added later following the Discord pattern.
DEFAULT_KEEPER = os.environ.get("IMESSAGE_DEFAULT_KEEPER", "sangsu")


class IMessageBot:
    """iMessage bot that routes messages to gate-backed keepers."""

    def __init__(self) -> None:
        self.cfg = get_config()
        self.gate = GateClient()
        self.status_store = StatusStore(Path(self.cfg.status_path))
        self._running = False
        self._messages_processed = 0
        self._messages_failed = 0
        self._last_message_at = ""
        self._bindings: dict[str, str] = {}  # chat_id -> keeper_name
        self._last_cursor_rowid: int = 0

    def _load_bindings(self) -> None:
        """Load chat-to-keeper bindings from state file."""
        path = Path(self.cfg.binding_store_path)
        if not path.exists():
            return
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                self._bindings = {str(k): str(v) for k, v in data.items() if isinstance(v, str)}
                logger.info("Loaded %d binding(s)", len(self._bindings))
        except (json.JSONDecodeError, OSError) as e:
            logger.warning("Failed to load bindings: %s", e)

    def _resolve_keeper(self, msg: InboundMessage) -> str:
        """Resolve which keeper handles a message.

        Binding lookup order:
        1. chat_identifier exact match
        2. sender (handle) exact match
        3. DEFAULT_KEEPER fallback
        """
        keeper = self._bindings.get(msg.chat_identifier)
        if keeper:
            return keeper
        keeper = self._bindings.get(msg.sender)
        if keeper:
            return keeper
        return DEFAULT_KEEPER

    async def _handle_message(self, msg: InboundMessage) -> None:
        """Process one inbound message: gate dispatch + reply."""
        keeper = self._resolve_keeper(msg)
        logger.info(
            "Dispatching message from %s (chat=%s) to keeper %s",
            msg.sender,
            msg.chat_identifier,
            keeper,
        )

        response = await self.gate.send_message(
            keeper_name=keeper,
            content=msg.text,
            sender=msg.sender,
            chat_id=msg.room_id,
            message_rowid=msg.rowid,
        )

        if response.ok and response.reply:
            sent = send_message(msg.sender, response.reply)
            if sent:
                logger.info(
                    "Replied to %s (%d chars, keeper=%s, model=%s, %dms)",
                    msg.sender,
                    len(response.reply),
                    response.keeper_name,
                    response.model_used,
                    response.duration_ms,
                )
            else:
                logger.error("Failed to send reply to %s via AppleScript", msg.sender)
        elif response.error and response.error != "duplicate message":
            logger.warning("Gate error for %s: %s", msg.sender, response.error)

        if response.ok:
            self._messages_processed += 1
        else:
            self._messages_failed += 1
        self._last_message_at = datetime.now(tz=timezone.utc).isoformat()

    async def _poll_once(self) -> None:
        """Single poll cycle: read new messages and dispatch."""
        messages = read_new_messages()
        if messages:
            self._last_cursor_rowid = messages[-1].rowid
        for msg in messages:
            try:
                await self._handle_message(msg)
            except Exception as e:
                logger.error("Error handling message ROWID %d: %s", msg.rowid, e)
                self._messages_failed += 1

    async def _write_status(self) -> None:
        """Persist current status for dashboard consumption."""
        gate_healthy: bool | None = None
        gate_health_checked_at = ""
        try:
            gate_healthy = await self.gate.health_check()
            gate_health_checked_at = datetime.now(tz=timezone.utc).isoformat()
        except Exception:
            gate_healthy = False

        self.status_store.write(
            ConnectorRuntimeStatus(
                updated_at=datetime.now(tz=timezone.utc).isoformat(),
                connected=True,
                gate_base_url=self.cfg.gate_base_url,
                gate_healthy=gate_healthy,
                gate_health_checked_at=gate_health_checked_at,
                last_message_at=self._last_message_at,
                messages_processed=self._messages_processed,
                messages_failed=self._messages_failed,
                cursor_rowid=self._last_cursor_rowid,
                chat_db_path=self.cfg.chat_db_path,
                poll_interval_sec=self.cfg.poll_interval_sec,
                pid=os.getpid(),
            )
        )

    async def run(self) -> None:
        """Main event loop."""
        self._running = True
        self._load_bindings()

        logger.info(
            "iMessage bot starting (poll=%.1fs, gate=%s, default_keeper=%s)",
            self.cfg.poll_interval_sec,
            self.cfg.gate_base_url,
            DEFAULT_KEEPER,
        )

        # Initial health check
        healthy = await self.gate.health_check()
        if not healthy:
            logger.warning("Gate health check failed at %s", self.cfg.gate_base_url)
        else:
            logger.info("Gate healthy at %s", self.cfg.gate_base_url)

        status_counter = 0

        while self._running:
            try:
                await self._poll_once()
            except Exception as e:
                logger.error("Poll cycle error: %s", e)

            status_counter += 1

            # Write status every 5 cycles
            if status_counter % 5 == 0:
                try:
                    await self._write_status()
                except Exception as e:
                    logger.warning("Status write error: %s", e)

            # Reload bindings every 50 cycles (~100s at default 2s interval)
            if status_counter % 50 == 0:
                self._load_bindings()

            await asyncio.sleep(self.cfg.poll_interval_sec)

    def stop(self) -> None:
        """Signal the bot to stop."""
        self._running = False
        logger.info("Stop requested")


async def main() -> None:
    bot = IMessageBot()

    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, bot.stop)

    try:
        await bot.run()
    finally:
        await bot.gate.aclose()
        await bot._write_status()
        logger.info("iMessage bot stopped (processed=%d, failed=%d)", bot._messages_processed, bot._messages_failed)


if __name__ == "__main__":
    asyncio.run(main())
