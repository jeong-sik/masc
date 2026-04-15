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
import time
from datetime import datetime, timezone
from pathlib import Path
from .config import get_config
from .gate_client import GateClient
from .imessage_bridge import (
    InboundMessage,
    advance_cursor,
    redact_chat_guid,
    read_new_messages,
    resolve_self_chat_guid,
    send_message,
)
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
        self._self_chat_guid = ""
        self._self_chat_guid_retry_after = 0.0
        if self.cfg.reply_mode == "self-chat":
            self._refresh_self_chat_guid(force=True)

    def _load_bindings(self) -> None:
        """Load chat-to-keeper bindings from state file.

        Read priority: new default (binding_store_path) > legacy
        (legacy_binding_store_path) > empty. Next write always goes to the
        new default, so a one-shot migration is transparent after the
        .gate/runtime/ rollout (see #7468, #7471).
        """
        path = Path(self.cfg.binding_store_path)
        source = "default"
        if not path.exists():
            legacy_path = Path(self.cfg.legacy_binding_store_path)
            if legacy_path.exists():
                path = legacy_path
                source = "legacy"
            else:
                return
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                self._bindings = {str(k): str(v) for k, v in data.items() if isinstance(v, str)}
                if source == "legacy":
                    logger.info(
                        "Loaded %d binding(s) from legacy store %s; next write goes to %s",
                        len(self._bindings),
                        path,
                        self.cfg.binding_store_path,
                    )
                else:
                    logger.info("Loaded %d binding(s)", len(self._bindings))
        except (json.JSONDecodeError, OSError) as e:
            logger.warning("Failed to load bindings from %s: %s", path, e)

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

    def _resolve_reply_chat_guid(self, msg: InboundMessage) -> str:
        """Resolve the outbound chat guid according to configured reply mode."""
        if self.cfg.reply_mode == "source-chat":
            return msg.chat_guid
        if self._self_chat_guid:
            return self._self_chat_guid
        return self._refresh_self_chat_guid()

    def _refresh_self_chat_guid(self, *, force: bool = False) -> str:
        if self._self_chat_guid:
            return self._self_chat_guid
        now = time.monotonic()
        if not force and now < self._self_chat_guid_retry_after:
            return ""
        self._self_chat_guid = resolve_self_chat_guid(
            self.cfg.chat_db_path,
            self.cfg.self_chat_guid,
        )
        if self._self_chat_guid:
            self._self_chat_guid_retry_after = 0.0
        else:
            self._self_chat_guid_retry_after = now + self.cfg.poll_interval_sec
        return self._self_chat_guid

    def _log_chat_ref(self, msg: InboundMessage) -> str:
        return redact_chat_guid(msg.chat_guid or msg.chat_identifier)

    async def _handle_message(self, msg: InboundMessage) -> bool:
        """Process one inbound message: gate dispatch + reply.

        Returns True if the message was processed successfully (or was a
        benign duplicate), False on gate error (caller should stop batch).
        """
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
            target_chat_guid = self._resolve_reply_chat_guid(msg)
            if not target_chat_guid:
                logger.error(
                    "Refusing to send reply to %s: missing target chat guid (mode=%s, source_chat=%s)",
                    msg.sender,
                    self.cfg.reply_mode,
                    self._log_chat_ref(msg) or "unknown",
                )
                self._messages_failed += 1
                self._messages_processed += 1
                self._last_message_at = datetime.now(tz=timezone.utc).isoformat()
                return True
            sent = send_message(
                text=response.reply,
                chat_guid=target_chat_guid,
            )
            if sent:
                logger.info(
                    "Replied to %s (source_chat=%s, target_chat=%s, %d chars, keeper=%s, model=%s, %dms)",
                    msg.sender,
                    self._log_chat_ref(msg) or "unknown",
                    redact_chat_guid(target_chat_guid),
                    len(response.reply),
                    response.keeper_name,
                    response.model_used,
                    response.duration_ms,
                )
            else:
                logger.error(
                    "Failed to send reply to %s (source_chat=%s, target_chat=%s) via AppleScript",
                    msg.sender,
                    self._log_chat_ref(msg) or "unknown",
                    redact_chat_guid(target_chat_guid),
                )
                self._messages_failed += 1
        elif response.error and response.error != "duplicate message":
            logger.warning("Gate error for %s: %s", msg.sender, response.error)

        if response.ok:
            self._messages_processed += 1
        elif response.error == "duplicate message":
            pass  # expected during at-least-once redelivery
        else:
            self._messages_failed += 1
            return False

        self._last_message_at = datetime.now(tz=timezone.utc).isoformat()
        return True

    async def _poll_once(self) -> None:
        """Single poll cycle: read new messages and dispatch.

        At-least-once delivery: cursor advances only to the last successfully
        processed ROWID. On first failure, processing stops and the cursor
        stays behind so unprocessed messages are re-fetched on restart.
        """
        messages = await asyncio.to_thread(read_new_messages)
        if not messages:
            return
        last_ok_rowid: int | None = None
        for msg in messages:
            try:
                ok = await self._handle_message(msg)
            except Exception as e:
                logger.error("Error handling message ROWID %d: %s", msg.rowid, e)
                self._messages_failed += 1
                break  # stop to keep cursor behind failed message
            if not ok:
                break  # gate error -- stop to allow retry on next cycle
            last_ok_rowid = msg.rowid
        if last_ok_rowid is not None:
            advance_cursor(Path(self.cfg.cursor_path), last_ok_rowid)
        self._last_cursor_rowid = last_ok_rowid or self._last_cursor_rowid

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
                reply_mode=self.cfg.reply_mode,
                self_chat_guid=self._self_chat_guid,
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
            "iMessage bot starting (poll=%.1fs, gate=%s, default_keeper=%s, reply_mode=%s)",
            self.cfg.poll_interval_sec,
            self.cfg.gate_base_url,
            DEFAULT_KEEPER,
            self.cfg.reply_mode,
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
