#!/usr/bin/env python3
"""The Tools view reads each part on the server's pushes (RFC-0483 §4.3):

- the Surface pane reads the selected Keeper's inventory when that Keeper's
  row, the Lane Add-on exports or runtime.toml change, and not for another
  Keeper's row;

- the Activations pane reads the selected Keeper's ledger when that Keeper's
  ledger changes, and not for another Keeper's change;
- the Usage pane reads one Keeper's usage when that Keeper's ledger changes,
  and the catalog with every Keeper's usage when the catalog is published;
- opening either pane reads it once;
- the refresh cadence reads none of them, the inventory included.
"""

import os
import sys
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


INVENTORY_PATH = "/api/v1/dashboard/tools"
CATALOG_PATH = "/api/v1/skills"
ACTIVATIONS_PATH = "/api/v1/keepers/skill-activations"
USAGE_PATH = "/api/v1/keepers/skill-usage"
SKILL_PATHS = (CATALOG_PATH, ACTIVATIONS_PATH, USAGE_PATH)


def keeper_of(query: str) -> str:
    values = urllib.parse.parse_qs(query).get("keeper", [])
    return values[0] if values else ""


class SkillHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(SkillServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == INVENTORY_PATH:
            # A built, empty inventory: an answer that does not decode would be
            # read again like a failed read.
            body: dict[str, object] = {
                "tool_inventory": {"tools": [], "count": 0},
                "effective_keeper_surface": None,
            }
        elif request.path == CATALOG_PATH:
            body = {"schema": "masc.skill-snapshot/v1", "state": "not_registered"}
        elif request.path == ACTIVATIONS_PATH:
            keeper = keeper_of(request.query)
            body = {
                "schema": "masc.keeper-skill-activations/v1",
                "keeper": keeper,
                "skill_activations": {"status": "no_session", "keeper_name": keeper},
            }
        elif request.path == USAGE_PATH:
            body = {
                "schema": "masc.keeper-skill-usage/v1",
                "keeper": keeper_of(request.query),
                "usage": {"state": "no_session"},
            }
        else:
            super().do_GET()
            return
        phase = server.record(request.path)
        if self.respond(200, body, workspace_receipt=True):
            server.responded(phase, request.path)


class SkillServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = SkillHandler


def activations_changed(keeper: str) -> dict[str, object]:
    return {
        "type": "keeper_skill_activations_changed",
        "name": keeper,
        "trace_id": "trace-" + keeper,
        "ts_unix": 1.0,
    }


def catalog_published() -> dict[str, object]:
    return {"type": "skill_catalog_published", "ts_unix": 1.0}


def row_changed(keeper: str) -> dict[str, object]:
    return {"type": "keeper_row_changed", "name": keeper, "ts_unix": 1.0}


def exports_changed() -> dict[str, object]:
    return {"type": "lane_addon_exports_changed", "ts_unix": 1.0}


def runtime_config_changed() -> dict[str, object]:
    return {"type": "runtime_config_changed", "ts_unix": 1.0}


class ToolsSkillSignalTest(unittest.TestCase):
    binary = ""

    def run_tools(
        self,
        panes: int,
        scenario: Callable[[SkillServer, Callable[..., None]], None],
        refresh_seconds: float = 1000.0,
    ) -> None:
        owed.ChatServer = SkillServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            tools = cast(SkillServer, server)
            tools.set_phase("tools")
            step("keys", ":")
            step("drain", 0.3)
            step("keys", "go Tools")
            step("drain", 0.3)
            step("keys", "\r")
            step(
                "wait",
                lambda: tools.response_count("tools", INVENTORY_PATH) >= 1,
                "the Tools surface did not read the selected Keeper's inventory",
            )
            step("drain", 0.5)
            # From the Keeper surface, [p] twice reaches Activations and three
            # times reaches Usage.
            tools.set_phase("pane")
            for _ in range(panes):
                step("keys", "p")
                step("drain", 0.3)
            step("drain", 1.0)
            scenario(tools, step)

        owed.ChatOwedHistoryTest.run_chat(
            cast(owed.ChatOwedHistoryTest, self), opened, refresh_seconds=refresh_seconds
        )

    def test_activations_read_on_the_selected_keepers_change(self) -> None:
        def scenario(server: SkillServer, step: Callable[..., None]) -> None:
            self.assertGreaterEqual(server.count("pane", ACTIVATIONS_PATH), 1)
            server.set_phase("other")
            server.events.put(activations_changed("bravo"))
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the other Keeper's change was not sent",
            )
            step("drain", 1.5)
            for path in SKILL_PATHS:
                self.assertEqual(server.count("other", path), 0, path)
            server.set_phase("changed")
            server.events.put(activations_changed("analyst"))
            step(
                "wait",
                lambda: server.response_count("changed", ACTIVATIONS_PATH) == 1,
                "the selected Keeper's change did not read its activations",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", ACTIVATIONS_PATH), 1)
            self.assertEqual(server.count("changed", USAGE_PATH), 0)
            self.assertEqual(server.count("changed", CATALOG_PATH), 0)

        self.run_tools(2, scenario)

    def test_usage_reads_one_keeper_or_the_catalog_on_its_push(self) -> None:
        def scenario(server: SkillServer, step: Callable[..., None]) -> None:
            self.assertGreaterEqual(server.count("pane", CATALOG_PATH), 1)
            self.assertGreaterEqual(server.count("pane", USAGE_PATH), 1)
            server.set_phase("changed")
            server.events.put(activations_changed("analyst"))
            step(
                "wait",
                lambda: server.response_count("changed", USAGE_PATH) == 1,
                "a Keeper's change did not read its usage",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", USAGE_PATH), 1)
            self.assertEqual(server.count("changed", CATALOG_PATH), 0)
            self.assertEqual(server.count("changed", ACTIVATIONS_PATH), 0)
            server.set_phase("published")
            server.events.put(catalog_published())
            step(
                "wait",
                lambda: server.response_count("published", CATALOG_PATH) == 1
                and server.response_count("published", USAGE_PATH) == 1,
                "a published catalog did not read the catalog and the usage",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("published", CATALOG_PATH), 1)
            self.assertEqual(server.count("published", USAGE_PATH), 1)

        self.run_tools(3, scenario)

    def test_every_pane_but_async_reads_the_inventory_on_its_pushes(self) -> None:
        def scenario(server: SkillServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(row_changed("bravo"))
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 1,
                "the other Keeper's row change was not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", INVENTORY_PATH), 0)
            for phase, event in (
                ("row", row_changed("analyst")),
                ("exports", exports_changed()),
                ("runtime", runtime_config_changed()),
            ):
                server.set_phase(phase)
                server.events.put(event)
                step(
                    "wait",
                    lambda phase=phase: server.response_count(phase, INVENTORY_PATH) == 1,
                    f"the {phase} push did not read the inventory",
                )
                step("drain", 1.5)
                self.assertEqual(server.count(phase, INVENTORY_PATH), 1, phase)

        # Surface, Activations and Usage. Catalog shares Surface's reading.
        for panes in (0, 2, 3):
            with self.subTest(panes=panes):
                self.run_tools(panes, scenario)

    def test_the_cadence_reads_no_tools_part(self) -> None:
        def scenario(server: SkillServer, step: Callable[..., None]) -> None:
            server.set_phase("quiet")
            step("drain", 3.5)
            for path in (INVENTORY_PATH,) + SKILL_PATHS:
                self.assertEqual(server.count("quiet", path), 0, path)

        for panes in (0, 2, 3):
            with self.subTest(panes=panes):
                self.run_tools(panes, scenario, refresh_seconds=1.0)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_tools_skill_signal.py /path/to/masc_tui.exe")
    ToolsSkillSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
