"""Slack Gate Bot -- main bot logic using Socket Mode.

Routes Slack messages/mentions to MASC keepers via Channel Gate.
Uses Socket Mode (no public endpoint needed).

Supports:
- @mention in channels to route to bound keeper
- DMs to route to default keeper
- /keeper-bind <name> slash command
- /keeper-status slash command
- /keeper-list slash command
"""

from __future__ import annotations

import logging
import os
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from gate_shared import response_text
from gate_shared.bindings_store import load_bindings, save_bindings
from gate_shared.status_store import ConnectorRuntimeStatus, StatusStore

from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

from .config import get_config
from .formatters import fallback_text, response_blocks
from .gate_client import GateClient, GateResponse

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("slack-gate-bot")


class SlackGateBot:
    """Slack bot that routes messages to gate-backed keepers."""

    def __init__(self) -> None:
        self.cfg = get_config()
        self.gate = GateClient()
        self._bindings: dict[str, str] = {}  # channel_id -> keeper_name
        self._messages_processed = 0
        self._messages_failed = 0
        self._last_message_at = ""
        self.status_store = StatusStore(Path(self.cfg.status_path))
        self._status_stop = threading.Event()
        self._status_thread: threading.Thread | None = None

    def _load_bindings(self) -> None:
        self._bindings = load_bindings(
            self.cfg.binding_store_path,
            logger=logger,
        )

    def _save_bindings(self) -> None:
        save_bindings(self.cfg.binding_store_path, self._bindings, logger=logger)

    def _resolve_keeper(self, channel_id: str) -> str:
        return self._bindings.get(channel_id, self.cfg.default_keeper)

    def _write_status(self) -> None:
        self.status_store.write(
            ConnectorRuntimeStatus(
                updated_at=datetime.now(tz=timezone.utc).isoformat(),
                connected=True,
                gate_base_url=self.cfg.gate_base_url,
                gate_healthy=None,
                gate_health_checked_at="",
                last_message_at=self._last_message_at,
                messages_processed=self._messages_processed,
                messages_failed=self._messages_failed,
                pid=os.getpid(),
                runtime_bindings_count=len(self._bindings),
                default_keeper=self.cfg.default_keeper,
            )
        )

    def _status_loop(self) -> None:
        while not self._status_stop.is_set():
            try:
                self._write_status()
            except Exception as exc:
                logger.warning("Status write error: %s", exc)
            self._status_stop.wait(10.0)

    def start_status_heartbeat(self) -> None:
        if self._status_thread is not None and self._status_thread.is_alive():
            return
        self._status_stop.clear()
        self._status_thread = threading.Thread(
            target=self._status_loop,
            name="slack-status-heartbeat",
            daemon=True,
        )
        self._status_thread.start()

    def stop_status_heartbeat(self) -> None:
        self._status_stop.set()
        if self._status_thread is not None:
            self._status_thread.join(timeout=2.0)
        try:
            self._write_status()
        except Exception as exc:
            logger.warning("Final status write error: %s", exc)

    def register_handlers(self, app: App) -> None:
        """Register all Slack event and command handlers."""

        @app.event("app_mention")
        def handle_mention(event: dict[str, Any], say: Any) -> None:
            """Handle @mentions in channels."""
            import asyncio

            text = str(event.get("text", "")).strip()
            user_id = str(event.get("user", ""))
            channel_id = str(event.get("channel", ""))
            ts = str(event.get("ts", ""))

            # Strip the bot mention from the text
            # Format: <@BOT_USER_ID> message text
            import re

            text = re.sub(r"<@[A-Z0-9]+>\s*", "", text).strip()
            if not text:
                say("Send me a message after the mention.")
                return

            keeper = self._resolve_keeper(channel_id)

            # Send "thinking" message
            result = say("...")
            thinking_ts = result.get("ts", "") if isinstance(result, dict) else ""

            # Call gate synchronously (slack_bolt uses threads)
            response = asyncio.run(
                self.gate.send_slack_message(
                    keeper_name=keeper,
                    content=text,
                    user_id=user_id,
                    username=user_id,
                    channel_id=channel_id,
                    message_ts=ts,
                )
            )

            self._handle_response(response, say, app, channel_id, thinking_ts)

        @app.event("message")
        def handle_dm(event: dict[str, Any], say: Any) -> None:
            """Handle DMs to the bot."""
            import asyncio

            # Only handle DMs (channel type 'im')
            channel_type = str(event.get("channel_type", ""))
            if channel_type != "im":
                return

            # Skip bot messages
            if event.get("bot_id"):
                return

            text = str(event.get("text", "")).strip()
            user_id = str(event.get("user", ""))
            channel_id = str(event.get("channel", ""))
            ts = str(event.get("ts", ""))

            if not text:
                return

            keeper = self._resolve_keeper(channel_id)

            result = say("...")
            thinking_ts = result.get("ts", "") if isinstance(result, dict) else ""

            response = asyncio.run(
                self.gate.send_slack_message(
                    keeper_name=keeper,
                    content=text,
                    user_id=user_id,
                    username=user_id,
                    channel_id=channel_id,
                    message_ts=ts,
                )
            )

            self._handle_response(response, say, app, channel_id, thinking_ts)

        @app.command("/keeper-bind")
        def handle_bind(ack: Any, command: dict[str, Any], respond: Any) -> None:
            """Handle /keeper-bind <keeper_name> slash command."""
            import asyncio

            ack()
            keeper_name = str(command.get("text", "")).strip()
            channel_id = str(command.get("channel_id", ""))

            if not keeper_name:
                respond("Usage: `/keeper-bind <keeper_name>`")
                return

            available = asyncio.run(self.gate.list_keepers())
            if available and keeper_name not in available:
                respond(
                    f"Unknown keeper `{keeper_name}`. "
                    f"Available: {', '.join(sorted(available))}"
                )
                return

            self._bindings[channel_id] = keeper_name
            self._save_bindings()
            respond(f"Channel bound to keeper *{keeper_name}*.")

        @app.command("/keeper-list")
        def handle_list(ack: Any, respond: Any) -> None:
            """Handle /keeper-list slash command."""
            import asyncio

            ack()
            names = asyncio.run(self.gate.list_keepers())
            if not names:
                respond("No keepers available or gate unreachable.")
                return
            lines = [f"- `{name}`" for name in sorted(names)]
            respond(f"Available keepers ({len(names)}):\n" + "\n".join(lines))

        @app.command("/keeper-status")
        def handle_status(ack: Any, command: dict[str, Any], respond: Any) -> None:
            """Handle /keeper-status slash command."""
            import asyncio

            ack()
            channel_id = str(command.get("channel_id", ""))
            keeper = self._resolve_keeper(channel_id)
            status = asyncio.run(self.gate.keeper_status(keeper))
            if status is None:
                respond(f"Could not fetch status for *{keeper}*.")
                return

            alive = status.get("alive", False)
            state = status.get("state", "unknown")
            model = status.get("last_model_used", "?")
            turns = status.get("total_turns", 0)
            mark = ":white_check_mark:" if alive else ":x:"
            respond(f"{mark} *{keeper}*: {state}\nModel: `{model}` | Turns: {turns}")

    def _handle_response(
        self,
        response: GateResponse,
        say: Any,
        app: App,
        channel_id: str,
        thinking_ts: str,
    ) -> None:
        """Process gate response and update the thinking message."""
        rendered_text = response_text(response).strip()
        if response.ok and rendered_text:
            reply = response.reply.strip()
            blocks = response_blocks(
                reply,
                keeper_name=response.keeper_name,
                model_used=response.model_used,
                duration_ms=response.duration_ms,
                tokens_used=response.tokens_used,
                structured=response.structured,
            )
            text = fallback_text(rendered_text)
            if thinking_ts:
                try:
                    app.client.chat_update(
                        channel=channel_id,
                        ts=thinking_ts,
                        text=text,
                        blocks=blocks,
                    )
                except Exception:
                    say(text=text, blocks=blocks)
            else:
                say(text=text, blocks=blocks)
            self._messages_processed += 1
            self._last_message_at = datetime.now(tz=timezone.utc).isoformat()
        elif response.error:
            error_text = f":warning: {response.error}"
            if thinking_ts:
                try:
                    app.client.chat_update(
                        channel=channel_id,
                        ts=thinking_ts,
                        text=error_text,
                    )
                except Exception:
                    say(error_text)
            else:
                say(error_text)
            self._messages_failed += 1
            self._last_message_at = datetime.now(tz=timezone.utc).isoformat()
        else:
            if thinking_ts:
                try:
                    app.client.chat_update(
                        channel=channel_id,
                        ts=thinking_ts,
                        text="(empty response)",
                    )
                except Exception:
                    pass
            self._messages_processed += 1
            self._last_message_at = datetime.now(tz=timezone.utc).isoformat()


def main() -> None:
    """Start the Slack bot with Socket Mode."""
    cfg = get_config()
    bot = SlackGateBot()
    bot._load_bindings()
    bot.start_status_heartbeat()

    try:
        app = App(token=cfg.slack_bot_token)
        bot.register_handlers(app)

        logger.info(
            "Slack bot starting (gate=%s, default_keeper=%s, socket_mode=true)",
            cfg.gate_base_url,
            cfg.default_keeper,
        )

        handler = SocketModeHandler(app, cfg.slack_app_token)
        handler.start()
    finally:
        bot.stop_status_heartbeat()
