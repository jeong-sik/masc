"""Shared Slack API limits for the Slack Gate Bot."""

from __future__ import annotations

from typing import Final

SLACK_MESSAGE_LIMIT: Final[int] = 4000
SLACK_MAX_BLOCKS: Final[int] = 50
SLACK_BLOCK_TEXT_LIMIT: Final[int] = 3000
