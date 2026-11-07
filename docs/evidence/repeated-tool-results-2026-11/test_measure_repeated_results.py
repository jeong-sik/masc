"""Tests for measure_repeated_results.py. Run: python3 -m unittest discover docs/evidence/repeated-tool-results-2026-11"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import pathlib
import sys
import tempfile
import unittest
from collections.abc import Sequence

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import measure_repeated_results as repeats  # noqa: E402

BASE_TS = 1_794_000_000.0  # 2026-11-06T21:20:00Z
DAY = "2026-11-06"
CALL_SIZE = 3000


def message_blob(content: object, call_id: str) -> bytes:
    body = {
        "role": "tool",
        "origin": "conversation",
        "content_blocks": [{"type": "tool_result", "tool_use_id": call_id, "content": content}],
        "tool_call_id": call_id,
    }
    return json.dumps(body).encode("utf-8")


class Fixture:
    """A temporary base path with stored requests, message blobs and ledger files."""

    def __init__(self, root: pathlib.Path) -> None:
        self.root = root

    def blob(self, raw: bytes) -> tuple[str, int]:
        sha = hashlib.sha256(raw).hexdigest()
        path = self.root / ".masc" / "tool_blobs" / sha[:2] / sha
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        return sha, len(raw)

    def tool(self, index: int, content: object, call_id: str, media: bool = False, store: bool = True) -> dict[str, object]:
        raw = message_blob(content, call_id)
        sha, size = self.blob(raw) if store else (hashlib.sha256(raw).hexdigest(), len(raw))
        return entry(index, "tool", sha, size, media)

    def batch(self, index: int, results: Sequence[tuple[str, str | None]], store: bool = True) -> dict[str, object]:
        """One tool message that holds a block per (content, call id), like a batch of parallel calls."""
        blocks = [{"type": "tool_result", "tool_use_id": call_id, "content": content} for content, call_id in results]
        raw = json.dumps({"role": "tool", "origin": "conversation", "content_blocks": blocks, "tool_call_id": results[0][1]}).encode("utf-8")
        sha, size = self.blob(raw) if store else (hashlib.sha256(raw).hexdigest(), len(raw))
        return entry(index, "tool", sha, size)

    def user(self, index: int, origin: str = "conversation", store: bool = True) -> dict[str, object]:
        body = {"role": "user", "origin": origin, "content_blocks": [{"type": "text", "text": f"prompt {index}"}]}
        raw = json.dumps(body).encode("utf-8")
        sha, size = self.blob(raw) if store else (hashlib.sha256(raw).hexdigest(), len(raw))
        return entry(index, "user", sha, size)

    def request(
        self,
        keeper: str,
        messages: Sequence[dict[str, object]],
        captured_at: float = BASE_TS,
        day: str = DAY,
        trace: str | None = "trace-1",
    ) -> None:
        folder = self.root / ".masc" / "keepers" / keeper / "provider-inputs" / day[:7]
        folder.mkdir(parents=True, exist_ok=True)
        row: dict[str, object] = {
            "captured_at": captured_at,
            "messages": list(messages),
            "system_prompt": {"bytes": 100},
            "tool_schemas": [{"artifact": {"bytes": 50}}, {"artifact": {"bytes": 50}}],
        }
        if trace is not None:
            row["trace_id"] = trace
        with (folder / f"{day[8:]}.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(row) + "\n")

    def ledger(self, name: str, rows: Sequence[object], month: str = "2026-11") -> None:
        folder = self.root / ".masc" / "tool_calls" / month
        folder.mkdir(parents=True, exist_ok=True)
        with (folder / name).open("a", encoding="utf-8") as handle:
            for row in rows:
                handle.write((row if isinstance(row, str) else json.dumps(row)) + "\n")


def entry(index: int, role: str, sha: str | None, size: int, media: bool = False) -> dict[str, object]:
    ref = "" if sha is None else f'[masc:blob sha256={sha} bytes={size} mime=application/json preview=""]'
    return {"index": index, "role": role, "artifact": {"bytes": size, "content_ref": ref}, "media": [{"type": "image"}] if media else []}


def text_entry(index: int, role: str, size: int = 10) -> dict[str, object]:
    return entry(index, role, None, size)


def call_row(
    keeper: str = "k",
    tool: str = "BrowserRead",
    fingerprint: str = "f1",
    size: int = CALL_SIZE,
    ts: float = BASE_TS,
    turn: int = 1,
    session: str = "s1",
    kind: str = "tool_call",
    call_id: str | None = None,
) -> dict[str, object]:
    row: dict[str, object] = {
        "record_kind": kind,
        "ts": ts,
        "keeper": keeper,
        "tool": tool,
        "output_fingerprint": fingerprint,
        "result_bytes": size,
        "keeper_turn_id": turn,
        "session_id": session,
    }
    if call_id is not None:
        row["tool_use_id"] = call_id
    return row


def params(min_bytes: int = 1024, stub_bytes: int = 600, since: float | None = None, until: float | None = None) -> repeats.Params:
    return repeats.Params(min_bytes, stub_bytes, since, until)


def run_requests(
    fixture: Fixture, p: repeats.Params | None = None, excluded: Sequence[str] = (), answers: bool = False
) -> tuple[repeats.Tally, repeats.Skipped]:
    skipped = repeats.Skipped()
    stored = repeats.load_requests(fixture.root, "2026-11-01", "2026-11-30", excluded, skipped)
    fingerprints = repeats.load_ledger(fixture.root, "2026-11-01", "2026-11-30", [], repeats.Skipped()).fingerprints if answers else None
    return repeats.replay_requests(fixture.root, stored, p or params(), skipped, fingerprints), skipped


def run_ledger(fixture: Fixture, p: repeats.Params | None = None, excluded: Sequence[str] = ()) -> tuple[repeats.Tally, repeats.Skipped]:
    skipped = repeats.Skipped()
    ledger = repeats.load_ledger(fixture.root, "2026-11-01", "2026-11-30", excluded, skipped)
    return repeats.replay_ledger(ledger.groups, p or params(), skipped), skipped


class TempCase(unittest.TestCase):
    def setUp(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.fixture = Fixture(pathlib.Path(self._dir.name))


class ResultBlocksTest(unittest.TestCase):
    def test_every_tool_result_block_is_one_result_with_its_own_call_id(self) -> None:
        blob = {
            "content_blocks": [
                {"type": "tool_result", "tool_use_id": "call_a", "content": "a"},
                {"type": "text", "content": "x"},
                {"type": "tool_result", "tool_use_id": "call_b", "content": "b"},
            ],
            "tool_call_id": "call_a",
        }
        self.assertEqual(repeats.result_blocks(blob), [repeats.Result("call_a", "a"), repeats.Result("call_b", "b")])

    def test_a_list_content_is_serialized_with_sorted_keys(self) -> None:
        first = repeats.result_blocks({"content_blocks": [{"type": "tool_result", "content": [{"b": 1, "a": 2}]}]})
        second = repeats.result_blocks({"content_blocks": [{"type": "tool_result", "content": [{"a": 2, "b": 1}]}]})
        self.assertEqual(len(first), 1)
        self.assertEqual(first, second)

    def test_a_lone_block_without_an_id_takes_the_top_level_call_id(self) -> None:
        lone = {"content_blocks": [{"type": "tool_result", "content": "a"}], "tool_call_id": "call_top"}
        self.assertEqual(repeats.result_blocks(lone), [repeats.Result("call_top", "a")])
        several = {"content_blocks": [{"type": "tool_result", "content": "a"}, {"type": "tool_result", "content": "b"}], "tool_call_id": "call_top"}
        self.assertEqual(repeats.result_blocks(several), [repeats.Result(None, "a"), repeats.Result(None, "b")])

    def test_no_tool_result_block_gives_nothing(self) -> None:
        self.assertEqual(repeats.result_blocks({"content_blocks": [{"type": "text", "content": "x"}]}), [])
        self.assertEqual(repeats.result_blocks({"role": "tool"}), [])
        self.assertEqual(repeats.result_blocks(["not", "an", "object"]), [])


class RequestViewTest(TempCase):
    def two_equal_results(self, call_ids: tuple[str, str] = ("call_a", "call_b")) -> list[dict[str, object]]:
        body = "x" * 3000
        return [
            text_entry(0, "user"),
            self.fixture.tool(1, body, call_ids[0]),
            self.fixture.tool(2, body, call_ids[1]),
        ]

    def test_equal_text_with_different_call_ids_is_one_repeat(self) -> None:
        messages = self.two_equal_results()
        self.assertNotEqual(messages[1]["artifact"], messages[2]["artifact"])
        self.fixture.request("k", messages)
        tally, skipped = run_requests(self.fixture)
        self.assertEqual(tally.total.repeat_count, 1)
        self.assertEqual(tally.total.repeat_bytes, 3000)
        self.assertEqual(tally.total.saved_bytes, 3000 - 600)
        self.assertEqual(skipped.missing_blobs, 0)

    def test_the_share_of_a_request_is_saved_bytes_over_prompt_bytes(self) -> None:
        messages = self.two_equal_results()
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        self.assertEqual(tally.request_shares, [(3000 - 600) / tally.total.total_bytes])

    def test_each_block_of_a_batch_message_is_compared_on_its_own(self) -> None:
        messages = [
            text_entry(0, "user"),
            self.fixture.batch(1, [("x" * 3000, "c1"), ("y" * 3000, "c2")]),
            self.fixture.batch(2, [("x" * 3000, "c3"), ("z" * 3000, "c4")]),
        ]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        self.assertEqual((tally.total.repeat_count, tally.total.repeat_bytes), (1, 3000))

    def test_a_small_block_next_to_a_big_one_is_never_a_repeat(self) -> None:
        messages = [
            text_entry(0, "user"),
            self.fixture.batch(1, [("tiny", "c1"), ("p" * 3000, "c2")]),
            self.fixture.batch(2, [("tiny", "c3"), ("q" * 3000, "c4")]),
        ]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        self.assertEqual(tally.total.repeat_count, 0)

    def test_a_batch_message_is_not_a_repeat_because_one_block_repeats(self) -> None:
        messages = [
            text_entry(0, "user"),
            self.fixture.batch(1, [("same" * 400, "c1"), ("p" * 3000, "c2")]),
            self.fixture.batch(2, [("same" * 400, "c3"), ("q" * 3000, "c4")]),
        ]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        self.assertEqual((tally.total.repeat_count, tally.total.repeat_bytes), (1, 1600))

    def test_prompt_bytes_are_messages_plus_system_prompt_and_schemas(self) -> None:
        messages = self.two_equal_results()
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        expected = 10 + sum(int(m["artifact"]["bytes"]) for m in messages[1:]) + 200  # type: ignore[index]
        self.assertEqual(tally.total.total_bytes, expected)

    def test_different_text_is_not_a_repeat(self) -> None:
        messages = [text_entry(0, "user"), self.fixture.tool(1, "a" * 3000, "c1"), self.fixture.tool(2, "b" * 3000, "c2")]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        self.assertEqual(tally.total.repeat_count, 0)
        self.assertEqual(tally.request_shares, [0.0])

    def test_a_result_of_an_earlier_turn_is_an_earlier_turn_repeat_and_saves_nothing(self) -> None:
        body = "y" * 3000
        messages = [self.fixture.user(0), self.fixture.tool(1, body, "c1"), self.fixture.user(2), self.fixture.tool(3, body, "c2")]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        self.assertEqual(tally.total.repeat_count, 0)
        self.assertEqual(tally.total.saved_bytes, 0)
        self.assertEqual(tally.total.earlier_count, 1)
        self.assertEqual(tally.total.earlier_bytes, 3000)

    def test_a_text_seen_in_an_earlier_turn_and_twice_in_this_one(self) -> None:
        body = "w" * 3000
        messages = [
            self.fixture.user(0),
            self.fixture.tool(1, body, "c1"),
            self.fixture.user(2),
            self.fixture.tool(3, body, "c2"),
            self.fixture.tool(4, body, "c3"),
        ]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        self.assertEqual((tally.total.repeat_count, tally.total.earlier_count), (1, 1))

    def test_only_a_conversation_user_message_starts_a_turn(self) -> None:
        body = "v" * 3000
        for origin in ("agent_instruction", "recovery_instruction", "system_context"):
            with self.subTest(origin=origin):
                fixture = Fixture(self.fixture.root / origin)
                messages = [fixture.user(0), fixture.tool(1, body, "c1"), fixture.user(2, origin), fixture.tool(3, body, "c2")]
                fixture.request("k", messages)
                tally, _ = run_requests(fixture)
                self.assertEqual((tally.total.repeat_count, tally.total.earlier_count), (1, 0))

    def test_a_user_message_that_cannot_be_read_starts_a_turn(self) -> None:
        body = "u" * 3000
        missing = [self.fixture.user(0), self.fixture.tool(1, body, "c1"), self.fixture.user(2, store=False), self.fixture.tool(3, body, "c2")]
        self.fixture.request("k", missing)
        tally, skipped = run_requests(self.fixture)
        self.assertEqual((tally.total.repeat_count, tally.total.earlier_count), (0, 1))
        self.assertEqual(skipped.missing_blobs, 1)

    def test_a_user_message_without_a_digest_or_with_a_blob_that_is_not_an_object_starts_a_turn(self) -> None:
        body = "t" * 3000
        for name, unreadable in (("no-digest", 0), ("not-an-object", 1)):
            fixture = Fixture(self.fixture.root / name)
            if unreadable:
                sha, size = fixture.blob(json.dumps(["not", "an", "object"]).encode("utf-8"))
                boundary = entry(2, "user", sha, size)
            else:
                boundary = text_entry(2, "user")
            fixture.request("k", [fixture.user(0), fixture.tool(1, body, "c1"), boundary, fixture.tool(3, body, "c2")])
            tally, skipped = run_requests(fixture)
            self.assertEqual((tally.total.repeat_count, tally.total.earlier_count), (0, 1))
            self.assertEqual(skipped.unreadable_blobs, unreadable)

    def test_two_repeats_of_one_text_count_twice(self) -> None:
        body = "z" * 3000
        messages = [text_entry(0, "user")] + [self.fixture.tool(i, body, f"c{i}") for i in range(1, 4)]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        self.assertEqual(tally.total.repeat_count, 2)

    def test_results_below_min_bytes_are_ignored(self) -> None:
        messages = [text_entry(0, "user"), self.fixture.tool(1, "s" * 100, "c1"), self.fixture.tool(2, "s" * 100, "c2")]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        self.assertEqual(tally.total.repeat_count, 0)

    def test_a_result_text_of_exactly_min_bytes_counts_and_the_message_wrapper_does_not(self) -> None:
        messages = [text_entry(0, "user"), self.fixture.tool(1, "m" * 500, "c1"), self.fixture.tool(2, "m" * 500, "c2")]
        self.assertGreater(int(messages[1]["artifact"]["bytes"]), 501)  # type: ignore[index]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture, params(min_bytes=500))
        self.assertEqual(tally.total.repeat_count, 1)
        tally, _ = run_requests(self.fixture, params(min_bytes=501))
        self.assertEqual(tally.total.repeat_count, 0)

    def test_empty_results_never_repeat_even_with_a_zero_minimum(self) -> None:
        messages = [text_entry(0, "user"), self.fixture.tool(1, "", "c1"), self.fixture.tool(2, "", "c2")]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture, params(min_bytes=0))
        self.assertEqual(tally.total.repeat_count, 0)

    def test_multibyte_text_is_measured_in_utf8_bytes(self) -> None:
        messages = [text_entry(0, "user"), self.fixture.tool(1, "한" * 200, "c1"), self.fixture.tool(2, "한" * 200, "c2")]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture, params(min_bytes=600))
        self.assertEqual(tally.total.repeat_count, 1)
        tally, _ = run_requests(self.fixture, params(min_bytes=601))
        self.assertEqual(tally.total.repeat_count, 0)

    def test_saved_bytes_do_not_go_below_zero(self) -> None:
        messages = self.two_equal_results()
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture, params(stub_bytes=10_000))
        self.assertEqual(tally.total.repeat_count, 1)
        self.assertEqual(tally.total.saved_bytes, 0)

    def test_a_message_with_media_is_skipped(self) -> None:
        body = "i" * 3000
        messages = [text_entry(0, "user"), self.fixture.tool(1, body, "c1", media=True), self.fixture.tool(2, body, "c2", media=True)]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        self.assertEqual(tally.total.repeat_count, 0)

    def test_a_deleted_blob_is_counted_and_not_compared(self) -> None:
        body = "d" * 3000
        messages = [text_entry(0, "user"), self.fixture.tool(1, body, "c1"), self.fixture.tool(2, body, "c2", store=False)]
        self.fixture.request("k", messages)
        tally, skipped = run_requests(self.fixture)
        self.assertEqual(tally.total.repeat_count, 0)
        self.assertEqual(skipped.missing_blobs, 1)

    def test_a_blob_that_is_not_json_is_counted_as_unreadable(self) -> None:
        sha, size = self.fixture.blob(b"not json at all" * 100)
        messages = [text_entry(0, "user"), entry(1, "tool", sha, size)]
        self.fixture.request("k", messages)
        tally, skipped = run_requests(self.fixture)
        self.assertEqual(tally.total.repeat_count, 0)
        self.assertEqual(skipped.unreadable_blobs, 1)

    def test_a_blob_without_a_tool_result_block_is_counted_as_unreadable(self) -> None:
        sha, size = self.fixture.blob(json.dumps({"role": "tool", "content_blocks": [{"type": "text", "content": "x" * 2000}]}).encode())
        messages = [text_entry(0, "user"), entry(1, "tool", sha, size)]
        self.fixture.request("k", messages)
        _, skipped = run_requests(self.fixture)
        self.assertEqual(skipped.unreadable_blobs, 1)

    def test_only_tool_messages_are_compared(self) -> None:
        raw = message_blob("same" * 1000, "c1")
        sha, size = self.fixture.blob(raw)
        messages = [text_entry(0, "user"), entry(1, "assistant", sha, size), entry(2, "assistant", sha, size)]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        self.assertEqual(tally.total.repeat_count, 0)

    def test_requests_outside_the_window_are_not_counted(self) -> None:
        self.fixture.request("k", self.two_equal_results(), captured_at=BASE_TS)
        self.fixture.request("k", self.two_equal_results(("c3", "c4")), captured_at=BASE_TS + 7200)
        tally, skipped = run_requests(self.fixture, params(since=BASE_TS + 3600))
        self.assertEqual(tally.total.count, 1)
        self.assertEqual(skipped.outside_window, 1)
        tally, _ = run_requests(self.fixture, params(until=BASE_TS + 3600))
        self.assertEqual(tally.total.count, 1)

    def test_an_excluded_keeper_is_not_loaded(self) -> None:
        self.fixture.request("k", self.two_equal_results())
        self.fixture.request("noisy", self.two_equal_results(("c5", "c6")))
        tally, _ = run_requests(self.fixture, excluded=["noisy"])
        self.assertEqual(sorted(tally.by_keeper), ["k"])

    def test_buckets_are_split_by_keeper_and_by_hour(self) -> None:
        self.fixture.request("a", self.two_equal_results())
        self.fixture.request("b", self.two_equal_results(("c7", "c8")), captured_at=BASE_TS + 3600)
        tally, _ = run_requests(self.fixture)
        self.assertEqual(sorted(tally.by_keeper), ["a", "b"])
        self.assertEqual(sorted(tally.by_period), ["2026-11-06T21", "2026-11-06T22"])

    def test_per_request_shares_are_kept_for_quantiles(self) -> None:
        self.fixture.request("k", self.two_equal_results())
        self.fixture.request("k", [text_entry(0, "user"), self.fixture.tool(1, "u" * 3000, "c9")], captured_at=BASE_TS + 10)
        tally, _ = run_requests(self.fixture)
        self.assertEqual(len(tally.request_shares), 2)
        self.assertEqual(sorted(value == 0.0 for value in tally.request_shares), [False, True])

    def test_bad_lines_and_bad_entries_are_counted(self) -> None:
        folder = self.fixture.root / ".masc" / "keepers" / "k" / "provider-inputs" / "2026-11"
        folder.mkdir(parents=True)
        good = json.dumps({"captured_at": BASE_TS, "messages": [text_entry(0, "user"), {"role": "tool"}]})
        (folder / "06.jsonl").write_text("{broken\n" + json.dumps(["list"]) + "\n" + good + "\n", encoding="utf-8")
        _, skipped = run_requests(self.fixture)
        self.assertEqual(skipped.bad_lines, 2)
        self.assertEqual(skipped.bad_message_entries, 1)


class DistanceTest(TempCase):
    def repeats_of(self, tally: repeats.Tally) -> list[repeats.Repeat]:
        return [repeat for _, _, repeat in tally.repeats]

    def test_a_repeat_records_its_distance_to_the_first_result_and_to_the_previous_one(self) -> None:
        body = "d" * 3000
        messages = [
            text_entry(0, "user"),
            self.fixture.tool(1, body, "c1"),
            text_entry(2, "assistant", 40),
            self.fixture.tool(3, body, "c2"),
            text_entry(4, "assistant", 60),
            self.fixture.tool(5, body, "c3"),
        ]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        second, third = self.repeats_of(tally)
        between_third = 40 + int(messages[3]["artifact"]["bytes"]) + 60  # type: ignore[index]
        self.assertEqual((second.to_first, second.to_previous, second.bytes_between, second.rank, second.call_id), (2, 2, 40, 2, "c2"))
        self.assertEqual((third.to_first, third.to_previous, third.bytes_between, third.rank, third.call_id), (4, 2, between_third, 3, "c3"))

    def test_the_previous_result_is_the_nearest_equal_one_and_not_a_different_text(self) -> None:
        a, b = "a" * 3000, "b" * 3000
        messages = [
            text_entry(0, "user"),
            self.fixture.tool(1, a, "c1"),
            self.fixture.tool(2, b, "c2"),
            self.fixture.tool(3, a, "c3"),
            self.fixture.tool(4, b, "c4"),
            self.fixture.tool(5, a, "c5"),
        ]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        found = {repeat.call_id: repeat for repeat in self.repeats_of(tally)}
        self.assertEqual({call: (repeat.to_first, repeat.to_previous, repeat.rank) for call, repeat in found.items()},
                         {"c3": (2, 2, 2), "c4": (2, 2, 2), "c5": (4, 2, 3)})

    def test_two_results_of_one_message_are_zero_apart(self) -> None:
        self.fixture.request("k", [text_entry(0, "user"), self.fixture.batch(1, [("e" * 3000, "c1"), ("e" * 3000, "c2")])])
        tally, _ = run_requests(self.fixture)
        (only,) = self.repeats_of(tally)
        self.assertEqual((only.to_first, only.to_previous, only.bytes_between, only.rank), (0, 0, 0, 2))

    def test_a_repeat_in_the_next_message_has_nothing_between_it_and_the_first(self) -> None:
        self.fixture.request("k", [text_entry(0, "user"), self.fixture.tool(1, "n" * 3000, "c1"), self.fixture.tool(2, "n" * 3000, "c2")])
        tally, _ = run_requests(self.fixture)
        (only,) = self.repeats_of(tally)
        self.assertEqual((only.to_first, only.bytes_between), (1, 0))

    def test_distances_restart_with_each_turn(self) -> None:
        body = "t" * 3000
        messages = [
            self.fixture.user(0),
            self.fixture.tool(1, body, "c1"),
            self.fixture.user(2),
            self.fixture.tool(3, body, "c2"),
            text_entry(4, "assistant"),
            self.fixture.tool(5, body, "c3"),
        ]
        self.fixture.request("k", messages)
        tally, _ = run_requests(self.fixture)
        (only,) = self.repeats_of(tally)
        self.assertEqual((only.call_id, only.to_first, only.rank), ("c3", 2, 2))

    def test_the_answer_match_measures_the_same_distances(self) -> None:
        messages = [text_entry(0, "user"), self.fixture.tool(1, "a" * 3000 + "1", "call_a"), text_entry(2, "assistant", 30), self.fixture.tool(3, "a" * 3000 + "2", "call_b")]
        self.fixture.request("k", messages)
        self.fixture.ledger("06.jsonl", [call_row(keeper="k", session="trace-1", call_id=call_id, fingerprint="same", ts=BASE_TS + n) for n, call_id in enumerate(("call_a", "call_b"))])
        tally, _ = run_requests(self.fixture, answers=True)
        (only,) = self.repeats_of(tally)
        self.assertEqual((only.to_first, only.to_previous, only.bytes_between, only.rank), (2, 2, 30, 2))

    def test_a_call_that_several_requests_carry_is_counted_once_in_the_report(self) -> None:
        messages = [text_entry(0, "user"), self.fixture.tool(1, "m" * 3000, "c1"), self.fixture.tool(2, "m" * 3000, "c2")]
        self.fixture.request("k", messages, captured_at=BASE_TS)
        self.fixture.request("k", messages, captured_at=BASE_TS + 10)
        self.fixture.request("k", messages, captured_at=BASE_TS + 20, trace="trace-2")
        tally, _ = run_requests(self.fixture)
        block = repeats.report(tally, 3, "by_hour", ledger=False)
        self.assertEqual(block["repeat_count"], 3)
        self.assertEqual(block["distance"]["repeats"], 2)  # type: ignore[index]

    def test_a_repeat_that_cannot_be_named_is_counted_each_time(self) -> None:
        messages = [text_entry(0, "user"), self.fixture.tool(1, "m" * 3000, "c1"), self.fixture.tool(2, "m" * 3000, "c2")]
        self.fixture.request("k", messages, trace=None)
        self.fixture.request("k", messages, captured_at=BASE_TS + 10, trace=None)
        tally, _ = run_requests(self.fixture)
        self.assertEqual(repeats.report(tally, 3, "by_hour", ledger=False)["distance"]["repeats"], 2)  # type: ignore[index]

    def test_a_call_is_counted_once_per_keeper(self) -> None:
        messages = [text_entry(0, "user"), self.fixture.tool(1, "m" * 3000, "c1"), self.fixture.tool(2, "m" * 3000, "c2")]
        self.fixture.request("a", messages)
        self.fixture.request("b", messages)
        tally, _ = run_requests(self.fixture)
        block = repeats.report(tally, 3, "by_hour", ledger=False)["distance"]
        self.assertEqual(block["repeats"], 2)  # type: ignore[index]
        self.assertEqual(sorted(item["keeper"] for item in block["by_keeper"]), ["a", "b"])  # type: ignore[index]

    def test_a_repeat_without_a_call_id_is_in_the_report_each_time(self) -> None:
        messages = [text_entry(0, "user"), self.fixture.batch(1, [("u" * 3000, None), ("u" * 3000, None)])]
        self.fixture.request("k", messages)
        self.fixture.request("k", messages, captured_at=BASE_TS + 10)
        tally, _ = run_requests(self.fixture)
        self.assertEqual(repeats.report(tally, 3, "by_hour", ledger=False)["distance"]["repeats"], 2)  # type: ignore[index]

    def test_the_first_request_that_carries_a_call_gives_its_distance(self) -> None:
        early = [text_entry(0, "user"), self.fixture.tool(1, "m" * 3000, "c1"), self.fixture.tool(2, "m" * 3000, "c2")]
        late = [text_entry(0, "user"), self.fixture.tool(1, "m" * 3000, "c1"), text_entry(2, "assistant", 20), self.fixture.tool(3, "m" * 3000, "c2")]
        self.fixture.request("k", early, captured_at=BASE_TS)
        self.fixture.request("k", late, captured_at=BASE_TS + 10)
        tally, _ = run_requests(self.fixture)
        block = repeats.report(tally, 3, "by_hour", ledger=False)
        self.assertEqual(block["distance"]["to_first_messages"]["max"], 1)  # type: ignore[index]

    def test_the_report_gives_quantiles_per_keeper_ranked_by_repeat_bytes(self) -> None:
        tally = repeats.Tally()
        tally.repeats.extend(
            [
                ("small", "t1", repeats.Repeat(2000, 2, 2, 10, 2, "a")),
                ("big", "t2", repeats.Repeat(5000, 10, 2, 900, 2, "b")),
                ("big", "t2", repeats.Repeat(5000, 30, 2, 2900, 3, "c")),
            ]
        )
        block = repeats.report(tally, 1, "by_hour", ledger=False)["distance"]
        self.assertEqual(block["repeats"], 3)  # type: ignore[index]
        self.assertEqual(block["repeat_bytes"], 12000)  # type: ignore[index]
        self.assertEqual(block["to_first_messages"], {"p50": 10, "p90": 30, "p99": 30, "max": 30})  # type: ignore[index]
        self.assertEqual(block["bytes_between_first"]["max"], 2900)  # type: ignore[index]
        self.assertEqual(block["rank"], {"p50": 2, "p90": 3, "p99": 3, "max": 3})  # type: ignore[index]
        self.assertEqual([item["keeper"] for item in block["by_keeper"]], ["big"])  # type: ignore[index]
        self.assertEqual(block["by_keeper"][0]["to_first_messages"]["max"], 30)  # type: ignore[index]

    def test_an_empty_tally_has_zero_distances_and_the_ledger_has_none(self) -> None:
        block = repeats.report(repeats.Tally(), 3, "by_hour", ledger=False)["distance"]
        self.assertEqual(block["repeats"], 0)  # type: ignore[index]
        self.assertEqual(block["to_first_messages"], {"p50": 0, "p90": 0, "p99": 0, "max": 0})  # type: ignore[index]
        self.assertEqual(block["by_keeper"], [])  # type: ignore[index]
        self.assertNotIn("distance", repeats.report(repeats.Tally(), 3, "by_day", ledger=True))


class AnswerMatchTest(TempCase):
    def pair(self, first: str, second: str, ids: tuple[str, str] = ("call_a", "call_b")) -> list[dict[str, object]]:
        return [text_entry(0, "user"), self.fixture.tool(1, first, ids[0]), self.fixture.tool(2, second, ids[1])]

    def ledger_rows(self, *rows: tuple[str, str]) -> None:
        self.fixture.ledger("06.jsonl", [call_row(keeper="k", session="trace-1", call_id=call_id, fingerprint=fp, ts=BASE_TS + n) for n, (call_id, fp) in enumerate(rows)])

    def test_different_texts_with_the_same_answer_fingerprint_repeat(self) -> None:
        messages = self.pair("a" * 3000 + "1", "a" * 3000 + "2")
        self.fixture.request("k", messages)
        self.ledger_rows(("call_a", "answer-1"), ("call_b", "answer-1"))
        tally, skipped = run_requests(self.fixture, answers=True)
        self.assertEqual(tally.total.repeat_count, 1)
        self.assertEqual(skipped.unmatched_results, 0)
        text_tally, _ = run_requests(self.fixture)
        self.assertEqual(text_tally.total.repeat_count, 0)

    def test_equal_texts_with_different_answer_fingerprints_do_not_repeat(self) -> None:
        self.fixture.request("k", self.pair("b" * 3000, "b" * 3000))
        self.ledger_rows(("call_a", "answer-1"), ("call_b", "answer-2"))
        tally, _ = run_requests(self.fixture, answers=True)
        self.assertEqual(tally.total.repeat_count, 0)

    def test_a_result_without_a_ledger_row_is_counted_and_skipped(self) -> None:
        self.fixture.request("k", self.pair("c" * 3000, "c" * 3000))
        self.ledger_rows(("call_a", "answer-1"))
        tally, skipped = run_requests(self.fixture, answers=True)
        self.assertEqual(tally.total.repeat_count, 0)
        self.assertEqual(skipped.unmatched_results, 1)

    def test_the_join_is_by_keeper_and_session(self) -> None:
        self.fixture.request("k", self.pair("d" * 3000, "d" * 3000))
        self.fixture.ledger(
            "06.jsonl",
            [
                call_row(keeper="k", session="other-session", call_id="call_a", fingerprint="f"),
                call_row(keeper="other", session="trace-1", call_id="call_b", fingerprint="f"),
            ],
        )
        tally, skipped = run_requests(self.fixture, answers=True)
        self.assertEqual(skipped.unmatched_results, 2)
        self.assertEqual(tally.total.repeat_count, 0)

    def test_a_request_without_a_trace_matches_nothing(self) -> None:
        self.fixture.request("k", self.pair("e" * 3000, "e" * 3000), trace=None)
        self.ledger_rows(("call_a", "f"), ("call_b", "f"))
        tally, skipped = run_requests(self.fixture, answers=True)
        self.assertEqual(tally.total.repeat_count, 0)
        self.assertEqual(skipped.unmatched_results, 2)

    def test_the_call_id_can_come_from_the_block(self) -> None:
        body = {"role": "tool", "content_blocks": [{"type": "tool_result", "tool_use_id": "call_x", "content": "f" * 3000}]}
        sha, size = self.fixture.blob(json.dumps(body).encode("utf-8"))
        other = {"role": "tool", "content_blocks": [{"type": "tool_result", "tool_use_id": "call_y", "content": "g" * 3000}]}
        sha_other, size_other = self.fixture.blob(json.dumps(other).encode("utf-8"))
        self.fixture.request("k", [text_entry(0, "user"), entry(1, "tool", sha, size), entry(2, "tool", sha_other, size_other)])
        self.ledger_rows(("call_x", "same"), ("call_y", "same"))
        tally, _ = run_requests(self.fixture, answers=True)
        self.assertEqual(tally.total.repeat_count, 1)

    def test_a_block_is_joined_by_its_own_call_id_and_not_the_first_of_the_message(self) -> None:
        messages = [
            text_entry(0, "user"),
            self.fixture.batch(1, [("tiny", "call_s1"), ("p" * 3000, "call_b1")]),
            self.fixture.batch(2, [("tiny", "call_s2"), ("q" * 3000, "call_b2")]),
        ]
        self.fixture.request("k", messages)
        self.ledger_rows(("call_s1", "status"), ("call_b1", "page-1"), ("call_s2", "status"), ("call_b2", "page-2"))
        tally, skipped = run_requests(self.fixture, answers=True)
        self.assertEqual(tally.total.repeat_count, 0)
        self.assertEqual(skipped.unmatched_results, 0)
        self.fixture.ledger("06.jsonl", [call_row(keeper="k", session="trace-1", call_id="call_b2", fingerprint="page-1", ts=BASE_TS + 50)])
        tally, _ = run_requests(self.fixture, answers=True)
        self.assertEqual((tally.total.repeat_count, tally.total.repeat_bytes), (1, 3000))

    def test_a_blob_without_any_call_id_is_unmatched(self) -> None:
        body = {"role": "tool", "content_blocks": [{"type": "tool_result", "content": "h" * 3000}]}
        sha, size = self.fixture.blob(json.dumps(body).encode("utf-8"))
        self.fixture.request("k", [text_entry(0, "user"), entry(1, "tool", sha, size)])
        _, skipped = run_requests(self.fixture, answers=True)
        self.assertEqual(skipped.unmatched_results, 1)

    def test_an_earlier_turn_repeat_by_answer(self) -> None:
        messages = [
            self.fixture.user(0),
            self.fixture.tool(1, "i" * 3000 + "1", "call_a"),
            self.fixture.user(2),
            self.fixture.tool(3, "i" * 3000 + "2", "call_b"),
        ]
        self.fixture.request("k", messages)
        self.ledger_rows(("call_a", "same"), ("call_b", "same"))
        tally, _ = run_requests(self.fixture, answers=True)
        self.assertEqual((tally.total.repeat_count, tally.total.earlier_count), (0, 1))

    def test_small_results_are_ignored_even_when_the_answers_match(self) -> None:
        self.fixture.request("k", self.pair("j" * 100, "j" * 100))
        self.ledger_rows(("call_a", "same"), ("call_b", "same"))
        tally, skipped = run_requests(self.fixture, answers=True)
        self.assertEqual(tally.total.repeat_count, 0)
        self.assertEqual(skipped.unmatched_results, 0)

    def test_main_compares_texts_by_default_and_loads_the_ledger_for_the_answer_match(self) -> None:
        self.fixture.request("k", self.pair("m" * 3000 + "1", "m" * 3000 + "2"))
        self.ledger_rows(("call_a", "same"), ("call_b", "same"))
        out = self.fixture.root / "out.json"
        argv = ["--base-path", str(self.fixture.root), "--from-date", "2026-11-06", "--to-date", "2026-11-06", "--view", "requests", "--json-out", str(out)]
        self.assertEqual(repeats.main(argv), 0)
        result = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(result["params"]["match"], "text")
        self.assertEqual(result["requests"]["repeat_count"], 0)
        self.assertNotIn("ledger", result)
        self.assertEqual(repeats.main([*argv, "--match", "answer"]), 0)
        result = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(result["params"]["match"], "answer")
        self.assertEqual(result["requests"]["repeat_count"], 1)
        self.assertNotIn("ledger", result)


class LedgerViewTest(TempCase):
    def test_equal_fingerprints_in_one_turn_are_repeats(self) -> None:
        self.fixture.ledger("06.jsonl", [call_row(ts=BASE_TS), call_row(ts=BASE_TS + 1), call_row(ts=BASE_TS + 2)])
        tally, _ = run_ledger(self.fixture)
        self.assertEqual(tally.total.count, 3)
        self.assertEqual(tally.total.repeat_count, 2)
        self.assertEqual(tally.total.repeat_bytes, 2 * CALL_SIZE)
        self.assertEqual(tally.total.saved_bytes, 2 * (CALL_SIZE - 600))

    def test_the_same_fingerprint_in_another_turn_or_session_is_not_a_repeat(self) -> None:
        self.fixture.ledger(
            "06.jsonl",
            [call_row(turn=1), call_row(turn=2, ts=BASE_TS + 1), call_row(session="s2", ts=BASE_TS + 2), call_row(keeper="other", ts=BASE_TS + 3)],
        )
        tally, _ = run_ledger(self.fixture)
        self.assertEqual(tally.total.repeat_count, 0)

    def test_the_tool_does_not_matter_only_the_output_does(self) -> None:
        self.fixture.ledger("06.jsonl", [call_row(tool="A"), call_row(tool="B", ts=BASE_TS + 1)])
        tally, _ = run_ledger(self.fixture)
        self.assertEqual(tally.total.repeat_count, 1)
        self.assertEqual(tally.by_tool["B"].repeat_count, 1)
        self.assertEqual(tally.by_tool["A"].repeat_count, 0)

    def test_rows_are_ordered_by_time_not_by_file_position(self) -> None:
        self.fixture.ledger("06.jsonl", [call_row(tool="late", ts=BASE_TS + 5), call_row(tool="early", ts=BASE_TS)])
        tally, _ = run_ledger(self.fixture)
        self.assertEqual(tally.by_tool["late"].repeat_count, 1)
        self.assertEqual(tally.by_tool["early"].repeat_count, 0)

    def test_small_results_are_in_the_total_but_never_repeat(self) -> None:
        self.fixture.ledger("06.jsonl", [call_row(size=100), call_row(size=100, ts=BASE_TS + 1)])
        tally, _ = run_ledger(self.fixture)
        self.assertEqual(tally.total.total_bytes, 200)
        self.assertEqual(tally.total.repeat_count, 0)

    def test_a_small_result_is_not_a_repeat_of_a_big_one(self) -> None:
        self.fixture.ledger("06.jsonl", [call_row(size=CALL_SIZE), call_row(size=100, ts=BASE_TS + 1)])
        tally, _ = run_ledger(self.fixture)
        self.assertEqual(tally.total.repeat_count, 0)

    def test_a_ledger_result_of_exactly_min_bytes_counts(self) -> None:
        self.fixture.ledger("06.jsonl", [call_row(size=1024), call_row(size=1024, ts=BASE_TS + 1)])
        tally, _ = run_ledger(self.fixture, params(min_bytes=1024))
        self.assertEqual(tally.total.repeat_count, 1)

    def test_a_small_result_is_not_the_first_of_a_big_one(self) -> None:
        self.fixture.ledger("06.jsonl", [call_row(size=100), call_row(size=CALL_SIZE, ts=BASE_TS + 1)])
        tally, _ = run_ledger(self.fixture)
        self.assertEqual(tally.total.repeat_count, 0)

    def test_segments_and_the_active_file_are_all_read(self) -> None:
        self.fixture.ledger("06.001.jsonl", [call_row(ts=BASE_TS)])
        self.fixture.ledger("06.jsonl", [call_row(ts=BASE_TS + 1)])
        tally, _ = run_ledger(self.fixture)
        self.assertEqual(tally.total.repeat_count, 1)

    def test_files_outside_the_day_range_and_other_names_are_not_read(self) -> None:
        self.fixture.ledger("06.jsonl", [call_row()])
        self.fixture.ledger("notes.jsonl", [call_row(ts=BASE_TS + 1)])
        self.fixture.ledger("01.jsonl", [call_row(ts=BASE_TS + 2)])
        skipped = repeats.Skipped()
        ledger = repeats.load_ledger(self.fixture.root, "2026-11-05", "2026-11-06", [], skipped)
        self.assertEqual(sum(len(calls) for calls in ledger.groups.values()), 1)

    def test_the_window_includes_since_and_excludes_until(self) -> None:
        self.fixture.ledger("06.jsonl", [call_row(ts=BASE_TS, fingerprint="a"), call_row(ts=BASE_TS + 10, fingerprint="b")])
        tally, _ = run_ledger(self.fixture, params(since=BASE_TS, until=BASE_TS + 10))
        self.assertEqual(tally.total.count, 1)
        tally, _ = run_ledger(self.fixture, params(since=BASE_TS + 10))
        self.assertEqual(tally.total.count, 1)

    def test_rows_before_since_still_serve_as_the_first_occurrence(self) -> None:
        self.fixture.ledger("06.jsonl", [call_row(ts=BASE_TS), call_row(ts=BASE_TS + 100)])
        tally, skipped = run_ledger(self.fixture, params(since=BASE_TS + 50))
        self.assertEqual(tally.total.count, 1)
        self.assertEqual(tally.total.repeat_count, 1)
        self.assertEqual(skipped.outside_window, 1)

    def test_other_record_kinds_and_unkeyed_rows_are_counted(self) -> None:
        broken = call_row()
        del broken["output_fingerprint"]
        self.fixture.ledger("06.jsonl", [call_row(kind="composition_run"), broken, "{broken", json.dumps([1]), call_row()])
        tally, skipped = run_ledger(self.fixture)
        self.assertEqual(tally.total.count, 1)
        self.assertEqual(skipped.other_records, 1)
        self.assertEqual(skipped.unkeyed_calls, 1)
        self.assertEqual(skipped.bad_lines, 2)

    def test_a_boolean_turn_id_is_not_a_turn(self) -> None:
        row = call_row()
        row["keeper_turn_id"] = True
        self.fixture.ledger("06.jsonl", [row])
        _, skipped = run_ledger(self.fixture)
        self.assertEqual(skipped.unkeyed_calls, 1)

    def test_an_excluded_keeper_is_not_loaded(self) -> None:
        self.fixture.ledger("06.jsonl", [call_row(keeper="noisy"), call_row(keeper="noisy", ts=BASE_TS + 1), call_row()])
        tally, _ = run_ledger(self.fixture, excluded=["noisy"])
        self.assertEqual(tally.total.count, 1)

    def test_buckets_are_split_by_keeper_tool_and_day(self) -> None:
        self.fixture.ledger("06.jsonl", [call_row(keeper="a", tool="T1"), call_row(keeper="b", tool="T2", fingerprint="f2", ts=BASE_TS + 86400)])
        tally, _ = run_ledger(self.fixture)
        self.assertEqual(sorted(tally.by_keeper), ["a", "b"])
        self.assertEqual(sorted(tally.by_tool), ["T1", "T2"])
        self.assertEqual(sorted(tally.by_period), ["2026-11-06", "2026-11-07"])


class ReportTest(unittest.TestCase):
    def test_shares_and_ranking(self) -> None:
        tally = repeats.Tally()
        tally.add("small", None, "p", 1000, [], 600)
        tally.add("big", None, "p", 1000, [800], 600)
        block = repeats.report(tally, 1, "by_hour", ledger=False)
        self.assertEqual(block["saved_bytes"], 200)
        self.assertEqual(block["saved_share"], 0.1)
        self.assertEqual(block["repeat_share"], 0.4)
        self.assertEqual([item["keeper"] for item in block["by_keeper"]], ["big"])  # type: ignore[union-attr]
        self.assertNotIn("by_tool", block)

    def test_an_empty_tally_has_zero_shares(self) -> None:
        ledger = repeats.report(repeats.Tally(), 3, "by_day", ledger=True)
        self.assertEqual(ledger["saved_share"], 0.0)
        self.assertEqual(ledger["by_tool"], [])
        self.assertNotIn("per_request_saved_share", ledger)
        requests = repeats.report(repeats.Tally(), 3, "by_hour", ledger=False)
        self.assertEqual(requests["per_request_saved_share"], {"p50": 0.0, "p90": 0.0, "p99": 0.0, "max": 0.0})
        self.assertEqual(requests["requests_with_repeat"], 0)

    def test_earlier_turn_repeats_are_reported_for_requests_and_not_for_the_ledger(self) -> None:
        tally = repeats.Tally()
        tally.add("k", None, "p", 1000, [], 600, [250])
        requests = repeats.report(tally, 1, "by_hour", ledger=False)
        self.assertEqual(requests["earlier_turn_repeat_bytes"], 250)
        self.assertEqual(requests["earlier_turn_repeat_share"], 0.25)
        self.assertEqual(requests["by_keeper"][0]["earlier_turn_repeat_count"], 1)  # type: ignore[index]
        self.assertEqual(requests["by_hour"][0]["earlier_turn_repeat_bytes"], 250)  # type: ignore[index]
        ledger = repeats.report(tally, 1, "by_day", ledger=True)
        self.assertNotIn("earlier_turn_repeat_bytes", ledger)
        self.assertNotIn("earlier_turn_repeat_bytes", ledger["by_keeper"][0])  # type: ignore[index]

    def test_request_quantiles_and_the_count_of_requests_with_a_repeat(self) -> None:
        tally = repeats.Tally(request_shares=[1.0, 0.0, 0.5, 0.0])
        block = repeats.report(tally, 1, "by_hour", ledger=False)
        self.assertEqual(block["requests_with_repeat"], 2)
        self.assertEqual(block["per_request_saved_share"], {"p50": 0.0, "p90": 1.0, "p99": 1.0, "max": 1.0})

    def test_ties_are_ranked_by_name(self) -> None:
        tally = repeats.Tally()
        for name in ("b", "a"):
            tally.add(name, None, "p", 1000, [800], 600)
        block = repeats.report(tally, 2, "by_hour", ledger=False)
        self.assertEqual([item["keeper"] for item in block["by_keeper"]], ["a", "b"])  # type: ignore[union-attr]


class MainTest(TempCase):
    def run_main(self, *extra: str) -> tuple[int, dict[str, object]]:
        out = self.fixture.root / "out.json"
        code = repeats.main(["--base-path", str(self.fixture.root), "--from-date", "2026-11-06", "--to-date", "2026-11-07", "--json-out", str(out), *extra])
        return code, json.loads(out.read_text(encoding="utf-8"))

    def test_both_views_are_written(self) -> None:
        body = "x" * 3000
        self.fixture.request("k", [text_entry(0, "user"), self.fixture.tool(1, body, "c1"), self.fixture.tool(2, body, "c2")])
        self.fixture.ledger("06.jsonl", [call_row(), call_row(ts=BASE_TS + 1)])
        code, result = self.run_main("--match", "text")
        self.assertEqual(code, 0)
        self.assertEqual(result["requests"]["repeat_count"], 1)  # type: ignore[index]
        self.assertEqual(result["ledger"]["repeat_count"], 1)  # type: ignore[index]
        self.assertEqual(result["params"]["stub_bytes"], repeats.DEFAULT_STUB_BYTES)  # type: ignore[index]
        self.assertEqual(result["params"]["match"], "text")  # type: ignore[index]
        self.assertIn("by_tool", result["ledger"])  # type: ignore[operator]
        self.assertEqual(result["skipped"]["missing_blobs"], 0)  # type: ignore[index]

    def test_a_single_view_leaves_the_other_out(self) -> None:
        self.fixture.ledger("06.jsonl", [call_row()])
        _, result = self.run_main("--view", "ledger")
        self.assertIn("ledger", result)
        self.assertNotIn("requests", result)

    def test_bad_arguments_exit_with_an_error(self) -> None:
        base = ["--base-path", str(self.fixture.root)]
        days = ["--from-date", "2026-11-06", "--to-date", "2026-11-07"]
        for argv in (
            [*base, *days, "--since", "yesterday"],
            [*base, *days, "--min-bytes", "-1"],
            [*base, *days, "--top", "0"],
            [*base, "--from-date", "11-06", "--to-date", "2026-11-07"],
        ):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                repeats.main(argv)
            self.assertEqual(raised.exception.code, 2)

    def test_without_json_out_the_report_goes_to_stdout(self) -> None:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = repeats.main(["--base-path", str(self.fixture.root), "--from-date", "2026-11-06", "--to-date", "2026-11-07", "--view", "ledger"])
        self.assertEqual(code, 0)
        self.assertIn('"ledger"', buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
