"""Discord message formatting for keeper responses.

Converts GateResponse objects into Discord embeds and chunked messages.
"""

from __future__ import annotations

from collections.abc import Sequence

import discord

from .config import DISCORD_EMBED_LIMIT, DISCORD_MESSAGE_LIMIT
from .gate_client import GateResponse


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
