"""Slack message formatting for keeper responses.

Converts keeper responses into Slack Block Kit format.
Handles structured content and message length limits.
"""

from __future__ import annotations

import html
from typing import Any

from .constants import SLACK_BLOCK_TEXT_LIMIT, SLACK_MAX_BLOCKS, SLACK_MESSAGE_LIMIT

TRUNCATION_NOTICE = "\n[truncated: Slack block limit]"
STRUCTURED_TRUNCATION_TEMPLATE = (
    ":warning: {count} structured block(s) omitted because Slack allows "
    f"at most {SLACK_MAX_BLOCKS} blocks per message."
)

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


def _structured_truncation_notice(omitted: int) -> dict[str, Any]:
    return _section_block(
        escape_mrkdwn_text(STRUCTURED_TRUNCATION_TEMPLATE.format(count=omitted))
    )


def _structured_text(value: Any) -> str:
    return html.unescape(str(value)) if isinstance(value, str) else ""


def _structured_raw_text(value: Any) -> str:
    return str(value) if isinstance(value, str) else ""


def _link_block(url: str, title: str, meta: str = "") -> dict[str, Any]:
    label = escape_mrkdwn_text(title or url)
    escaped_url = escape_mrkdwn_text(url)
    suffix = f"\n{escape_mrkdwn_text(meta)}" if meta else ""
    return _section_block(f"*<{escaped_url}|{label}>*{suffix}")


def _image_block(url: str, caption: str = "") -> dict[str, Any]:
    alt_text = caption or "image"
    return {
        "type": "image",
        "image_url": url,
        "alt_text": alt_text[:SLACK_BLOCK_TEXT_LIMIT],
    }


def _fusion_block(board_post_id: str, run_id: str = "") -> dict[str, Any]:
    lines = ["*Fusion result*", f"board_post_id: {escape_mrkdwn_text(board_post_id)}"]
    if run_id:
        lines.append(f"run_id: {escape_mrkdwn_text(run_id)}")
    return _section_block("\n".join(lines))


def _code_block(source: str, cap: str = "") -> dict[str, Any]:
    title = f"*Code:* `{escape_mrkdwn_text(cap)}`\n" if cap else ""
    body = escape_mrkdwn_text(source)
    return _section_block(f"{title}```\n{body}\n```")


def _structured_list_block(raw: dict[str, Any]) -> dict[str, Any] | None:
    items = raw.get("items")
    if not isinstance(items, list):
        return None
    lines = [
        f"- {escape_mrkdwn_text(_structured_text(item).strip())}"
        for item in items
        if _structured_text(item).strip()
    ]
    if not lines:
        return None
    return _section_block("\n".join(lines))


def _structured_table_cell(raw: Any) -> str:
    if isinstance(raw, dict):
        return _structured_text(raw.get("v")).strip()
    return _structured_text(raw).strip()


def _structured_table_block(raw: dict[str, Any]) -> dict[str, Any] | None:
    head = raw.get("head")
    rows = raw.get("rows")
    if not isinstance(head, list) or not isinstance(rows, list):
        return None
    rendered_rows = [[_structured_table_cell(cell) for cell in head]]
    for row in rows:
        if isinstance(row, list):
            rendered_rows.append([_structured_table_cell(cell) for cell in row])
    if not any(any(cell for cell in row) for row in rendered_rows):
        return None
    body = "\n".join(" | ".join(row) for row in rendered_rows)
    return _section_block(f"```\n{escape_mrkdwn_text(body)}\n```")


def _callout_block(raw: dict[str, Any]) -> dict[str, Any] | None:
    body = _structured_text(raw.get("html")).strip()
    if not body:
        return None
    severity = _structured_text(raw.get("severity")).strip()
    label = f"*Callout ({escape_mrkdwn_text(severity)}):*" if severity else "*Callout:*"
    return _section_block(f"{label} {escape_mrkdwn_text(body)}")


def _voice_block(raw: dict[str, Any]) -> dict[str, Any] | None:
    src = _structured_text(raw.get("src")).strip()
    transcript = _structured_text(raw.get("transcript")).strip()
    via = _structured_text(raw.get("via")).strip()
    if not src and not transcript:
        return None
    label = f"*Audio ({escape_mrkdwn_text(via)}):*" if via else "*Audio:*"
    lines = [label]
    if transcript:
        lines.append(escape_mrkdwn_text(transcript))
    if src:
        lines.append(escape_mrkdwn_text(src))
    return _section_block("\n".join(lines))


