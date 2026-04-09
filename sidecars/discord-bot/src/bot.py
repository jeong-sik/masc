"""Discord Gate Bot -- Channel Gate consumer.

Bridges Discord messages to gate-backed keepers via the Channel Gate HTTP API.
This bot is a pure protocol adapter: no business logic, no LLM calls.

Usage:
    python -m src.bot
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
import time
from typing import Any, cast

import discord
from discord import app_commands

from .audit_store import BindingAuditEvent, BindingAuditStore, utc_now_iso
from .binding_store import BindingStore
from .config import get_config
from .formatters import (
    chunk_text,
    compose_gate_content,
    format_error_embed,
    format_keeper_embed,
    markdown_to_structured,
    render_structured_embeds,
)
from .gate_client import BreakerSnapshot, GateClient, GateResponse
from .status_store import ConnectorRuntimeStatus, StatusStore

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("discord-gate-bot")


def attachment_lines(message: discord.Message) -> list[str]:
    """Render Discord attachments into deterministic plain text."""
    lines: list[str] = []
    visible = message.attachments[:5]
    for attachment in visible:
        filename = attachment.filename.strip() or "attachment"
        lines.append(f"- {filename}: {attachment.url}")
    extra = len(message.attachments) - len(visible)
    if extra > 0:
        lines.append(f"- ... {extra} more attachment(s)")
    return lines


def channel_stats_for(status: dict[str, Any] | None, channel_name: str) -> dict[str, Any] | None:
    """Extract one connector row from gate status."""
    if status is None:
        return None
    rows = status.get("channels")
    if not isinstance(rows, list):
        return None
    for item in cast(list[object], rows):
        if isinstance(item, dict):
            row = cast(dict[str, Any], item)
            if row.get("channel") == channel_name:
                return row
    return None


class GateBot(discord.Client):
    """Discord client that routes messages to gate-backed keepers."""

    def __init__(self) -> None:
        intents = discord.Intents.default()
        intents.message_content = True
        super().__init__(intents=intents)
        self.tree = app_commands.CommandTree(self)
        self.gate = GateClient()
        self.cfg = get_config()
        self.binding_store = BindingStore(self.cfg.binding_store_path())
        self.audit_store = BindingAuditStore(self.cfg.binding_audit_path())
        self.status_store = StatusStore(self.cfg.status_path())
        persisted_bindings = self.binding_store.load()
        if persisted_bindings is None:
            legacy_binding_store = BindingStore(self.cfg.legacy_binding_store_path())
            legacy_bindings = legacy_binding_store.load()
            if legacy_bindings is not None:
                self.keeper_bindings = legacy_bindings
                self.binding_source = "legacy-fallback"
            else:
                self.keeper_bindings = self.cfg.keeper_map()
                self.binding_source = "env-seed"
        else:
            self.keeper_bindings = persisted_bindings
            self.binding_source = "persisted"
        if self.binding_source == "legacy-fallback":
            logger.info(
                "Loaded Discord bindings from legacy store %s; new writes go to %s",
                self.cfg.legacy_binding_store_path(),
                self.binding_store.path,
            )
        self._binding_store_mtime_ns = self.binding_store.modified_time_ns()
        self._last_gate_health: bool | None = None
        self._last_gate_health_at = ""
        self._last_ready_at = ""
        self._status_task: asyncio.Task[None] | None = None
        self._write_runtime_status(connected_override=False)

    async def setup_hook(self) -> None:
        """Register slash commands on startup."""
        self.tree.add_command(keeper_ask)  # pyright: ignore[reportUnknownArgumentType]
        self.tree.add_command(keeper_status)  # pyright: ignore[reportUnknownArgumentType]
        self.tree.add_command(keeper_bind)  # pyright: ignore[reportUnknownArgumentType]
        self.tree.add_command(keeper_unbind)  # pyright: ignore[reportUnknownArgumentType]
        self.tree.add_command(keeper_map)  # pyright: ignore[reportUnknownArgumentType]
        self.tree.add_command(keeper_audit)  # pyright: ignore[reportUnknownArgumentType]
        await self.tree.sync()
        self._status_task = asyncio.create_task(self._status_heartbeat_loop())
        self._write_runtime_status()
        logger.info("Slash commands synced")

    async def close(self) -> None:
        """Release resources on shutdown."""
        if self._status_task is not None:
            self._status_task.cancel()
            try:
                await self._status_task
            except asyncio.CancelledError:
                pass
            self._status_task = None
        self._write_runtime_status(connected_override=False)
        await self.gate.aclose()
        await super().close()

    async def on_ready(self) -> None:
        assert self.user is not None
        self._last_ready_at = utc_now_iso()
        logger.info("Bot ready: %s (id=%s)", self.user.name, self.user.id)
        logger.info(
            "Keeper map (%s @ %s, audit %s): %s",
            self.binding_source,
            self.binding_store.path,
            self.audit_store.path,
            self.keeper_bindings,
        )

        healthy = await self.gate.health_check()
        self._note_gate_health(healthy)
        self._write_runtime_status()
        if healthy:
            logger.info("Gate health check: OK")
        else:
            logger.warning("Gate health check: FAILED (bot will retry on messages)")

    def _resolve_keeper_for_channel(self, channel: discord.abc.Snowflake) -> str | None:
        self._maybe_reload_bindings()
        channel_id = str(channel.id)
        direct = self.keeper_bindings.get(channel_id)
        if direct is not None:
            return direct
        if isinstance(channel, discord.Thread) and channel.parent is not None:
            return self.keeper_bindings.get(str(channel.parent.id))
        return None

    def channel_binding_debug(self, channel: discord.abc.Snowflake) -> tuple[str | None, str]:
        self._maybe_reload_bindings()
        channel_id = str(channel.id)
        direct = self.keeper_bindings.get(channel_id)
        if direct is not None:
            return direct, "direct"
        if isinstance(channel, discord.Thread) and channel.parent is not None:
            inherited = self.keeper_bindings.get(str(channel.parent.id))
            if inherited is not None:
                return inherited, "thread-parent"
        return None, "unmapped"

    def set_channel_binding(self, channel_id: str, keeper_name: str) -> str | None:
        previous = self.keeper_bindings.get(channel_id)
        self.keeper_bindings[channel_id] = keeper_name
        return previous

    def remove_channel_binding(self, channel_id: str) -> str | None:
        return self.keeper_bindings.pop(channel_id, None)

    def persist_bindings(self) -> None:
        self.binding_store.save(self.keeper_bindings)
        self.binding_source = "persisted"
        self._binding_store_mtime_ns = self.binding_store.modified_time_ns()
        self._write_runtime_status()

    def append_binding_audit(
        self,
        *,
        action: str,
        interaction: discord.Interaction,
        channel_id: str,
        keeper_name: str,
        previous_keeper: str | None,
    ) -> None:
        self.audit_store.append(
            BindingAuditEvent(
                timestamp=utc_now_iso(),
                action=action,
                guild_id=str(interaction.guild_id or ""),
                channel_id=channel_id,
                keeper_name=keeper_name,
                actor_id=str(interaction.user.id),
                actor_name=str(interaction.user),
                previous_keeper=previous_keeper or "",
            )
        )

    def _compose_gate_content(self, message: discord.Message) -> str:
        return compose_gate_content(message.content, attachment_lines(message))

    def _note_gate_health(self, healthy: bool) -> None:
        self._last_gate_health = healthy
        self._last_gate_health_at = utc_now_iso()

    def _maybe_reload_bindings(self) -> None:
        current_mtime = self.binding_store.modified_time_ns()
        if current_mtime == self._binding_store_mtime_ns:
            return

        if current_mtime is None:
            self._binding_store_mtime_ns = None
            return

        persisted_bindings = self.binding_store.load()
        self._binding_store_mtime_ns = current_mtime
        if persisted_bindings is None:
            return

        if persisted_bindings != self.keeper_bindings:
            logger.info(
                "Reloaded %d Discord binding(s) from %s",
                len(persisted_bindings),
                self.binding_store.path,
            )
            self.keeper_bindings = persisted_bindings
            self.binding_source = "persisted"
            self._write_runtime_status()

    def _write_runtime_status(self, *, connected_override: bool | None = None) -> None:
        user_name = self.user.name if self.user is not None else ""
        user_id = str(self.user.id) if self.user is not None else ""
        connected = (
            connected_override
            if connected_override is not None
            else self.is_ready() and not self.is_closed()
        )
        status = ConnectorRuntimeStatus(
            updated_at=utc_now_iso(),
            connected=connected,
            bot_user_name=user_name,
            bot_user_id=user_id,
            guild_count=len(self.guilds),
            gate_base_url=self.cfg.gate_base_url,
            gate_healthy=self._last_gate_health,
            gate_health_checked_at=self._last_gate_health_at,
            last_ready_at=self._last_ready_at,
            binding_source=self.binding_source,
            runtime_bindings_count=len(self.keeper_bindings),
            binding_store_path=str(self.binding_store.path),
            audit_store_path=str(self.audit_store.path),
            pid=os.getpid(),
        )
        try:
            self.status_store.write(status)
        except OSError as exc:
            logger.warning("Failed to write Discord status store %s: %s", self.status_store.path, exc)

    async def _status_heartbeat_loop(self) -> None:
        interval = max(5, self.cfg.status_heartbeat_sec)
        while True:
            try:
                self._maybe_reload_bindings()
                healthy = await self.gate.health_check()
                self._note_gate_health(healthy)
                self._write_runtime_status()
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # pragma: no cover - defensive logging
                logger.warning("Discord status heartbeat failed: %s", exc)
            await asyncio.sleep(interval)

    def is_admin(self, interaction: discord.Interaction) -> bool:
        member = interaction.user
        if not isinstance(member, discord.Member):
            return False
        if member.guild_permissions.administrator or member.guild_permissions.manage_guild:
            return True
        role_id = self.cfg.discord_admin_role_id.strip()
        if not role_id:
            return False
        return any(str(role.id) == role_id for role in member.roles)

    async def _stream_to_channel(
        self,
        channel: discord.abc.Messageable,
        keeper_name: str,
        content: str,
        *,
        channel_user_id: str,
        channel_user_name: str,
        channel_room_id: str,
    ) -> bool:
        """Stream a keeper response with progressive Discord message edits.

        Returns True if streaming succeeded, False if caller should fall back
        to the batch send_message path.
        """
        accumulated = ""
        reply_msg: discord.Message | None = None
        last_edit = 0.0
        edit_interval = 1.5  # seconds, Discord rate limit: 5 edits / 5s

        async for delta in self.gate.stream_message(
            keeper_name=keeper_name,
            content=content,
            channel_user_id=channel_user_id,
            channel_user_name=channel_user_name,
            channel_room_id=channel_room_id,
        ):
            accumulated += delta

            now = time.monotonic()
            if now - last_edit < edit_interval:
                continue

            display = accumulated[:4000]
            if reply_msg is None:
                reply_msg = await channel.send(display + " ...")
            else:
                try:
                    await reply_msg.edit(content=display + " ...")
                except discord.HTTPException:
                    pass
            last_edit = now

        if not accumulated:
            return False

        # Final edit with complete text
        display = accumulated[:4000]
        if reply_msg is None:
            await channel.send(display)
        else:
            try:
                await reply_msg.edit(content=display)
            except discord.HTTPException:
                pass
        return True

    async def _send_response(
        self,
        channel: discord.abc.Messageable,
        response: GateResponse,
    ) -> None:
        """Send a gate response to a Discord channel (batch fallback)."""
        if not response.ok:
            if response.error == "duplicate message":
                return
            embed = format_error_embed(response.error)
            await channel.send(embed=embed)
            return

        # Try structured rendering (from gate or auto-parsed markdown)
        structured = response.structured or markdown_to_structured(response.reply)
        if structured is not None:
            embeds = render_structured_embeds(structured)
            if embeds:
                await channel.send(embeds=embeds[:10])
                return

        if len(response.reply) > 4096:
            for chunk in chunk_text(response.reply):
                await channel.send(chunk)
            return

        if len(response.reply) <= 500 and not response.model_used:
            for chunk in chunk_text(response.reply):
                await channel.send(chunk)
        else:
            embed = format_keeper_embed(response)
            await channel.send(embed=embed)

    async def on_message(self, message: discord.Message) -> None:
        """Route channel messages to the mapped keeper via streaming."""
        if message.author == self.user or message.author.bot:
            return
        if not message.guild:
            return

        self._maybe_reload_bindings()
        keeper_name = self._resolve_keeper_for_channel(message.channel)
        if keeper_name is None:
            return

        content = self._compose_gate_content(message)
        if not content:
            logger.info("Skipping empty Discord message %s", message.id)
            return

        # Try streaming first, fall back to batch
        async with message.channel.typing():
            streamed = await self._stream_to_channel(
                message.channel,
                keeper_name,
                content,
                channel_user_id=str(message.author.id),
                channel_user_name=str(message.author),
                channel_room_id=str(message.channel.id),
            )
            if streamed:
                return

            # Fallback: batch request via gate/message
            response = await self.gate.send_message(
                keeper_name=keeper_name,
                content=content,
                channel_user_id=str(message.author.id),
                channel_user_name=str(message.author),
                channel_room_id=str(message.channel.id),
                message_id=str(message.id),
            )

        await self._send_response(message.channel, response)


def breaker_summary(snapshot: BreakerSnapshot) -> str:
    if snapshot.open:
        return f"open ({snapshot.remaining_sec}s)"
    if snapshot.consecutive_failures > 0 and snapshot.last_failure:
        return f"closed, last failure: {snapshot.last_failure}"
    return "closed"


def keeper_status_embed(keeper_name: str, data: dict[str, Any]) -> discord.Embed:
    """Build a compact embed from gate keeper-status JSON."""
    embed = discord.Embed(
        title=f"Keeper: {keeper_name}",
        color=0x5865F2,
    )

    active_model = str(data.get("active_model", "-"))
    running = "yes" if bool(data.get("keepalive_running", False)) else "no"
    last_turn_ago = data.get("last_turn_ago_s")
    last_turn_value = "-"
    if isinstance(last_turn_ago, (int, float)):
        last_turn_value = f"{last_turn_ago:.0f}s ago"

    embed.add_field(name="Model", value=active_model or "-", inline=True)
    embed.add_field(name="Keepalive", value=running, inline=True)
    embed.add_field(name="Last Turn", value=last_turn_value, inline=True)

    goal = data.get("goal")
    if isinstance(goal, str) and goal.strip():
        embed.add_field(name="Goal", value=goal[:1024], inline=False)

    blocker = data.get("last_blocker")
    if isinstance(blocker, str) and blocker.strip():
        embed.add_field(name="Last Blocker", value=blocker[:1024], inline=False)

    return embed


def connector_status_embed(
    *,
    channel_id: str | None,
    channel_binding: tuple[str | None, str],
    gate_status: dict[str, Any] | None,
    breaker: BreakerSnapshot,
) -> discord.Embed:
    """Build connector status embed for Discord operators."""
    embed = discord.Embed(
        title="Discord Connector Status",
        color=0x57F287 if not breaker.open else 0xFEE75C,
    )

    binding_name, binding_source = channel_binding
    embed.add_field(
        name="Current Channel",
        value=f"{channel_id or 'n/a'}\nkeeper: {binding_name or 'unmapped'} ({binding_source})",
        inline=False,
    )
    embed.add_field(name="Breaker", value=breaker_summary(breaker), inline=False)

    if gate_status is None:
        embed.description = "Gate status unavailable"
        return embed

    discord_row = channel_stats_for(gate_status, "discord")
    if discord_row is None:
        embed.description = "No Discord traffic recorded yet"
        return embed

    health = str(discord_row.get("health", "unknown"))
    success_rate = discord_row.get("success_rate_pct", 0)
    errors = discord_row.get("error_count", 0)
    duplicates = discord_row.get("duplicate_count", 0)
    rooms = discord_row.get("room_count", 0)
    avg_duration_ms = discord_row.get("avg_duration_ms", 0)
    max_duration_ms = discord_row.get("max_duration_ms", 0)
    last_error = str(discord_row.get("last_error", "")).strip()

    embed.add_field(
        name="Connector",
        value=(
            f"health: {health}\n"
            f"success: {success_rate}%\n"
            f"errors: {errors} | duplicates: {duplicates}\n"
            f"rooms: {rooms}"
        ),
        inline=True,
    )
    embed.add_field(
        name="Latency",
        value=(
            f"avg: {int(avg_duration_ms) / 1000:.1f}s\n"
            f"max: {int(max_duration_ms) / 1000:.1f}s"
        ),
        inline=True,
    )

    if last_error:
        embed.add_field(name="Last Error", value=last_error[:1024], inline=False)

    return embed


def format_audit_event_line(event: BindingAuditEvent) -> str:
    action = event.action or "unknown"
    target = event.keeper_name or "-"
    previous = f" (prev {event.previous_keeper})" if event.previous_keeper else ""
    actor = event.actor_name or event.actor_id or "unknown"
    channel = event.channel_id or "-"
    guild = event.guild_id or "-"
    timestamp = event.timestamp or "-"
    return (
        f"{timestamp} · {action} · channel {channel} · guild {guild} · "
        f"keeper {target}{previous} · by {actor}"
    )


async def keeper_name_autocomplete(
    interaction: discord.Interaction,
    current: str,
) -> list[app_commands.Choice[str]]:
    bot = interaction.client
    assert isinstance(bot, GateBot)
    names = await bot.gate.list_keepers()
    needle = current.strip().lower()
    matches = [
        name for name in names if not needle or needle in name.lower()
    ][:25]
    return [app_commands.Choice(name=name, value=name) for name in matches]


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
    """Send a message to a named keeper with streaming."""
    await interaction.response.defer(thinking=True)

    bot = interaction.client
    assert isinstance(bot, GateBot)

    # Try streaming first
    accumulated = ""
    followup_msg: discord.WebhookMessage | None = None
    last_edit = 0.0
    edit_interval = 1.5

    async for delta in bot.gate.stream_message(
        keeper_name=keeper,
        content=message.strip(),
        channel_user_id=str(interaction.user.id),
        channel_user_name=str(interaction.user),
        channel_room_id=str(interaction.channel_id or "unknown"),
    ):
        accumulated += delta
        now = time.monotonic()
        if now - last_edit < edit_interval:
            continue
        display = accumulated[:4000]
        if followup_msg is None:
            followup_msg = await interaction.followup.send(display + " ...", wait=True)
        else:
            try:
                await followup_msg.edit(content=display + " ...")
            except discord.HTTPException:
                pass
        last_edit = now

    if accumulated:
        display = accumulated[:4000]
        if followup_msg is None:
            await interaction.followup.send(display)
        else:
            try:
                await followup_msg.edit(content=display)
            except discord.HTTPException:
                pass
        return

    # Fallback: batch request
    response = await bot.gate.send_message(
        keeper_name=keeper,
        content=message.strip(),
        channel_user_id=str(interaction.user.id),
        channel_user_name=str(interaction.user),
        channel_room_id=str(interaction.channel_id or "unknown"),
        message_id=f"slash-{interaction.id}",
    )

    if response.ok:
        if len(response.reply) > 4096:
            for chunk in chunk_text(response.reply):
                await interaction.followup.send(chunk)
        else:
            embed = format_keeper_embed(response)
            await interaction.followup.send(embed=embed)
    else:
        if response.error == "duplicate message":
            await interaction.followup.send(
                "이미 접수된 요청입니다. 잠시 기다린 뒤 새 요청으로 다시 시도해 주세요.",
                ephemeral=True,
            )
            return
        embed = format_error_embed(response.error)
        await interaction.followup.send(embed=embed, ephemeral=True)


@keeper_ask.autocomplete("keeper")
async def keeper_ask_autocomplete(
    interaction: discord.Interaction,
    current: str,
) -> list[app_commands.Choice[str]]:
    return await keeper_name_autocomplete(interaction, current)


@app_commands.command(
    name="keeper-status",
    description="Show connector health or a single keeper status",
)
@app_commands.describe(
    keeper="Optional keeper name",
)
async def keeper_status(
    interaction: discord.Interaction,
    keeper: str | None = None,
) -> None:
    """Check gate + connector health, or inspect one keeper."""
    await interaction.response.defer(thinking=True, ephemeral=True)

    bot = interaction.client
    assert isinstance(bot, GateBot)

    if keeper is not None and keeper.strip():
        data = await bot.gate.keeper_status(keeper)
        if data is None:
            embed = format_error_embed(f"keeper status unavailable: {keeper}")
            await interaction.followup.send(embed=embed, ephemeral=True)
            return
        embed = keeper_status_embed(keeper.strip(), data)
        await interaction.followup.send(embed=embed, ephemeral=True)
        return

    channel_binding = (
        bot.channel_binding_debug(interaction.channel)
        if interaction.channel is not None
        else (None, "no-channel")
    )
    embed = connector_status_embed(
        channel_id=str(interaction.channel_id) if interaction.channel_id is not None else None,
        channel_binding=channel_binding,
        gate_status=await bot.gate.gate_status(),
        breaker=bot.gate.breaker_snapshot(),
    )
    await interaction.followup.send(embed=embed, ephemeral=True)


@keeper_status.autocomplete("keeper")
async def keeper_status_autocomplete(
    interaction: discord.Interaction,
    current: str,
) -> list[app_commands.Choice[str]]:
    return await keeper_name_autocomplete(interaction, current)


@app_commands.command(
    name="keeper-bind",
    description="Bind the current Discord channel to a keeper",
)
@app_commands.describe(keeper="Keeper name")
async def keeper_bind(
    interaction: discord.Interaction,
    keeper: str,
) -> None:
    """Bind the current channel to a keeper in runtime memory."""
    bot = interaction.client
    assert isinstance(bot, GateBot)

    if not bot.is_admin(interaction):
        await interaction.response.send_message(
            "Admin role or Manage Server permission required.",
            ephemeral=True,
        )
        return

    if interaction.channel is None:
        await interaction.response.send_message("Channel context required.", ephemeral=True)
        return

    await interaction.response.defer(thinking=True, ephemeral=True)

    keeper_name = keeper.strip()
    known = await bot.gate.list_keepers()
    if keeper_name not in known:
        status = await bot.gate.keeper_status(keeper_name)
        if status is None:
            embed = format_error_embed(f"unknown keeper: {keeper_name}")
            await interaction.followup.send(embed=embed, ephemeral=True)
            return

    channel_id = str(interaction.channel.id)
    previous = bot.set_channel_binding(channel_id, keeper_name)
    try:
        bot.persist_bindings()
        bot.append_binding_audit(
            action="bind",
            interaction=interaction,
            channel_id=channel_id,
            keeper_name=keeper_name,
            previous_keeper=previous,
        )
    except OSError as exc:
        if previous is None:
            bot.remove_channel_binding(channel_id)
        else:
            bot.set_channel_binding(channel_id, previous)
        try:
            bot.persist_bindings()
        except OSError as rollback_exc:
            logger.error("Binding rollback failed for %s: %s", channel_id, rollback_exc)
        embed = format_error_embed(f"failed to persist binding store: {exc}")
        await interaction.followup.send(embed=embed, ephemeral=True)
        return

    await interaction.followup.send(
        f"Bound channel `{channel_id}` to keeper `{keeper_name}`.\n"
        f"Store: `{bot.binding_store.path}`\n"
        f"Audit: `{bot.audit_store.path}`",
        ephemeral=True,
    )


@keeper_bind.autocomplete("keeper")
async def keeper_bind_autocomplete(
    interaction: discord.Interaction,
    current: str,
) -> list[app_commands.Choice[str]]:
    return await keeper_name_autocomplete(interaction, current)


@app_commands.command(
    name="keeper-unbind",
    description="Remove the current Discord channel binding",
)
async def keeper_unbind(interaction: discord.Interaction) -> None:
    """Remove channel -> keeper binding from runtime memory."""
    bot = interaction.client
    assert isinstance(bot, GateBot)

    if not bot.is_admin(interaction):
        await interaction.response.send_message(
            "Admin role or Manage Server permission required.",
            ephemeral=True,
        )
        return

    if interaction.channel is None:
        await interaction.response.send_message("Channel context required.", ephemeral=True)
        return

    channel_id = str(interaction.channel.id)
    removed = bot.remove_channel_binding(channel_id)
    if removed is None:
        await interaction.response.send_message(
            f"Channel `{channel_id}` is not currently bound.",
            ephemeral=True,
        )
        return

    try:
        bot.persist_bindings()
        bot.append_binding_audit(
            action="unbind",
            interaction=interaction,
            channel_id=channel_id,
            keeper_name=removed,
            previous_keeper=removed,
        )
    except OSError as exc:
        bot.set_channel_binding(channel_id, removed)
        try:
            bot.persist_bindings()
        except OSError as rollback_exc:
            logger.error("Binding rollback failed for %s: %s", channel_id, rollback_exc)
        embed = format_error_embed(f"failed to persist binding store: {exc}")
        await interaction.response.send_message(embed=embed, ephemeral=True)
        return

    await interaction.response.send_message(
        f"Removed binding `{channel_id}` -> `{removed}`.\n"
        f"Store: `{bot.binding_store.path}`\n"
        f"Audit: `{bot.audit_store.path}`",
        ephemeral=True,
    )


@app_commands.command(
    name="keeper-map",
    description="Show runtime Discord channel bindings",
)
async def keeper_map(interaction: discord.Interaction) -> None:
    """Show current runtime bindings."""
    bot = interaction.client
    assert isinstance(bot, GateBot)

    binding = (
        bot.channel_binding_debug(interaction.channel)
        if interaction.channel is not None
        else (None, "no-channel")
    )
    lines = [
        f"current channel: {interaction.channel_id or 'n/a'}",
        f"resolved keeper: {binding[0] or 'unmapped'} ({binding[1]})",
        f"binding source: {bot.binding_source}",
        f"binding store: {bot.binding_store.path}",
        f"audit log: {bot.audit_store.path}",
        f"runtime bindings: {len(bot.keeper_bindings)}",
    ]

    for channel_id, keeper_name in sorted(bot.keeper_bindings.items())[:10]:
        lines.append(f"- {channel_id} -> {keeper_name}")

    await interaction.response.send_message("\n".join(lines), ephemeral=True)


@app_commands.command(
    name="keeper-audit",
    description="Show recent Discord binding changes",
)
@app_commands.describe(limit="Number of recent audit events to show")
async def keeper_audit(
    interaction: discord.Interaction,
    limit: app_commands.Range[int, 1, 20] = 10,
) -> None:
    """Show recent bind/unbind audit entries."""
    bot = interaction.client
    assert isinstance(bot, GateBot)

    if not bot.is_admin(interaction):
        await interaction.response.send_message(
            "Admin role or Manage Server permission required.",
            ephemeral=True,
        )
        return

    events = bot.audit_store.read_recent(limit=limit)
    if not events:
        await interaction.response.send_message(
            f"No audit entries found in `{bot.audit_store.path}`.",
            ephemeral=True,
        )
        return

    lines = [
        f"audit log: {bot.audit_store.path}",
        f"showing last {len(events)} event(s)",
    ]
    for event in reversed(events):
        lines.append(f"- {format_audit_event_line(event)}")

    await interaction.response.send_message("\n".join(lines), ephemeral=True)


# ── Entry point ─────────────────────────────────────────────


def main() -> None:
    """Run the bot."""
    cfg = get_config()
    bot = GateBot()

    logger.info("Starting Discord Gate bot")
    logger.info("Gate URL: %s", cfg.gate_base_url)

    try:
        asyncio.run(bot.start(cfg.discord_bot_token))
    except KeyboardInterrupt:
        logger.info("Shutting down")
        sys.exit(0)


if __name__ == "__main__":
    main()
