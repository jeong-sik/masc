"""Telegram message formatting for keeper responses.

Converts GateResponse into Telegram-friendly markdown.
Handles structured content and message length limits.
"""

from __future__ import annotations

import html
from typing import Any

from .config import TELEGRAM_MESSAGE_LIMIT

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


def _structured_table_cell(raw: Any) -> str:
    if isinstance(raw, dict):
        return _structured_text(raw.get("v")).strip()
    return _structured_text(raw).strip()


def _structured_table_text(raw: dict[str, Any]) -> str:
    head = raw.get("head")
    rows = raw.get("rows")
    if not isinstance(head, list) or not isinstance(rows, list):
        return ""
    rendered_rows = [[_structured_table_cell(cell) for cell in head]]
    for row in rows:
        if isinstance(row, list):
            rendered_rows.append([_structured_table_cell(cell) for cell in row])
    if not any(any(cell for cell in row) for row in rendered_rows):
        return ""
    return "\n".join(" | ".join(row) for row in rendered_rows)


def _telegram_part_from_structured(raw: Any) -> str:
    if not isinstance(raw, dict):
        return ""
    block_type = raw.get("t")
    if block_type == "p":
        text = html.unescape(_structured_text(raw.get("html")))
        return html.escape(text).strip()
    if block_type == "h4":
        text = html.unescape(_structured_text(raw.get("html"))).strip()
        return f"<b>{html.escape(text)}</b>" if text else ""
    if block_type == "ul":
        items = raw.get("items")
        if not isinstance(items, list):
            return ""
        lines = [
            f"- {html.escape(html.unescape(_structured_text(item)).strip())}"
            for item in items
            if html.unescape(_structured_text(item)).strip()
        ]
        return "\n".join(lines)
    if block_type == "callout":
        body = html.unescape(_structured_text(raw.get("html"))).strip()
        if not body:
            return ""
        severity = _structured_text(raw.get("severity")).strip()
        label = f"Callout ({severity})" if severity else "Callout"
        return f"<b>{html.escape(label)}:</b> {html.escape(body)}"
    if block_type == "table":
        table = _structured_table_text(raw)
        return f"<pre>{html.escape(table)}</pre>" if table else ""
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
    if block_type == "mermaid":
        source = _structured_text(raw.get("source"))
        if not source:
            return ""
        return f"<b>Mermaid</b>\n<pre><code>{html.escape(source)}</code></pre>"
    if block_type == "svg":
        source = _structured_text(raw.get("svg"))
        if not source:
            return ""
        caption = _structured_text(raw.get("cap")).strip()
        label = f"<b>SVG: {html.escape(caption)}</b>\n" if caption else "<b>SVG</b>\n"
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
    if block_type in ("voice", "audio"):
        src = _structured_text(raw.get("src")).strip()
        transcript = _structured_text(raw.get("transcript")).strip()
        via = _structured_text(raw.get("via")).strip()
        if not src and not transcript:
            return ""
        label = f"Audio ({via})" if via else "Audio"
        lines = [f"<b>{html.escape(label)}</b>"]
        if transcript:
            lines.append(html.escape(transcript))
        if src:
            lines.append(_html_link(src, src))
        return "\n".join(lines)
    if block_type == "attach":
        name = _structured_text(raw.get("name")).strip()
        src = _structured_text(raw.get("src")).strip()
        kind = _structured_text(raw.get("kind")).strip()
        if not name and not src:
            return ""
        label = f"Attachment ({kind})" if kind else "Attachment"
        lines = [f"<b>{html.escape(label)}:</b> {html.escape(name or src)}"]
        if src and src != name:
            lines.append(_html_link(src, src))
        return "\n".join(lines)
    if block_type == "video":
        src = _structured_text(raw.get("src")).strip()
        caption = _structured_text(raw.get("cap")).strip() or _structured_text(raw.get("name")).strip()
        if not src and not caption:
            return ""
        lines = [f"<b>Video:</b> {html.escape(caption or src)}"]
        if src and src != caption:
            lines.append(_html_link(src, src))
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
