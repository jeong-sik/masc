"""iMessage bridge -- read chat.db, send via AppleScript.

Apple's Messages.app stores messages in ~/Library/Messages/chat.db (SQLite).
The date column uses Apple Core Data epoch (2001-01-01 00:00:00 UTC) in nanoseconds.

This module provides:
- read_new_messages(): poll for inbound messages since last cursor
- send_message(): send a text via AppleScript osascript
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Final

from .config import get_config

logger = logging.getLogger(__name__)

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
POLL_QUERY: Final[str] = """
SELECT DISTINCT
    m.ROWID,
    m.text,
    m.date,
    m.is_from_me,
    m.service,
    h.id AS handle_id,
    h.service AS handle_service,
    c.guid AS chat_guid,
    c.chat_identifier,
    c.display_name
FROM message m
LEFT JOIN handle h ON m.handle_id = h.ROWID
LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
LEFT JOIN chat c ON cmj.chat_id = c.ROWID
WHERE m.ROWID > ?
  AND m.is_from_me = 0
  AND m.text IS NOT NULL
  AND m.text != ''
  AND m.service = 'iMessage'
ORDER BY m.ROWID ASC
LIMIT 100
"""


@dataclass(frozen=True, slots=True)
class InboundMessage:
    """A single inbound iMessage."""

    rowid: int
    text: str
    date: datetime
    service: str
    sender: str  # phone number or email
    chat_guid: str
    chat_identifier: str
    display_name: str

    @property
    def room_id(self) -> str:
        """Use chat_identifier as room ID for gate routing."""
        return self.chat_identifier or self.sender


def _apple_date_to_datetime(apple_ns: int) -> datetime:
    """Convert Apple Core Data timestamp (nanoseconds since 2001-01-01) to datetime."""
    seconds = apple_ns / 1_000_000_000
    return datetime.fromtimestamp(
        (APPLE_EPOCH.timestamp() + seconds),
        tz=timezone.utc,
    )


def _read_cursor(path: Path) -> int:
    """Read last seen ROWID from cursor file. Returns 0 if not found."""
    if not path.exists():
        return 0
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return int(data.get("last_rowid", 0))
    except (json.JSONDecodeError, OSError, ValueError):
        logger.warning("Failed to read cursor from %s, starting from 0", path)
        return 0


def advance_cursor(path: Path, rowid: int) -> None:
    """Persist last seen ROWID atomically.

    Call after messages are successfully processed to ensure
    at-least-once delivery: unprocessed messages are re-fetched on restart.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    try:
        tmp.write_text(
            json.dumps({"last_rowid": rowid, "updated_at": datetime.now(tz=timezone.utc).isoformat()}, indent=2),
            encoding="utf-8",
        )
        os.replace(tmp, path)
    except OSError:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def read_new_messages() -> list[InboundMessage]:
    """Poll chat.db for new inbound messages since last cursor.

    Requires Full Disk Access for the calling process.
    Returns messages ordered by ROWID ascending.
    """
    cfg = get_config()
    db_path = Path(cfg.chat_db_path)
    cursor_path = Path(cfg.cursor_path)

    if not db_path.exists():
        logger.error("chat.db not found at %s", db_path)
        return []

    last_rowid = _read_cursor(cursor_path)
    messages: list[InboundMessage] = []

    try:
        # chat.db is WAL-mode; open read-only to avoid locking issues
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute(POLL_QUERY, (last_rowid,)).fetchall()
            for row in rows:
                msg = InboundMessage(
                    rowid=row["ROWID"],
                    text=row["text"],
                    date=_apple_date_to_datetime(row["date"]),
                    service=row["service"] or "iMessage",
                    sender=row["handle_id"] or "unknown",
                    chat_guid=row["chat_guid"] or "",
                    chat_identifier=row["chat_identifier"] or "",
                    display_name=row["display_name"] or "",
                )
                messages.append(msg)
            if messages:
                logger.info("Read %d new message(s) up to ROWID %d", len(messages), messages[-1].rowid)
        finally:
            conn.close()
    except sqlite3.OperationalError as e:
        if "authorization denied" in str(e).lower():
            logger.error(
                "chat.db access denied. Grant Full Disk Access to the terminal app: "
                "System Settings > Privacy & Security > Full Disk Access"
            )
        else:
            logger.error("chat.db read error: %s", e)
    except Exception as e:
        logger.error("Unexpected error reading chat.db: %s", e)

    return messages


def send_message(*, text: str, chat_guid: str = "") -> bool:
    """Send an iMessage via AppleScript.

    Uses ``on run argv`` to pass parameters as native AppleScript text
    objects, eliminating string-literal injection risks entirely.

    Args:
        text: Message body.
        chat_guid: Exact Messages.app chat identifier. Replies are sent only
            when this value is available so the connector fails closed.

    Returns:
        True if AppleScript executed without error.
    """
    if not chat_guid:
        logger.error("AppleScript send aborted: missing chat_guid")
        return False

    script = (
        'on run argv\n'
        '  tell application "Messages"\n'
        '    set targetChat to first chat whose id is (item 1 of argv)\n'
        '    send (item 2 of argv) to targetChat\n'
        '  end tell\n'
        'end run'
    )
    argv = [chat_guid, text]

    try:
        result = subprocess.run(
            ["osascript", "-e", script, *argv],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode != 0:
            logger.error("AppleScript send failed (rc=%d): %s", result.returncode, result.stderr.strip())
            return False
        return True
    except subprocess.TimeoutExpired:
        logger.error("AppleScript send timed out for chat %s", chat_guid)
        return False
    except Exception as e:
        logger.error("AppleScript send error: %s", e)
        return False
