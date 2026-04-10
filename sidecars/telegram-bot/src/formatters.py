"""Telegram message formatting for keeper responses.

Converts GateResponse into Telegram-friendly markdown.
Strips [STATE] blocks and handles message length limits.
"""

from __future__ import annotations

import re
from collections.abc import Sequence

from .config import TELEGRAM_MESSAGE_LIMIT

_RE_STATE_BLOCK = re.compile(
    r"\[STATE\].*?(?:\[/STATE\]|$)", re.DOTALL
)


def strip_state_blocks(text: str) -> str:
    """Remove [STATE]...[/STATE] keeper metadata blocks from text."""
    return _RE_STATE_BLOCK.sub("", text).strip()


def chunk_text(text: str, limit: int = TELEGRAM_MESSAGE_LIMIT) -> list[str]:
    """Split text into chunks that fit Telegram's message limit.

    Tries to split on newlines or spaces to avoid breaking words.
    """
    if len(text) <= limit:
        return [text]

    chunks: list[str] = []
    remaining = text

    while remaining:
        if len(remaining) <= limit:
            chunks.append(remaining)
            break

        split_at = limit
        newline_pos = remaining.rfind("\n", 0, limit)
        if newline_pos > limit // 2:
            split_at = newline_pos + 1
        else:
            space_pos = remaining.rfind(" ", 0, limit)
            if space_pos > limit // 2:
                split_at = space_pos + 1

        chunks.append(remaining[:split_at])
        remaining = remaining[split_at:]

    return chunks


def format_footer(
    keeper_name: str,
    model_used: str,
    duration_ms: int,
    tokens_used: int,
) -> str:
    """Format a compact footer for keeper responses."""
    parts: list[str] = []
    if keeper_name:
        parts.append(keeper_name)
    if duration_ms > 0:
        secs = duration_ms / 1000.0
        parts.append(f"{secs:.1f}s")
    if model_used:
        parts.append(model_used)
    if tokens_used > 0:
        parts.append(f"{tokens_used} tok")
    if not parts:
        return ""
    return f"_{'  |  '.join(parts)}_"
