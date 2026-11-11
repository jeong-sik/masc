"""Checks measure_marker_rereads.py on small synthetic stores.

Run: python3 -m unittest discover -s docs/evidence/aged-tool-results-2026-11
"""

from __future__ import annotations

import contextlib
import datetime
import hashlib
import io
import json
import pathlib
import re
import sys
import tempfile
import unittest
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_marker_rereads as reread  # noqa: E402

REPO = pathlib.Path(__file__).resolve().parents[3]
DAY = datetime.date(2026, 11, 10)
AGENT_CORE = "ollama_cloud.test-profile"
CLIENT_CLI = "codex.test-profile"
MIN = reread.AGED_MIN_BYTES
CEILING = reread.AGENT_CORE_INLINE_CEILING_BYTES


def compact(value: object) -> str:
    return json.dumps(value, separators=(",", ":"))


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def marker_text(sha: str, size: int) -> str:
    return f'[masc:blob sha256={sha} bytes={size} mime=text/plain preview="x"]'


def message_body(*contents: object) -> str:
    blocks = [
        {"type": "tool_result", "tool_use_id": f"call_{index}", "content": content, "is_error": False}
        for index, content in enumerate(contents)
    ]
    return compact({"role": "tool", "origin": "conversation", "content_blocks": blocks})


