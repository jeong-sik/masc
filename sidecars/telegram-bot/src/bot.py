"""Telegram Gate Bot -- main bot logic.

Routes Telegram messages to MASC keepers via Channel Gate.
Supports:
- Direct messages to default keeper
- /bind <keeper> command to bind a chat to a keeper
- /keepers command to list available keepers
- /status command to show keeper status
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path

from telegram import Update
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

from .config import get_config
from .formatters import chunk_text, format_footer, strip_state_blocks
from .gate_client import GateClient, GateResponse

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

    def _load_bindings(self) -> None:
        """Load chat-to-keeper bindings from state file."""
        path = Path(self.cfg.binding_store_path)
        if not path.exists():
            return
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                self._bindings = {
                    str(k): str(v)
                    for k, v in data.items()
                    if isinstance(v, str)
                }
                logger.info("Loaded %d binding(s)", len(self._bindings))
        except (json.JSONDecodeError, OSError) as e:
            logger.warning("Failed to load bindings: %s", e)

    def _save_bindings(self) -> None:
        """Persist bindings to disk."""
        path = Path(self.cfg.binding_store_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{path.name}.tmp")
        try:
            tmp.write_text(
                json.dumps(self._bindings, indent=2),
                encoding="utf-8",
            )
            os.replace(tmp, path)
        except OSError as e:
            logger.error("Failed to save bindings: %s", e)
            tmp.unlink(missing_ok=True)

    def _resolve_keeper(self, chat_id: int) -> str:
        """Resolve which keeper handles a chat."""
        return self._bindings.get(str(chat_id), self.cfg.default_keeper)

    def _is_admin(self, user_id: int | None) -> bool:
        """Check if a user is an admin."""
        if not self._admin_ids:
            return True  # no admin restriction configured
        return user_id is not None and user_id in self._admin_ids

    # ── Command Handlers ───────────────────────────────────

    async def cmd_start(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
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

    async def cmd_keepers(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        """Handle /keepers command -- list available keepers."""
        if update.effective_chat is None:
            return
        names = await self.gate.list_keepers()
        if not names:
            await update.effective_chat.send_message("No keepers available or gate unreachable.")
            return
        lines = [f"- `{name}`" for name in sorted(names)]
        await update.effective_chat.send_message(
            f"Available keepers ({len(names)}):\n" + "\n".join(lines),
            parse_mode="Markdown",
        )

    async def cmd_bind(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
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

    async def cmd_unbind(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
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

    async def cmd_status(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
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

    async def handle_message(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        """Handle incoming text messages -- route to keeper."""
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

        response = await self.gate.send_telegram_message(
            keeper_name=keeper,
            content=text,
            user_id=update.effective_user.id,
            username=update.effective_user.username or str(update.effective_user.id),
            chat_id=update.effective_chat.id,
            message_id=update.message.message_id,
        )

        if response.ok and response.reply:
            reply = strip_state_blocks(response.reply)
            footer = format_footer(
                keeper_name=response.keeper_name,
                model_used=response.model_used,
                duration_ms=response.duration_ms,
                tokens_used=response.tokens_used,
            )

            chunks = chunk_text(reply)

            # Edit the "thinking" message with the first chunk
            first_text = chunks[0]
            if footer and len(chunks) == 1:
                first_text = f"{first_text}\n\n{footer}"
            try:
                await thinking_msg.edit_text(first_text)
            except Exception:
                # If edit fails, send as new message
                await update.effective_chat.send_message(first_text)

            # Send remaining chunks as new messages
            for i, chunk in enumerate(chunks[1:], 1):
                msg_text = chunk
                if footer and i == len(chunks) - 1:
                    msg_text = f"{chunk}\n\n{footer}"
                await update.effective_chat.send_message(msg_text)

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

    # Run with polling (simpler than webhooks for local dev)
    async with app:
        await app.start()
        await app.updater.start_polling(drop_pending_updates=True)  # type: ignore[union-attr]
        logger.info("Telegram bot running. Press Ctrl+C to stop.")

        # Block until stopped
        import asyncio

        stop_event = asyncio.Event()

        import signal

        loop = asyncio.get_event_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, stop_event.set)

        await stop_event.wait()

        await app.updater.stop()  # type: ignore[union-attr]
        await app.stop()

    await bot.gate.aclose()
    logger.info(
        "Telegram bot stopped (processed=%d, failed=%d)",
        bot._messages_processed,
        bot._messages_failed,
    )
