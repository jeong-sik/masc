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

import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

from .config import get_config
from .formatters import chunk_text, response_blocks, strip_state_blocks
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

    def _load_bindings(self) -> None:
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
        path = Path(self.cfg.binding_store_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{path.name}.tmp")
        try:
            tmp.write_text(json.dumps(self._bindings, indent=2), encoding="utf-8")
            os.replace(tmp, path)
        except OSError as e:
            logger.error("Failed to save bindings: %s", e)
            tmp.unlink(missing_ok=True)

    def _resolve_keeper(self, channel_id: str) -> str:
        return self._bindings.get(channel_id, self.cfg.default_keeper)

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
            respond(
                f"{mark} *{keeper}*: {state}\n"
                f"Model: `{model}` | Turns: {turns}"
            )

    def _handle_response(
        self,
        response: GateResponse,
        say: Any,
        app: App,
        channel_id: str,
        thinking_ts: str,
    ) -> None:
        """Process gate response and update the thinking message."""
        if response.ok and response.reply:
            reply = strip_state_blocks(response.reply)
            blocks = response_blocks(
                reply,
                keeper_name=response.keeper_name,
                model_used=response.model_used,
                duration_ms=response.duration_ms,
                tokens_used=response.tokens_used,
            )
            if thinking_ts:
                try:
                    app.client.chat_update(
                        channel=channel_id,
                        ts=thinking_ts,
                        text=reply,
                        blocks=blocks,
                    )
                except Exception:
                    say(text=reply, blocks=blocks)
            else:
                say(text=reply, blocks=blocks)
            self._messages_processed += 1
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


def main() -> None:
    """Start the Slack bot with Socket Mode."""
    cfg = get_config()
    bot = SlackGateBot()
    bot._load_bindings()

    app = App(token=cfg.slack_bot_token)
    bot.register_handlers(app)

    logger.info(
        "Slack bot starting (gate=%s, default_keeper=%s, socket_mode=true)",
        cfg.gate_base_url,
        cfg.default_keeper,
    )

    handler = SocketModeHandler(app, cfg.slack_app_token)
    handler.start()
