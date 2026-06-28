"""Structured GateResponse content helpers for sidecar connectors."""

from __future__ import annotations

import html
import re
from typing import Any

from .gate_response import GateResponse

_HTML_TAG_RE = re.compile(r"<[^>]+>")

SUPPORTED_BLOCK_TYPES = frozenset(
    {
        "p",
        "h4",
        "ul",
        "callout",
        "table",
        "image",
        "code",
        "mermaid",
        "svg",
        "link",
        "voice",
        "audio",
        "attach",
        "fusion",
    }
)


def _string(value: Any) -> str:
    return str(value) if isinstance(value, str) else ""


def _html_text(value: Any) -> str:
    text = _string(value)
    if not text:
        return ""
    return html.unescape(_HTML_TAG_RE.sub("", text)).strip()


def _text_part(raw: dict[str, Any]) -> str:
    return _html_text(raw.get("html"))


def _heading_part(raw: dict[str, Any]) -> str:
    text = _html_text(raw.get("html"))
    return f"## {text}" if text else ""


def _list_part(raw: dict[str, Any]) -> str:
    items = raw.get("items")
    if not isinstance(items, list):
        return ""
    lines = [f"- {text}" for item in items if (text := _html_text(item))]
    return "\n".join(lines)


def _callout_part(raw: dict[str, Any]) -> str:
    body = _html_text(raw.get("html"))
    if not body:
        return ""
    severity = _string(raw.get("severity")).strip()
    label = f"Callout ({severity})" if severity else "Callout"
    return f"{label}: {body}"


def _table_cell_text(raw: Any) -> str:
    if isinstance(raw, str):
        return _html_text(raw)
    if isinstance(raw, dict):
        return _html_text(raw.get("v"))
    return ""


def _table_part(raw: dict[str, Any]) -> str:
    head = raw.get("head")
    rows = raw.get("rows")
    if not isinstance(head, list) or not isinstance(rows, list):
        return ""
    rendered_rows = [[_table_cell_text(cell) for cell in head]]
    for row in rows:
        if isinstance(row, list):
            rendered_rows.append([_table_cell_text(cell) for cell in row])
    if not rendered_rows or not any(any(cell for cell in row) for row in rendered_rows):
        return ""
    return "\n".join(" | ".join(row) for row in rendered_rows)


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


def _mermaid_part(raw: dict[str, Any]) -> str:
    source = _string(raw.get("source"))
    if not source:
        return ""
    caption = _string(raw.get("caption")).strip()
    prefix = f"Mermaid: {caption}\n" if caption else ""
    return f"{prefix}```mermaid\n{source}\n```"


def _svg_part(raw: dict[str, Any]) -> str:
    source = _string(raw.get("svg"))
    if not source:
        return ""
    caption = _string(raw.get("cap")).strip()
    prefix = f"SVG: {caption}\n" if caption else "SVG\n"
    return f"{prefix}```svg\n{source}\n```"


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


def _voice_part(raw: dict[str, Any]) -> str:
    src = _string(raw.get("src")).strip()
    transcript = _string(raw.get("transcript")).strip()
    via = _string(raw.get("via")).strip()
    lines = ["Audio"]
    if via:
        lines[0] = f"Audio ({via})"
    if transcript:
        lines.append(transcript)
    if src:
        lines.append(src)
    return "\n".join(lines) if len(lines) > 1 else ""


def _attach_part(raw: dict[str, Any]) -> str:
    name = _string(raw.get("name")).strip()
    src = _string(raw.get("src")).strip()
    kind = _string(raw.get("kind")).strip()
    if not name and not src:
        return ""
    label = "Attachment"
    if kind:
        label = f"Attachment ({kind})"
    lines = [f"{label}: {name or src}"]
    if src and src != name:
        lines.append(src)
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
    if block_type == "h4":
        return _heading_part(raw)
    if block_type == "ul":
        return _list_part(raw)
    if block_type == "callout":
        return _callout_part(raw)
    if block_type == "table":
        return _table_part(raw)
    if block_type == "image":
        return _image_part(raw)
    if block_type == "code":
        return _code_part(raw)
    if block_type == "mermaid":
        return _mermaid_part(raw)
    if block_type == "svg":
        return _svg_part(raw)
    if block_type == "link":
        return _link_part(raw)
    if block_type in ("voice", "audio"):
        return _voice_part(raw)
    if block_type == "attach":
        return _attach_part(raw)
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


def _message_request_text(response: GateResponse) -> str:
    request = response.message_request
    if not isinstance(request, dict):
        return ""

    status = str(request.get("status", "")).strip().lower()
    if not status:
        return ""
    keeper = str(request.get("destination_id") or response.keeper_name or "keeper")
    request_id = str(request.get("request_id", "")).strip()
    metadata = request.get("metadata")
    in_flight_lane = ""
    if isinstance(metadata, dict):
        in_flight_lane = str(metadata.get("in_flight_lane", "")).strip()

    if status in {"accepted", "queued"}:
        state = "queued"
    elif status == "running":
        state = "running"
    else:
        state = status

    id_text = f" (request_id={request_id})" if request_id else ""
    lane_text = f" Current turn: {in_flight_lane}." if in_flight_lane else ""
    return f"{keeper} is busy; your message is {state}{id_text}.{lane_text}"


def response_text(response: GateResponse) -> str:
    """Return the renderable response body independent of reply vs structured shape."""
    return (
        structured_plain_text(response.structured)
        or _message_request_text(response)
        or response.reply
    )
