# pyright: strict
"""Checks the arithmetic of measure_mcp_result_demotion.py on small synthetic stores.

Run: python3 -m unittest discover -s docs/evidence/mcp-result-demotion-2026-11
"""

from __future__ import annotations

import json
import pathlib
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_mcp_result_demotion as replay  # noqa: E402
from measure_mcp_result_demotion import Json, JsonObject  # noqa: E402

LONG_TEXT = "화면 " * 1000
SHORT_TEXT = "pressed Enter"
IMAGE_SHA = "a" * 64
FLOOR = 2048


def message(role: str, blocks: list[Json], origin: str = "conversation") -> JsonObject:
    return {"role": role, "origin": origin, "content": blocks}


def text(body: str) -> JsonObject:
    return {"type": "text", "text": body}


def structured_result(inner: list[Json]) -> JsonObject:
    copy = "\n".join(
        body for item in inner if (body := replay.as_str((replay.as_object(item) or {}).get("text"))) is not None
    )
    return {"type": "tool_result", "tool_use_id": "c0", "content": inner, "text_content": copy}


def image() -> JsonObject:
    return {"type": "image", "source": {"type": "media_ref", "sha256": IMAGE_SHA, "bytes": 10, "media_type": "image/png"}}


def inner_items(block: JsonObject) -> list[Json]:
    items = replay.as_list(block.get("content"))
    assert items is not None
    return items


def inner_text(item: Json) -> str:
    body = replay.as_str((replay.as_object(item) or {}).get("text"))
    assert body is not None
    return body


def number(result: JsonObject, key: str) -> int:
    value = replay.as_int(result.get(key))
    assert value is not None
    return value


class EscapingTest(unittest.TestCase):
    def test_high_bytes_become_three_digit_escapes(self) -> None:
        self.assertEqual(replay.ocaml_escaped("가".encode("utf-8")), "\\234\\176\\128")

    def test_named_escapes(self) -> None:
        self.assertEqual(replay.ocaml_escaped(b'a"\\\n'), 'a\\"\\\\\\n')

    def test_preview_keeps_the_first_200_bytes_and_blanks_line_breaks(self) -> None:
        preview = replay.make_preview(b"a\nb" + b"c" * 300)
        self.assertEqual(len(preview), replay.PREVIEW_MAX)
        self.assertTrue(preview.startswith(b"a b"))


class LabelTest(unittest.TestCase):
    def test_tool_and_historical_rows_join_the_atom_before(self) -> None:
        rows = [
            message("system", [], origin="system_context"),
            message("user", [text("q")]),
            message("system", [text("carrier")], origin="historical_system_context"),
            message("assistant", [text("a")]),
            message("tool", [text("r")]),
            message("system", [text("prompt")]),
        ]
        labels, count = replay.label(rows)
        self.assertEqual(labels, [None, 0, 0, 1, 1, None])
        self.assertEqual(count, 2)


