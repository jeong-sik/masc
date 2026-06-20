"""Structured GateResponse content helpers for sidecar connectors."""

from __future__ import annotations

import html
from typing import Any


def _string(value: Any) -> str:
    return str(value) if isinstance(value, str) else ""


def _text_part(raw: dict[str, Any]) -> str:
    text = _string(raw.get("html"))
    return html.unescape(text).strip()


def _image_part(raw: dict[str, Any]) -> str:
    src = _string(raw.get("src")).strip()
    if not src:
        return ""
    caption = _string(raw.get("cap")).strip()
    if caption:
        return f"Image: {caption}\n{src}"
    return f"Image: {src}"


def _code_part(raw: dict[str, Any]) -> str:
    source = _string(raw.get("source"))
    if not source:
        source = html.unescape(_string(raw.get("html")))
    if not source:
        return ""
    cap = _string(raw.get("cap")).strip()
    fence = f"```{cap}" if cap else "```"
    return f"{fence}\n{source}\n```"


def _link_part(raw: dict[str, Any]) -> str:
    url = _string(raw.get("url")).strip()
    if not url:
        return ""
    title = _string(raw.get("title")).strip()
    meta = _string(raw.get("meta")).strip()
    lines = [title or url, url]
    if meta and meta != title:
        lines.append(meta)
    return "\n".join(lines)


def _fusion_part(raw: dict[str, Any]) -> str:
    board_post_id = _string(raw.get("board_post_id")).strip()
    if not board_post_id:
        return ""
    run_id = _string(raw.get("run_id")).strip()
    lines = ["Fusion result", f"board_post_id: {board_post_id}"]
    if run_id:
        lines.append(f"run_id: {run_id}")
    return "\n".join(lines)


def _plain_part(raw: Any) -> str:
    if not isinstance(raw, dict):
        return ""
    block_type = raw.get("t")
    if block_type == "p":
        return _text_part(raw)
    if block_type == "image":
        return _image_part(raw)
    if block_type == "code":
        return _code_part(raw)
    if block_type == "link":
        return _link_part(raw)
    if block_type == "fusion":
        return _fusion_part(raw)
    return ""


def structured_plain_text(structured: dict[str, Any] | None) -> str:
    """Project dashboard chat-block JSON into plain text for low-richness channels."""
    if not isinstance(structured, dict):
        return ""
    raw_blocks = structured.get("blocks")
    if not isinstance(raw_blocks, list):
        return ""
    parts = [part for raw in raw_blocks if (part := _plain_part(raw))]
    return "\n\n".join(parts)
