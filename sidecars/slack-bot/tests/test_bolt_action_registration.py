"""Integration pin for Slack Bolt action matcher registration."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

_sidecars_root = Path(__file__).resolve().parents[2]
_shared_root = _sidecars_root / "shared"
if str(_shared_root) not in sys.path:
    sys.path.insert(0, str(_shared_root))

pytest.importorskip("slack_bolt")

from slack_bolt import App  # noqa: E402
from slack_bolt.request import BoltRequest  # noqa: E402
from slack_bolt.response import BoltResponse  # noqa: E402
from src.bot import SlackGateBot  # noqa: E402


def test_compiled_button_action_matcher_matches_real_bolt_request() -> None:
    app = App(signing_secret="test", token_verification_enabled=False)
    bot = SlackGateBot.__new__(SlackGateBot)
    bot.register_handlers(app)

    action_listener = app._listeners[2]
    request = BoltRequest(
        body=json.dumps(
            {
                "type": "block_actions",
                "actions": [
                    {
                        "type": "button",
                        "action_id": "approve_123",
                        "action_ts": "171.001",
                    }
                ],
            }
        ),
        headers={"content-type": "application/json"},
    )

    assert action_listener.matchers[0].matches(
        request,
        BoltResponse(status=200, body=""),
    )
