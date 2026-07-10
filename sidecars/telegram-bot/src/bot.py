"""Telegram Gate Bot -- main bot logic.

Routes Telegram messages to MASC keepers via Channel Gate.
Supports:
- Direct messages to default keeper
- /bind <keeper> command to bind a chat to a keeper
- /keepers command to list available keepers
- /status command to show keeper status
"""

from __future__ import annotations

import asyncio
import logging
import os
import signal
import time
from contextlib import suppress
from datetime import datetime, timezone
from pathlib import Path

from gate_shared.bindings_store import load_bindings, save_bindings
from gate_shared.structured_content import response_text
from gate_shared.status_store import ConnectorRuntimeStatus, StatusStore

from telegram import Message, Update
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

from .config import get_config
from .formatters import (
    chunk_text,
    format_footer,
    format_footer_html,
    render_response_text,
)
from .gate_client import GateClient

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("telegram-gate-bot")


class TelegramGateBot:
    """Telegram bot that routes messages to gate-backed keepers."""

    def __init__(self) -> None:
        self.cfg = get_config()
        self.gate = GateClient()
        self._bindings: dict[str, str] = {}  # chat_id -> keeper_name
        self._admin_ids = self.cfg.admin_ids()
        self._messages_processed = 0
        self._messages_failed = 0
        self._last_message_at = ""
        self._running = False
        self.status_store = StatusStore(Path(self.cfg.status_path))

    def _load_bindings(self) -> None:
        self._bindings = load_bindings(
            self.cfg.binding_store_path,
            logger=logger,
        )

    def _save_bindings(self) -> None:
        save_bindings(self.cfg.binding_store_path, self._bindings, logger=logger)

    def _resolve_keeper(self, chat_id: int) -> str:
        """Resolve which keeper handles a chat."""
        return self._bindings.get(str(chat_id), self.cfg.default_keeper)

    def _is_admin(self, user_id: int | None) -> bool:
        """Check if a user is an admin."""
        if not self._admin_ids:
            return True  # no admin restriction configured
        return user_id is not None and user_id in self._admin_ids

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
                pid=os.getpid(),
                runtime_bindings_count=len(self._bindings),
                default_keeper=self.cfg.default_keeper,
            )
        )

    async def status_loop(self) -> None:
        while self._running:
            try:
                await self._write_status()
            except Exception as exc:
                logger.warning("Status write error: %s", exc)
            await asyncio.sleep(10.0)

    # ── Command Handlers ───────────────────────────────────

    async def cmd_start(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Handle /start command."""
        if update.effective_chat is None:
            return
        keeper = self._resolve_keeper(update.effective_chat.id)
        await update.effective_chat.send_message(
            f"MASC keeper connector active.\n"
            f"Current keeper: *{keeper}*\n\n"
            f"Commands:\n"
            f"/bind <keeper> - bind this chat to a keeper\n"
            f"/keepers - list available keepers\n"
            f"/status - show keeper status\n"
            f"/unbind - unbind this chat\n\n"
            f"Send any message to talk to the keeper.",
            parse_mode="Markdown",
        )

    async def cmd_keepers(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Handle /keepers command -- list available keepers."""
        if update.effective_chat is None:
            return
        names = await self.gate.list_keepers()
        if not names:
            await update.effective_chat.send_message(
                "No keepers available or gate unreachable."
            )
            return
        lines = [f"- `{name}`" for name in sorted(names)]
        await update.effective_chat.send_message(
            f"Available keepers ({len(names)}):\n" + "\n".join(lines),
            parse_mode="Markdown",
        )

    async def cmd_bind(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Handle /bind <keeper> -- bind this chat to a keeper."""
        if update.effective_chat is None or update.effective_user is None:
            return
        if not self._is_admin(update.effective_user.id):
            await update.effective_chat.send_message("Admin permission required.")
            return
        if not context.args:
            await update.effective_chat.send_message("Usage: /bind <keeper_name>")
            return

        keeper_name = context.args[0].strip()
        available = await self.gate.list_keepers()
        if available and keeper_name not in available:
            await update.effective_chat.send_message(
                f"Unknown keeper `{keeper_name}`. Use /keepers to see available keepers.",
                parse_mode="Markdown",
            )
            return

        chat_id = str(update.effective_chat.id)
        self._bindings[chat_id] = keeper_name
        self._save_bindings()
        await update.effective_chat.send_message(
            f"Chat bound to keeper *{keeper_name}*.",
            parse_mode="Markdown",
        )
        logger.info(
            "Chat %s bound to keeper %s by user %d",
            chat_id,
            keeper_name,
            update.effective_user.id,
        )

    async def cmd_unbind(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Handle /unbind -- unbind this chat from a keeper."""
        if update.effective_chat is None or update.effective_user is None:
            return
        if not self._is_admin(update.effective_user.id):
            await update.effective_chat.send_message("Admin permission required.")
            return

        chat_id = str(update.effective_chat.id)
        old = self._bindings.pop(chat_id, None)
        if old:
            self._save_bindings()
            await update.effective_chat.send_message(
                f"Unbound from keeper *{old}*. Using default: *{self.cfg.default_keeper}*.",
                parse_mode="Markdown",
            )
        else:
            await update.effective_chat.send_message(
                f"No binding for this chat. Using default: *{self.cfg.default_keeper}*.",
                parse_mode="Markdown",
            )

    async def cmd_status(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Handle /status -- show keeper status."""
        if update.effective_chat is None:
            return
        keeper = self._resolve_keeper(update.effective_chat.id)
        status = await self.gate.keeper_status(keeper)
        if status is None:
            await update.effective_chat.send_message(
                f"Could not fetch status for *{keeper}*.",
                parse_mode="Markdown",
            )
            return

        alive = status.get("alive", False)
        state = status.get("state", "unknown")
        model = status.get("last_model_used", "unknown")
        turns = status.get("total_turns", 0)
        emoji = "+" if alive else "-"
        await update.effective_chat.send_message(
            f"```\n"
            f"Keeper: {keeper}\n"
            f"State:  {emoji} {state}\n"
            f"Model:  {model}\n"
            f"Turns:  {turns}\n"
            f"```",
            parse_mode="Markdown",
        )

    # ── Message Handler ────────────────────────────────────

    async def _stream_response(
        self,
        update: Update,
        keeper: str,
        text: str,
        thinking_msg: Message,
    ) -> bool:
        """Try streaming response with live message editing.

        Returns True if streaming succeeded, False to fall back to batch.
        Telegram rate-limits edit_message to ~30/min per chat, so we
        throttle edits to every ~1 second or 80 characters of new content.
        """

        user = update.effective_user
        chat = update.effective_chat
        if user is None or chat is None:
            return False

        accumulated = ""
        last_edit_time = 0.0
        last_edit_len = 0
        edit_interval = 1.0  # seconds between edits
        char_threshold = 80  # min chars of new content before edit
        streamed_any = False

        try:
            async for delta in self.gate.stream_message(
                keeper_name=keeper,
                content=text,
                user_id=user.id,
                username=user.username or str(user.id),
                chat_id=chat.id,
            ):
                accumulated += delta
                streamed_any = True
                now = time.monotonic()
                new_chars = len(accumulated) - last_edit_len
                if (
                    now - last_edit_time >= edit_interval
                    and new_chars >= char_threshold
                ):
                    display = accumulated.strip()
                    if display:
                        try:
                            await thinking_msg.edit_text(display)
                        except Exception:
                            pass
                        last_edit_time = now
                        last_edit_len = len(accumulated)
        except Exception as e:
            logger.warning("Stream error: %s", e)
            return False

        if not streamed_any:
            return False

        # Final edit with complete text
        final = accumulated.strip()
        if final:
            try:
                await thinking_msg.edit_text(final)
            except Exception:
                await chat.send_message(final)
            self._messages_processed += 1
        else:
            try:
                await thinking_msg.edit_text("(empty response)")
            except Exception:
                pass
            self._messages_processed += 1

        return True

    async def handle_message(
        self, update: Update, context: ContextTypes.DEFAULT_TYPE
    ) -> None:
        """Handle incoming text messages -- route to keeper.

        Tries SSE streaming first for real-time response display.
        Falls back to batch mode if streaming fails.
        """
        if (
            update.effective_chat is None
            or update.effective_user is None
            or update.message is None
            or not update.message.text
        ):
            return

        keeper = self._resolve_keeper(update.effective_chat.id)
        text = update.message.text.strip()
        if not text:
            return

        # Send "thinking" indicator
        thinking_msg = await update.effective_chat.send_message("...")

        # Try streaming first
        streamed = await self._stream_response(update, keeper, text, thinking_msg)
        if streamed:
            self._last_message_at = datetime.now(tz=timezone.utc).isoformat()
            return

        # Fall back to batch mode
        response = await self.gate.send_telegram_message(
            keeper_name=keeper,
            content=text,
            user_id=update.effective_user.id,
            username=update.effective_user.username or str(update.effective_user.id),
            chat_id=update.effective_chat.id,
            message_id=update.message.message_id,
        )

        if response.ok and response_text(response):
            reply = response.reply.strip()
            rendered_reply, parse_mode = render_response_text(
                reply,
                response.structured,
            )
            footer_fn = format_footer_html if parse_mode == "HTML" else format_footer
            footer = footer_fn(
                keeper_name=response.keeper_name,
                model_used=response.model_used,
                duration_ms=response.duration_ms,
                tokens_used=response.tokens_used,
            )

            chunks = chunk_text(rendered_reply)

            first_text = chunks[0]
            if footer and len(chunks) == 1:
                first_text = f"{first_text}\n\n{footer}"
            try:
                await thinking_msg.edit_text(first_text, parse_mode=parse_mode)
            except Exception:
                # HTML chunking is not tag-aware (chunk_text splits on
                # newline/space at TELEGRAM_MESSAGE_LIMIT), so a chunk can land
                # inside a tag/entity and Telegram rejects it with HTTP 400
                # "can't parse entities". Degrade to plain text so the reply is
                # never dropped instead of re-sending the same unparseable HTML.
                await update.effective_chat.send_message(first_text, parse_mode=None)

            for i, chunk in enumerate(chunks[1:], 1):
                msg_text = chunk
                if footer and i == len(chunks) - 1:
                    msg_text = f"{chunk}\n\n{footer}"
                try:
                    await update.effective_chat.send_message(
                        msg_text, parse_mode=parse_mode
                    )
                except Exception:
                    # Same tag-unaware chunking risk as above: fall back to
                    # plain text so a parse error on one continuation chunk does
                    # not drop the rest of the reply.
                    await update.effective_chat.send_message(msg_text, parse_mode=None)

            self._messages_processed += 1
        elif response.error:
            error_text = f"Error: {response.error}"
            try:
                await thinking_msg.edit_text(error_text)
            except Exception:
                await update.effective_chat.send_message(error_text)
            self._messages_failed += 1
        else:
            try:
                await thinking_msg.edit_text("(empty response)")
            except Exception:
                pass
            self._messages_processed += 1

        self._last_message_at = datetime.now(tz=timezone.utc).isoformat()


async def main() -> None:
    """Start the Telegram bot."""
    cfg = get_config()
    bot = TelegramGateBot()
    bot._load_bindings()

    app = Application.builder().token(cfg.telegram_bot_token).build()

    # Register handlers
    app.add_handler(CommandHandler("start", bot.cmd_start))
    app.add_handler(CommandHandler("keepers", bot.cmd_keepers))
    app.add_handler(CommandHandler("bind", bot.cmd_bind))
    app.add_handler(CommandHandler("unbind", bot.cmd_unbind))
    app.add_handler(CommandHandler("status", bot.cmd_status))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, bot.handle_message))

    logger.info(
        "Telegram bot starting (gate=%s, default_keeper=%s)",
        cfg.gate_base_url,
        cfg.default_keeper,
    )

    # Check gate health
    healthy = await bot.gate.health_check()
    if healthy:
        logger.info("Gate healthy at %s", cfg.gate_base_url)
    else:
        logger.warning("Gate health check failed at %s", cfg.gate_base_url)

    bot._running = True
    status_task = asyncio.create_task(bot.status_loop())

    # Run with polling (simpler than webhooks for local dev)
    try:
        async with app:
            await app.start()
            await app.updater.start_polling(drop_pending_updates=True)  # type: ignore[union-attr]
            logger.info("Telegram bot running. Press Ctrl+C to stop.")

            # Block until stopped
            stop_event = asyncio.Event()
            loop = asyncio.get_event_loop()
            for sig in (signal.SIGINT, signal.SIGTERM):
                loop.add_signal_handler(sig, stop_event.set)

            await stop_event.wait()

            await app.updater.stop()  # type: ignore[union-attr]
            await app.stop()
    finally:
        bot._running = False
        status_task.cancel()
        with suppress(asyncio.CancelledError):
            await status_task
        try:
            await bot._write_status()
        except Exception as exc:
            logger.warning("Final status write error: %s", exc)

    await bot.gate.aclose()
    logger.info(
        "Telegram bot stopped (processed=%d, failed=%d)",
        bot._messages_processed,
        bot._messages_failed,
    )
