"""Checks the arithmetic of measure_tool_result_carry.py on small synthetic stores.

Run: python3 -m unittest discover -s docs/evidence/tool-result-carry-2026-11
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_tool_result_carry as carry_tool  # noqa: E402

DAY_1 = "2026-11-01"
DAY_2 = "2026-11-02"
OUTSIDE_DAY = "2026-10-20"
STORED_COPY_FIELD = ',"text_content":'
Ref = tuple[str, int]


def compact(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def size_of(value: object) -> int:
    return len(compact(value).encode("utf-8"))


def result_block(use_id: object, content: object, **extra: object) -> dict[str, object]:
    return {"type": "tool_result", "tool_use_id": use_id, "content": content, "is_error": False, **extra}


def tool_message(*blocks: dict[str, object], call_id: str = "call-1") -> dict[str, object]:
    return {"role": "tool", "origin": "conversation", "content_blocks": list(blocks), "tool_call_id": call_id}


def stub_text(original: int, mime: str = "text/plain", answer: str | None = None) -> str:
    semantic = f" answer_sha256={answer}" if answer else ""
    return f'[masc:blob sha256={"a" * 64} bytes={original} mime={mime}{semantic} preview="head"]'


def listing(ref: Ref, role: str = "tool", recorded: int | None = None) -> dict[str, object]:
    sha, size = ref
    reference = f'[masc:blob sha256={sha} bytes={size} mime=application/vnd.masc.provider-input-message+json preview=""]'
    return {
        "role": role,
        "artifact": {"bytes": size if recorded is None else recorded, "content_ref": reference},
        "media": [],
    }


def request(*messages: dict[str, object], body: int = 0, stored: bool = True) -> dict[str, object]:
    row: dict[str, object] = {"trace_id": "t", "wire": {"body_bytes": body}, "messages": list(messages)}
    if stored:
        row["tool_schemas"] = []
    return row


def ledger_row(tool: str, use_id: str, record_kind: str = "tool_call") -> dict[str, object]:
    return {"record_kind": record_kind, "tool": tool, "tool_use_id": use_id}


class Store:
    """A temporary base path holding `.masc` with the three stores."""

    def __init__(self, base: pathlib.Path) -> None:
        self.base = base

    def blob(self, message: object) -> Ref:
        return self.raw_blob(compact(message).encode("utf-8"))

    def raw_blob(self, data: bytes) -> Ref:
        sha = hashlib.sha256(data).hexdigest()
        path = self.base / ".masc" / "tool_blobs" / sha[:2] / sha
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return sha, len(data)

    def requests(
        self, keeper: str, day: str, rows: list[dict[str, object]], filename: str | None = None
    ) -> None:
        name = filename or f"{day[8:]}.jsonl"
        path = self.base / ".masc" / "keepers" / keeper / "provider-inputs" / day[:7] / name
        self._write(path, rows, ())

    def ledger(self, day: str, rows: list[dict[str, object]], raw: tuple[str, ...] = ()) -> None:
        path = self.base / ".masc" / "tool_calls" / day[:7] / f"{day[8:]}.jsonl"
        self._write(path, rows, raw)

    @staticmethod
    def _write(path: pathlib.Path, rows: list[dict[str, object]], raw: tuple[str, ...]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        lines = [json.dumps(row) for row in rows] + list(raw)
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")


class TempStoreCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.store = Store(pathlib.Path(self._tmp.name))
        self.masc_dir = self.store.base / ".masc"

    def read(self, from_day: str = DAY_1, to_day: str = DAY_2) -> tuple[carry_tool.Carried, carry_tool.Skipped]:
        skipped = carry_tool.Skipped()
        return carry_tool.read_carried(self.masc_dir, from_day, to_day, skipped), skipped

    def run_all(
        self, from_day: str = DAY_1, to_day: str = DAY_2
    ) -> tuple[carry_tool.Carried, carry_tool.Summary, carry_tool.Skipped]:
        carried, skipped = self.read(from_day, to_day)
        names = carry_tool.read_tool_names(self.masc_dir, from_day, to_day, skipped)
        return carried, carry_tool.summarize(self.masc_dir, carried, names, skipped), skipped


class ReadingTest(TempStoreCase):
    def test_a_message_is_carried_once_for_each_request_that_lists_it(self) -> None:
        a = self.store.blob(tool_message(result_block("u1", "x")))
        b = self.store.blob(tool_message(result_block("u2", "y"), call_id="call-2"))
        self.store.requests("alpha", DAY_1, [request(listing(a)), request(listing(a), listing(b)), request(listing(b))])
        carried, _ = self.read()
        self.assertEqual(carried.requests, 3)
        self.assertEqual(dict(carried.carriers), {a[0]: 2, b[0]: 2})
        self.assertEqual(carried.recorded_bytes, {a[0]: a[1], b[0]: b[1]})

    def test_a_message_listed_twice_in_one_request_is_carried_twice(self) -> None:
        a = self.store.blob(tool_message(result_block("u1", "x")))
        self.store.requests("alpha", DAY_1, [request(listing(a), listing(a))])
        carried, _ = self.read()
        self.assertEqual(dict(carried.carriers), {a[0]: 2})

    def test_a_row_without_a_tool_schemas_list_is_not_a_stored_request(self) -> None:
        a = self.store.blob(tool_message(result_block("u1", "x")))
        self.store.requests("alpha", DAY_1, [request(listing(a), body=900, stored=False), request(listing(a), body=100)])
        carried, _ = self.read()
        self.assertEqual((carried.requests, carried.body_bytes), (1, 100))
        self.assertEqual(dict(carried.carriers), {a[0]: 1})

    def test_body_bytes_add_up_over_stored_requests(self) -> None:
        self.store.requests("alpha", DAY_1, [request(body=100), request(body=250)])
        self.store.requests("beta", DAY_2, [request(body=7)])
        carried, _ = self.read()
        self.assertEqual((carried.requests, carried.body_bytes), (3, 357))

    def test_only_days_inside_the_window_count(self) -> None:
        a = self.store.blob(tool_message(result_block("u1", "x")))
        for day in (OUTSIDE_DAY, DAY_1, DAY_2, "2026-11-09"):
            self.store.requests("alpha", day, [request(listing(a))])
        carried, _ = self.read(DAY_1, DAY_1)
        self.assertEqual(carried.requests, 1)
        carried, _ = self.read(DAY_1, DAY_2)
        self.assertEqual(carried.requests, 2)

    def test_a_file_whose_name_is_not_a_day_is_reported(self) -> None:
        self.store.requests("alpha", DAY_1, [request()], filename="notes.jsonl")
        carried, skipped = self.read()
        self.assertEqual((carried.requests, skipped.unplaced_files), (0, 1))

    def test_messages_of_other_roles_are_not_tool_messages(self) -> None:
        a = self.store.blob(tool_message(result_block("u1", "x")))
        self.store.requests("alpha", DAY_1, [request(listing(a, role="assistant"), listing(a, role="user"))])
        carried, skipped = self.read()
        self.assertEqual((carried.requests, len(carried.carriers), skipped.bad_message_entries), (1, 0, 0))

    def test_a_tool_message_without_a_reference_is_reported(self) -> None:
        broken = {"role": "tool", "artifact": {"bytes": 5, "content_ref": "no reference"}}
        no_size = {"role": "tool", "artifact": {"content_ref": f"sha256={'b' * 64}"}}
        self.store.requests("alpha", DAY_1, [request(broken, no_size)])
        carried, skipped = self.read()
        self.assertEqual((len(carried.carriers), skipped.bad_message_entries), (0, 2))

    def test_a_boolean_size_is_not_a_size(self) -> None:
        flagged = listing(("e" * 64, 5))
        flagged["artifact"] = {"bytes": True, "content_ref": f"sha256={'e' * 64}"}
        self.store.requests("alpha", DAY_1, [request(flagged)])
        carried, skipped = self.read()
        self.assertEqual((len(carried.carriers), skipped.bad_message_entries), (0, 1))

    def test_the_ledger_pairs_each_tool_use_id_with_its_tool(self) -> None:
        self.store.ledger(DAY_1, [ledger_row("Execute", "u1"), ledger_row("Read", "u2"), ledger_row("Edit", "u3", "other")])
        skipped = carry_tool.Skipped()
        names = carry_tool.read_tool_names(self.masc_dir, DAY_1, DAY_2, skipped)
        self.assertEqual(names, {"u1": "Execute", "u2": "Read"})
        self.assertEqual(skipped.unidentified_calls, 0)

    def test_a_ledger_row_without_an_id_is_reported(self) -> None:
        self.store.ledger(DAY_1, [{"record_kind": "tool_call", "tool": "Execute"}, {"record_kind": "tool_call", "tool_use_id": "u9"}])
        skipped = carry_tool.Skipped()
        self.assertEqual(carry_tool.read_tool_names(self.masc_dir, DAY_1, DAY_2, skipped), {})
        self.assertEqual(skipped.unidentified_calls, 2)

    def test_ledger_days_outside_the_window_are_left_out(self) -> None:
        self.store.ledger(OUTSIDE_DAY, [ledger_row("Execute", "old")])
        self.store.ledger(DAY_2, [ledger_row("Read", "new")])
        names = carry_tool.read_tool_names(self.masc_dir, DAY_1, DAY_2, carry_tool.Skipped())
        self.assertEqual(names, {"new": "Read"})

    def test_lines_that_are_not_json_objects_are_counted(self) -> None:
        self.store.ledger(DAY_1, [ledger_row("Execute", "u1")], raw=("{not json", "[1, 2]", ""))
        skipped = carry_tool.Skipped()
        self.assertEqual(carry_tool.read_tool_names(self.masc_dir, DAY_1, DAY_2, skipped), {"u1": "Execute"})
        self.assertEqual(skipped.bad_lines, 2)


class BlobTest(unittest.TestCase):
    @staticmethod
    def inspect(message: object) -> tuple[list[carry_tool.Result], carry_tool.Skipped, int]:
        raw = compact(message).encode("utf-8")
        skipped = carry_tool.Skipped()
        return carry_tool.inspect_blob(raw, skipped), skipped, len(raw)

    def test_a_plain_result_is_the_whole_message(self) -> None:
        results, skipped, length = self.inspect(tool_message(result_block("u1", "hello")))
        self.assertEqual(results, [carry_tool.Result("u1", length, 0, None)])
        self.assertEqual(skipped.reserialization_mismatch, 0)

    def test_the_stored_copy_is_the_text_content_field_as_written(self) -> None:
        text = '내용 {"a": 1}\n'
        block = result_block("u1", [{"type": "text", "text": text}], text_content=text)
        results, _, length = self.inspect(tool_message(block))
        copy = len(STORED_COPY_FIELD) + size_of(text)
        self.assertEqual(results[0].stored_copy_bytes, copy)
        without_copy = {name: value for name, value in block.items() if name != "text_content"}
        self.assertEqual(results[0].bytes - copy, size_of(tool_message(without_copy)))
        self.assertEqual(results[0].bytes, length)

    def test_a_block_whose_content_is_a_string_has_no_stored_copy(self) -> None:
        results, _, _ = self.inspect(tool_message(result_block("u1", "flat", text_content=5)))
        self.assertEqual(results[0].stored_copy_bytes, 0)

    def test_a_stub_is_read_from_string_content_and_from_the_first_text_part(self) -> None:
        in_string, _, _ = self.inspect(tool_message(result_block("u1", stub_text(941))))
        in_part, _, _ = self.inspect(
            tool_message(result_block("u2", [{"type": "image", "data": "x"}, {"type": "text", "text": stub_text(5000)}]))
        )
        self.assertEqual(in_string[0].stub_original_bytes, 941)
        self.assertEqual(in_part[0].stub_original_bytes, 5000)

    def test_a_marker_with_an_answer_fingerprint_or_a_manifest_mime_is_a_stub(self) -> None:
        with_answer, _, _ = self.inspect(tool_message(result_block("u1", stub_text(7, answer="b" * 64))))
        manifest, _, _ = self.inspect(
            tool_message(result_block("u2", stub_text(8, mime="application/vnd.masc.tool-result-manifest+json")))
        )
        self.assertEqual((with_answer[0].stub_original_bytes, manifest[0].stub_original_bytes), (7, 8))

    def test_text_that_only_mentions_the_marker_is_not_a_stub(self) -> None:
        mention, _, _ = self.inspect(tool_message(result_block("u1", "see " + stub_text(10))))
        short_hash, _, _ = self.inspect(tool_message(result_block("u2", "[masc:blob sha256=ab bytes=3 mime=text/plain preview=\"\"]")))
        not_text, _, _ = self.inspect(tool_message(result_block("u3", 5)))
        self.assertEqual([r[0].stub_original_bytes for r in (mention, short_hash, not_text)], [None, None, None])

    def test_the_results_of_a_message_add_up_to_its_stored_size(self) -> None:
        message = tool_message(result_block("u1", "aaa"), result_block("u2", "bbbbbb"), result_block("u3", "c"))
        results, _, length = self.inspect(message)
        self.assertEqual([r.tool_use_id for r in results], ["u1", "u2", "u3"])
        self.assertEqual(sum(r.bytes for r in results), length)

    def test_the_bytes_around_the_blocks_go_to_the_first_result(self) -> None:
        first, second = result_block("u1", "a"), result_block("u2", "bb")
        results, _, length = self.inspect(tool_message(first, second))
        self.assertEqual(results[1].bytes, size_of(second))
        self.assertEqual(results[0].bytes, length - size_of(second))
        self.assertGreater(results[0].bytes, size_of(first))

    def test_blocks_that_are_not_tool_results_are_not_results(self) -> None:
        message = tool_message({"type": "text", "text": "note"}, result_block("u1", "x"), "stray")  # type: ignore[arg-type]
        results, _, length = self.inspect(message)
        self.assertEqual([r.tool_use_id for r in results], ["u1"])
        self.assertEqual(results[0].bytes, length)

    def test_a_message_without_a_tool_result_is_one_result_without_an_id(self) -> None:
        for message in ({"role": "tool", "content_blocks": [{"type": "text", "text": "x"}]}, {"role": "tool"}):
            results, _, length = self.inspect(message)
            self.assertEqual(results, [carry_tool.Result(None, length, 0, None)])

    def test_an_id_that_is_not_a_string_is_no_id(self) -> None:
        results, _, _ = self.inspect(tool_message(result_block(5, "x")))
        self.assertIsNone(results[0].tool_use_id)

    def test_a_blob_that_is_not_a_json_object_is_refused(self) -> None:
        for raw in (b"not json", b"[1, 2]", b'{"content_blocks": "\xff"}'):
            with self.assertRaises(ValueError):
                carry_tool.inspect_blob(raw, carry_tool.Skipped())

    def test_a_pretty_printed_blob_is_counted_as_a_reserialization_mismatch(self) -> None:
        raw = json.dumps(tool_message(result_block("u1", "x")), indent=2).encode("utf-8")
        skipped = carry_tool.Skipped()
        self.assertEqual(len(carry_tool.inspect_blob(raw, skipped)), 1)
        self.assertEqual(skipped.reserialization_mismatch, 1)

    def test_a_later_result_with_non_ascii_text_is_counted_in_utf8_bytes(self) -> None:
        later = result_block("u2", "한글 결과")
        results, _, _ = self.inspect(tool_message(result_block("u1", "a"), later))
        self.assertEqual(results[1].bytes, size_of(later))
        self.assertGreater(size_of(later), len(compact(later)))

    def test_non_ascii_text_is_counted_in_utf8_bytes(self) -> None:
        results, skipped, length = self.inspect(tool_message(result_block("u1", "한글")))
        self.assertEqual(results[0].bytes, length)
        self.assertGreater(length, len(compact(tool_message(result_block("u1", "한글")))))
        self.assertEqual(skipped.reserialization_mismatch, 0)


class SummaryTest(TempStoreCase):
    def test_carried_bytes_are_result_bytes_times_requests(self) -> None:
        ref = self.store.blob(tool_message(result_block("u1", "x" * 40)))
        self.store.requests("alpha", DAY_1, [request(listing(ref)) for _ in range(3)])
        self.store.ledger(DAY_1, [ledger_row("Execute", "u1")])
        carried, summary, skipped = self.run_all()
        self.assertEqual(summary.messages, 1)
        (row,) = summary.rows
        self.assertEqual((row.tool, row.results), ("Execute", 1))
        self.assertEqual((row.stored_bytes, row.carried_bytes), (ref[1], 3 * ref[1]))
        self.assertEqual(carried.requests, 3)
        self.assertEqual(skipped, carry_tool.Skipped())

    def test_rows_run_from_the_most_carried_tool_to_the_least_then_by_name(self) -> None:
        big = self.store.blob(tool_message(result_block("u1", "x" * 300)))
        small_a = self.store.blob(tool_message(result_block("u2", "y"), call_id="c2"))
        small_b = self.store.blob(tool_message(result_block("u3", "z"), call_id="c3"))
        self.store.requests("alpha", DAY_1, [request(listing(big), listing(small_a), listing(small_b))])
        self.store.ledger(DAY_1, [ledger_row("Zed", "u1"), ledger_row("Beta", "u2"), ledger_row("Alpha", "u3")])
        _, summary, _ = self.run_all()
        self.assertEqual([row.tool for row in summary.rows], ["Zed", "Alpha", "Beta"])

    def test_a_result_the_ledger_does_not_know_is_unmapped(self) -> None:
        ref = self.store.blob(tool_message(result_block("nobody", "x")))
        self.store.requests("alpha", DAY_1, [request(listing(ref))])
        self.store.ledger(DAY_1, [ledger_row("Execute", "u1")])
        _, summary, _ = self.run_all()
        self.assertEqual([row.tool for row in summary.rows], [carry_tool.UNMAPPED])

    def test_stub_bytes_and_original_bytes_are_totalled_per_tool(self) -> None:
        stub = self.store.blob(tool_message(result_block("u1", stub_text(941))))
        live = self.store.blob(tool_message(result_block("u2", "x" * 50), call_id="c2"))
        self.store.requests("alpha", DAY_1, [request(listing(stub), listing(live)), request(listing(stub))])
        self.store.ledger(DAY_1, [ledger_row("Execute", "u1"), ledger_row("Execute", "u2")])
        _, summary, _ = self.run_all()
        (row,) = summary.rows
        self.assertEqual((row.results, row.stub_results), (2, 1))
        self.assertEqual((row.stub_bytes, row.stub_carried_bytes, row.stub_original_bytes), (stub[1], 2 * stub[1], 941))
        self.assertEqual(row.carried_bytes, 2 * stub[1] + live[1])
        self.assertEqual((summary.stub_results, summary.stub_carried_bytes), (1, 2 * stub[1]))

    def test_the_stored_copy_is_totalled_per_tool_and_weighted_by_requests(self) -> None:
        text = "p" * 100
        typed = self.store.blob(tool_message(result_block("u1", [{"type": "text", "text": text}], text_content=text)))
        self.store.requests("alpha", DAY_1, [request(listing(typed)), request(listing(typed))])
        self.store.ledger(DAY_1, [ledger_row("masc_dos_press", "u1")])
        _, summary, _ = self.run_all()
        (row,) = summary.rows
        copy = len(STORED_COPY_FIELD) + size_of(text)
        self.assertEqual(row.stored_copy_carried_bytes, 2 * copy)
        self.assertEqual(summary.stored_copy_carried_bytes, 2 * copy)

    def test_a_message_with_two_tools_splits_its_bytes_between_them(self) -> None:
        first, second = result_block("u1", "a" * 30), result_block("u2", "b" * 10)
        ref = self.store.blob(tool_message(first, second))
        self.store.requests("alpha", DAY_1, [request(listing(ref)), request(listing(ref))])
        self.store.ledger(DAY_1, [ledger_row("Read", "u1"), ledger_row("Execute", "u2")])
        _, summary, _ = self.run_all()
        by_tool = {row.tool: row for row in summary.rows}
        self.assertEqual(by_tool["Execute"].stored_bytes, size_of(second))
        self.assertEqual(by_tool["Read"].stored_bytes, ref[1] - size_of(second))
        self.assertEqual(sum(row.carried_bytes for row in summary.rows), 2 * ref[1])

    def test_a_missing_blob_is_counted_and_left_out(self) -> None:
        present = self.store.blob(tool_message(result_block("u1", "x")))
        self.store.requests("alpha", DAY_1, [request(listing(present), listing(("c" * 64, 10)))])
        self.store.ledger(DAY_1, [ledger_row("Execute", "u1")])
        _, summary, skipped = self.run_all()
        self.assertEqual((summary.messages, skipped.unreadable_blobs), (1, 1))

    def test_a_blob_that_is_not_a_message_is_counted_and_left_out(self) -> None:
        ref = self.store.raw_blob(b"oops")
        self.store.requests("alpha", DAY_1, [request(listing(ref))])
        _, summary, skipped = self.run_all()
        self.assertEqual((summary.messages, summary.rows, skipped.invalid_blobs), (0, (), 1))

    def test_a_recorded_size_that_differs_from_the_file_is_counted(self) -> None:
        ref = self.store.blob(tool_message(result_block("u1", "x")))
        self.store.requests("alpha", DAY_1, [request(listing(ref, recorded=ref[1] + 1)), request(listing(ref, recorded=ref[1] + 1))])
        _, summary, skipped = self.run_all()
        self.assertEqual((summary.messages, skipped.size_disagreements), (1, 1))

    def test_the_tool_rows_add_up_to_the_stored_sizes_times_requests(self) -> None:
        one = self.store.blob(tool_message(result_block("u1", "a" * 12), result_block("u2", "b" * 7)))
        two = self.store.blob(tool_message(result_block("u3", "ccc"), call_id="c2"))
        self.store.requests("alpha", DAY_1, [request(listing(one), listing(two)), request(listing(one))])
        self.store.requests("beta", DAY_2, [request(listing(two))])
        self.store.ledger(DAY_1, [ledger_row("A", "u1"), ledger_row("B", "u2")])
        carried, summary, _ = self.run_all()
        expected = 2 * one[1] + 2 * two[1]
        self.assertEqual(summary.carried_bytes, expected)
        self.assertEqual(sum(row.stored_bytes for row in summary.rows), one[1] + two[1])
        self.assertEqual(carried.requests, 3)


class PercentTest(unittest.TestCase):
    def test_share_of_a_whole(self) -> None:
        self.assertEqual(carry_tool._pct(1, 4), 25.0)
        self.assertEqual(carry_tool._pct(3, 3), 100.0)

    def test_an_empty_whole_has_no_share(self) -> None:
        self.assertEqual(carry_tool._pct(5, 0), 0.0)


class CommandLineTest(TempStoreCase):
    def run_main(self, *extra: str, base: pathlib.Path | None = None) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        args = ["--base-path", str(base or self.store.base), "--from-date", DAY_1, "--to-date", DAY_2, *extra]
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = carry_tool.main(args)
        return code, out.getvalue(), err.getvalue()

    def fill(self) -> dict[str, Ref]:
        text = "q" * 60
        typed = self.store.blob(tool_message(result_block("u1", [{"type": "text", "text": text}], text_content=text)))
        stub = self.store.blob(tool_message(result_block("u2", stub_text(900)), call_id="c2"))
        plain = self.store.blob(tool_message(result_block("u3", "r" * 10), call_id="c3"))
        self.store.requests(
            "alpha",
            DAY_1,
            [request(listing(typed), listing(stub), listing(plain), body=5000), request(listing(typed), body=3000)],
        )
        self.store.ledger(DAY_1, [ledger_row("masc_dos_press", "u1"), ledger_row("Execute", "u2"), ledger_row("Read", "u3")])
        return {"typed": typed, "stub": stub, "plain": plain}

    def test_report_and_json_match(self) -> None:
        refs = self.fill()
        target = self.store.base / "result.json"
        code, out, err = self.run_main("--json-out", str(target))
        self.assertEqual((code, err), (0, ""))
        payload = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(payload["window"], {"from": DAY_1, "to": DAY_2})
        self.assertEqual((payload["stored_requests"], payload["body_bytes"], payload["tool_messages"]), (2, 8000, 3))
        carried = 2 * refs["typed"][1] + refs["stub"][1] + refs["plain"][1]
        self.assertEqual(payload["carried_bytes"], carried)
        self.assertEqual(payload["stub_results"], 1)
        self.assertEqual(payload["stub_carried_bytes"], refs["stub"][1])
        copy = len(STORED_COPY_FIELD) + size_of("q" * 60)
        self.assertEqual(payload["stored_copy_carried_bytes"], 2 * copy)
        self.assertEqual([row["tool"] for row in payload["tools"]], ["masc_dos_press", "Execute", "Read"])
        self.assertEqual(payload["skipped"]["unreadable_blobs"], 0)
        self.assertIn("window 2026-11-01 ~ 2026-11-02: stored requests 2", out)
        self.assertIn("tool messages 3 distinct", out)
        self.assertIn("stored copy (not on the wire)", out)
        self.assertIn("blob stubs: 1 results", out)
        self.assertIn("skipped: none", out)

    def test_top_limits_the_tools_printed(self) -> None:
        self.fill()
        _, out, _ = self.run_main("--top", "1")
        self.assertIn("masc_dos_press", out)
        self.assertNotIn("Execute", out)
        _, out, _ = self.run_main("--top", "3")
        self.assertIn("Read", out)

    def test_the_report_names_what_it_skipped(self) -> None:
        self.fill()
        self.store.requests("alpha", DAY_2, [request(listing(("d" * 64, 10)))])
        _, out, _ = self.run_main()
        self.assertIn("skipped: unreadable_blobs 1", out)

    def test_errors_exit_with_two_and_name_the_cause(self) -> None:
        code, _, err = self.run_main()
        self.assertEqual((code, err.strip()), (2, f"error: {self.masc_dir} is not a directory"))
        self.masc_dir.mkdir()
        code, _, err = self.run_main()
        self.assertEqual((code, err.strip()), (2, "error: no stored request in the window"))

    def test_a_reversed_window_is_refused(self) -> None:
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
            carry_tool.main(["--base-path", str(self.store.base), "--from-date", DAY_2, "--to-date", DAY_1])
        self.assertEqual(raised.exception.code, 2)

    def test_a_date_that_is_not_a_day_is_refused(self) -> None:
        for bad in ("2026-13-01", "2026-02-30", "2026-00-10", "11-01", "2026-11-01T00:00", "20261101"):
            with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
                carry_tool.main(["--base-path", str(self.store.base), "--from-date", bad, "--to-date", "2099-12-31"])
            self.assertEqual(raised.exception.code, 2)

    def test_top_below_one_is_refused(self) -> None:
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
            carry_tool.main(["--base-path", str(self.store.base), "--from-date", DAY_1, "--to-date", DAY_2, "--top", "0"])
        self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