class Store:
    def __init__(self, base: pathlib.Path) -> None:
        self.base = base

    def blob(self, body: str) -> str:
        sha = digest(body)
        folder = self.base / ".masc" / "tool_blobs" / sha[:2]
        folder.mkdir(parents=True, exist_ok=True)
        (folder / sha).write_text(body, encoding="utf-8")
        return sha

    def request(
        self, keeper: str, profile: str, bodies: list[str], day: datetime.date = DAY, write_blobs: bool = True
    ) -> None:
        messages: list[object] = [{"role": "user", "artifact": {"bytes": 10, "content_ref": "[masc:blob]"}}]
        for body in bodies:
            sha = self.blob(body) if write_blobs else digest(body)
            reference = f"[masc:blob sha256={sha} bytes={len(body)} mime=application/json preview=\"\"]"
            messages.append({"role": "tool", "artifact": {"bytes": len(body), "content_ref": reference}})
        folder = self.base / ".masc" / "keepers" / keeper / "provider-inputs" / f"{day:%Y-%m}"
        folder.mkdir(parents=True, exist_ok=True)
        with (folder / f"{day:%d}.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(compact({"runtime_profile": profile, "messages": messages}) + "\n")

    def read(
        self, keeper: str, sha: str | None, returned: int = 100, day: datetime.date = DAY, name: str | None = None
    ) -> None:
        call_input: dict[str, object] = {} if sha is None else {"sha256": sha}
        if sha is None:
            call_input["answer_sha256"] = "0" * 64
        row = {
            "record_kind": "tool_call",
            "tool": reread.READ_TOOL,
            "keeper": keeper,
            "input": call_input,
            "result_bytes": returned,
        }
        folder = self.base / ".masc" / "tool_calls" / f"{day:%Y-%m}"
        folder.mkdir(parents=True, exist_ok=True)
        with (folder / (name or f"{day:%d}.jsonl")).open("a", encoding="utf-8") as handle:
            handle.write(compact(row) + "\n")


def run(base: pathlib.Path, days: list[datetime.date] | None = None) -> dict[str, object]:
    window = days or [DAY]
    scan = reread.scan_requests(base, window, reread.DEFAULT_PROFILE_PREFIXES)
    reads = reread.scan_reads(base, window)
    return reread.summarize(scan, reads, MIN, CEILING, 8)


def bands(result: dict[str, object]) -> list[tuple[int, int, int, int]]:
    rows = cast(list[dict[str, int]], result["bands"])
    return [(r["from_bytes"], r["to_bytes_exclusive"], r["markers"], r["read"]) for r in rows]


class MeasureMarkerRereadsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.base = pathlib.Path(self.directory.name)
        self.store = Store(self.base)

    def test_classes_by_the_two_declared_limits(self) -> None:
        aged, boundary, creation, under = ("a" * 63 + n for n in "1234")
        body = message_body(
            marker_text(aged, MIN + 1),
            marker_text(boundary, CEILING),
            marker_text(creation, CEILING + 1),
            marker_text(under, MIN - 1),
        )
        self.store.request("k1", AGENT_CORE, [body])
        result = run(self.base)
        self.assertEqual(result["requests"], 1)
        self.assertEqual(result["tool_messages"], 1)
        self.assertEqual(result["tool_messages_with_marker"], 1)
        self.assertEqual(result["markers"], 4)
        self.assertEqual(result["aged_markers"], 2)
        self.assertEqual(result["creation_markers"], 1)
        self.assertEqual(result["markers_under_minimum"], 1)
        self.assertEqual(result["aged_original_bytes"], MIN + 1 + CEILING)

    def test_a_read_counts_only_for_the_keeper_that_carried_the_marker(self) -> None:
        marker = "b" * 64
        self.store.request("k1", AGENT_CORE, [message_body(marker_text(marker, 3000))])
        self.store.read("k1", marker, returned=3000)
        self.store.read("k1", marker, returned=3000)
        self.store.read("k2", marker, returned=3000)
        result = run(self.base)
        self.assertEqual(result["aged_markers"], 1)
        self.assertEqual(result["aged_markers_read"], 1)
        self.assertEqual(result["read_calls_on_aged_markers"], 2)
        self.assertEqual(result["read_aged_returned_bytes"], 6000)
        self.assertEqual(result["read_aged_original_bytes"], 3000)
        self.assertEqual(result["reads_total"], 3)
        self.assertEqual(result["reads_by_keepers_with_scanned_requests"], 2)
        self.assertEqual(result["reads_on_known_markers"], 2)

    def test_the_same_marker_in_two_requests_counts_once(self) -> None:
        marker = "c" * 64
        for extra in ("one", "two"):
            self.store.request("k1", AGENT_CORE, [message_body(marker_text(marker, 5000), extra)])
        result = run(self.base)
        self.assertEqual(result["requests"], 2)
        self.assertEqual(result["markers"], 1)
        self.assertEqual(result["tool_messages_with_marker"], 2)

    def test_a_marker_quoted_inside_a_result_is_not_a_marker(self) -> None:
        quoted = "d" * 64
        text = "the ledger row said " + marker_text(quoted, 9000) + " and nothing else"
        self.store.request("k1", AGENT_CORE, [message_body(text)])
        self.assertEqual(run(self.base)["markers"], 0)

    def test_a_marker_in_a_text_block_counts(self) -> None:
        marker = "e" * 64
        blocks = [{"type": "text", "text": marker_text(marker, 4096)}]
        self.store.request("k1", AGENT_CORE, [message_body(blocks)])
        self.assertEqual(run(self.base)["aged_markers"], 1)

    def test_a_request_of_another_lane_is_skipped(self) -> None:
        self.store.request("k1", CLIENT_CLI, [message_body(marker_text("f" * 64, 4096))])
        result = run(self.base)
        self.assertEqual(result["requests"], 0)
        self.assertEqual(result["markers"], 0)

    def test_a_missing_message_blob_is_counted_not_guessed(self) -> None:
        self.store.request("k1", AGENT_CORE, [message_body(marker_text("1" * 64, 4096))], write_blobs=False)
        result = run(self.base)
        self.assertEqual(result["missing_message_blobs"], 1)
        self.assertEqual(result["markers"], 0)

    def test_a_read_without_sha256_is_counted_apart(self) -> None:
        self.store.read("k1", None)
        result = run(self.base)
        self.assertEqual(result["reads_total"], 1)
        self.assertEqual(result["reads_without_sha256"], 1)
        self.assertEqual(result["reads_on_known_markers"], 0)

    def test_ledger_days_and_segments(self) -> None:
        marker = "2" * 64
        self.store.request("k1", AGENT_CORE, [message_body(marker_text(marker, 3000))])
        self.store.read("k1", marker, name=f"{DAY:%d}.001.jsonl")
        self.store.read("k1", marker, day=DAY + datetime.timedelta(days=1))
        result = run(self.base)
        self.assertEqual(result["read_calls_on_aged_markers"], 1)
        both = run(self.base, [DAY, DAY + datetime.timedelta(days=1)])
        self.assertEqual(both["read_calls_on_aged_markers"], 2)

    def test_bands_start_at_the_minimum_and_end_after_the_ceiling(self) -> None:
        self.assertEqual(reread.size_edges(MIN, CEILING), [2048, 4096, 8192, 16384, 32768, 65537])
        low, mid, high = "3" * 64, "4" * 64, "5" * 64
        self.store.request(
            "k1",
            AGENT_CORE,
            [message_body(marker_text(low, MIN), marker_text(mid, 8192), marker_text(high, CEILING))],
        )
        self.store.read("k1", mid)
        got = bands(run(self.base))
        self.assertEqual(got[0], (2048, 4096, 1, 0))
        self.assertEqual(got[2], (8192, 16384, 1, 1))
        self.assertEqual(got[-1], (32768, 65537, 1, 0))

    def test_main_prints_and_writes_json(self) -> None:
        marker = "6" * 64
        self.store.request("k1", AGENT_CORE, [message_body(marker_text(marker, 3000))])
        self.store.read("k1", marker)
        out = self.base / "result.json"
        argv = ["--base-path", str(self.base), "--from-date", "2026-11-10", "--to-date", "2026-11-10", "--json-out", str(out)]
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            self.assertEqual(reread.main(argv), 0)
        written = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(written["aged_markers_read"], 1)
        self.assertEqual(written["window"], {"from": "2026-11-10", "to": "2026-11-10"})
        self.assertIn("aged_markers_read_share: 1.0", printed.getvalue())

    def test_a_window_that_ends_before_it_starts_is_refused(self) -> None:
        argv = ["--base-path", str(self.base), "--from-date", "2026-11-10", "--to-date", "2026-11-09"]
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(reread.main(argv), 2)


class DeclaredLimitsTest(unittest.TestCase):
    def ocaml_constant(self, relative: str, name: str) -> int:
        text = (REPO / relative).read_text(encoding="utf-8")
        match = re.search(rf"^let {name}\s*=\s*([0-9_]+)\s*$", text, re.MULTILINE)
        self.assertIsNotNone(match, f"{name} not found in {relative}")
        assert match is not None
        return int(match.group(1).replace("_", ""))

    def test_the_minimum_is_the_one_the_turn_driver_declares(self) -> None:
        declared = self.ocaml_constant("lib/keeper/keeper_turn_driver_try_provider.ml", "aged_result_min_bytes")
        self.assertEqual(reread.AGED_MIN_BYTES, declared)

    def test_the_ceiling_is_the_one_common_declares(self) -> None:
        declared = self.ocaml_constant("lib/core/common.ml", "max_agent_core_inline_result_bytes")
        self.assertEqual(reread.AGENT_CORE_INLINE_CEILING_BYTES, declared)


if __name__ == "__main__":
    unittest.main()
