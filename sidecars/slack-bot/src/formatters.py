"""Slack message formatting for keeper responses.

Converts keeper responses into Slack Block Kit format.
Strips [STATE] blocks and handles message length limits.
"""

from __future__ import annotations

import re
from typing import Any

from .config import SLACK_MESSAGE_LIMIT

_RE_STATE_BLOCK = re.compile(
    r"\[STATE\].*?(?:\[/STATE\]|$)", re.DOTALL
)


def strip_state_blocks(text: str) -> str:
    """Remove [STATE]...[/STATE] keeper metadata blocks from text."""
    return _RE_STATE_BLOCK.sub("", text).strip()


def chunk_text(text: str, limit: int = SLACK_MESSAGE_LIMIT) -> list[str]:
    """Split text into chunks that fit Slack's message limit."""
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


def format_context_block(
    keeper_name: str,
    model_used: str,
    duration_ms: int,
    tokens_used: int,
) -> dict[str, Any] | None:
    """Format a Slack context block with keeper metadata."""
    parts: list[str] = []
    if keeper_name:
        parts.append(f"keeper: {keeper_name}")
    if duration_ms > 0:
        secs = duration_ms / 1000.0
        parts.append(f"{secs:.1f}s")
    if model_used:
        parts.append(model_used)
    if tokens_used > 0:
        parts.append(f"{tokens_used} tok")
    if not parts:
        return None
    return {
        "type": "context",
        "elements": [
            {"type": "mrkdwn", "text": " | ".join(parts)},
        ],
    }


def response_blocks(
    text: str,
    keeper_name: str = "",
    model_used: str = "",
    duration_ms: int = 0,
    tokens_used: int = 0,
) -> list[dict[str, Any]]:
    """Build Slack Block Kit blocks for a keeper response."""
    blocks: list[dict[str, Any]] = [
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": text[:SLACK_MESSAGE_LIMIT]},
        },
    ]
    ctx = format_context_block(keeper_name, model_used, duration_ms, tokens_used)
    if ctx is not None:
        blocks.append(ctx)
    return blocks
