#!/usr/bin/env python3
"""A workspace dataset push reads only the surface that shows the dataset it
names (RFC-0480 §3.4).

The Repositories surface is on screen. The refresh cadence is pushed out of
the test's lifetime, so every list read after arrival comes from a push.
"""

import os
import sys
import unittest
import urllib.parse
from typing import Callable, cast

import test_tui_chat_owed_history as owed


REPOSITORIES_PATH = "/api/v1/repositories"


class RepositoriesHandler(owed.ChatHandler):
    def do_GET(self) -> None:
        server = cast(RepositoriesServer, self.server)
        request = urllib.parse.urlsplit(self.path)
        if request.path == REPOSITORIES_PATH:
            phase = server.record(request.path)
            if self.respond(200, {"repositories": [], "total": 0}):
                server.responded(phase, request.path)
        else:
            super().do_GET()


class RepositoriesServer(owed.ChatServer):
    def __init__(self, base: str) -> None:
        super().__init__(base)
        self.RequestHandlerClass = RepositoriesHandler


def dataset_changed(dataset: str) -> dict[str, object]:
    return {"type": "workspace_dataset_changed", "dataset": dataset}


class WorkspaceDatasetSignalTest(unittest.TestCase):
    binary = ""

    def run_repositories(
        self, scenario: Callable[[RepositoriesServer, Callable[..., None]], None]
    ) -> None:
        owed.ChatServer = RepositoriesServer
        owed.ChatOwedHistoryTest.binary = self.binary

        def opened(server: owed.ChatServer, step: Callable[..., None]) -> None:
            repositories = cast(RepositoriesServer, server)
            repositories.set_phase("open")
            # Keepers -> Features & plugins -> Workspace (#50465 took Usage and
            # Board off the tab ring, so Workspace is two tabs from Keepers).
            step("keys", "\t\t")
            step(
                "wait",
                lambda: repositories.response_count("open", REPOSITORIES_PATH) >= 1,
                "the Repositories surface did not read its list",
            )
            step("drain", 1.0)
            scenario(repositories, step)

        owed.ChatOwedHistoryTest.run_chat(cast(owed.ChatOwedHistoryTest, self), opened)

    def test_only_the_repositories_dataset_reads_the_list(self) -> None:
        def scenario(server: RepositoriesServer, step: Callable[..., None]) -> None:
            server.set_phase("other")
            server.events.put(dataset_changed("verification_requests"))
            server.events.put(dataset_changed("elsewhere"))
            step(
                "wait",
                lambda: server.count("other", "observer-event-written") == 2,
                "the other dataset pushes were not sent",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("other", REPOSITORIES_PATH), 0)
            server.set_phase("changed")
            server.events.put(dataset_changed("repositories"))
            step(
                "wait",
                lambda: server.response_count("changed", REPOSITORIES_PATH) == 1,
                "a repositories push did not read the list",
            )
            step("drain", 1.5)
            self.assertEqual(server.count("changed", REPOSITORIES_PATH), 1)

        self.run_repositories(scenario)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_tui_workspace_dataset_signal.py /path/to/masc_tui.exe")
    WorkspaceDatasetSignalTest.binary = os.path.abspath(sys.argv.pop())
    unittest.main()
