"""Discord message formatting for keeper responses.

Converts GateResponse objects into Discord embeds and chunked messages.
Supports structured content blocks for rich rendering.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from typing import Any, cast

import discord

from .config import DISCORD_EMBED_LIMIT, DISCORD_MESSAGE_LIMIT
from .gate_client import GateResponse


# ── Structured Content Rendering ──────────────────────────────


def render_structured_embeds(structured: dict[str, Any]) -> list[discord.Embed]:
    """Render structured content blocks into Discord embeds.

    Each block type maps to a Discord-native representation.
    Unknown types are skipped (caller falls back to plain text).
    """
    raw_blocks = structured.get("blocks")
    if not isinstance(raw_blocks, list):
        return []

    embeds: list[discord.Embed] = []
    for raw_block in cast(list[object], raw_blocks):
        if not isinstance(raw_block, dict):
            continue
        block = cast(dict[str, Any], raw_block)
        block_type = str(block.get("type", ""))
        embed = _render_block(block_type, block)
        if embed is not None:
            embeds.append(embed)
    return embeds


def _render_block(block_type: str, block: dict[str, Any]) -> discord.Embed | None:
    if block_type == "card":
        return _render_card(block)
    if block_type == "code":
        return _render_code(block)
    if block_type == "table":
        return _render_table(block)
    if block_type == "image":
        return _render_image(block)
    if block_type == "progress":
        return _render_progress(block)
    return None


def _render_card(block: dict[str, Any]) -> discord.Embed:
    title = block.get("title")
    description = str(block.get("description", ""))
    color_hex = block.get("color", "#5865F2")
    color = int(str(color_hex).lstrip("#"), 16) if isinstance(color_hex, str) else 0x5865F2

    embed = discord.Embed(
        title=title if isinstance(title, str) else None,
        description=description[:DISCORD_EMBED_LIMIT],
        color=color,
    )
    raw_fields = block.get("fields")
    if isinstance(raw_fields, list):
        for raw_field in cast(list[object], raw_fields)[:25]:
            if not isinstance(raw_field, dict):
                continue
            field = cast(dict[str, Any], raw_field)
            name = str(field.get("name", "-"))
            value = str(field.get("value", "-"))
            inline = bool(field.get("inline", False))
            embed.add_field(name=name, value=value, inline=inline)
    return embed


def _render_code(block: dict[str, Any]) -> discord.Embed:
    language = block.get("language", "")
    code = str(block.get("code", ""))
    lang_str = str(language) if language else ""
    formatted = f"```{lang_str}\n{code[:3900]}\n```"
    return discord.Embed(description=formatted, color=0x2B2D31)


def _render_table(block: dict[str, Any]) -> discord.Embed:
    raw_headers = block.get("headers", [])
    raw_rows = block.get("rows", [])
    headers = [str(h) for h in raw_headers] if isinstance(raw_headers, list) else []
    rows: list[list[str]] = []
    if isinstance(raw_rows, list):
        for raw_row in cast(list[object], raw_rows):
            if isinstance(raw_row, list):
                rows.append([str(cell) for cell in cast(list[object], raw_row)])

    if not headers:
        return discord.Embed(description="(empty table)", color=0x2B2D31)

    col_widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            if i < len(col_widths):
                col_widths[i] = max(col_widths[i], len(cell))

    def fmt_row(cells: list[str]) -> str:
        parts = []
        for i, cell in enumerate(cells):
            w = col_widths[i] if i < len(col_widths) else len(cell)
            parts.append(cell.ljust(w))
        return " | ".join(parts)

    lines = [fmt_row(headers)]
    lines.append("-+-".join("-" * w for w in col_widths))
    for row in rows[:20]:
        padded = row + [""] * (len(headers) - len(row))
        lines.append(fmt_row(padded[:len(headers)]))

    table_text = "\n".join(lines)
    return discord.Embed(description=f"```\n{table_text[:3900]}\n```", color=0x2B2D31)


def _render_image(block: dict[str, Any]) -> discord.Embed:
    url = str(block.get("url", ""))
    alt = block.get("alt", "")
    embed = discord.Embed(color=0x5865F2)
    if isinstance(alt, str) and alt:
        embed.description = alt
    if url:
        embed.set_image(url=url)
    return embed


def _render_progress(block: dict[str, Any]) -> discord.Embed:
    label = block.get("label", "Progress")
    percent = int(block.get("percent", 0))
    percent = max(0, min(100, percent))
    filled = percent // 10
    bar = "\u2588" * filled + "\u2591" * (10 - filled)
    embed = discord.Embed(color=0x57F287 if percent >= 100 else 0x5865F2)
    embed.add_field(
        name=str(label) if isinstance(label, str) else "Progress",
        value=f"`{bar}` {percent}%",
        inline=False,
    )
    return embed


# ── Markdown → Structured Auto-Conversion ─────────────────────


def markdown_to_structured(text: str) -> dict[str, Any] | None:
    """Parse markdown text into structured blocks.

    Returns None if the text has no recognizable structure
    (plain paragraph text stays as plain text).
    """
    blocks: list[dict[str, Any]] = []
    remaining = text.strip()
    if not remaining:
        return None

    # Extract code blocks
    code_pattern = re.compile(r"```(\w*)\n(.*?)```", re.DOTALL)
    parts = code_pattern.split(remaining)

    has_structure = False
    i = 0
    while i < len(parts):
        if i + 2 < len(parts) and (i % 3) == 0:
            # Text before code block
            before = parts[i].strip()
            if before:
                card = _text_to_card(before)
                if card is not None:
                    blocks.append(card)
                    has_structure = True
                else:
                    blocks.append({"type": "card", "description": before})
            # Code block
            lang = parts[i + 1]
            code = parts[i + 2]
            blocks.append({"type": "code", "language": lang or None, "code": code.strip()})
            has_structure = True
            i += 3
        else:
            # Remaining text after last code block
            after = parts[i].strip()
            if after:
                card = _text_to_card(after)
                if card is not None:
                    blocks.append(card)
                    has_structure = True
                else:
                    blocks.append({"type": "card", "description": after})
            i += 1

    if not has_structure:
        return None

    return {"blocks": blocks}


def _text_to_card(text: str) -> dict[str, Any] | None:
    """Try to extract a card with title from markdown heading."""
    lines = text.strip().split("\n", 1)
    first_line = lines[0].strip()
    heading_match = re.match(r"^#{1,3}\s+(.+)$", first_line)
    if heading_match and len(lines) > 1:
        return {
            "type": "card",
            "title": heading_match.group(1).strip(),
            "description": lines[1].strip(),
        }
    return None


# ── Legacy Response Formatting ────────────────────────────────


def format_keeper_embed(response: GateResponse) -> discord.Embed:
    """Create a Discord embed from a keeper response."""
    reply = response.reply
    if len(reply) > DISCORD_EMBED_LIMIT:
        reply = reply[: DISCORD_EMBED_LIMIT - 20] + "\n... (truncated)"

    embed = discord.Embed(
        description=reply,
        color=0x5865F2,  # Discord blurple
    )

    # Footer with turn stats
    footer_parts: list[str] = []
    if response.keeper_name:
        footer_parts.append(f"keeper: {response.keeper_name}")
    if response.duration_ms > 0:
        secs = response.duration_ms / 1000.0
        footer_parts.append(f"{secs:.1f}s")
    if response.model_used:
        footer_parts.append(response.model_used)
    if response.tokens_used > 0:
        footer_parts.append(f"{response.tokens_used} tok")

    if footer_parts:
        embed.set_footer(text=" | ".join(footer_parts))

    return embed


def format_error_embed(error_msg: str) -> discord.Embed:
    """Create an error embed."""
    return discord.Embed(
        description=error_msg,
        color=0xED4245,  # Discord red
    )


_RE_STATE_BLOCK = re.compile(
    r"\[STATE\].*?(?:\[/STATE\]|$)", re.DOTALL
)


def strip_state_blocks(text: str) -> str:
    """Remove [STATE]...[/STATE] keeper metadata blocks from text."""
    return _RE_STATE_BLOCK.sub("", text).strip()


def compose_gate_content(text: str, attachment_lines: Sequence[str]) -> str:
    """Build deterministic gate content from text + Discord attachments."""
    parts: list[str] = []
    body = text.strip()
    if body:
        parts.append(body)
    if attachment_lines:
        parts.append("Attachments:\n" + "\n".join(attachment_lines))
    return "\n\n".join(parts).strip()


def chunk_text(text: str, limit: int = DISCORD_MESSAGE_LIMIT) -> list[str]:
    """Split text into chunks that fit Discord's message limit.

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

        # Find a good split point
        split_at = limit
        # Try newline first
        newline_pos = remaining.rfind("\n", 0, limit)
        if newline_pos > limit // 2:
            split_at = newline_pos + 1
        else:
            # Try space
            space_pos = remaining.rfind(" ", 0, limit)
            if space_pos > limit // 2:
                split_at = space_pos + 1

        chunks.append(remaining[:split_at])
        remaining = remaining[split_at:]

    return chunks
