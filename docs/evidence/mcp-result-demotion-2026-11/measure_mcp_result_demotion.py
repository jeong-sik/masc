#!/usr/bin/env python3
# pyright: strict
"""Replay RFC-0363 §3.1.2 over stored Keeper checkpoints, read-only.

Four commands. None of them writes under the store it reads.

- ``measure``: for the atoms from --first-atom up to --end-atom of one
  checkpoint, count the bytes the carried messages hold before and after every
  text body of a ``tool_result`` becomes a stored marker.
- ``floor-hole``: over every checkpoint under a traces directory, count the
  results a floor of --floor bytes treats differently when it is checked on
  each text block or on the whole result.
- ``turn-starts``: from one Keeper's ``turn-boundaries.jsonl``, the end of the
  last finished turn before an instant and the start of each turn the lines
  name, with every turn that started past the end of the line before it.
- ``rule-seven``: over one day's system log, the requests a Keeper composed
  past a Librarian point whose start could move when rule 7 of
  RFC-librarian-lifecycle §4.10 bounds it by this turn's start instead of the
  finished end.

A checkpoint is ``<trace_dir>/<trace>.json`` (the head) and the objects it
names under ``<trace_dir>/objects/<sha[:2]>/<sha>``:

- head ``history.segment.segment``: a segment object. Its ``previous`` names an
  older segment and its ``turns[].bundle`` name turn bundles.
- head ``history.turns[].bundle``: the newest turn bundles.
- head ``history.open[]``: messages saved by a turn that has no bundle yet.
- an older head holds its messages inline as ``messages[]``.
- a bundle is JSON lines: an index line, then one message per line.

Definitions:

- atom: the label ``Runtime_model_input_tail_window.annotate`` gives a message.
  A ``system_context`` row is pinned. A ``tool`` row or a
  ``historical_system_context`` row joins the atom before it. Any other
  ``system`` row is pinned. Every other row opens a new atom.
- body: a text a provider encoder sends for a ``tool_result``. A string
  ``content`` is one. A list ``content`` (the stored form of
  ``content_blocks = Some``) holds typed blocks, and each ``text`` block among
  them is one; its plain copy ``text_content`` is another
  (``Agent_core.History.content_block_to_json``).
- measured: the compact JSON of the stored message, blocks and copy both; the
  message measurer counts both.
- wire: the same JSON without ``text_content``, the shape Anthropic, OpenAI and
  Responses send: the typed blocks and not the copy. This is the stored
  vocabulary, not a provider's wire form; OpenAI chat wraps the blocks in one
  more JSON string.
- copy: the bytes of the ``text_content`` strings alone. Gemini sends the copy
  as ``functionResponse.response.result``, and OpenAI chat sends it next to the
  blocks when they hold an image.
- openai chat: the tool-result bodies OpenAI chat sends, each as one more JSON
  string. Without an image it sends the blocks as one JSON string, so each
  ``text`` body is escaped twice (``tool_result_content_string``). With an image
  it sends the copy as the tool message and the ``text`` blocks in a user
  follow-up (``Tool_result_projection.with_image_followups``). Image bytes are
  left out; they are the same before and after.
- marker: ``[masc:blob sha256=<64 hex> bytes=<n> mime=text/plain preview="<p>"]``,
  the preview being ``Tool_blob_store.make_preview`` of the body escaped as
  OCaml ``%S`` does. The sha256 here is a fixed 64-character stand-in of the
  same width.
- demoted (after): a body that is not already a marker becomes a marker when
  the marker, as one JSON string, is shorter than the body as one
  (``shrinks_its_body``). A result is left whole when the text it carries on
  one lane, the longer of its copy and the sum of its ``text`` blocks (or its
  string ``content``), is shorter than --min-result-bytes. Every other block
  stays as it is.

Sizes are bytes, not tokens.
"""

from __future__ import annotations

import argparse
import bisect
import datetime
import json
import pathlib
import re
import struct
import sys
from collections.abc import Iterator, Sequence
from dataclasses import dataclass

