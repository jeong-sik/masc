"""CLI Gate Connector -- interactive terminal keeper chat.

Usage:
    python -m src [keeper_name]
    python -m src sangsu

No external service needed. Useful for testing and debugging.
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import sys
from pathlib import Path

logging.basicConfig(
    level=logging.WARNING,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("cli-connector")

_RE_STATE_BLOCK = re.compile(r"\[STATE\].*?(?:\[/STATE\]|$)", re.DOTALL)

# Add shared module to path
_shared_root = Path(__file__).resolve().parent.parent.parent / "shared"
if str(_shared_root) not in sys.path:
    sys.path.insert(0, str(_shared_root))

from gate_shared import GateClientBase, GateResponse  # noqa: E402


class CLIGateClient(GateClientBase):
    """Minimal gate client for CLI usage."""

    def __init__(self, gate_url: str) -> None:
        super().__init__(
            agent_name="cli-connector",
            gate_base_url=gate_url,
            gate_api_token="",
            gate_origin=gate_url,
            timeout_sec=120.0,
        )


def _strip_state(text: str) -> str:
    return _RE_STATE_BLOCK.sub("", text).strip()


async def _interactive_loop(client: CLIGateClient, keeper: str) -> None:
    """Run the interactive prompt loop."""
    msg_counter = 0

    while True:
        try:
            line = await asyncio.to_thread(input, f"\033[36m[{keeper}]\033[0m > ")
        except (EOFError, KeyboardInterrupt):
            print("\nBye.")
            break

        text = line.strip()
        if not text:
            continue

        # Meta commands
        if text.startswith("/"):
            parts = text.split(maxsplit=1)
            cmd = parts[0].lower()

            if cmd in ("/quit", "/exit", "/q"):
                print("Bye.")
                break
            if cmd == "/keepers":
                names = await client.list_keepers()
                if names:
                    print(f"Available keepers: {', '.join(sorted(names))}")
                else:
                    print("No keepers available or gate unreachable.")
                continue
            if cmd == "/bind" and len(parts) > 1:
                new_keeper = parts[1].strip()
                names = await client.list_keepers()
                if names and new_keeper not in names:
                    print(f"Unknown keeper '{new_keeper}'. Available: {', '.join(sorted(names))}")
                else:
                    keeper = new_keeper
                    print(f"Switched to keeper: {keeper}")
                continue
            if cmd == "/status":
                status = await client.keeper_status(keeper)
                if status:
                    alive = status.get("alive", False)
                    state = status.get("state", "unknown")
                    model = status.get("last_model_used", "?")
                    turns = status.get("total_turns", 0)
                    mark = "+" if alive else "-"
                    print(f"  {mark} {keeper}: {state} | model={model} | turns={turns}")
                else:
                    print(f"  Could not fetch status for {keeper}")
                continue
            if cmd == "/health":
                ok = await client.health_check()
                print(f"  Gate health: {'OK' if ok else 'FAIL'}")
                continue
            if cmd == "/help":
                print("Commands:")
                print("  /keepers       - list available keepers")
                print("  /bind <name>   - switch to a different keeper")
                print("  /status        - show keeper status")
                print("  /health        - check gate health")
                print("  /quit          - exit")
                continue

            # Unknown command -- treat as message
            text = text

        msg_counter += 1
        context = {
            "channel": "cli",
            "channel_user_id": os.environ.get("USER", "cli-user"),
            "channel_user_name": os.environ.get("USER", "cli-user"),
            "channel_room_id": "cli-session",
        }
        response = await client.send_message(
            keeper_name=keeper,
            content=text,
            context=context,
            idempotency_key=f"cli-{os.getpid()}-{msg_counter}",
        )

        if response.ok and response.reply:
            reply = _strip_state(response.reply)
            print(f"\n\033[33m{reply}\033[0m")
            # Footer
            footer_parts: list[str] = []
            if response.model_used:
                footer_parts.append(response.model_used)
            if response.duration_ms > 0:
                footer_parts.append(f"{response.duration_ms / 1000:.1f}s")
            if response.tokens_used > 0:
                footer_parts.append(f"{response.tokens_used} tok")
            if footer_parts:
                print(f"\033[90m  {'  |  '.join(footer_parts)}\033[0m")
            print()
        elif response.error:
            print(f"\n\033[31mError: {response.error}\033[0m\n")
        else:
            print("\n(empty response)\n")


async def main(keeper_override: str | None = None) -> None:
    """Start the CLI connector."""
    gate_url = os.environ.get("GATE_BASE_URL", "http://localhost:8935")
    default_keeper = os.environ.get("CLI_DEFAULT_KEEPER", "sangsu")
    keeper = keeper_override or default_keeper

    client = CLIGateClient(gate_url)

    # Health check
    healthy = await client.health_check()
    if not healthy:
        print(f"\033[31mGate unreachable at {gate_url}\033[0m")
        print("Set GATE_BASE_URL to the correct gate address.")
        return

    # List keepers
    names = await client.list_keepers()
    if names:
        if keeper not in names:
            print(f"\033[33mWarning: keeper '{keeper}' not found. Available: {', '.join(sorted(names))}\033[0m")

    print(f"\033[32mConnected to gate at {gate_url}\033[0m")
    print(f"Keeper: \033[1m{keeper}\033[0m  |  /help for commands  |  /quit to exit")
    print()

    try:
        await _interactive_loop(client, keeper)
    finally:
        await client.aclose()
