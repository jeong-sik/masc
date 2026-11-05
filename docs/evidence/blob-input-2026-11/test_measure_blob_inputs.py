"""Checks the arithmetic of measure_blob_inputs.py on small synthetic stores.

Run: python3 -m unittest discover -s docs/evidence/blob-input-2026-11
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
from datetime import date
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_blob_inputs as blobs  # noqa: E402

NOON = 1793534400.0  # 2026-11-01T12:00:00Z
HOUR = 3600.0
MIDNIGHT = 1793577600.0  # 2026-11-02T00:00:00Z
DAY = date(2026, 11, 1)
NEXT_DAY = date(2026, 11, 2)
SINCE = NOON - HOUR
UNTIL = NOON + HOUR
SHA_A = "a" * 64
SHA_B = "b" * 64
SHA_C = "c" * 64
SHA_D = "d" * 64
# `{"_blob":{"bytes":1000,"mime":"application/json","preview":"{}","sha256":"<64 hex>"}}` as compact JSON.
ENVELOPE_JSON_BYTES = 141
# The same with the preview `한글`, which is two characters and six bytes.
KOREAN_ENVELOPE_JSON_BYTES = 145


def envelope(sha: str = SHA_A, size: int = 1000, preview: str = "{}") -> dict[str, object]:
    return {"bytes": size, "mime": "application/json", "preview": preview, "sha256": sha}


def ledger_row(
    ts: object,
    keeper: object,
    tool: object,
    tool_input: object,
    *,
    record_kind: str = "tool_call",
    disposition: str | None = None,
    wire_outcome: str | None = None,
    **extra: object,
) -> str:
    row: dict[str, object] = {"ts": ts, "record_kind": record_kind, "keeper": keeper, "tool": tool, "input": tool_input}
    if disposition is not None:
        row["disposition"] = disposition
    if wire_outcome is not None:
        row["wire_outcome"] = wire_outcome
    row.update(extra)
    return json.dumps(row)


def write_ledger(base: pathlib.Path, day: date, lines: list[str], *, segment: int | None = None) -> None:
    name = f"{day.day:02d}.jsonl" if segment is None else f"{day.day:02d}.{segment:03d}.jsonl"
    path = base / ".masc" / "tool_calls" / f"{day.year:04d}-{day.month:02d}" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_captures(base: pathlib.Path, keeper: str, day: date, lines: list[str]) -> None:
    path = base / ".masc" / "keepers" / keeper / "provider-inputs" / f"{day.year:04d}-{day.month:02d}" / f"{day.day:02d}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def put_blob(base: pathlib.Path, sha: str, text: str) -> None:
    path = base / ".masc" / "tool_blobs" / sha[:2] / sha
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def put_message(base: pathlib.Path, blocks: object) -> str:
    """Stores a provider-bound message and returns the `content_ref` a capture lists for it."""
    text = json.dumps({"role": "assistant", "content_blocks": blocks})
    sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
    put_blob(base, sha, text)
    return content_ref(sha)


def content_ref(sha: str) -> str:
    return f'[masc:blob sha256={sha} bytes=9 mime=application/vnd.masc.provider-input-message+json preview=""]'


def capture_row(
    captured_at: object,
    body_bytes: object,
    refs: list[object],
    *,
    model: object = "glm",
) -> str:
    wire: dict[str, object] = {"body_bytes": body_bytes}
    if model is not None:
        wire["model"] = model
    messages = [{"artifact": {"content_ref": ref}} for ref in refs]
    return json.dumps({"captured_at": captured_at, "wire": wire, "messages": messages})


def tool_use(tool_input: object) -> dict[str, object]:
    return {"type": "tool_use", "id": "call", "name": "Write", "input": tool_input}


def tool_result(content: object) -> dict[str, object]:
    return {"type": "tool_result", "content": content}


def marker(sha: str, size: int) -> str:
    return f'[masc:blob sha256={sha} bytes={size} mime=text/plain preview=""]'


def blob_call(
    day: str,
    keeper: str,
    tool: str,
    form: str,
    shape: str,
    outcome: str,
    sha: str | None = None,
    stamp: float = 0.0,
) -> blobs.BlobCall:
    return blobs.BlobCall(day, keeper, tool, form, shape, outcome, sha, stamp)


def stamped_call(keeper: str, stamp: float, form: str = "alone") -> blobs.BlobCall:
    return blob_call("2026-11-01", keeper, "t", form, "not_an_object", "refused_before_run", None, stamp)


def stored_request(
    keeper: str, model: str, captured_at: float, arguments: int = 0, stored: int = 0
) -> blobs.HistoryRequest:
    return blobs.HistoryRequest(keeper, model, 1000, arguments, 0, 0, 0, 0, captured_at, stored)


def attributed_pairs(calls: list[blobs.BlobCall], requests: list[blobs.HistoryRequest]) -> list[tuple[str, str]]:
    return [(item.keeper, item.label) for item in blobs.attribute_calls(calls, requests)]


class IsoUtcTest(unittest.TestCase):
    def test_a_time_is_written_in_utc_with_its_offset(self) -> None:
        self.assertEqual(blobs.iso_utc(0.0), "1970-01-01T00:00:00+00:00")
        self.assertEqual(blobs.iso_utc(NOON), "2026-11-01T12:00:00+00:00")


class NumberOfTest(unittest.TestCase):
    def test_numbers_are_floats(self) -> None:
        self.assertEqual(blobs.number_of(1), 1.0)
        self.assertEqual(blobs.number_of(2.5), 2.5)
        self.assertEqual(blobs.number_of(0), 0.0)

    def test_a_boolean_is_not_a_number(self) -> None:
        self.assertIsNone(blobs.number_of(True))
        self.assertIsNone(blobs.number_of(False))

    def test_text_and_nothing_are_not_numbers(self) -> None:
        for value in ("1", None, [], {}):
            self.assertIsNone(blobs.number_of(value), repr(value))


class EnvelopeTest(unittest.TestCase):
    def test_the_exact_four_fields_are_an_envelope(self) -> None:
        value = envelope()
        self.assertEqual(blobs.envelope_of(value), value)

    def test_zero_bytes_is_an_envelope(self) -> None:
        self.assertIsNotNone(blobs.envelope_of(envelope(size=0)))

    def test_a_missing_field_is_not(self) -> None:
        for name in blobs.ENVELOPE_KEYS:
            value = envelope()
            del value[name]
            self.assertIsNone(blobs.envelope_of(value), name)

    def test_an_extra_field_is_not(self) -> None:
        self.assertIsNone(blobs.envelope_of({**envelope(), "answer_fingerprint": SHA_B}))

    def test_bytes_must_be_a_non_negative_integer(self) -> None:
        for size in (True, False, -1, "10", 1.5, None):
            self.assertIsNone(blobs.envelope_of({**envelope(), "bytes": size}), repr(size))

    def test_mime_must_be_text_without_whitespace(self) -> None:
        for mime in ("", " ", "text/plain; charset=utf-8", "a\tb", "a\nb", 5, None):
            self.assertIsNone(blobs.envelope_of({**envelope(), "mime": mime}), repr(mime))

    def test_preview_must_be_text(self) -> None:
        self.assertIsNotNone(blobs.envelope_of(envelope(preview="")))
        self.assertIsNone(blobs.envelope_of({**envelope(), "preview": 5}))
        self.assertIsNone(blobs.envelope_of({**envelope(), "preview": None}))

    def test_sha256_must_be_sixty_four_lowercase_hex_digits(self) -> None:
        for sha in ("a" * 63, "a" * 65, "A" * 64, "g" * 64, "", 5, None):
            self.assertIsNone(blobs.envelope_of({**envelope(), "sha256": sha}), repr(sha))

    def test_anything_but_an_object_is_not(self) -> None:
        for value in (None, "x", 5, [], [envelope()]):
            self.assertIsNone(blobs.envelope_of(value), repr(value))


class ClassifyTest(unittest.TestCase):
    def test_an_input_without_a_blob_key_is_not_a_blob_call(self) -> None:
        for value in (None, "_blob", 5, [], {}, {"post_id": "p"}, {"blob": envelope()}, {"nested": {"_blob": envelope()}}):
            self.assertIsNone(blobs.classify_input(value), repr(value))

    def test_a_lone_envelope_is_alone_and_complete(self) -> None:
        self.assertEqual(blobs.classify_input({"_blob": envelope(SHA_B)}), ("alone", "complete_envelope", SHA_B))

    def test_other_keys_beside_the_blob_key_make_it_mixed(self) -> None:
        self.assertEqual(
            blobs.classify_input({"_blob": envelope(SHA_C), "content": "x"}), ("mixed", "complete_envelope", SHA_C)
        )

    def test_another_object_under_the_key_is_wrapped_arguments_without_a_hash(self) -> None:
        self.assertEqual(
            blobs.classify_input({"_blob": {"post_id": "p", "content": "c"}}), ("alone", "wrapped_arguments", None)
        )
        self.assertEqual(blobs.classify_input({"_blob": {**envelope(), "extra": 1}}), ("alone", "wrapped_arguments", None))

    def test_a_value_that_is_not_an_object_is_reported_as_such(self) -> None:
        for inner in ("text", 5, [], [envelope()], None):
            self.assertEqual(blobs.classify_input({"_blob": inner}), ("alone", "not_an_object", None), repr(inner))
        self.assertEqual(blobs.classify_input({"_blob": "text", "a": 1}), ("mixed", "not_an_object", None))


class LoneEnvelopeTest(unittest.TestCase):
    def test_exactly_one_blob_key_holding_an_envelope(self) -> None:
        self.assertEqual(blobs.lone_envelope({"_blob": envelope(SHA_B)}), envelope(SHA_B))

    def test_a_sibling_key_is_refused(self) -> None:
        self.assertIsNone(blobs.lone_envelope({"_blob": envelope(), "content": "x"}))

    def test_a_value_that_is_not_an_envelope_is_refused(self) -> None:
        for value in ({"_blob": {"post_id": "p"}}, {"_blob": "x"}, {"other": envelope()}, {}, "x", None):
            self.assertIsNone(blobs.lone_envelope(value), repr(value))


class OutcomeTest(unittest.TestCase):
    def test_no_disposition_and_a_wire_error_is_a_refusal_before_the_run(self) -> None:
        self.assertEqual(blobs.outcome_of({"wire_outcome": "error"}), "refused_before_run")

    def test_a_completed_disposition_is_completed(self) -> None:
        self.assertEqual(blobs.outcome_of({"disposition": "completed", "wire_outcome": "ok"}), "completed")
        self.assertEqual(blobs.outcome_of({"disposition": "completed", "wire_outcome": "error"}), "completed")

    def test_a_disposition_other_than_completed_is_other_even_with_a_wire_error(self) -> None:
        self.assertEqual(blobs.outcome_of({"disposition": "failed", "wire_outcome": "error"}), "other")

    def test_no_disposition_and_no_wire_error_is_other(self) -> None:
        self.assertEqual(blobs.outcome_of({"wire_outcome": "ok"}), "other")
        self.assertEqual(blobs.outcome_of({}), "other")


class ReadBlobCallsTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = pathlib.Path(self._tmp.name)

    def read(self, lines: list[str], *, since: float = SINCE, until: float = UNTIL) -> list[blobs.BlobCall]:
        write_ledger(self.base, DAY, lines)
        return blobs.read_blob_calls(self.base, DAY, DAY, since, until)

    def test_a_row_with_a_blob_input_becomes_one_call(self) -> None:
        calls = self.read([ledger_row(NOON, "alpha", "Write", {"_blob": envelope()}, wire_outcome="error")])
        self.assertEqual(
            calls,
            [blob_call("2026-11-01", "alpha", "Write", "alone", "complete_envelope", "refused_before_run", SHA_A, NOON)],
        )

    def test_rows_without_a_blob_input_are_skipped(self) -> None:
        calls = self.read(
            [
                ledger_row(NOON, "alpha", "Write", {"content": "x"}),
                ledger_row(NOON, "alpha", "Write", "text that says _blob"),
                ledger_row(NOON, "alpha", "Write", {"content": "x"}, output=json.dumps({"_blob": envelope()})),
            ]
        )
        self.assertEqual(calls, [])

    def test_other_record_kinds_are_skipped(self) -> None:
        calls = self.read([ledger_row(NOON, "alpha", "Write", {"_blob": envelope()}, record_kind="route_evidence")])
        self.assertEqual(calls, [])

    def test_the_window_includes_both_ends_and_nothing_outside(self) -> None:
        rows = [
            ledger_row(SINCE - 1, "alpha", "t", {"_blob": envelope()}),
            ledger_row(SINCE, "beta", "t", {"_blob": envelope()}),
            ledger_row(UNTIL, "gamma", "t", {"_blob": envelope()}),
            ledger_row(UNTIL + 1, "delta", "t", {"_blob": envelope()}),
        ]
        self.assertEqual([call.keeper for call in self.read(rows)], ["beta", "gamma"])

    def test_a_missing_or_non_numeric_timestamp_is_skipped(self) -> None:
        rows = [
            ledger_row("noon", "alpha", "t", {"_blob": envelope()}),
            ledger_row(True, "beta", "t", {"_blob": envelope()}),
            ledger_row(None, "gamma", "t", {"_blob": envelope()}),
            json.dumps({"record_kind": "tool_call", "keeper": "delta", "tool": "t", "input": {"_blob": envelope()}}),
        ]
        self.assertEqual(self.read(rows), [])

    def test_lines_that_are_not_rows_are_skipped(self) -> None:
        calls = self.read(["not json with _blob in it", json.dumps(["_blob"]), ledger_row(NOON, "alpha", "t", {"_blob": envelope()})])
        self.assertEqual([call.keeper for call in calls], ["alpha"])

    def test_a_keeper_or_tool_that_is_not_text_becomes_a_question_mark(self) -> None:
        calls = self.read([ledger_row(NOON, 7, None, {"_blob": envelope()})])
        self.assertEqual((calls[0].keeper, calls[0].tool), ("?", "?"))

    def test_the_day_comes_from_the_timestamp_in_utc(self) -> None:
        write_ledger(self.base, DAY, [ledger_row(MIDNIGHT - 1, "alpha", "t", {"_blob": envelope()}), ledger_row(MIDNIGHT, "beta", "t", {"_blob": envelope()})])
        calls = blobs.read_blob_calls(self.base, DAY, DAY, SINCE, MIDNIGHT + HOUR)
        self.assertEqual([(call.keeper, call.day) for call in calls], [("alpha", "2026-11-01"), ("beta", "2026-11-02")])

    def test_the_live_file_and_its_segments_are_both_read(self) -> None:
        write_ledger(self.base, DAY, [ledger_row(NOON, "live", "t", {"_blob": envelope()})])
        write_ledger(self.base, DAY, [ledger_row(NOON, "segment", "t", {"_blob": envelope()})], segment=1)
        calls = blobs.read_blob_calls(self.base, DAY, DAY, SINCE, UNTIL)
        self.assertEqual(sorted(call.keeper for call in calls), ["live", "segment"])

    def test_every_day_of_the_range_is_read(self) -> None:
        write_ledger(self.base, DAY, [ledger_row(NOON, "first", "t", {"_blob": envelope()})])
        write_ledger(self.base, NEXT_DAY, [ledger_row(MIDNIGHT + HOUR, "second", "t", {"_blob": envelope()})])
        calls = blobs.read_blob_calls(self.base, DAY, NEXT_DAY, SINCE, MIDNIGHT + 2 * HOUR)
        self.assertEqual(sorted(call.keeper for call in calls), ["first", "second"])

    def test_a_day_outside_the_range_is_not_read(self) -> None:
        write_ledger(self.base, NEXT_DAY, [ledger_row(MIDNIGHT + HOUR, "late", "t", {"_blob": envelope()})])
        self.assertEqual(blobs.read_blob_calls(self.base, DAY, DAY, SINCE, MIDNIGHT + 2 * HOUR), [])

    def test_form_shape_and_hash_come_from_the_input(self) -> None:
        rows = [
            ledger_row(NOON, "a", "t", {"_blob": {"post_id": "p"}}),
            ledger_row(NOON, "b", "t", {"_blob": envelope(SHA_B), "content": "x"}, disposition="completed", wire_outcome="ok"),
        ]
        calls = self.read(rows)
        self.assertEqual((calls[0].form, calls[0].shape, calls[0].sha256, calls[0].outcome), ("alone", "wrapped_arguments", None, "other"))
        self.assertEqual((calls[1].form, calls[1].shape, calls[1].sha256, calls[1].outcome), ("mixed", "complete_envelope", SHA_B, "completed"))


class MessageDemotionTest(unittest.TestCase):
    def demotion(self, blocks: object) -> blobs.MessageDemotion:
        return blobs.demotion_of_message({"content_blocks": blocks})

    def test_a_demoted_argument_reports_its_hash_original_size_and_envelope_size(self) -> None:
        result = self.demotion([tool_use({"_blob": envelope()})])
        self.assertEqual(result, blobs.MessageDemotion(((SHA_A, 1000, ENVELOPE_JSON_BYTES),), 0, 0))

    def test_the_envelope_size_counts_utf8_bytes(self) -> None:
        result = self.demotion([tool_use({"_blob": envelope(preview="한글")})])
        self.assertEqual(result.arguments, ((SHA_A, 1000, KOREAN_ENVELOPE_JSON_BYTES),))

    def test_arguments_that_are_not_a_lone_envelope_are_not_demoted(self) -> None:
        blocks = [
            tool_use({"post_id": "p"}),
            tool_use({"_blob": envelope(), "content": "x"}),
            tool_use({"_blob": {"bytes": 1}}),
            tool_use(json.dumps({"_blob": envelope()})),
            tool_use(None),
        ]
        self.assertEqual(self.demotion(blocks), blobs.MessageDemotion((), 0, 0))

    def test_a_tool_result_marker_reports_the_bytes_it_saved(self) -> None:
        text = marker(SHA_B, 500)
        result = self.demotion([tool_result(text)])
        self.assertEqual(result, blobs.MessageDemotion((), 1, 500 - len(text)))

    def test_results_add_up_across_blocks(self) -> None:
        first, second = marker(SHA_A, 500), marker(SHA_B, 900)
        result = self.demotion([tool_result(first), tool_result(second)])
        self.assertEqual((result.results, result.result_saved), (2, 500 - len(first) + 900 - len(second)))

    def test_results_that_are_not_markers_are_ignored(self) -> None:
        blocks = [
            tool_result("plain text bytes=900"),
            tool_result(" " + marker(SHA_A, 900)),
            tool_result('[masc:blob preview=""]'),
            tool_result([{"type": "text"}]),
            tool_result(None),
        ]
        self.assertEqual(self.demotion(blocks), blobs.MessageDemotion((), 0, 0))

    def test_a_block_that_is_neither_a_call_nor_a_result_is_ignored(self) -> None:
        blocks = [{"type": "text", "text": marker(SHA_A, 900)}, "not a block", 5, None]
        self.assertEqual(self.demotion(blocks), blobs.MessageDemotion((), 0, 0))

    def test_a_message_without_a_block_list_has_nothing_demoted(self) -> None:
        messages: list[dict[str, object]] = [
            {},
            {"content_blocks": None},
            {"content_blocks": "x"},
            {"content_blocks": {"type": "tool_use"}},
        ]
        for message in messages:
            self.assertEqual(blobs.demotion_of_message(message), blobs.MessageDemotion((), 0, 0), repr(message))

    def test_arguments_and_results_of_one_message_are_both_reported(self) -> None:
        text = marker(SHA_B, 500)
        result = self.demotion([tool_use({"_blob": envelope()}), tool_result(text), tool_use({"_blob": envelope(SHA_C, 2000)})])
        self.assertEqual([item[:2] for item in result.arguments], [(SHA_A, 1000), (SHA_C, 2000)])
        self.assertEqual(result.results, 1)


class MessageBlobTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = pathlib.Path(self._tmp.name)

    def test_the_blob_named_by_the_reference_is_parsed(self) -> None:
        put_blob(self.base, SHA_A, json.dumps({"role": "user"}))
        self.assertEqual(blobs.message_blob(self.base, content_ref(SHA_A)), {"role": "user"})

    def test_a_missing_blob_is_none(self) -> None:
        self.assertIsNone(blobs.message_blob(self.base, content_ref(SHA_A)))

    def test_a_blob_that_is_not_json_is_none(self) -> None:
        put_blob(self.base, SHA_A, "not json")
        self.assertIsNone(blobs.message_blob(self.base, content_ref(SHA_A)))

    def test_a_blob_that_is_not_an_object_is_none(self) -> None:
        put_blob(self.base, SHA_A, json.dumps(["x"]))
        self.assertIsNone(blobs.message_blob(self.base, content_ref(SHA_A)))

    def test_a_blob_that_is_not_utf8_is_none(self) -> None:
        path = self.base / ".masc" / "tool_blobs" / SHA_A[:2] / SHA_A
        path.parent.mkdir(parents=True)
        path.write_bytes(b"\xff\xfe{}")
        self.assertIsNone(blobs.message_blob(self.base, content_ref(SHA_A)))

    def test_a_reference_without_a_hash_is_none(self) -> None:
        for ref in (None, 5, "", "[masc:blob bytes=1]", f"sha256={'A' * 64}", "sha256=" + "a" * 63):
            self.assertIsNone(blobs.message_blob(self.base, ref), repr(ref))

    def test_the_blob_directory_is_named_by_the_first_two_digits(self) -> None:
        sha = "ab" + "c" * 62
        path = self.base / ".masc" / "tool_blobs" / "ab" / sha
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"x": 1}), encoding="utf-8")
        self.assertEqual(blobs.message_blob(self.base, content_ref(sha)), {"x": 1})


class StoredWithSizeTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = pathlib.Path(self._tmp.name)
        put_blob(self.base, SHA_A, "x" * 10)

    def test_a_blob_with_exactly_the_size_is_stored(self) -> None:
        self.assertTrue(blobs.stored_with_size(self.base, SHA_A, 10))

    def test_a_blob_of_another_size_is_not(self) -> None:
        self.assertFalse(blobs.stored_with_size(self.base, SHA_A, 9))
        self.assertFalse(blobs.stored_with_size(self.base, SHA_A, 11))

    def test_a_missing_blob_is_not_stored_whatever_the_size(self) -> None:
        self.assertFalse(blobs.stored_with_size(self.base, SHA_B, 0))
        self.assertFalse(blobs.stored_with_size(self.base, SHA_B, 10))


class ReadHistoryRequestsTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = pathlib.Path(self._tmp.name)

    def read(self, *, first: date = DAY, last: date = DAY, since: float = SINCE, until: float = UNTIL):
        return blobs.read_history_requests(self.base, first, last, since, until)

    def test_each_request_sums_what_its_messages_demoted(self) -> None:
        text = marker(SHA_B, 500)
        demoted = put_message(self.base, [tool_use({"_blob": envelope()}), tool_result(text)])
        plain = put_message(self.base, [tool_use({"post_id": "p"})])
        write_captures(self.base, "alpha", DAY, [capture_row(NOON, 5000, [demoted, plain, demoted], model="deepseek")])
        requests, envelopes = self.read()
        saved = 1000 - ENVELOPE_JSON_BYTES
        self.assertEqual(
            requests,
            [blobs.HistoryRequest("alpha", "deepseek", 5000, 2, 2 * saved, 2, 2 * (500 - len(text)), 0, NOON)],
        )
        self.assertEqual(envelopes, {SHA_A: 1000})

    def test_a_message_blob_shared_by_requests_is_parsed_once(self) -> None:
        demoted = put_message(self.base, [tool_use({"_blob": envelope()})])
        write_captures(self.base, "alpha", DAY, [capture_row(NOON, 100, [demoted]), capture_row(NOON + 1, 200, [demoted])])
        with mock.patch.object(blobs, "message_blob", wraps=blobs.message_blob) as parse:
            requests, _ = self.read()
        self.assertEqual(parse.call_count, 1)
        self.assertEqual([request.arguments for request in requests], [1, 1])

    def test_a_message_that_cannot_be_read_is_counted_and_skipped(self) -> None:
        demoted = put_message(self.base, [tool_use({"_blob": envelope()})])
        missing = content_ref(SHA_C)
        row = json.loads(capture_row(NOON, 100, [demoted, missing, demoted]))
        row["messages"].append({"role": "user"})
        row["messages"].append({"artifact": {"content_ref": 5}})
        write_captures(self.base, "alpha", DAY, [json.dumps(row), capture_row(NOON + 1, 100, [missing])])
        requests, _ = self.read()
        self.assertEqual([(request.arguments, request.unreadable) for request in requests], [(2, 3), (0, 1)])

    def test_requests_outside_the_window_or_without_numbers_are_skipped(self) -> None:
        write_captures(
            self.base,
            "alpha",
            DAY,
            [
                capture_row(SINCE - 1, 100, []),
                capture_row(SINCE, 101, []),
                capture_row(UNTIL, 102, []),
                capture_row(UNTIL + 1, 103, []),
                capture_row("noon", 104, []),
                capture_row(True, 105, []),
                capture_row(NOON, "big", []),
                capture_row(NOON, True, []),
                json.dumps({"captured_at": NOON, "messages": []}),
                json.dumps({"captured_at": NOON, "wire": "x", "messages": []}),
                json.dumps(["captured_at"]),
                "not json",
            ],
        )
        requests, _ = self.read()
        self.assertEqual([request.body_bytes for request in requests], [101, 102])

    def test_a_missing_model_is_a_question_mark(self) -> None:
        write_captures(self.base, "alpha", DAY, [capture_row(NOON, 100, [], model=None), capture_row(NOON, 100, [], model=7)])
        requests, _ = self.read()
        self.assertEqual([request.model for request in requests], ["?", "?"])

    def test_messages_that_are_not_a_list_are_ignored(self) -> None:
        row = {"captured_at": NOON, "wire": {"body_bytes": 100}, "messages": "x"}
        write_captures(self.base, "alpha", DAY, [json.dumps(row)])
        requests, _ = self.read()
        self.assertEqual((requests[0].arguments, requests[0].unreadable), (0, 0))

    def test_the_keeper_is_the_directory_name_and_every_keeper_is_read(self) -> None:
        for keeper in ("beta", "alpha"):
            write_captures(self.base, keeper, DAY, [capture_row(NOON, 100, [])])
        requests, _ = self.read()
        self.assertEqual([request.keeper for request in requests], ["alpha", "beta"])

    def test_only_the_days_of_the_range_are_read(self) -> None:
        write_captures(self.base, "alpha", DAY, [capture_row(NOON, 1, [])])
        write_captures(self.base, "alpha", NEXT_DAY, [capture_row(MIDNIGHT + HOUR, 2, [])])
        later = date(2026, 11, 3)
        write_captures(self.base, "alpha", later, [capture_row(MIDNIGHT + 2 * HOUR, 3, [])])
        requests, _ = self.read(first=DAY, last=NEXT_DAY, until=MIDNIGHT + 3 * HOUR)
        self.assertEqual([request.body_bytes for request in requests], [1, 2])

    def test_no_keeper_directory_means_no_requests(self) -> None:
        self.assertEqual(self.read(), ([], {}))

    def test_a_demoted_argument_is_stored_only_when_its_blob_has_the_original_size(self) -> None:
        put_blob(self.base, SHA_A, "x" * 1000)
        put_blob(self.base, SHA_B, "y" * 10)
        message = put_message(
            self.base,
            [
                tool_use({"_blob": envelope(SHA_A, 1000)}),
                tool_use({"_blob": envelope(SHA_B, 2000)}),
                tool_use({"_blob": envelope(SHA_C, 3000)}),
            ],
        )
        write_captures(self.base, "alpha", DAY, [capture_row(NOON, 5000, [message])])
        requests, _ = self.read()
        self.assertEqual((requests[0].arguments, requests[0].stored_arguments), (3, 1))

    def test_a_stored_argument_is_counted_in_every_request_that_shows_it(self) -> None:
        put_blob(self.base, SHA_A, "x" * 1000)
        message = put_message(self.base, [tool_use({"_blob": envelope(SHA_A, 1000)})])
        write_captures(self.base, "alpha", DAY, [capture_row(NOON, 100, [message, message]), capture_row(NOON + 1, 100, [message])])
        requests, _ = self.read()
        self.assertEqual([(request.arguments, request.stored_arguments) for request in requests], [(2, 2), (1, 1)])

    def test_a_demoted_hash_keeps_its_original_size(self) -> None:
        first = put_message(self.base, [tool_use({"_blob": envelope(SHA_A, 1000)})])
        second = put_message(self.base, [tool_use({"_blob": envelope(SHA_B, 2000)}), tool_use({"_blob": envelope(SHA_A, 1000)})])
        write_captures(self.base, "alpha", DAY, [capture_row(NOON, 100, [first, second])])
        _, envelopes = self.read()
        self.assertEqual(envelopes, {SHA_A: 1000, SHA_B: 2000})


class SummarizeBlobCallsTest(unittest.TestCase):
    CALLS = [
        blob_call("2026-11-01", "k1", "Write", "alone", "complete_envelope", "refused_before_run", SHA_A),
        blob_call("2026-11-01", "k1", "Write", "alone", "complete_envelope", "refused_before_run", SHA_B),
        blob_call("2026-11-01", "k2", "Edit", "alone", "wrapped_arguments", "refused_before_run"),
        blob_call("2026-11-02", "k2", "Edit", "alone", "not_an_object", "completed"),
        blob_call("2026-11-02", "k1", "Write", "mixed", "complete_envelope", "completed", SHA_C),
        blob_call("2026-11-02", "k3", "Execute", "mixed", "wrapped_arguments", "other"),
    ]
    STORED = {SHA_A: True, SHA_B: False, SHA_C: True}

    def summary(self) -> dict[str, object]:
        return blobs.summarize_blob_calls(self.CALLS, self.STORED)

    def test_totals_split_alone_from_mixed(self) -> None:
        result = self.summary()
        self.assertEqual((result["calls"], result["alone"], result["mixed"]), (6, 4, 2))

    def test_outcomes_are_counted_per_form(self) -> None:
        result = self.summary()
        self.assertEqual(result["outcome_alone"], {"completed": 1, "refused_before_run": 3})
        self.assertEqual(result["outcome_mixed"], {"completed": 1, "other": 1})

    def test_shapes_count_alone_calls_only(self) -> None:
        self.assertEqual(
            self.summary()["shape_alone"], {"complete_envelope": 2, "not_an_object": 1, "wrapped_arguments": 1}
        )

    def test_the_hash_check_counts_alone_envelopes_only(self) -> None:
        self.assertEqual(
            self.summary()["complete_envelope_alone"], {"calls": 2, "hash_in_store": 1, "hash_not_in_store": 1}
        )

    def test_a_hash_missing_from_the_check_counts_as_not_in_store(self) -> None:
        result = blobs.summarize_blob_calls(self.CALLS, {SHA_A: True})
        self.assertEqual(result["complete_envelope_alone"], {"calls": 2, "hash_in_store": 1, "hash_not_in_store": 1})

    def test_days_list_each_form_in_date_order(self) -> None:
        self.assertEqual(
            self.summary()["by_day"], {"2026-11-01": {"alone": 3}, "2026-11-02": {"alone": 1, "mixed": 2}}
        )

    def test_keepers_rank_by_alone_calls_then_name(self) -> None:
        self.assertEqual(
            self.summary()["top_keepers_alone"],
            [
                {"keeper": "k1", "calls": 2, "outcome": {"refused_before_run": 2}},
                {"keeper": "k2", "calls": 2, "outcome": {"completed": 1, "refused_before_run": 1}},
            ],
        )

    def test_tools_rank_by_alone_calls_then_name(self) -> None:
        self.assertEqual(
            self.summary()["top_tools_alone"], [{"tool": "Edit", "calls": 2}, {"tool": "Write", "calls": 2}]
        )

    def test_keepers_rank_most_calls_first(self) -> None:
        calls = [
            blob_call("2026-11-01", "few", "t", "alone", "not_an_object", "other"),
            blob_call("2026-11-01", "many", "t", "alone", "not_an_object", "other"),
            blob_call("2026-11-01", "many", "t", "alone", "not_an_object", "other"),
        ]
        result = blobs.summarize_blob_calls(calls, {})
        self.assertEqual([(row["keeper"], row["calls"]) for row in result["top_keepers_alone"]], [("many", 2), ("few", 1)])  # type: ignore[index]

    def test_hashes_in_store_and_not_in_store_are_counted_apart(self) -> None:
        calls = [
            blob_call("2026-11-01", "k", "t", "alone", "complete_envelope", "refused_before_run", sha)
            for sha in (SHA_A, SHA_B, SHA_C)
        ]
        result = blobs.summarize_blob_calls(calls, {SHA_A: True, SHA_B: False, SHA_C: False})
        self.assertEqual(result["complete_envelope_alone"], {"calls": 3, "hash_in_store": 1, "hash_not_in_store": 2})

    def test_keepers_with_equal_counts_rank_by_name_whatever_the_order_they_came_in(self) -> None:
        calls = [
            blob_call("2026-11-01", "k2", "t", "alone", "not_an_object", "other"),
            blob_call("2026-11-01", "k1", "t", "alone", "not_an_object", "other"),
        ]
        result = blobs.summarize_blob_calls(calls, {})
        self.assertEqual([row["keeper"] for row in result["top_keepers_alone"]], ["k1", "k2"])  # type: ignore[index]

    def test_the_rankings_are_capped(self) -> None:
        with mock.patch.object(blobs, "TOP_KEEPERS", 1), mock.patch.object(blobs, "TOP_TOOLS", 1):
            result = self.summary()
        self.assertEqual([row["keeper"] for row in result["top_keepers_alone"]], ["k1"])  # type: ignore[index]
        self.assertEqual([row["tool"] for row in result["top_tools_alone"]], ["Edit"])  # type: ignore[index]

    def test_every_keeper_is_counted_by_alone_calls_whatever_the_ranking_cap(self) -> None:
        with mock.patch.object(blobs, "TOP_KEEPERS", 1):
            result = self.summary()
        # k1 has one mixed call and k3 has only a mixed call: neither counts.
        self.assertEqual(result["alone_by_keeper"], {"k1": 2, "k2": 2})

    def test_nothing_read_gives_zeros(self) -> None:
        result = blobs.summarize_blob_calls([], {})
        self.assertEqual((result["calls"], result["alone"], result["mixed"]), (0, 0, 0))
        self.assertEqual(result["complete_envelope_alone"], {"calls": 0, "hash_in_store": 0, "hash_not_in_store": 0})
        self.assertEqual((result["by_day"], result["top_keepers_alone"], result["top_tools_alone"]), ({}, [], []))
        self.assertEqual(result["alone_by_keeper"], {})


class SummarizeHistoryTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = pathlib.Path(self._tmp.name)

    REQUESTS = [
        blobs.HistoryRequest("k1", "m1", 1000, 2, 300, 1, 400, 0),
        blobs.HistoryRequest("k1", "m1", 2000, 4, 500, 0, 0, 1),
        blobs.HistoryRequest("k1", "m1", 3000, 0, 0, 2, 600, 0),
        blobs.HistoryRequest("k2", "m2", 500, 0, 0, 0, 0, 0),
        blobs.HistoryRequest("k1", "m2", 4000, 1, 100, 1, 200, 0),
    ]

    def summary(self, envelopes: dict[str, int] | None = None) -> dict[str, object]:
        return blobs.summarize_history(self.REQUESTS, envelopes or {}, self.base)

    def test_totals_count_requests_that_carry_a_demoted_argument(self) -> None:
        result = self.summary()
        self.assertEqual(
            (result["requests"], result["with_demoted_arguments"], result["with_demoted_arguments_percent"]),
            (5, 3, 60.0),
        )
        self.assertEqual(result["unreadable_messages"], 1)

    def test_a_group_row_reports_shares_and_medians_over_its_requests(self) -> None:
        row = self.summary()["by_keeper_and_model"][0]  # type: ignore[index]
        self.assertEqual(
            row,
            {
                "keeper": "k1",
                "model": "m1",
                "requests": 3,
                "with_demoted_arguments": 2,
                "with_demoted_arguments_percent": 66.7,
                "with_demoted_results_percent": 66.7,
                "body_bytes_median": 2000,
                "demoted_arguments_median": 3,
                "argument_saved_bytes_median": 400,
                "argument_saved_percent_of_body_median": 27.5,
                "result_saved_bytes_median": 500,
            },
        )

    def test_the_same_keeper_on_another_model_is_its_own_row(self) -> None:
        rows = self.summary()["by_keeper_and_model"]
        self.assertEqual([(row["keeper"], row["model"]) for row in rows], [("k1", "m1"), ("k1", "m2")])  # type: ignore[index]
        self.assertEqual(rows[1]["argument_saved_percent_of_body_median"], 2.5)  # type: ignore[index]

    def test_a_group_that_never_carried_a_demoted_argument_has_no_row(self) -> None:
        rows = self.summary()["by_keeper_and_model"]
        self.assertNotIn("k2", [row["keeper"] for row in rows])  # type: ignore[index]

    def test_rows_rank_by_requests_that_carry_one_then_name(self) -> None:
        requests = [
            blobs.HistoryRequest("b", "m", 100, 1, 1, 0, 0, 0),
            blobs.HistoryRequest("a", "m", 100, 1, 1, 0, 0, 0),
            blobs.HistoryRequest("c", "m", 100, 1, 1, 0, 0, 0),
            blobs.HistoryRequest("c", "m", 100, 1, 1, 0, 0, 0),
        ]
        result = blobs.summarize_history(requests, {}, self.base)
        self.assertEqual([row["keeper"] for row in result["by_keeper_and_model"]], ["c", "a", "b"])  # type: ignore[index]

    def test_the_rows_are_capped(self) -> None:
        with mock.patch.object(blobs, "TOP_HISTORY_ROWS", 1):
            rows = self.summary()["by_keeper_and_model"]
        self.assertEqual(len(rows), 1)  # type: ignore[arg-type]

    def test_every_keeper_and_model_is_counted_even_without_a_demoted_argument_or_beyond_the_row_cap(self) -> None:
        with mock.patch.object(blobs, "TOP_HISTORY_ROWS", 1):
            result = self.summary()
        self.assertEqual(
            result["requests_by_keeper_and_model"],
            {
                "k1": {
                    "m1": {"requests": 3, "with_demoted_arguments": 2},
                    "m2": {"requests": 1, "with_demoted_arguments": 1},
                },
                "k2": {"m2": {"requests": 1, "with_demoted_arguments": 0}},
            },
        )

    def test_a_group_counts_requests_with_demoted_arguments_apart_from_those_with_demoted_results(self) -> None:
        requests = [
            blobs.HistoryRequest("k", "m", 100, 1, 10, 0, 0, 0),
            blobs.HistoryRequest("k", "m", 100, 0, 0, 1, 10, 0),
            blobs.HistoryRequest("k", "m", 100, 0, 0, 2, 20, 0),
        ]
        result = blobs.summarize_history(requests, {}, self.base)
        self.assertEqual(
            result["requests_by_keeper_and_model"], {"k": {"m": {"requests": 3, "with_demoted_arguments": 1}}}
        )

    def test_a_request_without_body_bytes_is_left_out_of_the_share(self) -> None:
        requests = [blobs.HistoryRequest("k", "m", 0, 1, 50, 0, 0, 0), blobs.HistoryRequest("k", "m", 1000, 1, 50, 0, 0, 0)]
        row = blobs.summarize_history(requests, {}, self.base)["by_keeper_and_model"][0]  # type: ignore[index]
        self.assertEqual(row["argument_saved_percent_of_body_median"], 5.0)

    def test_no_request_has_a_share_when_none_has_a_body(self) -> None:
        row = blobs.summarize_history([blobs.HistoryRequest("k", "m", 0, 1, 50, 0, 0, 0)], {}, self.base)["by_keeper_and_model"][0]  # type: ignore[index]
        self.assertIsNone(row["argument_saved_percent_of_body_median"])

    def test_a_group_without_demoted_results_reports_zero_saved_bytes(self) -> None:
        row = blobs.summarize_history([blobs.HistoryRequest("k", "m", 100, 1, 50, 0, 0, 0)], {}, self.base)["by_keeper_and_model"][0]  # type: ignore[index]
        self.assertEqual((row["with_demoted_results_percent"], row["result_saved_bytes_median"]), (0.0, 0))

    def test_nothing_read_gives_zeros(self) -> None:
        result = blobs.summarize_history([], {}, self.base)
        self.assertEqual(
            (result["requests"], result["with_demoted_arguments"], result["with_demoted_arguments_percent"]),
            (0, 0, None),
        )
        self.assertEqual((result["distinct_demoted_arguments"], result["stored_and_same_size"], result["by_keeper_and_model"]), (0, 0, []))
        self.assertEqual(result["requests_by_keeper_and_model"], {})

    def test_a_demoted_argument_is_stored_when_its_blob_has_the_recorded_size(self) -> None:
        put_blob(self.base, SHA_A, "12345")
        put_blob(self.base, SHA_B, "12345678")
        result = self.summary({SHA_A: 5, SHA_B: 7, SHA_C: 9})
        self.assertEqual((result["distinct_demoted_arguments"], result["stored_and_same_size"]), (3, 1))

    def test_the_stored_size_is_counted_in_bytes_not_characters(self) -> None:
        put_blob(self.base, SHA_A, "한글")
        self.assertEqual(self.summary({SHA_A: 6})["stored_and_same_size"], 1)


class AttributeCallsTest(unittest.TestCase):
    def test_a_call_between_two_requests_of_one_model_takes_that_model(self) -> None:
        requests = [stored_request("k", "m1", 10.0), stored_request("k", "m1", 30.0)]
        self.assertEqual(attributed_pairs([stamped_call("k", 20.0)], requests), [("k", "m1")])

    def test_a_call_between_two_models_stays_unattributed(self) -> None:
        requests = [stored_request("k", "m1", 10.0), stored_request("k", "m2", 30.0)]
        self.assertEqual(attributed_pairs([stamped_call("k", 20.0)], requests), [("k", blobs.NEIGHBOURS_DIFFER)])

    def test_a_call_before_the_first_or_after_the_last_request_has_no_neighbour(self) -> None:
        requests = [stored_request("k", "m1", 10.0), stored_request("k", "m1", 30.0)]
        calls = [stamped_call("k", 5.0), stamped_call("k", 35.0)]
        self.assertEqual(attributed_pairs(calls, requests), [("k", blobs.NO_NEIGHBOUR), ("k", blobs.NO_NEIGHBOUR)])

    def test_a_keeper_without_a_stored_request_has_no_neighbour(self) -> None:
        self.assertEqual(attributed_pairs([stamped_call("k", 20.0)], []), [("k", blobs.NO_NEIGHBOUR)])

    def test_a_request_written_at_the_call_time_closes_the_calls_turn(self) -> None:
        requests = [stored_request("k", "m1", 10.0), stored_request("k", "m2", 20.0), stored_request("k", "m2", 30.0)]
        # At 20.0 the neighbours are the m1 request at 10.0 and the m2 request at 20.0.
        self.assertEqual(attributed_pairs([stamped_call("k", 20.0)], requests), [("k", blobs.NEIGHBOURS_DIFFER)])
        # An instant later both neighbours are m2.
        self.assertEqual(attributed_pairs([stamped_call("k", 20.5)], requests), [("k", "m2")])

    def test_another_keepers_requests_are_not_neighbours(self) -> None:
        requests = [stored_request("other", "m1", 10.0), stored_request("other", "m1", 30.0)]
        self.assertEqual(attributed_pairs([stamped_call("k", 20.0)], requests), [("k", blobs.NO_NEIGHBOUR)])

    def test_each_call_keeps_the_keeper_that_made_it_and_that_keepers_model(self) -> None:
        requests = [
            stored_request("a", "m1", 10.0),
            stored_request("a", "m1", 30.0),
            stored_request("b", "m2", 10.0),
            stored_request("b", "m2", 30.0),
        ]
        calls = [stamped_call("b", 20.0), stamped_call("a", 21.0)]
        self.assertEqual(attributed_pairs(calls, requests), [("b", "m2"), ("a", "m1")])

    def test_each_attributed_call_keeps_its_time(self) -> None:
        requests = [stored_request("k", "m1", 10.0), stored_request("k", "m1", 30.0)]
        calls = [stamped_call("k", 25.0), stamped_call("k", 15.0)]
        self.assertEqual(
            blobs.attribute_calls(calls, requests),
            [blobs.AttributedCall("k", "m1", 25.0), blobs.AttributedCall("k", "m1", 15.0)],
        )

    def test_only_alone_calls_are_attributed(self) -> None:
        requests = [stored_request("k", "m1", 10.0), stored_request("k", "m1", 30.0)]
        self.assertEqual(attributed_pairs([stamped_call("k", 20.0, "mixed")], requests), [])

    def test_requests_need_not_arrive_in_time_order(self) -> None:
        requests = [stored_request("k", "m1", 30.0), stored_request("k", "m2", 10.0), stored_request("k", "m1", 20.0)]
        # Sorted by time: m2 at 10, m1 at 20, m1 at 30. The call at 25 sits between the two m1 requests.
        self.assertEqual(attributed_pairs([stamped_call("k", 25.0)], requests), [("k", "m1")])


class SummarizeModelsTest(unittest.TestCase):
    REQUESTS = [
        stored_request("k", "m1", 10.0, arguments=2, stored=2),
        stored_request("k", "m1", 30.0, arguments=0),
        stored_request("k", "m2", 50.0, arguments=1),
    ]

    def test_requests_and_demoted_arguments_are_counted_per_model(self) -> None:
        result = blobs.summarize_models([], self.REQUESTS, self.REQUESTS)
        self.assertEqual(
            (result["stored_requests"], result["with_demoted_arguments"], result["with_demoted_arguments_percent"]),
            (3, 2, 66.7),
        )
        self.assertEqual(
            result["requests_by_model"],
            {
                "m1": {"requests": 2, "with_demoted_arguments": 1, "with_stored_demotion": 1},
                "m2": {"requests": 1, "with_demoted_arguments": 1, "with_stored_demotion": 0},
            },
        )

    def test_the_last_alone_call_is_kept_per_model_and_per_unattributed_label(self) -> None:
        calls = [
            stamped_call("k", 25.0),
            stamped_call("k", 15.0),
            stamped_call("k", 20.0, "mixed"),
            stamped_call("k", 70.0),
            stamped_call("k", 5.0),
        ]
        result = blobs.summarize_models(calls, self.REQUESTS, self.REQUESTS)
        self.assertEqual(
            result["last_alone_call_by_model"],
            {"m1": "1970-01-01T00:00:25+00:00", blobs.NO_NEIGHBOUR: "1970-01-01T00:01:10+00:00"},
        )

    def test_a_demoted_argument_without_a_stored_blob_is_not_a_stored_demotion(self) -> None:
        result = blobs.summarize_models([], self.REQUESTS, self.REQUESTS)
        self.assertEqual((result["with_stored_demotion"], result["with_stored_demotion_percent"]), (1, 33.3))

    def test_the_last_stored_demotion_is_kept_per_model_whatever_the_order(self) -> None:
        requests = [
            stored_request("k", "m1", 30.0, arguments=1, stored=1),
            stored_request("k", "m1", 10.0, arguments=1, stored=1),
            stored_request("k", "m1", 40.0, arguments=1),
            stored_request("k", "m2", 5.0, arguments=1, stored=1),
            stored_request("k", "m2", 7.0),
            stored_request("k", "m3", 9.0, arguments=1),
        ]
        result = blobs.summarize_models([], requests, requests)
        self.assertEqual(
            result["last_stored_demotion_by_model"],
            {"m1": "1970-01-01T00:00:30+00:00", "m2": "1970-01-01T00:00:05+00:00"},
        )

    def test_alone_calls_are_counted_and_attributed(self) -> None:
        calls = [stamped_call("k", 20.0), stamped_call("k", 20.5, "mixed"), stamped_call("k", 70.0)]
        result = blobs.summarize_models(calls, self.REQUESTS, self.REQUESTS)
        self.assertEqual(result["alone_calls"], 2)
        self.assertEqual(result["alone_calls_by_model"], {"m1": 1, blobs.NO_NEIGHBOUR: 1})

    def test_alone_calls_are_also_counted_per_keeper_and_model(self) -> None:
        requests = [
            stored_request("a", "m1", 10.0),
            stored_request("a", "m1", 30.0),
            stored_request("b", "m2", 10.0),
            stored_request("b", "m2", 30.0),
        ]
        calls = [
            stamped_call("a", 20.0),
            stamped_call("a", 25.0),
            stamped_call("b", 20.0),
            stamped_call("b", 40.0),
            stamped_call("a", 26.0, "mixed"),
        ]
        result = blobs.summarize_models(calls, requests, requests)
        self.assertEqual(result["alone_calls"], 4)
        self.assertEqual(result["alone_calls_by_model"], {"m1": 2, "m2": 1, blobs.NO_NEIGHBOUR: 1})
        self.assertEqual(
            result["alone_calls_by_keeper_and_model"], {"a": {"m1": 2}, "b": {"m2": 1, blobs.NO_NEIGHBOUR: 1}}
        )

    def test_neighbours_may_lie_outside_the_requests_being_counted(self) -> None:
        result = blobs.summarize_models([stamped_call("k", 20.0)], [], self.REQUESTS)
        self.assertEqual(result["alone_calls_by_model"], {"m1": 1})
        self.assertEqual(
            (result["stored_requests"], result["with_demoted_arguments_percent"], result["with_stored_demotion_percent"]),
            (0, None, None),
        )


class SummarizeTurnsTest(unittest.TestCase):
    def test_calls_between_two_requests_belong_to_the_turn_the_later_one_closes(self) -> None:
        requests = [
            stored_request("k", "m1", 10.0, arguments=1, stored=1),
            stored_request("k", "m1", 20.0, arguments=1, stored=1),
            stored_request("k", "m1", 30.0),
        ]
        calls = [stamped_call("k", 5.0), stamped_call("k", 15.0), stamped_call("k", 25.0), stamped_call("k", 35.0)]
        self.assertEqual(
            blobs.summarize_turns(calls, requests),
            {
                "m1": {
                    "no_stored_demotion": {"calls": 1, "turns": 1, "turns_with_call": 1},
                    "stored_demotion": {"calls": 1, "turns": 1, "turns_with_call": 1},
                }
            },
        )

    def test_a_call_at_a_request_time_belongs_to_the_turn_that_request_closes(self) -> None:
        requests = [stored_request("k", "m1", 10.0), stored_request("k", "m1", 20.0)]
        calls = [stamped_call("k", 10.0), stamped_call("k", 20.0)]
        row = blobs.summarize_turns(calls, requests)["m1"]["no_stored_demotion"]
        self.assertEqual(row, {"calls": 1, "turns": 1, "turns_with_call": 1})

    def test_several_calls_in_one_turn_count_once_as_a_turn_with_a_call(self) -> None:
        requests = [stored_request("k", "m1", 10.0), stored_request("k", "m1", 20.0)]
        calls = [stamped_call("k", 12.0), stamped_call("k", 14.0), stamped_call("k", 16.0)]
        row = blobs.summarize_turns(calls, requests)["m1"]["no_stored_demotion"]
        self.assertEqual(row, {"calls": 3, "turns": 1, "turns_with_call": 1})

    def test_calls_need_not_arrive_in_time_order(self) -> None:
        requests = [stored_request("k", "m1", 13.0), stored_request("k", "m1", 20.0)]
        calls = [stamped_call("k", 16.0), stamped_call("k", 12.0), stamped_call("k", 14.0)]
        # In (13, 20] fall the calls at 16 and 14. The call at 12 belongs to an earlier turn.
        row = blobs.summarize_turns(calls, requests)["m1"]["no_stored_demotion"]
        self.assertEqual(row, {"calls": 2, "turns": 1, "turns_with_call": 1})

    def test_a_turn_without_a_call_is_counted_with_zero_calls(self) -> None:
        requests = [stored_request("k", "m1", 10.0), stored_request("k", "m1", 20.0)]
        row = blobs.summarize_turns([], requests)["m1"]["no_stored_demotion"]
        self.assertEqual(row, {"calls": 0, "turns": 1, "turns_with_call": 0})

    def test_only_alone_calls_of_the_same_keeper_count(self) -> None:
        requests = [stored_request("k", "m1", 10.0), stored_request("k", "m1", 20.0)]
        calls = [stamped_call("k", 15.0, "mixed"), stamped_call("other", 15.0)]
        row = blobs.summarize_turns(calls, requests)["m1"]["no_stored_demotion"]
        self.assertEqual(row, {"calls": 0, "turns": 1, "turns_with_call": 0})

    def test_the_model_is_the_one_of_the_request_that_closes_the_turn(self) -> None:
        requests = [stored_request("k", "m1", 10.0), stored_request("k", "m2", 20.0, arguments=1, stored=1)]
        result = blobs.summarize_turns([stamped_call("k", 15.0)], requests)
        self.assertEqual(result, {"m2": {"stored_demotion": {"calls": 1, "turns": 1, "turns_with_call": 1}}})

    def test_a_keepers_first_request_closes_no_turn(self) -> None:
        self.assertEqual(blobs.summarize_turns([stamped_call("k", 5.0)], [stored_request("k", "m1", 10.0)]), {})

    def test_each_keeper_has_its_own_turns_and_requests_need_not_come_in_order(self) -> None:
        requests = [
            stored_request("b", "m1", 40.0),
            stored_request("a", "m1", 20.0),
            stored_request("b", "m1", 30.0),
            stored_request("a", "m1", 10.0),
        ]
        calls = [stamped_call("a", 15.0), stamped_call("b", 35.0), stamped_call("b", 36.0)]
        row = blobs.summarize_turns(calls, requests)["m1"]["no_stored_demotion"]
        self.assertEqual(row, {"calls": 3, "turns": 2, "turns_with_call": 2})

    def test_a_demoted_argument_without_a_stored_blob_does_not_count_as_stored_demotion(self) -> None:
        requests = [stored_request("k", "m1", 10.0), stored_request("k", "m1", 20.0, arguments=3, stored=0)]
        self.assertEqual(list(blobs.summarize_turns([], requests)["m1"]), ["no_stored_demotion"])


class SummarizeSplitTest(unittest.TestCase):
    REQUESTS = [
        stored_request("k", "m1", 10.0, arguments=1),
        stored_request("k", "m1", 20.0, arguments=1),
        stored_request("k", "m1", 30.0, arguments=0),
        stored_request("k", "m1", 40.0, arguments=0),
    ]
    CALLS = [stamped_call("k", 15.0), stamped_call("k", 25.0), stamped_call("k", 30.0), stamped_call("k", 35.0)]

    def test_what_comes_before_the_instant_and_what_comes_at_or_after_it_are_summarized_apart(self) -> None:
        result = blobs.summarize_split(self.CALLS, self.REQUESTS, 30.0)
        before, after = result["before"], result["after"]
        assert isinstance(before, dict) and isinstance(after, dict)
        self.assertEqual((before["stored_requests"], before["with_demoted_arguments"], before["alone_calls"]), (2, 2, 2))
        self.assertEqual((after["stored_requests"], after["with_demoted_arguments"], after["alone_calls"]), (2, 0, 2))

    def test_a_call_near_the_instant_still_finds_its_neighbours_on_the_other_side(self) -> None:
        result = blobs.summarize_split(self.CALLS, self.REQUESTS, 30.0)
        before, after = result["before"], result["after"]
        assert isinstance(before, dict) and isinstance(after, dict)
        # The call at 25 has the request at 30 after it, which is on the other side of the instant.
        self.assertEqual(before["alone_calls_by_model"], {"m1": 2})
        self.assertEqual(after["alone_calls_by_model"], {"m1": 2})

    def test_the_instant_is_reported_in_utc(self) -> None:
        self.assertEqual(blobs.summarize_split([], [], 30.0)["at"], "1970-01-01T00:00:30+00:00")


class MainTest(unittest.TestCase):
    """Runs the command on a store that holds one of everything, so each reader feeds the right section."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = pathlib.Path(self._tmp.name)

    def run_main(self, *extra: str) -> dict[str, object]:
        out = self.base / "result.json"
        argv = [
            "measure_blob_inputs.py",
            "--base-path",
            str(self.base),
            "--from-date",
            "2026-11-01",
            "--to-date",
            "2026-11-02",
            "--until",
            "2026-11-02T06:00:00Z",
            *extra,
            "--json-out",
            str(out),
        ]
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(blobs.main(), 0)
        return json.loads(out.read_text(encoding="utf-8"))

    def test_the_models_section_follows_the_stored_requests_and_a_split_divides_the_calls(self) -> None:
        self.fill_store()
        result = self.run_main("--split", "2026-11-02T00:00:00Z")
        models = result["by_model"]
        assert isinstance(models, dict)
        self.assertEqual(
            models["requests_by_model"],
            {"deepseek": {"requests": 2, "with_demoted_arguments": 1, "with_stored_demotion": 1}},
        )
        self.assertEqual(models["with_stored_demotion"], 1)
        self.assertEqual(models["last_stored_demotion_by_model"], {"deepseek": "2026-11-02T01:00:00+00:00"})
        # Of alpha's four alone calls, only the one at +2h lies between two stored requests (+1h and +3h).
        self.assertEqual(models["alone_calls_by_model"], {"deepseek": 1, blobs.NO_NEIGHBOUR: 3})
        self.assertEqual(models["alone_calls_by_keeper_and_model"], {"alpha": {"deepseek": 1, blobs.NO_NEIGHBOUR: 3}})
        self.assertEqual(
            models["last_alone_call_by_model"],
            {"deepseek": "2026-11-02T02:00:00+00:00", blobs.NO_NEIGHBOUR: "2026-11-02T01:00:00+00:00"},
        )
        split = result["split"]
        assert isinstance(split, dict)
        self.assertEqual(split["at"], "2026-11-02T00:00:00+00:00")
        before, after = split["before"], split["after"]
        self.assertEqual((before["stored_requests"], before["alone_calls"]), (0, 2))
        self.assertEqual((after["stored_requests"], after["alone_calls"]), (2, 2))
        self.assertEqual(after["alone_calls_by_model"], {"deepseek": 1, blobs.NO_NEIGHBOUR: 1})

    def test_each_turn_is_counted_under_the_model_and_the_exposure_of_the_request_that_closes_it(self) -> None:
        self.fill_store()
        # The request at +3h closes the turn that made the call at +2h. It shows no stored demotion.
        self.assertEqual(
            self.run_main()["turns_by_model"],
            {"deepseek": {"no_stored_demotion": {"calls": 1, "turns": 1, "turns_with_call": 1}}},
        )

    def test_without_a_split_the_summary_has_no_split_section(self) -> None:
        self.fill_store()
        self.assertNotIn("split", self.run_main())

    def test_the_ledger_and_the_captures_feed_their_own_sections(self) -> None:
        self.fill_store()
        result = self.run_main()
        self.assertEqual(result["window"], {"from": "2026-11-01", "to": "2026-11-02", "until": "2026-11-02T06:00:00+00:00"})
        calls = result["blob_calls"]
        assert isinstance(calls, dict)
        self.assertEqual((calls["calls"], calls["alone"], calls["mixed"]), (5, 4, 1))
        self.assertEqual(calls["shape_alone"], {"complete_envelope": 3, "wrapped_arguments": 1})
        self.assertEqual(calls["complete_envelope_alone"], {"calls": 3, "hash_in_store": 1, "hash_not_in_store": 2})
        self.assertEqual(calls["by_day"], {"2026-11-01": {"alone": 2, "mixed": 1}, "2026-11-02": {"alone": 2}})
        history = result["history_arguments"]
        assert isinstance(history, dict)
        self.assertEqual((history["requests"], history["with_demoted_arguments"]), (2, 1))
        self.assertEqual((history["distinct_demoted_arguments"], history["stored_and_same_size"]), (1, 1))
        rows = history["by_keeper_and_model"]
        assert isinstance(rows, list)
        self.assertEqual((rows[0]["keeper"], rows[0]["model"], rows[0]["demoted_arguments_median"]), ("alpha", "deepseek", 1))

    def fill_store(self) -> None:
        put_blob(self.base, SHA_B, "x" * 10)
        write_ledger(
            self.base,
            DAY,
            [
                ledger_row(NOON, "alpha", "Write", {"_blob": envelope(SHA_A)}, wire_outcome="error"),
                ledger_row(NOON, "alpha", "Write", {"_blob": envelope(SHA_B)}, wire_outcome="error"),
                ledger_row(NOON, "beta", "Edit", {"_blob": envelope(SHA_D), "x": 1}, disposition="completed", wire_outcome="ok"),
            ],
        )
        write_ledger(
            self.base,
            NEXT_DAY,
            [
                ledger_row(MIDNIGHT + HOUR, "alpha", "Write", {"_blob": {"content": "c"}}, wire_outcome="error"),
                ledger_row(MIDNIGHT + 2 * HOUR, "alpha", "Write", {"_blob": envelope(SHA_D)}, wire_outcome="error"),
            ],
        )
        put_blob(self.base, SHA_C, "y" * 1000)
        demoted = put_message(self.base, [tool_use({"_blob": envelope(SHA_C, 1000)}), tool_result(marker(SHA_A, 500))])
        write_captures(
            self.base,
            "alpha",
            NEXT_DAY,
            [
                capture_row(MIDNIGHT + HOUR, 5000, [demoted], model="deepseek"),
                capture_row(MIDNIGHT + 3 * HOUR, 5000, [], model="deepseek"),
            ],
        )


if __name__ == "__main__":
    unittest.main()