def _attach_block(raw: dict[str, Any]) -> dict[str, Any] | None:
    name = _structured_text(raw.get("name")).strip()
    src = _structured_text(raw.get("src")).strip()
    kind = _structured_text(raw.get("kind")).strip()
    if not name and not src:
        return None
    label = "Attachment"
    if kind:
        label = f"Attachment ({escape_mrkdwn_text(kind)})"
    lines = [f"*{label}:* {escape_mrkdwn_text(name or src)}"]
    if src and src != name:
        lines.append(escape_mrkdwn_text(src))
    return _section_block("\n".join(lines))


def _video_block(raw: dict[str, Any]) -> dict[str, Any] | None:
    src = _structured_text(raw.get("src")).strip()
    caption = (
        _structured_text(raw.get("cap")).strip()
        or _structured_text(raw.get("name")).strip()
    )
    if not src and not caption:
        return None
    lines = [f"*Video:* {escape_mrkdwn_text(caption or src)}"]
    if src and src != caption:
        lines.append(escape_mrkdwn_text(src))
    return _section_block("\n".join(lines))


def _slack_block_from_structured(raw: Any) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    block_type = raw.get("t")
    if block_type == "p":
        text = _structured_text(raw.get("html"))
        if not text:
            return None
        return _section_block(escape_mrkdwn_text(text))
    if block_type == "h4":
        text = _structured_text(raw.get("html")).strip()
        if not text:
            return None
        return _section_block(f"*{escape_mrkdwn_text(text)}*")
    if block_type == "ul":
        return _structured_list_block(raw)
    if block_type == "callout":
        return _callout_block(raw)
    if block_type == "table":
        return _structured_table_block(raw)
    if block_type == "image":
        src = _structured_text(raw.get("src")).strip()
        if not src:
            return None
        return _image_block(src, _structured_text(raw.get("cap")))
    if block_type == "code":
        source = _structured_raw_text(raw.get("source")) or _structured_text(
            raw.get("html")
        )
        if not source:
            return None
        return _code_block(source, _structured_raw_text(raw.get("cap")).strip())
    if block_type == "mermaid":
        source = _structured_raw_text(raw.get("source"))
        if not source:
            return None
        return _code_block(source, "mermaid")
    if block_type == "svg":
        source = _structured_raw_text(raw.get("svg"))
        if not source:
            return None
        return _code_block(source, "svg")
    if block_type == "link":
        url = _structured_text(raw.get("url")).strip()
        if not url:
            return None
        title = _structured_text(raw.get("title")).strip() or url
        meta = _structured_text(raw.get("meta")).strip()
        return _link_block(url, title, meta)
    if block_type == "fusion":
        board_post_id = _structured_text(raw.get("board_post_id")).strip()
        if not board_post_id:
            return None
        return _fusion_block(board_post_id, _structured_text(raw.get("run_id")).strip())
    if block_type in ("voice", "audio"):
        return _voice_block(raw)
    if block_type == "attach":
        return _attach_block(raw)
    if block_type == "video":
        return _video_block(raw)
    return None


def structured_response_blocks(
    structured: dict[str, Any] | None,
) -> list[dict[str, Any]]:
    """Project GateResponse structured chat blocks into Slack Block Kit blocks."""
    if not isinstance(structured, dict):
        return []
    raw_blocks = structured.get("blocks")
    if not isinstance(raw_blocks, list):
        return []
    blocks: list[dict[str, Any]] = []
    for raw in raw_blocks:
        block = _slack_block_from_structured(raw)
        if block is not None:
            blocks.append(block)
    return blocks


def _limit_blocks(blocks: list[dict[str, Any]], budget: int) -> list[dict[str, Any]]:
    if budget <= 0:
        return []
    if len(blocks) <= budget:
        return blocks
    keep = max(0, budget - 1)
    omitted = len(blocks) - keep
    return blocks[:keep] + [_structured_truncation_notice(omitted)]


def response_blocks(
    text: str,
    keeper_name: str = "",
    model_used: str = "",
    duration_ms: int = 0,
    tokens_used: int = 0,
    structured: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    """Build Slack Block Kit blocks for a keeper response."""
    ctx = format_context_block(keeper_name, model_used, duration_ms, tokens_used)
    block_budget = SLACK_MAX_BLOCKS - (1 if ctx is not None else 0)
    structured_blocks = structured_response_blocks(structured)
    if structured_blocks:
        blocks = _limit_blocks(structured_blocks, block_budget)
    else:
        chunks = chunk_text(escape_mrkdwn_text(text), limit=SLACK_BLOCK_TEXT_LIMIT)
        if len(chunks) > block_budget:
            chunks = chunks[:block_budget]
            chunks[-1] = _append_truncation_notice(chunks[-1])
        blocks = [_section_block(chunk) for chunk in chunks]
    if ctx is not None:
        blocks.append(ctx)
    return blocks
