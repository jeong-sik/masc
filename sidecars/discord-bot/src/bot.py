"""MASC Discord Bot -- Channel Gate consumer.

Bridges Discord messages to MASC keepers via the Channel Gate HTTP API.
This bot is a pure protocol adapter: no business logic, no LLM calls.

Usage:
    python -m src.bot
"""

from __future__ import annotations

import asyncio
import logging
import sys

import discord
from discord import app_commands

from .config import get_config
from .formatters import chunk_text, format_error_embed, format_keeper_embed
from .masc_client import GateResponse, MascGateClient

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("masc-discord-bot")


class MascBot(discord.Client):
    """Discord client that routes messages to MASC keepers."""

    def __init__(self) -> None:
        intents = discord.Intents.default()
        intents.message_content = True
        super().__init__(intents=intents)
        self.tree = app_commands.CommandTree(self)
        self.gate = MascGateClient()
        self.cfg = get_config()
        self._keeper_map = self.cfg.keeper_map()

    async def setup_hook(self) -> None:
        """Register slash commands on startup."""
        self.tree.add_command(keeper_ask)
        self.tree.add_command(keeper_status)
        await self.tree.sync()
        logger.info("Slash commands synced")

    async def on_ready(self) -> None:
        assert self.user is not None
        logger.info("Bot ready: %s (id=%s)", self.user.name, self.user.id)
        logger.info("Keeper map: %s", self._keeper_map)

        # Health check on startup
        healthy = await self.gate.health_check()
        if healthy:
            logger.info("Gate health check: OK")
        else:
            logger.warning("Gate health check: FAILED (bot will retry on messages)")

    async def on_message(self, message: discord.Message) -> None:
        """Route channel messages to the mapped keeper."""
        # Ignore own messages
        if message.author == self.user:
            return
        # Ignore DMs for now
        if not message.guild:
            return

        channel_id = str(message.channel.id)
        keeper_name = self._keeper_map.get(channel_id)

        if keeper_name is None:
            return  # Channel not mapped to any keeper

        # Show typing while waiting for keeper response
        async with message.channel.typing():
            response = await self.gate.send_message(
                keeper_name=keeper_name,
                content=message.content,
                channel_user_id=str(message.author.id),
                channel_user_name=str(message.author),
                channel_room_id=channel_id,
                message_id=str(message.id),
            )

        await self._send_response(message.channel, response)

    async def _send_response(
        self,
        channel: discord.abc.Messageable,
        response: GateResponse,
    ) -> None:
        """Send a gate response to a Discord channel."""
        if not response.ok:
            if response.error == "duplicate message":
                return  # Silently skip duplicates
            embed = format_error_embed(response.error)
            await channel.send(embed=embed)
            return

        # Short replies: plain text. Long replies: embed.
        if len(response.reply) <= 500 and not response.model_used:
            chunks = chunk_text(response.reply)
            for chunk in chunks:
                await channel.send(chunk)
        else:
            embed = format_keeper_embed(response)
            await channel.send(embed=embed)


# ── Slash Commands ──────────────────────────────────────────

@app_commands.command(name="keeper-ask", description="Send a message to a specific keeper")
@app_commands.describe(
    keeper="Keeper name",
    message="Message to send",
)
async def keeper_ask(
    interaction: discord.Interaction,
    keeper: str,
    message: str,
) -> None:
    """Send a message to a named keeper."""
    await interaction.response.defer(thinking=True)

    bot = interaction.client
    assert isinstance(bot, MascBot)

    response = await bot.gate.send_message(
        keeper_name=keeper,
        content=message,
        channel_user_id=str(interaction.user.id),
        channel_user_name=str(interaction.user),
        channel_room_id=str(interaction.channel_id),
        message_id=f"slash-{interaction.id}",
    )

    if response.ok:
        embed = format_keeper_embed(response)
        await interaction.followup.send(embed=embed)
    else:
        embed = format_error_embed(response.error)
        await interaction.followup.send(embed=embed)


@app_commands.command(name="keeper-status", description="Check gate connection status")
async def keeper_status(interaction: discord.Interaction) -> None:
    """Check if the gate is reachable."""
    await interaction.response.defer(thinking=True)

    bot = interaction.client
    assert isinstance(bot, MascBot)

    healthy = await bot.gate.health_check()
    if healthy:
        await interaction.followup.send("Gate: connected")
    else:
        await interaction.followup.send("Gate: unreachable")


# ── Entry point ─────────────────────────────────────────────

def main() -> None:
    """Run the bot."""
    cfg = get_config()
    bot = MascBot()

    logger.info("Starting MASC Discord Bot")
    logger.info("Gate URL: %s", cfg.masc_mcp_url)

    try:
        asyncio.run(bot.start(cfg.discord_bot_token))
    except KeyboardInterrupt:
        logger.info("Shutting down")
        sys.exit(0)


if __name__ == "__main__":
    main()
