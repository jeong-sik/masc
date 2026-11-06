#!/usr/bin/env python3
"""Run one existing PTY suite and retain its actual request counts."""

import importlib
import json
import os
import pathlib
import subprocess
import sys
import unittest
from unittest import mock

from test_tui_fusion_recovery import FixtureServer


def counts(values: dict[tuple[str, str], int]) -> list[dict[str, object]]:
    return [
        {"phase": phase, "path": path, "count": count}
        for (phase, path), count in sorted(values.items())
    ]


def main() -> int:
    if len(sys.argv) != 5:
        raise SystemExit("usage: measure_suite_requests.py MODULE CLASS BINARY OUTPUT")
    module_name, class_name, binary, output_name = sys.argv[1:]
    binary = os.path.abspath(binary)
    build_commit = subprocess.check_output([binary, "--build-commit"], text=True).strip()
    suite_class = getattr(importlib.import_module(module_name), class_name)
    suite_class.binary = binary
    servers = []
    original_init = FixtureServer.__init__

    def capture_init(self, base: str) -> None:
        original_init(self, base)
        servers.append(self)

    with mock.patch.object(FixtureServer, "__init__", capture_init):
        result = unittest.TextTestRunner(verbosity=1).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(suite_class)
        )
    if len(servers) != 1:
        raise RuntimeError(f"expected one PTY server, observed {len(servers)}")
    server = servers[0]
    summary = {
        "schema": "masc.tui.pty-request-counts.v1",
        "module": module_name,
        "class": class_name,
        "build_commit": build_commit,
        "test_passed": result.wasSuccessful(),
        "tests_run": result.testsRun,
        "observer_connections": server.observer_connections,
        "requests": counts(server.requests),
        "responses": counts(server.responses),
    }
    output = pathlib.Path(output_name)
    output.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"REQUEST_SUMMARY={output}")
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
