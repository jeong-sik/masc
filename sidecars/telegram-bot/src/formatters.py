"""Telegram message formatting for keeper responses.

Converts GateResponse into Telegram-friendly markdown.
Strips [STATE] blocks and handles message length limits.
"""

from __future__ import annotations

import html
import re
from typing import Any

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


def format_footer_html(
    keeper_name: str,
    model_used: str,
    duration_ms: int,
    tokens_used: int,
) -> str:
    """Format a compact footer for Telegram HTML parse mode."""
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
    return f"<i>{html.escape('  |  '.join(parts))}</i>"


def _structured_text(value: Any) -> str:
    return str(value) if isinstance(value, str) else ""


def _html_link(url: str, label: str) -> str:
    safe_url = html.escape(url, quote=True)
    safe_label = html.escape(label or url)
    return f'<a href="{safe_url}">{safe_label}</a>'


def _telegram_part_from_structured(raw: Any) -> str:
    if not isinstance(raw, dict):
        return ""
    block_type = raw.get("t")
    if block_type == "p":
        text = html.unescape(_structured_text(raw.get("html")))
        return html.escape(text).strip()
    if block_type == "image":
        src = _structured_text(raw.get("src")).strip()
        if not src:
            return ""
        caption = _structured_text(raw.get("cap")).strip() or "image"
        return "Image: " + _html_link(src, caption)
    if block_type == "code":
        source = _structured_text(raw.get("source"))
        if not source:
            source = html.unescape(_structured_text(raw.get("html")))
        if not source:
            return ""
        cap = _structured_text(raw.get("cap")).strip()
        label = f"<b>Code: {html.escape(cap)}</b>\n" if cap else ""
        return f"{label}<pre><code>{html.escape(source)}</code></pre>"
    if block_type == "link":
        url = _structured_text(raw.get("url")).strip()
        if not url:
            return ""
        title = _structured_text(raw.get("title")).strip() or url
        meta = _structured_text(raw.get("meta")).strip()
        suffix = f"\n{html.escape(meta)}" if meta else ""
        return _html_link(url, title) + suffix
    if block_type == "fusion":
        board_post_id = _structured_text(raw.get("board_post_id")).strip()
        if not board_post_id:
            return ""
        run_id = _structured_text(raw.get("run_id")).strip()
        lines = [
            "<b>Fusion result</b>",
            f"board_post_id: <code>{html.escape(board_post_id)}</code>",
        ]
        if run_id:
            lines.append(f"run_id: <code>{html.escape(run_id)}</code>")
        return "\n".join(lines)
    return ""


def structured_html_text(structured: dict[str, Any] | None) -> str:
    """Project GateResponse structured chat blocks into Telegram HTML text."""
    if not isinstance(structured, dict):
        return ""
    raw_blocks = structured.get("blocks")
    if not isinstance(raw_blocks, list):
        return ""
    parts = [
        part
        for raw in raw_blocks
        if (part := _telegram_part_from_structured(raw))
    ]
    return "\n\n".join(parts)


def render_response_text(
    text: str,
    structured: dict[str, Any] | None = None,
) -> tuple[str, str | None]:
    """Return Telegram text plus parse mode for a keeper response."""
    rendered = structured_html_text(structured)
    if rendered:
        return rendered, "HTML"
    return text, None
