"""Slack message formatting for keeper responses.

Converts keeper responses into Slack Block Kit format.
Strips [STATE] blocks and handles message length limits.
"""

from __future__ import annotations

import re
from typing import Any

SLACK_MESSAGE_LIMIT = 4000
SLACK_MAX_BLOCKS = 50
SLACK_BLOCK_TEXT_LIMIT = 3000
TRUNCATION_NOTICE = "\n[truncated: Slack block limit]"

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


def escape_mrkdwn_text(text: str) -> str:
    """Escape Slack mrkdwn control characters."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def fallback_text(text: str) -> str:
    """Build a Slack-safe top-level text fallback."""
    return escape_mrkdwn_text(text)[:SLACK_MESSAGE_LIMIT]


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
            {"type": "mrkdwn", "text": escape_mrkdwn_text(" | ".join(parts))},
        ],
    }


def _section_block(text: str) -> dict[str, Any]:
    return {
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": text[:SLACK_BLOCK_TEXT_LIMIT],
        },
    }


def _append_truncation_notice(text: str) -> str:
    if len(text) + len(TRUNCATION_NOTICE) <= SLACK_BLOCK_TEXT_LIMIT:
        return text + TRUNCATION_NOTICE
    keep = max(0, SLACK_BLOCK_TEXT_LIMIT - len(TRUNCATION_NOTICE))
    return text[:keep] + TRUNCATION_NOTICE


def response_blocks(
    text: str,
    keeper_name: str = "",
    model_used: str = "",
    duration_ms: int = 0,
    tokens_used: int = 0,
) -> list[dict[str, Any]]:
    """Build Slack Block Kit blocks for a keeper response."""
    ctx = format_context_block(keeper_name, model_used, duration_ms, tokens_used)
    text_budget = SLACK_MAX_BLOCKS - (1 if ctx is not None else 0)
    chunks = chunk_text(escape_mrkdwn_text(text), limit=SLACK_BLOCK_TEXT_LIMIT)
    if len(chunks) > text_budget:
        chunks = chunks[:text_budget]
        chunks[-1] = _append_truncation_notice(chunks[-1])

    blocks: list[dict[str, Any]] = [_section_block(chunk) for chunk in chunks]
    if ctx is not None:
        blocks.append(ctx)
    return blocks