PREVIEW_MAX = 200
STAND_IN_SHA256 = "f" * 64
MARKER_PREFIX = "[masc:blob "
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_HEADER_BYTES = 24
STORED_COPY_FIELD = "text_content"
FINISHED_TURN_FLOOR = 2048

type Json = dict[str, Json] | list[Json] | str | int | float | bool | None
type JsonObject = dict[str, Json]


@dataclass(frozen=True, slots=True)
class Problem:
    reason: str


def parse_json(text: str) -> Json:
    value: Json = json.loads(text)
    return value


def as_object(value: Json) -> JsonObject | None:
    return value if isinstance(value, dict) else None


def as_list(value: Json) -> list[Json] | None:
    return value if isinstance(value, list) else None


def as_str(value: Json) -> str | None:
    return value if isinstance(value, str) else None


def as_int(value: Json) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def as_float(value: Json) -> float | None:
    if isinstance(value, bool):
        return None
    return float(value) if isinstance(value, int | float) else None


def byte_length(text: str) -> int:
    return len(text.encode("utf-8"))


def ocaml_escaped(raw: bytes) -> str:
    """``String.escaped``, which ``%S`` applies to the preview."""
    named = {0x22: '\\"', 0x5C: "\\\\", 0x0A: "\\n", 0x09: "\\t", 0x0D: "\\r", 0x08: "\\b"}
    out: list[str] = []
    for byte in raw:
        if byte in named:
            out.append(named[byte])
        elif 0x20 <= byte <= 0x7E:
            out.append(chr(byte))
        else:
            out.append("\\%03d" % byte)
    return "".join(out)


def make_preview(body: bytes) -> bytes:
    """``Tool_blob_store.make_preview``: the first PREVIEW_MAX bytes, line
    breaks as spaces, other control and invalid bytes as ``?``."""
    text = body[:PREVIEW_MAX].decode("utf-8", errors="replace")
    out: list[str] = []
    for ch in text:
        if ch in "\n\r\t":
            out.append(" ")
        elif ord(ch) < 0x20 or ch == "�":
            out.append("?")
        else:
            out.append(ch)
    return "".join(out).encode("utf-8")


def marker_for(body: str) -> str:
    raw = body.encode("utf-8")
    preview = ocaml_escaped(make_preview(raw))
    return '%ssha256=%s bytes=%d mime=text/plain preview="%s"]' % (
        MARKER_PREFIX,
        STAND_IN_SHA256,
        len(raw),
        preview,
    )


def json_string_bytes(text: str) -> int:
    return byte_length(json.dumps(text, ensure_ascii=False))


def demoted_body(body: str) -> str | None:
    """The marker that replaces ``body``, or None when ``body`` stays: it is a
    marker already, or its marker is not shorter than it."""
    if body.startswith(MARKER_PREFIX):
        return None
    marker = marker_for(body)
    return marker if json_string_bytes(marker) < json_string_bytes(body) else None