class DemoteTest(unittest.TestCase):
    def test_inner_text_and_the_plain_copy_become_markers_and_the_image_stays(self) -> None:
        demotion = replay.demote_block(structured_result([text(LONG_TEXT), image()]), 0)
        self.assertEqual((demotion.inner_texts, demotion.string_bodies, demotion.plain_copies), (1, 0, 1))
        items = inner_items(demotion.block)
        self.assertTrue(inner_text(items[0]).startswith(replay.MARKER_PREFIX))
        self.assertEqual(items[1], image())
        self.assertTrue(str(demotion.block["text_content"]).startswith(replay.MARKER_PREFIX))

    def test_a_marker_is_not_demoted_again(self) -> None:
        marker = replay.marker_for(LONG_TEXT)
        block: JsonObject = {**structured_result([text(marker)]), "text_content": marker}
        demotion = replay.demote_block(block, 0)
        self.assertEqual((demotion.inner_texts, demotion.plain_copies, demotion.kept_shorter), (0, 0, 0))
        self.assertEqual(demotion.block, block)

    def test_a_body_shorter_than_its_marker_stays(self) -> None:
        demotion = replay.demote_block(structured_result([text(LONG_TEXT), text(SHORT_TEXT)]), 0)
        items = inner_items(demotion.block)
        self.assertEqual((demotion.inner_texts, demotion.plain_copies, demotion.kept_shorter), (1, 1, 1))
        self.assertTrue(inner_text(items[0]).startswith(replay.MARKER_PREFIX))
        self.assertEqual(inner_text(items[1]), SHORT_TEXT)

    def test_the_floor_counts_the_whole_result(self) -> None:
        half = "v" * (FLOOR // 2)
        split = replay.demote_block(structured_result([text(half), text(half)]), FLOOR)
        under = replay.demote_block(structured_result([text("u" * (FLOOR - 1))]), FLOOR)
        self.assertEqual((split.inner_texts, split.plain_copies), (2, 1))
        self.assertEqual((under.inner_texts, under.plain_copies), (0, 0))

    def test_measured_drops_by_the_blocks_and_the_copy(self) -> None:
        rows = [
            message("user", [text("q")]),
            message("assistant", [{"type": "tool_use", "id": "c0", "name": "masc_dos_screen", "input": {}}]),
            message("tool", [structured_result([text(LONG_TEXT), image()])]),
        ]
        result = replay.measure(rows, first_atom=0, blobs_dir=None)
        measured_drop = number(result, "measured_before") - number(result, "measured_after")
        wire_drop = number(result, "wire_before") - number(result, "wire_after")
        copy_drop = number(result, "copy_before") - number(result, "copy_after")
        openai_drop = number(result, "openai_chat_before") - number(result, "openai_chat_after")
        self.assertGreater(wire_drop, 0)
        self.assertGreater(copy_drop, 0)
        self.assertGreater(openai_drop, 0)
        self.assertGreater(measured_drop, wire_drop)
        self.assertEqual(result["tool_result_shapes"], {"image+text": 1})

    def test_openai_chat_escapes_a_text_only_result_twice(self) -> None:
        quoted = '"' * 100
        rows = [message("tool", [structured_result([text(quoted)])])]
        result = replay.measure(rows, first_atom=0, blobs_dir=None)
        once = len(json.dumps([text(quoted)], separators=(",", ":")))
        self.assertEqual(number(result, "openai_chat_before"), len(json.dumps(json.dumps([text(quoted)], separators=(",", ":")))))
        self.assertGreater(number(result, "openai_chat_before"), once)

    def test_atoms_before_the_first_atom_are_not_counted(self) -> None:
        rows = [
            message("user", [text("old")]),
            message("tool", [structured_result([text(LONG_TEXT)])]),
            message("user", [text("new")]),
        ]
        result = replay.measure(rows, first_atom=1, blobs_dir=None)
        self.assertEqual(result["carried_messages"], 1)
        self.assertEqual(result["tool_results"], 0)

    def test_atoms_from_the_end_atom_on_are_not_counted(self) -> None:
        rows = [
            message("user", [text("old")]),
            message("tool", [structured_result([text(LONG_TEXT)])]),
            message("user", [text("new")]),
        ]
        result = replay.measure(rows, first_atom=0, blobs_dir=None, end_atom=1)
        self.assertEqual(result["carried_messages"], 2)
        self.assertEqual(result["tool_results"], 1)


class FloorHoleTest(unittest.TestCase):
    def test_only_small_blocks_that_sum_past_the_floor_are_the_hole(self) -> None:
        half = "v" * (FLOOR // 2)
        rows = [
            message("tool", [structured_result([text(half), text(half)])]),
            message("tool", [structured_result([text("w" * FLOOR), text(SHORT_TEXT)])]),
            message("tool", [structured_result([text(SHORT_TEXT), text(SHORT_TEXT)])]),
        ]
        count = replay.floor_count(rows, FLOOR)
        self.assertEqual(
            (count.structured, count.whole_result_reaches, count.some_block_reaches, count.hole, count.hole_text_bytes),
            (3, 2, 1, 1, FLOOR),
        )


class TurnStartsTest(unittest.TestCase):
    def test_finished_end_and_turns_that_started_past_the_line_before(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "turn-boundaries.jsonl"

            def line(turn: int, at: float, start: int, end: int) -> str:
                row: JsonObject = {
                    "kind": "turn_ended",
                    "recorded_at": at,
                    "turn_ref": "trace-x#%d" % turn,
                    "history_at_start": {"kind": "continued_from", "start_atom": start, "start_atom_digest": "d"},
                    "position": {"kind": "atom_history", "end_atom": end, "last_atom_digest": "d"},
                    "task_context": {"kind": "no_task"},
                }
                return json.dumps(row)

            other: JsonObject = {"kind": "turn_ended", "recorded_at": 5.0, "turn_ref": "trace-y#1",
                                 "history_at_start": "fresh_history",
                                 "position": {"kind": "atom_history", "end_atom": 99, "last_atom_digest": "d"}}
            path.write_text("\n".join([line(1, 10.0, 0, 4), json.dumps(other), line(2, 20.0, 7, 9), line(3, 30.0, 9, 12)]) + "\n", "utf-8")
            result = replay.turn_starts(replay.end_lines(path, "trace-x"), at=25.0)
            self.assertEqual(result["finished_end_atom_before_at"], 9)
            self.assertEqual(result["first_line_after_at"], {"turn_ref": "trace-x#3", "start_atom": 9, "end_atom": 12})
            self.assertEqual(result["turns_started_past_the_line_before"], 1)
            self.assertEqual(
                result["gaps"],
                [{"turn_ref": "trace-x#2", "previous_end_atom": 4, "start_atom": 7, "atoms_without_end_line": 3}],
            )

            restart: JsonObject = {"kind": "history_restarted", "recorded_at": 40.0, "trace_id": "trace-x"}
            official: JsonObject = {"kind": "turn_ended", "recorded_at": 50.0, "turn_ref": "trace-x#4",
                                    "history_at_start": {"kind": "continued_from", "start_atom": 3, "start_atom_digest": "d"},
                                    "position": "no_atom_history"}
            with path.open("a", encoding="utf-8") as appended:
                appended.write(json.dumps(restart) + "\n" + json.dumps(official) + "\n")
            after_restart = replay.turn_starts(replay.end_lines(path, "trace-x"), at=60.0)
            self.assertEqual(after_restart["end_lines"], 1)
            self.assertEqual(after_restart["finished_end_atom_before_at"], 3)


class RuleSevenTest(unittest.TestCase):
    def test_each_request_is_placed_against_the_finished_end_and_its_turn_start(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            boundaries = pathlib.Path(tmp) / "turn-boundaries.jsonl"
            log = pathlib.Path(tmp) / "system_log.jsonl"

            def line(turn: int, at: float, start: int, end: int) -> str:
                row: JsonObject = {
                    "kind": "turn_ended",
                    "recorded_at": at,
                    "turn_ref": "trace-x#%d" % turn,
                    "history_at_start": {"kind": "continued_from", "start_atom": start, "start_atom_digest": "d"},
                    "position": {"kind": "atom_history", "end_atom": end, "last_atom_digest": "d"},
                    "task_context": {"kind": "no_task"},
                }
                return json.dumps(row)

            def request(seq: int, ts: str, origin: str, first_atom: int, keeper: str = "k") -> str:
                message = "model input carried range runtime=r origin=%s first_atom=%d atoms=1/9 transmitted_bytes=5" % (
                    origin, first_atom)
                return json.dumps({"seq": seq, "ts": ts, "keeper_name": keeper, "message": message},
                                  separators=(",", ":"))

            # Turn 2 ended at 9 and turn 3 began at 12: a turn saved 9..11 and wrote no line.
            boundaries.write_text("\n".join([line(1, 10.0, 0, 4), line(2, 20.0, 4, 9), line(3, 40.0, 12, 14)]) + "\n",
                                  "utf-8")
            point = "past_librarian_point:turn_record#1"
            rows = [
                request(1, "1970-01-01T00:00:05+00:00", point, 0),
                request(2, "1970-01-01T00:00:15+00:00", point, 2),
                request(2, "1970-01-01T00:00:15+00:00", point, 2),
                request(3, "1970-01-01T00:00:25+00:00", point, 9),
                request(4, "1970-01-01T00:00:26+00:00", "turn_start:9", 9),
                request(5, "1970-01-01T00:00:27+00:00", point, 9, keeper="other"),
                request(6, "1970-01-01T00:00:45+00:00", point, 14),
                request(7, "1970-01-01T00:00:46+00:00", point, 10),
            ]
            log.write_text("\n".join(rows) + "\n", "utf-8")
            result = replay.rule_seven(replay.end_lines(boundaries, "trace-x"), log, "k")
            self.assertEqual(result["before_first_line"], 1)
            self.assertEqual(result["below_finished_end"], 1)
            self.assertEqual(result["at_finished_end_below_turn_start"], 1)
            self.assertEqual(result["at_finished_end_and_turn_start"], 0)
            self.assertEqual(result["past_finished_end"], 0)
            self.assertEqual(result["turn_wrote_no_line"], 2)
            self.assertEqual(result["turn_wrote_no_line_at_or_past_finished_end"], 1)
            self.assertEqual(result["other_origin"], 1)
            self.assertEqual(result["librarian_point_requests"], 5)
            self.assertEqual(
                result["cases"],
                [{"ts": "1970-01-01T00:00:25+00:00", "origin": point, "first_atom": 9, "finished_end_atom": 9,
                  "turn_start_atom": 12, "transmitted_bytes": 5}],
            )


class StoreTest(unittest.TestCase):
    def test_reads_segment_turn_and_open_objects_and_png_sizes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            trace = root / "trace-1"
            blobs = root / "tool_blobs"

            def put(digest: str, body: str) -> None:
                path = trace / "objects" / digest[:2] / digest
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(body, "utf-8")

            first = message("user", [text("q")])
            second = message("tool", [structured_result([text(LONG_TEXT), image()])])
            third = message("user", [text("next")])
            put("b1" * 32, json.dumps({"messages": ["x"]}) + "\n" + json.dumps(first) + "\n")
            put("s1" * 32, json.dumps({"previous": None, "turns": [{"bundle": "b1" * 32}]}))
            put("b2" * 32, json.dumps({"messages": ["y"]}) + "\n" + json.dumps(second) + "\n")
            put("o1" * 32, json.dumps(third))
            head = {"history": {"segment": {"segment": "s1" * 32}, "turns": [{"bundle": "b2" * 32}], "open": ["o1" * 32]}}
            (trace / "trace-1.json").write_text(json.dumps(head), "utf-8")
            png = blobs / IMAGE_SHA[:2] / IMAGE_SHA
            png.parent.mkdir(parents=True)
            png.write_bytes(replay.PNG_SIGNATURE + b"\x00\x00\x00\x0dIHDR" + struct.pack(">II", 640, 480))

            messages = replay.load_messages(trace)
            assert not isinstance(messages, replay.Problem)
            self.assertEqual(messages, [first, second, third])
            result = replay.measure(messages, first_atom=0, blobs_dir=blobs)
            self.assertEqual(result["image_blocks_by_png_size"], {"640x480": 1})

    def test_reads_an_older_head_with_inline_messages(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            trace = pathlib.Path(tmp) / "trace-2"
            trace.mkdir()
            rows = [message("user", [text("q")]), message("tool", [structured_result([text(LONG_TEXT)])])]
            (trace / "trace-2.json").write_text(json.dumps({"version": 1, "messages": rows}), "utf-8")
            self.assertEqual(replay.load_messages(trace), rows)


if __name__ == "__main__":
    unittest.main()