def compact_bytes(value: Json) -> int:
    return byte_length(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def object_path(trace_dir: pathlib.Path, digest: str) -> pathlib.Path:
    return trace_dir / "objects" / digest[:2] / digest


def read_bundle(trace_dir: pathlib.Path, digest: str) -> list[JsonObject] | Problem:
    lines = [line for line in object_path(trace_dir, digest).read_text("utf-8").split("\n") if line.strip()]
    messages: list[JsonObject] = []
    for line in lines[1:]:
        message = as_object(parse_json(line))
        if message is None:
            return Problem("bundle %s holds a row that is not an object" % digest)
        messages.append(message)
    return messages


def bundle_digests(turns: Json) -> list[str] | Problem:
    digests: list[str] = []
    for turn in as_list(turns) or []:
        digest = as_str((as_object(turn) or {}).get("bundle"))
        if digest is None:
            return Problem("a turn names no bundle")
        digests.append(digest)
    return digests


def segment_bundles(trace_dir: pathlib.Path, digest: str) -> list[str] | Problem:
    chain: list[str] = []
    current: str | None = digest
    while current is not None:
        segment = as_object(parse_json(object_path(trace_dir, current).read_text("utf-8")))
        if segment is None:
            return Problem("segment %s is not an object" % current)
        own = bundle_digests(segment.get("turns"))
        if isinstance(own, Problem):
            return own
        chain = own + chain
        current = as_str(segment.get("previous"))
    return chain


def load_messages(trace_dir: pathlib.Path) -> list[JsonObject] | Problem:
    head = as_object(parse_json((trace_dir / (trace_dir.name + ".json")).read_text("utf-8"))) or {}
    history = as_object(head.get("history"))
    inline = as_list(head.get("messages"))
    if history is None and inline is not None:
        rows = [row for item in inline if (row := as_object(item)) is not None]
        if len(rows) != len(inline):
            return Problem("%s holds a message that is not an object" % trace_dir.name)
        return rows
    if history is None:
        return Problem("%s has neither history nor messages" % trace_dir.name)
    bundles: list[str] = []
    segment = as_object(history.get("segment"))
    if segment is not None:
        segment_digest = as_str(segment.get("segment"))
        if segment_digest is None:
            return Problem("%s names a segment without a digest" % trace_dir.name)
        older = segment_bundles(trace_dir, segment_digest)
        if isinstance(older, Problem):
            return older
        bundles = older
    newest = bundle_digests(history.get("turns"))
    if isinstance(newest, Problem):
        return newest
    messages: list[JsonObject] = []
    for bundle in bundles + newest:
        rows = read_bundle(trace_dir, bundle)
        if isinstance(rows, Problem):
            return rows
        messages.extend(rows)
    for digest in as_list(history.get("open")) or []:
        name = as_str(digest)
        row = None if name is None else as_object(parse_json(object_path(trace_dir, name).read_text("utf-8")))
        if row is None:
            return Problem("%s holds an open message that is not an object" % trace_dir.name)
        messages.append(row)
    return messages


def label(messages: Sequence[JsonObject]) -> tuple[list[int | None], int]:
    """``Runtime_model_input_tail_window.annotate`` over the stored fields.
    ``None`` is Pinned."""
    count = 0
    labels: list[int | None] = []
    for message in messages:
        role = message.get("role")
        origin = message.get("origin")
        if origin == "system_context":
            labels.append(None)
        elif role == "tool" or origin == "historical_system_context":
            labels.append(0 if count == 0 else count - 1)
            count = max(count, 1)
        elif role == "system":
            labels.append(None)
        else:
            labels.append(count)
            count += 1
    return labels, count


def without_stored_copy(block: JsonObject) -> JsonObject:
    return {key: value for key, value in block.items() if key != STORED_COPY_FIELD}


def inner_texts(content: list[Json]) -> list[str]:
    texts: list[str] = []
    for item in content:
        inner = as_object(item)
        if inner is not None and inner.get("type") == "text":
            body = as_str(inner.get("text"))
            if body is not None:
                texts.append(body)
    return texts


def result_text_bytes(block: JsonObject) -> int:
    """The text the result carries on one lane: a string ``content``, or the
    longer of the copy and the sum of the ``text`` blocks."""
    content = block.get("content")
    text = as_str(content)
    if text is not None:
        return byte_length(text)
    blocks = sum(byte_length(body) for body in inner_texts(as_list(content) or []))
    copy = as_str(block.get(STORED_COPY_FIELD))
    return max(blocks, 0 if copy is None else byte_length(copy))


@dataclass(frozen=True, slots=True)
class Demotion:
    block: JsonObject
    inner_texts: int
    string_bodies: int
    plain_copies: int
    kept_shorter: int


def demote_block(block: JsonObject, min_result_bytes: int) -> Demotion:
    unchanged = Demotion(block, 0, 0, 0, 0)
    if block.get("type") != "tool_result" or result_text_bytes(block) < min_result_bytes:
        return unchanged
    content = block.get("content")
    text = as_str(content)
    if text is not None:
        marker = demoted_body(text)
        if marker is None:
            return Demotion(block, 0, 0, 0, 0 if text.startswith(MARKER_PREFIX) else 1)
        return Demotion({**block, "content": marker}, 0, 1, 0, 0)
    items = as_list(content)
    if items is None:
        return unchanged
    inner_demoted = kept = 0
    inner: list[Json] = []
    for item in items:
        inner_block = as_object(item)
        body = None if inner_block is None or inner_block.get("type") != "text" else as_str(inner_block.get("text"))
        marker = None if body is None else demoted_body(body)
        if inner_block is not None and marker is not None:
            inner.append({**inner_block, "text": marker})
            inner_demoted += 1
        else:
            if body is not None and not body.startswith(MARKER_PREFIX):
                kept += 1
            inner.append(item)
    demoted: JsonObject = {**block, "content": inner}
    copy = as_str(block.get(STORED_COPY_FIELD))
    copy_marker = None if copy is None else demoted_body(copy)
    if copy is not None and copy_marker is None and not copy.startswith(MARKER_PREFIX):
        kept += 1
    if copy_marker is not None:
        return Demotion({**demoted, STORED_COPY_FIELD: copy_marker}, inner_demoted, 0, 1, kept)
    return Demotion(demoted, inner_demoted, 0, 0, kept)


def png_dimensions(blobs_dir: pathlib.Path, sha256: str) -> tuple[int, int] | None:
    path = blobs_dir / sha256[:2] / sha256
    if not path.is_file():
        return None
    header = path.read_bytes()[:PNG_HEADER_BYTES]
    if header[: len(PNG_SIGNATURE)] != PNG_SIGNATURE:
        return None
    width, height = struct.unpack(">II", header[16:PNG_HEADER_BYTES])
    return int(width), int(height)


def copy_bytes(blocks: Sequence[JsonObject]) -> int:
    return sum(byte_length(copy) for block in blocks if (copy := as_str(block.get(STORED_COPY_FIELD))) is not None)


def has_image(items: Sequence[Json]) -> bool:
    return any((as_object(item) or {}).get("type") == "image" for item in items)


def openai_chat_bytes(blocks: Sequence[JsonObject]) -> int:
    total = 0
    for block in blocks:
        if block.get("type") != "tool_result":
            continue
        content = block.get("content")
        text = as_str(content)
        items = as_list(content)
        if text is not None:
            total += json_string_bytes(text)
        elif items is not None and has_image(items):
            copy = as_str(block.get(STORED_COPY_FIELD))
            total += (0 if copy is None else json_string_bytes(copy)) + sum(
                compact_bytes(item) for item in items if (as_object(item) or {}).get("type") == "text"
            )
        elif items is not None:
            total += json_string_bytes(json.dumps(items, ensure_ascii=False, separators=(",", ":")))
    return total


def result_shape(content: Json) -> str:
    if isinstance(content, str):
        return "string"
    items = as_list(content)
    if items is None:
        return "other"
    return "+".join(sorted({str((as_object(item) or {}).get("type")) for item in items}))


def image_sha256s(content: Json) -> Iterator[str | None]:
    for item in as_list(content) or []:
        inner = as_object(item)
        if inner is not None and inner.get("type") == "image":
            yield as_str((as_object(inner.get("source")) or {}).get("sha256"))


def image_reference_bytes(content: Json) -> int:
    return sum(
        compact_bytes(item)
        for item in as_list(content) or []
        if (as_object(item) or {}).get("type") == "image"
    )


def message_blocks(message: JsonObject) -> list[JsonObject]:
    return [block for item in as_list(message.get("content")) or [] if (block := as_object(item)) is not None]


def measure(
    messages: Sequence[JsonObject],
    first_atom: int,
    blobs_dir: pathlib.Path | None,
    end_atom: int | None = None,
    min_result_bytes: int = 0,
) -> JsonObject:
    labels, atom_count = label(messages)
    totals = {
        "measured_before": 0,
        "measured_after": 0,
        "wire_before": 0,
        "wire_after": 0,
        "copy_before": 0,
        "copy_after": 0,
        "openai_chat_before": 0,
        "openai_chat_after": 0,
    }
    shapes: dict[str, int] = {}
    wire_by_role_and_block: dict[str, int] = {}
    images: dict[str, int] = {}
    image_bytes = 0
    carried = tool_results = inner_text_demoted = string_demoted = copies_demoted = kept_shorter = 0
    for message, atom in zip(messages, labels):
        if atom is None or atom < first_atom or (end_atom is not None and atom >= end_atom):
            continue
        carried += 1
        blocks = message_blocks(message)
        after_blocks: list[JsonObject] = []
        for block in blocks:
            key = "%s:%s" % (message.get("role", "?"), block.get("type", "?"))
            wire_by_role_and_block[key] = wire_by_role_and_block.get(key, 0) + compact_bytes(without_stored_copy(block))
            if block.get("type") == "tool_result":
                tool_results += 1
                content = block.get("content")
                shape = result_shape(content)
                shapes[shape] = shapes.get(shape, 0) + 1
                image_bytes += image_reference_bytes(content)
                for sha256 in image_sha256s(content):
                    dims = None if blobs_dir is None or sha256 is None else png_dimensions(blobs_dir, sha256)
                    dims_key = "unread" if dims is None else "%dx%d" % dims
                    images[dims_key] = images.get(dims_key, 0) + 1
            demotion = demote_block(block, min_result_bytes)
            inner_text_demoted += demotion.inner_texts
            string_demoted += demotion.string_bodies
            copies_demoted += demotion.plain_copies
            kept_shorter += demotion.kept_shorter
            after_blocks.append(demotion.block)
        before_json: list[Json] = list(blocks)
        after_json: list[Json] = list(after_blocks)
        totals["measured_before"] += compact_bytes({**message, "content": before_json})
        totals["wire_before"] += compact_bytes({**message, "content": [without_stored_copy(b) for b in blocks]})
        totals["measured_after"] += compact_bytes({**message, "content": after_json})
        totals["wire_after"] += compact_bytes({**message, "content": [without_stored_copy(b) for b in after_blocks]})
        totals["copy_before"] += copy_bytes(blocks)
        totals["copy_after"] += copy_bytes(after_blocks)
        totals["openai_chat_before"] += openai_chat_bytes(blocks)
        totals["openai_chat_after"] += openai_chat_bytes(after_blocks)
    shape_counts: JsonObject = dict(shapes)
    image_counts: JsonObject = dict(images)
    ordered: list[tuple[str, int]] = sorted(wire_by_role_and_block.items(), key=lambda kv: -kv[1])
    by_role: JsonObject = {key: value for key, value in ordered}
    result: JsonObject = {
        "messages_total": len(messages),
        "atom_count": atom_count,
        "first_atom": first_atom,
        "end_atom": end_atom,
        "min_result_bytes": min_result_bytes,
        "carried_messages": carried,
        "tool_results": tool_results,
        "tool_result_shapes": shape_counts,
        "inner_text_blocks_demoted": inner_text_demoted,
        "string_bodies_demoted": string_demoted,
        "plain_copies_demoted": copies_demoted,
        "bodies_kept_shorter_than_marker": kept_shorter,
        "image_blocks_by_png_size": image_counts,
        "image_reference_bytes": image_bytes,
    }
    result.update(totals)
    result["wire_bytes_by_role_and_block"] = by_role
    return result


@dataclass(frozen=True, slots=True)
class FloorCount:
    """Results with list ``content`` in one checkpoint, by how a floor sees them."""

    structured: int = 0
    whole_result_reaches: int = 0
    some_block_reaches: int = 0
    hole: int = 0
    hole_text_bytes: int = 0

    def plus(self, other: FloorCount) -> FloorCount:
        return FloorCount(
            self.structured + other.structured,
            self.whole_result_reaches + other.whole_result_reaches,
            self.some_block_reaches + other.some_block_reaches,
            self.hole + other.hole,
            self.hole_text_bytes + other.hole_text_bytes,
        )


def floor_count(messages: Sequence[JsonObject], floor: int) -> FloorCount:
    """``hole``: two or more ``text`` blocks, summing to at least ``floor``
    bytes, each under ``floor``. A floor on each block keeps these whole; a
    floor on the whole result does not."""
    count = FloorCount()
    for message in messages:
        for block in message_blocks(message):
            items = as_list(block.get("content")) if block.get("type") == "tool_result" else None
            if items is None:
                continue
            lengths = [byte_length(body) for body in inner_texts(items)]
            whole = result_text_bytes(block) >= floor
            some = any(length >= floor for length in lengths)
            hole = len(lengths) >= 2 and sum(lengths) >= floor and not some
            count = count.plus(
                FloorCount(1, int(whole), int(some), int(hole), sum(lengths) if hole else 0)
            )
    return count


def checkpoint_dirs(traces_dir: pathlib.Path) -> list[pathlib.Path]:
    return sorted(d for d in traces_dir.iterdir() if d.is_dir() and (d / (d.name + ".json")).is_file())


def floor_hole(traces_dir: pathlib.Path, floor: int) -> JsonObject:
    total = FloorCount()
    per_trace: JsonObject = {}
    unreadable: list[Json] = []
    for trace_dir in checkpoint_dirs(traces_dir):
        loaded = load_messages(trace_dir)
        if isinstance(loaded, Problem):
            unreadable.append(loaded.reason)
            continue
        count = floor_count(loaded, floor)
        total = total.plus(count)
        if count.hole:
            per_trace[trace_dir.name] = {"hole": count.hole, "hole_text_bytes": count.hole_text_bytes}
    return {
        "floor": floor,
        "checkpoints": len(checkpoint_dirs(traces_dir)),
        "structured_results": total.structured,
        "whole_result_reaches_floor": total.whole_result_reaches,
        "some_text_block_reaches_floor": total.some_block_reaches,
        "hole": total.hole,
        "hole_text_bytes": total.hole_text_bytes,
        "hole_by_trace": per_trace,
        "unreadable": unreadable,
    }


@dataclass(frozen=True, slots=True)
class EndLine:
    recorded_at: float
    turn_ref: str
    start_atom: int | None
    end_atom: int | None
    """None for a line with no atom position (``no_atom_history``)."""

    def stated(self) -> int | None:
        """The history position this line states: its end, or, with no atom
        position, its start (``Keeper_librarian_range``'s witness line)."""
        return self.end_atom if self.end_atom is not None else self.start_atom


def end_lines(path: pathlib.Path, trace_id: str) -> list[EndLine]:
    """The ``turn_ended`` lines of ``trace_id`` after its last
    ``history_restarted`` line, in file order. A restart discards the
    positions the lines before it state; a line of another trace is left out."""
    lines: list[EndLine] = []
    for raw in path.read_text("utf-8").split("\n"):
        if not raw.strip():
            continue
        row = as_object(parse_json(raw)) or {}
        if row.get("kind") == "history_restarted" and row.get("trace_id") == trace_id:
            lines = []
            continue
        turn_ref = as_str(row.get("turn_ref"))
        position = as_object(row.get("position")) or {}
        recorded_at = as_float(row.get("recorded_at"))
        if row.get("kind") != "turn_ended" or turn_ref is None or not turn_ref.startswith(trace_id + "#") or recorded_at is None:
            continue
        end_atom = as_int(position.get("end_atom")) if position.get("kind") == "atom_history" else None
        start = as_object(row.get("history_at_start")) or {}
        start_atom = as_int(start.get("start_atom")) if start.get("kind") == "continued_from" else None
        lines.append(EndLine(recorded_at, turn_ref, start_atom, end_atom))
    return lines


def latest_stated(lines: Sequence[EndLine]) -> int | None:
    stated = [position for line in lines if (position := line.stated()) is not None]
    return max(stated) if stated else None


def turn_starts(lines: Sequence[EndLine], at: float) -> JsonObject:
    """``finished_end_atom_before_at``: the latest position the lines written
    by ``at`` state, which the turn running at ``at`` reads as the end of the
    completed history."""
    before = [line for line in lines if line.recorded_at <= at]
    after = [line for line in lines if line.recorded_at > at]
    gaps: list[Json] = []
    previous: int | None = None
    for line in lines:
        if line.start_atom is not None and previous is not None and line.start_atom > previous:
            gaps.append(
                {
                    "turn_ref": line.turn_ref,
                    "previous_end_atom": previous,
                    "start_atom": line.start_atom,
                    "atoms_without_end_line": line.start_atom - previous,
                }
            )
        stated = line.stated()
        if stated is not None:
            previous = stated if previous is None else max(previous, stated)
    next_line: JsonObject | None = (
        None
        if not after
        else {"turn_ref": after[0].turn_ref, "start_atom": after[0].start_atom, "end_atom": after[0].end_atom}
    )
    return {
        "at": datetime.datetime.fromtimestamp(at, datetime.UTC).isoformat(),
        "end_lines": len(lines),
        "finished_end_atom_before_at": latest_stated(before),
        "first_line_after_at": next_line,
        "turns_started_past_the_line_before": len(gaps),
        "gaps": gaps,
    }


CARRIED_RANGE = re.compile(
    r"model input carried range runtime=\S+ origin=(\S+) first_atom=(\d+) atoms=(\d+)/(\d+) transmitted_bytes=(\d+)"
)
LIBRARIAN_POINT_ORIGIN = "past_librarian_point"


def rule_seven(lines: Sequence[EndLine], log_path: pathlib.Path, keeper: str) -> JsonObject:
    """For each request a Keeper composed past a Librarian point (the only
    origin rule 7 bounds), the finished end ``B`` its turn read and the start
    ``S`` its turn wrote in its own end line. Rule 7 bounds the accepted start
    by ``B`` before the change and by ``max(B, S)`` after it, so the two can
    differ only for a logged ``first_atom == B < S``; there the new start is
    at most ``S``. A request whose turn wrote no line has no ``S`` here; those
    at ``B`` or past it are counted apart, since only they could move. The log
    names each request twice; each ``seq`` is counted once."""
    times = [line.recorded_at for line in lines]
    seen: set[int] = set()
    counts = {"below_finished_end": 0, "at_finished_end_and_turn_start": 0, "at_finished_end_below_turn_start": 0,
              "past_finished_end": 0, "turn_wrote_no_line": 0, "turn_wrote_no_line_at_or_past_finished_end": 0,
              "before_first_line": 0, "other_origin": 0}
    cases: list[Json] = []
    needle = '"keeper_name":"%s"' % keeper
    with log_path.open(encoding="utf-8") as log:
        for raw in log:
            if needle not in raw or "model input carried range runtime" not in raw:
                continue
            row = as_object(parse_json(raw)) or {}
            seq = as_int(row.get("seq"))
            ts = as_str(row.get("ts"))
            found = CARRIED_RANGE.search(as_str(row.get("message")) or "")
            if seq is None or ts is None or found is None or seq in seen:
                continue
            seen.add(seq)
            origin, first_atom, transmitted = found.group(1), int(found.group(2)), int(found.group(5))
            if not origin.startswith(LIBRARIAN_POINT_ORIGIN):
                counts["other_origin"] += 1
                continue
            at = datetime.datetime.fromisoformat(ts).timestamp()
            index = bisect.bisect_right(times, at)
            finished = latest_stated(lines[:index])
            start = lines[index].start_atom if index < len(lines) else None
            if finished is None:
                counts["before_first_line"] += 1
            elif start is None:
                counts["turn_wrote_no_line"] += 1
                if first_atom >= finished:
                    counts["turn_wrote_no_line_at_or_past_finished_end"] += 1
            elif first_atom < finished:
                counts["below_finished_end"] += 1
            elif first_atom == finished and start == finished:
                counts["at_finished_end_and_turn_start"] += 1
            else:
                key = "past_finished_end" if first_atom > finished else "at_finished_end_below_turn_start"
                counts[key] += 1
                cases.append({"ts": ts, "origin": origin, "first_atom": first_atom, "finished_end_atom": finished,
                              "turn_start_atom": start, "transmitted_bytes": transmitted})
    result: JsonObject = {
        "keeper": keeper,
        "librarian_point_requests": sum(
            v for k, v in counts.items() if k not in ("other_origin", "turn_wrote_no_line_at_or_past_finished_end")
        ),
    }
    result.update(counts)
    result["cases"] = cases
    return result


def write(result: JsonObject, json_out: pathlib.Path | None) -> None:
    text = json.dumps(result, indent=1, ensure_ascii=False) + "\n"
    if json_out is None:
        sys.stdout.write(text)
    else:
        json_out.write_text(text, "utf-8")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Replay RFC-0363 §3.1.2 over stored Keeper checkpoints.")
    commands = parser.add_subparsers(dest="command", required=True)
    measure_args = commands.add_parser("measure")
    measure_args.add_argument("trace_dir", type=pathlib.Path)
    measure_args.add_argument("--first-atom", type=int, required=True)
    measure_args.add_argument("--end-atom", type=int, default=None, help="exclusive; default: the end of the history")
    measure_args.add_argument("--min-result-bytes", type=int, default=0)
    measure_args.add_argument("--blobs-dir", type=pathlib.Path, default=None)
    measure_args.add_argument("--json-out", type=pathlib.Path, default=None)
    hole_args = commands.add_parser("floor-hole")
    hole_args.add_argument("traces_dir", type=pathlib.Path)
    hole_args.add_argument("--floor", type=int, default=FINISHED_TURN_FLOOR)
    hole_args.add_argument("--json-out", type=pathlib.Path, default=None)
    starts_args = commands.add_parser("turn-starts")
    starts_args.add_argument("boundaries", type=pathlib.Path)
    starts_args.add_argument("--trace-id", required=True)
    starts_args.add_argument("--at", required=True, help="ISO 8601 instant, e.g. 2026-11-06T12:12:10Z")
    starts_args.add_argument("--json-out", type=pathlib.Path, default=None)
    seven_args = commands.add_parser("rule-seven")
    seven_args.add_argument("boundaries", type=pathlib.Path)
    seven_args.add_argument("system_log", type=pathlib.Path)
    seven_args.add_argument("--keeper", required=True)
    seven_args.add_argument("--trace-id", required=True)
    seven_args.add_argument("--json-out", type=pathlib.Path, default=None)
    args = parser.parse_args(argv)
    command: str = args.command
    json_out: pathlib.Path | None = args.json_out
    match command:
        case "measure":
            trace_dir: pathlib.Path = args.trace_dir
            blobs: pathlib.Path | None = args.blobs_dir
            loaded = load_messages(trace_dir.expanduser())
            if isinstance(loaded, Problem):
                sys.stderr.write(loaded.reason + "\n")
                return 2
            first_atom: int = args.first_atom
            end_atom: int | None = args.end_atom
            min_result_bytes: int = args.min_result_bytes
            blobs_dir = None if blobs is None else blobs.expanduser()
            write(measure(loaded, first_atom, blobs_dir, end_atom=end_atom, min_result_bytes=min_result_bytes), json_out)
        case "floor-hole":
            traces_dir: pathlib.Path = args.traces_dir
            floor: int = args.floor
            write(floor_hole(traces_dir.expanduser(), floor), json_out)
        case "turn-starts":
            boundaries: pathlib.Path = args.boundaries
            trace_id: str = args.trace_id
            at_text: str = args.at
            at = datetime.datetime.fromisoformat(at_text).timestamp()
            write(turn_starts(end_lines(boundaries.expanduser(), trace_id), at), json_out)
        case "rule-seven":
            seven_boundaries: pathlib.Path = args.boundaries
            system_log: pathlib.Path = args.system_log
            keeper: str = args.keeper
            seven_trace: str = args.trace_id
            lines = end_lines(seven_boundaries.expanduser(), seven_trace)
            write(rule_seven(lines, system_log.expanduser(), keeper), json_out)
        case _:
            sys.stderr.write("unknown command %s\n" % command)
            return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
