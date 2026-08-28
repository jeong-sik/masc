#!/usr/bin/env python3
"""Verify one complete Keeper Skill-use evidence bundle offline."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import stat
import struct
import sys
from typing import Any, cast
import uuid
import zlib

import join_natural_keeper_skill_ledger as ledger_join
import keeper_skill_use_proof as proof_collector
import capture_keeper_skill_tui_proof as tui_capture


SCHEMA = "masc.keeper-skill-proof-verification/v1"
JOIN_SCHEMA = "masc.natural-keeper-skill-ledger-join/v2"
PROOF_SCHEMA = "masc.keeper-skill-use-proof.v2"
TUI_SCHEMA = "masc.keeper-skill-tui-proof.v3"
BUILD_SCHEMA = "masc.tui-build-evidence/v1"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
JOIN_ARTIFACTS = {
    "producer-receipt.json",
    "health-before.json",
    "health-after.json",
    "dashboard-tools-before.json",
    "dashboard-tools-after.json",
    "historical-skill-activations-before.json",
    "historical-skill-activations-after.json",
    "durable-skill-activations-before.json",
    "durable-skill-activations-after.json",
    "source-before.json",
    "source-after.json",
}
PROOF_ARTIFACTS = {
    "health.json",
    "dashboard-tools.json",
    "skill-activations.json",
    "tui-build-evidence.json",
    "masc_tui.exe",
}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_DEPTHS_BY_COLOR_TYPE = {
    0: {1, 2, 4, 8, 16},
    2: {8, 16},
    3: {1, 2, 4, 8},
    4: {8, 16},
    6: {8, 16},
}
PNG_SAMPLES_BY_COLOR_TYPE = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
PNG_ADAM7_PASSES = (
    (0, 0, 8, 8),
    (4, 0, 8, 8),
    (0, 4, 4, 8),
    (2, 0, 4, 4),
    (0, 2, 2, 4),
    (1, 0, 2, 2),
    (0, 1, 1, 2),
)


class VerificationError(RuntimeError):
    pass


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise VerificationError(detail)


def digest(payload: bytes) -> str:
    return sha256(payload).hexdigest()


def ledger_projection_matches(line: str, session_id: str, ledger_revision: str) -> bool:
    normalized = line.strip(" │")
    return normalized == f"session={session_id}  ledger={ledger_revision}"


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def decode_object(payload: bytes, context: str) -> dict[str, Any]:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for name, value in pairs:
            require(name not in result, f"{context} repeats field {name}")
            result[name] = value
        return result

    try:
        value = json.loads(payload, object_pairs_hook=reject_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"invalid JSON in {context}: {error}") from error
    require(isinstance(value, dict), f"{context} is not an object")
    return cast(dict[str, Any], value)


def object_field(value: Any, field: str, context: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{context} is not an object")
    child = value.get(field)
    require(isinstance(child, dict), f"{context}.{field} is not an object")
    return cast(dict[str, Any], child)


def list_field(value: Any, field: str, context: str) -> list[Any]:
    require(isinstance(value, dict), f"{context} is not an object")
    child = value.get(field)
    require(isinstance(child, list), f"{context}.{field} is not an array")
    return cast(list[Any], child)


def string_field(value: Any, field: str, context: str) -> str:
    require(isinstance(value, dict), f"{context} is not an object")
    child = value.get(field)
    require(isinstance(child, str) and child != "", f"{context}.{field} is empty")
    return cast(str, child)


def integer_field(value: Any, field: str, context: str) -> int:
    require(isinstance(value, dict), f"{context} is not an object")
    child = value.get(field)
    require(
        isinstance(child, int) and not isinstance(child, bool) and child >= 0,
        f"{context}.{field} is not a nonnegative integer",
    )
    return cast(int, child)


def regular_file_bytes(path: Path, context: str) -> bytes:
    require(not path.is_symlink(), f"{context} must not be a symlink")
    try:
        mode = path.stat().st_mode
        require(stat.S_ISREG(mode), f"{context} must be a regular file")
        return path.read_bytes()
    except OSError as error:
        raise VerificationError(f"cannot read {context}: {error}") from error


def load_manifest(
    path: Path, *, expected_sha256: str, expected_schema: str, context: str
) -> tuple[dict[str, Any], bytes, Path]:
    require(
        SHA256_RE.fullmatch(expected_sha256) is not None, f"{context} SHA is invalid"
    )
    payload = regular_file_bytes(path, context)
    require(digest(payload) == expected_sha256, f"{context} SHA differs")
    value = decode_object(payload, context)
    require(value.get("schema") == expected_schema, f"{context} schema is unsupported")
    root = path.parent.resolve(strict=True)
    require(not os.path.lexists(root / "INCOMPLETE"), f"{context} root is incomplete")
    return value, payload, root


def verify_file(
    *, root: Path, name: str, expected: dict[str, Any], context: str
) -> tuple[dict[str, Any], bytes]:
    require(Path(name).name == name, f"{context} name is not one path component")
    path = root / name
    require(not path.is_symlink(), f"{context} must not be a symlink")
    resolved = path.resolve(strict=True)
    require(resolved.parent == root, f"{context} escapes its evidence root")
    payload = regular_file_bytes(resolved, context)
    require(expected.get("bytes") == len(payload), f"{context} byte count differs")
    require(expected.get("sha256") == digest(payload), f"{context} SHA differs")
    return {"bytes": len(payload), "sha256": digest(payload)}, payload


def verify_artifact_set(
    manifest: dict[str, Any],
    *,
    root: Path,
    expected_names: set[str],
    context: str,
) -> tuple[dict[str, dict[str, Any]], dict[str, bytes]]:
    declared = object_field(manifest, "artifacts", context)
    require(set(declared) == expected_names, f"{context} artifact set differs")
    verified: dict[str, dict[str, Any]] = {}
    payloads: dict[str, bytes] = {}
    for name in sorted(expected_names):
        expected = object_field(declared, name, f"{context}.artifacts")
        identity, payload = verify_file(
            root=root,
            name=name,
            expected=expected,
            context=f"{context} artifact {name}",
        )
        verified[name] = identity
        payloads[name] = payload
    return verified, payloads


def png_extent(size: int, start: int, step: int) -> int:
    return 0 if size <= start else (size - start + step - 1) // step


def png_scanline_layouts(
    *, width: int, height: int, bit_depth: int, color_type: int, interlace: int
) -> list[tuple[int, int]]:
    samples = PNG_SAMPLES_BY_COLOR_TYPE[color_type]
    passes = ((0, 0, 1, 1),) if interlace == 0 else PNG_ADAM7_PASSES
    layouts: list[tuple[int, int]] = []
    for start_x, start_y, step_x, step_y in passes:
        pass_width = png_extent(width, start_x, step_x)
        pass_height = png_extent(height, start_y, step_y)
        if pass_width == 0 or pass_height == 0:
            continue
        row_bytes = (pass_width * samples * bit_depth + 7) // 8
        layouts.append((pass_height, row_bytes))
    return layouts


def validate_png(payload: bytes, context: str) -> tuple[int, int]:
    require(payload.startswith(PNG_SIGNATURE), f"{context} is not a PNG")
    offset = len(PNG_SIGNATURE)
    chunk_index = 0
    width = 0
    height = 0
    bit_depth = 0
    color_type = 0
    interlace = 0
    idat_parts: list[bytes] = []
    idat_closed = False
    saw_plte = False
    saw_iend = False
    while offset < len(payload):
        require(len(payload) - offset >= 12, f"{context} has a truncated PNG chunk")
        chunk_length = struct.unpack(">I", payload[offset : offset + 4])[0]
        chunk_type = payload[offset + 4 : offset + 8]
        require(
            len(chunk_type) == 4
            and all(
                ord("A") <= byte <= ord("Z") or ord("a") <= byte <= ord("z")
                for byte in chunk_type
            )
            and ord("A") <= chunk_type[2] <= ord("Z"),
            f"{context} has an invalid PNG chunk type",
        )
        data_start = offset + 8
        data_end = data_start + chunk_length
        chunk_end = data_end + 4
        require(chunk_end <= len(payload), f"{context} has a truncated PNG chunk")
        chunk_data = payload[data_start:data_end]
        expected_crc = struct.unpack(">I", payload[data_end:chunk_end])[0]
        require(
            zlib.crc32(chunk_type + chunk_data) & 0xFFFFFFFF == expected_crc,
            f"{context} {chunk_type!r} checksum differs",
        )
        if chunk_index == 0:
            require(
                chunk_type == b"IHDR" and chunk_length == 13,
                f"{context} first chunk is not IHDR",
            )
            (
                width,
                height,
                bit_depth,
                color_type,
                compression,
                filter_method,
                interlace,
            ) = struct.unpack(">IIBBBBB", chunk_data)
            require(width > 0 and height > 0, f"{context} dimensions are invalid")
            require(
                color_type in PNG_DEPTHS_BY_COLOR_TYPE
                and bit_depth in PNG_DEPTHS_BY_COLOR_TYPE[color_type],
                f"{context} IHDR color encoding is invalid",
            )
            require(
                compression == 0 and filter_method == 0 and interlace in (0, 1),
                f"{context} IHDR methods are invalid",
            )
        else:
            require(chunk_type != b"IHDR", f"{context} repeats IHDR")
        if chunk_type == b"PLTE":
            require(
                not saw_plte and not idat_parts,
                f"{context} PLTE is repeated or follows IDAT",
            )
            entries, remainder = divmod(chunk_length, 3)
            require(
                remainder == 0
                and 1 <= entries <= 256
                and color_type not in (0, 4)
                and (color_type != 3 or entries <= 2**bit_depth),
                f"{context} PLTE is invalid for its IHDR",
            )
            saw_plte = True
        if chunk_type == b"IDAT":
            require(not idat_closed, f"{context} has nonconsecutive IDAT chunks")
            require(
                color_type != 3 or saw_plte,
                f"{context} indexed PNG has no PLTE before IDAT",
            )
            idat_parts.append(chunk_data)
        elif idat_parts and chunk_type != b"IEND":
            idat_closed = True
        if chunk_type == b"IEND":
            require(chunk_length == 0, f"{context} IEND is not empty")
            require(idat_parts != [], f"{context} has no IDAT chunk")
            require(chunk_end == len(payload), f"{context} has bytes after IEND")
            saw_iend = True
            offset = chunk_end
            break
        if chunk_type[0] & 0x20 == 0:
            require(
                chunk_type in (b"IHDR", b"PLTE", b"IDAT"),
                f"{context} has an unsupported critical PNG chunk",
            )
        offset = chunk_end
        chunk_index += 1
    require(saw_iend and offset == len(payload), f"{context} has no terminal IEND")
    layouts = png_scanline_layouts(
        width=width,
        height=height,
        bit_depth=bit_depth,
        color_type=color_type,
        interlace=interlace,
    )
    expected_decoded_bytes = sum(rows * (row_bytes + 1) for rows, row_bytes in layouts)
    compressed = b"".join(idat_parts)
    try:
        decompressor = zlib.decompressobj()
        decoded = decompressor.decompress(compressed, expected_decoded_bytes + 1)
    except zlib.error as error:
        raise VerificationError(f"{context} IDAT stream is invalid: {error}") from error
    require(
        len(decoded) <= expected_decoded_bytes and decompressor.unconsumed_tail == b"",
        f"{context} decompressed scanline length differs from IHDR",
    )
    try:
        decoded += decompressor.flush()
    except zlib.error as error:
        raise VerificationError(f"{context} IDAT stream is invalid: {error}") from error
    require(
        len(decoded) == expected_decoded_bytes
        and decompressor.eof
        and decompressor.unused_data == b""
        and decompressor.unconsumed_tail == b"",
        f"{context} decompressed scanline length differs from IHDR",
    )
    cursor = 0
    for rows, row_bytes in layouts:
        for _ in range(rows):
            require(decoded[cursor] <= 4, f"{context} scanline filter is invalid")
            cursor += row_bytes + 1
    require(
        cursor == len(decoded),
        f"{context} decompressed scanline layout differs from IHDR",
    )
    return width, height


def decode_artifacts(
    payloads: dict[str, bytes], names: set[str], context: str
) -> dict[str, dict[str, Any]]:
    return {
        name: decode_object(payloads[name], f"{context} artifact {name}")
        for name in names
    }


def normalized_join_reference(match: dict[str, Any]) -> dict[str, str]:
    reference = object_field(match, "reference", "join match")
    identity = object_field(reference, "identity", "join match reference")
    return {
        "source_id": string_field(identity, "source_id", "join match identity"),
        "package_id": string_field(identity, "package_id", "join match identity"),
        "name": string_field(identity, "name", "join match identity"),
        "content_revision": string_field(
            reference, "content_revision", "join match reference"
        ),
    }


def proof_reference(proof: dict[str, Any]) -> dict[str, str]:
    reference = object_field(proof, "reference", "proof identity")
    return {
        field: string_field(reference, field, "proof reference")
        for field in ("source_id", "package_id", "name", "content_revision")
    }


def action_markers(actions: list[Any]) -> list[str]:
    markers: list[str] = []
    for index, action_value in enumerate(actions):
        require(
            isinstance(action_value, dict), f"proof action {index} is not an object"
        )
        action = cast(dict[str, Any], action_value)
        identity = object_field(action, "identity", f"proof action {index}")
        kind = identity.get("kind")
        if kind == "call_id":
            markers.append(
                "call=" + string_field(identity, "call_id", "action identity")
            )
        elif kind == "provider_step":
            conversation_id = string_field(
                identity, "conversation_id", "action identity"
            )
            step_index = integer_field(identity, "step_index", "action identity")
            markers.append(f"step={conversation_id}:{step_index}")
        else:
            raise VerificationError(f"proof action {index} identity is unsupported")
    return markers


def receipt_matches_activation(
    block: str, activation: dict[str, Any], actions: list[Any]
) -> bool:
    lines = [line.strip(" │") for line in block.splitlines()]
    try:
        expected = tui_capture.expected_receipt_lines(activation, actions)
    except tui_capture.CaptureError:
        return False
    return lines == expected


def receipt_rows_are_covered_in_order(
    frame_texts: list[str], expected_rows: list[str]
) -> bool:
    covered = 0
    for visible_text in frame_texts:
        try:
            next_covered = tui_capture.receipt_frame_progress(
                visible_text, expected_rows, covered
            )
        except tui_capture.CaptureError:
            return False
        if next_covered is None:
            return False
        covered = next_covered
    return covered == len(expected_rows)


def server_from_proof(evidence: dict[str, Any]) -> dict[str, str]:
    source = object_field(evidence, "source", "proof")
    runtime = object_field(evidence, "runtime", "proof")
    return {
        "binary_commit": string_field(source, "binary_commit", "proof source"),
        "source_fingerprint": string_field(
            source, "source_fingerprint", "proof source"
        ),
        "executable_sha256": string_field(source, "executable_sha256", "proof source"),
        "executable_provenance_path": string_field(
            source, "executable_provenance_path", "proof source"
        ),
        "executable_provenance_sha256": string_field(
            source, "executable_provenance_sha256", "proof source"
        ),
        "runtime_instance_id": string_field(
            source, "server_runtime_instance_id", "proof source"
        ),
        "started_at": string_field(source, "server_started_at", "proof source"),
        "effective_base_path": string_field(
            runtime, "effective_base_path", "proof runtime"
        ),
        "effective_masc_root": string_field(
            runtime, "effective_masc_root", "proof runtime"
        ),
    }


def server_identity(value: dict[str, Any], context: str) -> dict[str, str]:
    identity = {
        field: string_field(value, field, context)
        for field in (
            "binary_commit",
            "source_fingerprint",
            "executable_sha256",
            "executable_provenance_path",
            "executable_provenance_sha256",
            "runtime_instance_id",
            "started_at",
            "effective_base_path",
            "effective_masc_root",
        )
    }
    require(
        GIT_SHA_RE.fullmatch(identity["binary_commit"]) is not None,
        f"{context}.binary_commit is not a Git SHA",
    )
    require_sha256(identity["source_fingerprint"], f"{context}.source_fingerprint")
    require_sha256(identity["executable_sha256"], f"{context}.executable_sha256")
    require(
        Path(identity["executable_provenance_path"]).is_absolute(),
        f"{context}.executable_provenance_path is not absolute",
    )
    require_sha256(
        identity["executable_provenance_sha256"],
        f"{context}.executable_provenance_sha256",
    )
    try:
        parsed = uuid.UUID(identity["runtime_instance_id"])
    except ValueError as error:
        raise VerificationError(f"{context}.runtime_instance_id is invalid") from error
    require(
        parsed.version == 7 and str(parsed) == identity["runtime_instance_id"],
        f"{context}.runtime_instance_id is not canonical UUIDv7",
    )
    return identity


def require_sha256(value: str, context: str) -> str:
    require(SHA256_RE.fullmatch(value) is not None, f"{context} is not SHA-256")
    return value


def parse_turn_ref(value: str) -> tuple[str, int]:
    trace_id, separator, raw_turn = value.rpartition("#")
    require(separator == "#" and trace_id != "", "Skill Turn_ref is invalid")
    try:
        turn = int(raw_turn)
    except ValueError as error:
        raise VerificationError("Skill Turn_ref is invalid") from error
    require(str(turn) == raw_turn and turn > 0, "Skill Turn_ref is invalid")
    return trace_id, turn


def validate_join_authorities(
    join: dict[str, Any], payloads: dict[str, bytes]
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    decoded = decode_artifacts(payloads, JOIN_ARTIFACTS, "join")
    inputs = object_field(join, "inputs", "join")
    receipt_raw = payloads["producer-receipt.json"]
    try:
        recomputed = ledger_join.validate_join(
            receipt=decoded["producer-receipt.json"],
            receipt_raw=receipt_raw,
            expected_receipt_sha256=string_field(
                inputs, "producer_receipt_sha256", "join inputs"
            ),
            source_before=decoded["source-before.json"],
            source_after=decoded["source-after.json"],
            health_before=decoded["health-before.json"],
            health_after=decoded["health-after.json"],
            dashboard_before=decoded["dashboard-tools-before.json"],
            dashboard_after=decoded["dashboard-tools-after.json"],
            historical_before=decoded["historical-skill-activations-before.json"],
            historical_after=decoded["historical-skill-activations-after.json"],
            durable_ledger=decoded["durable-skill-activations-before.json"],
            durable_ledger_after=decoded["durable-skill-activations-after.json"],
            durable_ledger_raw=payloads["durable-skill-activations-before.json"],
            durable_ledger_after_raw=payloads["durable-skill-activations-after.json"],
        )
    except ledger_join.JoinError as error:
        raise VerificationError(f"join raw authority is invalid: {error}") from error
    for field in (
        "producer",
        "server",
        "ledger",
        "current_surface",
        "current_projection",
        "result",
    ):
        require(
            join.get(field) == recomputed[field],
            f"join manifest {field} differs from raw authority",
        )
    return recomputed, decoded


def validate_proof_authorities(
    *,
    proof: dict[str, Any],
    payloads: dict[str, bytes],
    keeper: str,
    skill_tool_use_id: str,
    expected_source_sha: str,
    join_server: dict[str, str],
    joined_ledger: dict[str, Any],
) -> dict[str, Any]:
    decoded = decode_artifacts(
        payloads,
        {"health.json", "dashboard-tools.json", "skill-activations.json"},
        "proof",
    )
    try:
        recomputed = proof_collector.validate_proof(
            health=decoded["health.json"],
            dashboard=decoded["dashboard-tools.json"],
            durable_ledger=decoded["skill-activations.json"],
            keeper=keeper,
            expected_source_sha=expected_source_sha,
            skill_tool_use_id=skill_tool_use_id,
        )
        raw_server = ledger_join.health_identity(
            decoded["health.json"], expected_source_head=expected_source_sha
        )
    except (proof_collector.ProofError, ledger_join.JoinError) as error:
        raise VerificationError(f"proof raw authority is invalid: {error}") from error
    require(
        object_field(proof, "proof", "proof") == recomputed,
        "proof manifest identity differs from raw authority",
    )
    require(raw_server == join_server, "proof raw server differs from join")
    require(
        decoded["skill-activations.json"] == joined_ledger,
        "proof durable ledger differs from join raw authority",
    )
    return recomputed


def verify_bundle(
    *,
    join: dict[str, Any],
    join_root: Path,
    proof: dict[str, Any],
    proof_raw: bytes,
    proof_root: Path,
    tui: dict[str, Any],
    tui_root: Path,
) -> dict[str, Any]:
    join_root = join_root.resolve(strict=True)
    proof_root = proof_root.resolve(strict=True)
    tui_root = tui_root.resolve(strict=True)
    join_artifacts, join_payloads = verify_artifact_set(
        join, root=join_root, expected_names=JOIN_ARTIFACTS, context="join"
    )
    proof_artifacts, proof_payloads = verify_artifact_set(
        proof, root=proof_root, expected_names=PROOF_ARTIFACTS, context="proof"
    )

    _, join_decoded = validate_join_authorities(join, join_payloads)
    receipt_raw = join_payloads["producer-receipt.json"]
    receipt = join_decoded["producer-receipt.json"]
    inputs = object_field(join, "inputs", "join")
    require(
        inputs.get("producer_receipt_sha256") == digest(receipt_raw),
        "join producer receipt SHA differs",
    )
    calls = object_field(receipt, "producer_calls", "producer receipt")
    require(calls == {"masc_keeper_msg": 1}, "natural producer call count differs")
    operation = object_field(receipt, "operation", "producer receipt")
    require(operation.get("state") == "Succeeded", "Keeper operation did not succeed")

    join_result = object_field(join, "result", "join")
    require(join_result.get("kind") == "exact_skill_invocation", "join is not exact")
    require(join_result.get("match_count") == 1, "join match count is not one")
    matches = list_field(join_result, "matches", "join result")
    require(len(matches) == 1 and isinstance(matches[0], dict), "join match is missing")
    match = cast(dict[str, Any], matches[0])
    selected_id = string_field(join_result, "selected_skill_tool_use_id", "join result")
    require(
        string_field(match, "skill_tool_use_id", "join match") == selected_id,
        "join selected id differs from exact match",
    )

    join_producer = object_field(join, "producer", "join")
    join_source = object_field(join_producer, "source", "join producer")
    receipt_source = object_field(receipt, "source", "producer receipt")
    require(
        join_source
        == {
            "head": string_field(receipt_source, "head", "receipt source"),
            "tree": string_field(receipt_source, "tree", "receipt source"),
        },
        "receipt and join source identities differ",
    )
    require(
        GIT_SHA_RE.fullmatch(string_field(join_source, "head", "join source"))
        is not None
        and GIT_SHA_RE.fullmatch(string_field(join_source, "tree", "join source"))
        is not None,
        "join source Git identity is invalid",
    )
    require(
        string_field(join_producer, "keeper", "join producer")
        == string_field(receipt, "keeper", "producer receipt"),
        "receipt and join Keeper differ",
    )
    require(
        join_producer.get("turn_ref") == operation.get("turn_ref"),
        "receipt and join Turn_ref differ",
    )
    join_server = server_identity(object_field(join, "server", "join"), "join server")
    require(
        join_server
        == server_identity(
            object_field(receipt, "server", "producer receipt"), "receipt server"
        ),
        "receipt and join server identities differ",
    )

    proof_source = object_field(proof, "source", "proof")
    require(
        proof_source.get("expected_sha") == join_source.get("head")
        and proof_source.get("collector_head") == join_source.get("head")
        and proof_source.get("collector_tree") == join_source.get("tree")
        and proof_source.get("tracked_checkout_clean") is True,
        "proof source differs from join source",
    )
    require(server_from_proof(proof) == join_server, "proof server differs from join")

    proof_identity = validate_proof_authorities(
        proof=proof,
        payloads=proof_payloads,
        keeper=string_field(join_producer, "keeper", "join producer"),
        skill_tool_use_id=selected_id,
        expected_source_sha=string_field(join_source, "head", "join source"),
        join_server=join_server,
        joined_ledger=join_decoded["durable-skill-activations-after.json"],
    )
    join_ledger = object_field(join, "ledger", "join")
    identity = {
        "workspace_key": require_sha256(
            string_field(join_ledger, "workspace_key", "join ledger"),
            "join workspace key",
        ),
        "session_id": string_field(join_ledger, "session_id", "join ledger"),
        "snapshot_revision": require_sha256(
            string_field(match, "snapshot_revision", "join match"),
            "join snapshot revision",
        ),
        "turn_ref": string_field(match, "turn_ref", "join match"),
        "invocation_runtime_id": string_field(
            match, "invocation_runtime_id", "join match"
        ),
        "reference": normalized_join_reference(match),
        "skill_tool_use_id": selected_id,
    }
    turn_trace_id, _ = parse_turn_ref(cast(str, identity["turn_ref"]))
    require(
        identity["session_id"] == join_producer.get("trace_id") == turn_trace_id,
        "join session and Turn_ref trace differ",
    )
    require(
        identity["turn_ref"] == join_producer.get("turn_ref"),
        "join activation and producer Turn_ref differ",
    )
    require_sha256(
        cast(dict[str, str], identity["reference"])["content_revision"],
        "join content revision",
    )
    expected_identity = {
        "workspace_key": string_field(
            proof_identity, "workspace_key", "proof identity"
        ),
        "session_id": string_field(proof_identity, "session_id", "proof identity"),
        "snapshot_revision": string_field(
            proof_identity, "snapshot_revision", "proof identity"
        ),
        "turn_ref": string_field(proof_identity, "turn_ref", "proof identity"),
        "invocation_runtime_id": string_field(
            proof_identity, "invocation_runtime_id", "proof identity"
        ),
        "reference": proof_reference(proof_identity),
        "skill_tool_use_id": string_field(
            proof_identity, "skill_tool_use_id", "proof identity"
        ),
    }
    require(identity == expected_identity, "join and proof Skill identities differ")
    require(
        string_field(proof_identity, "keeper", "proof identity")
        == string_field(join_producer, "keeper", "join producer"),
        "join and proof Keeper differ",
    )
    require(
        object_field(match, "delivery", "join match")
        == object_field(proof_identity, "delivery", "proof identity"),
        "delivery differs",
    )
    proof_actions = list_field(proof_identity, "actions", "proof identity")
    require(proof_actions != [], "proof has no later model-selected action")
    require(match.get("actions") == proof_actions, "join and proof actions differ")
    durable_activations = list_field(
        join_decoded["durable-skill-activations-after.json"],
        "activations",
        "joined durable Skill ledger",
    )
    durable_matches = [
        activation
        for activation in durable_activations
        if isinstance(activation, dict)
        and activation.get("skill_tool_use_id") == selected_id
    ]
    require(
        len(durable_matches) == 1,
        "joined durable Skill ledger does not contain one selected activation",
    )
    durable_activation = cast(dict[str, Any], durable_matches[0])
    scoped = object_field(proof_identity, "scoped_summary", "proof identity")
    scoped_summary = object_field(scoped, "summary", "proof scoped summary")
    require(
        integer_field(scoped_summary, "invalid_transitions", "proof scoped summary")
        == 0,
        "proof has invalid transitions",
    )
    delivery_count = integer_field(
        scoped_summary, "instruction_provider_deliveries", "proof scoped summary"
    ) + integer_field(
        scoped_summary,
        "instruction_official_client_handoffs",
        "proof scoped summary",
    )
    require(delivery_count >= 1, "proof has no verified delivery")
    durability = object_field(proof, "durability", "proof")
    require(
        durability.get("dashboard_projection_equals_ledger") is True,
        "proof Dashboard projection differs from its durable ledger",
    )
    require(
        durability.get("ledger_sha256")
        == proof_artifacts["skill-activations.json"]["sha256"],
        "proof durable ledger SHA differs from its artifact",
    )

    build_manifest = decode_object(
        proof_payloads["tui-build-evidence.json"], "TUI build evidence"
    )
    require(build_manifest.get("schema") == BUILD_SCHEMA, "TUI build schema differs")
    build_source = object_field(build_manifest, "source", "TUI build evidence")
    build_artifact = object_field(build_manifest, "artifact", "TUI build evidence")
    proof_build = object_field(proof_source, "tui_build", "proof source")
    require(
        build_source.get("head") == join_source.get("head")
        and build_source.get("tree") == join_source.get("tree")
        and build_source.get("tracked_checkout_clean") is True,
        "TUI build source differs",
    )
    require(
        proof_build.get("manifest_sha256")
        == proof_artifacts["tui-build-evidence.json"]["sha256"],
        "proof TUI build manifest SHA differs",
    )
    require(
        build_artifact.get("path") == "masc_tui.exe"
        and build_artifact.get("bytes") == proof_artifacts["masc_tui.exe"]["bytes"]
        and build_artifact.get("sha256") == proof_artifacts["masc_tui.exe"]["sha256"]
        and proof_build.get("executable_bytes")
        == proof_artifacts["masc_tui.exe"]["bytes"]
        and proof_build.get("executable_sha256")
        == proof_artifacts["masc_tui.exe"]["sha256"],
        "TUI executable identities differ",
    )

    dashboard = object_field(proof, "dashboard", "proof")
    dashboard_name = string_field(dashboard, "path", "proof Dashboard")
    require(
        dashboard_name == "dashboard-skill-use.png"
        and dashboard_name not in PROOF_ARTIFACTS,
        "Dashboard screenshot path is not the exact producer artifact",
    )
    require(
        dashboard.get("keeper") == proof_identity.get("keeper")
        and dashboard.get("ledger_revision") == proof_identity.get("ledger_revision")
        and dashboard.get("exact_row") == selected_id,
        "Dashboard capture identity differs from the selected Skill invocation",
    )
    dashboard_identity, dashboard_payload = verify_file(
        root=proof_root,
        name=dashboard_name,
        expected=dashboard,
        context="Dashboard screenshot",
    )
    validate_png(dashboard_payload, "Dashboard screenshot")
    proof_artifacts_with_dashboard = {
        **proof_artifacts,
        dashboard_name: dashboard_identity,
    }

    tui_source = object_field(tui, "source", "TUI proof")
    require(
        tui_source.get("expected_sha") == join_source.get("head")
        and tui_source.get("capture_head") == join_source.get("head")
        and tui_source.get("capture_tree") == join_source.get("tree")
        and tui_source.get("tracked_checkout_clean") is True,
        "TUI capture source differs",
    )
    require(
        tui_source.get("build_evidence_sha256")
        == proof_artifacts["tui-build-evidence.json"]["sha256"]
        and tui_source.get("executable_sha256")
        == proof_artifacts["masc_tui.exe"]["sha256"]
        and tui_source.get("executable_bytes")
        == proof_artifacts["masc_tui.exe"]["bytes"],
        "TUI capture build identity differs",
    )
    require(
        server_identity(object_field(tui, "server", "TUI proof"), "TUI server")
        == join_server,
        "TUI server differs",
    )
    tui_proof = object_field(tui, "proof", "TUI proof")
    require(
        tui_proof.get("manifest_sha256") == digest(proof_raw), "TUI proof SHA differs"
    )
    require(
        string_field(tui_proof, "keeper", "TUI proof") == proof_identity.get("keeper")
        and string_field(tui_proof, "session_id", "TUI proof")
        == proof_identity.get("session_id")
        and string_field(tui_proof, "ledger_revision", "TUI proof")
        == string_field(proof_identity, "ledger_revision", "proof identity")
        and string_field(tui_proof, "skill_tool_use_id", "TUI proof") == selected_id,
        "TUI repeated proof identity differs",
    )
    expected_markers = action_markers(proof_actions)
    require(
        tui_proof.get("action_markers") == expected_markers
        and tui_proof.get("captured_action_marker") == expected_markers[0],
        "TUI action markers differ",
    )
    require(
        object_field(tui, "producer_artifacts", "TUI proof")
        == proof_artifacts_with_dashboard,
        "TUI producer artifact index differs",
    )
    selection = object_field(tui, "selection", "TUI proof")
    visited_keepers = list_field(selection, "visited_keepers", "TUI selection")
    visited_tools_panes = list_field(selection, "visited_tools_panes", "TUI selection")
    require(
        visited_keepers != []
        and all(isinstance(value, str) for value in visited_keepers)
        and visited_keepers[-1] == proof_identity.get("keeper"),
        "TUI Keeper selection path differs",
    )
    require(
        len(set(visited_keepers)) == len(visited_keepers),
        "TUI Keeper selection path differs",
    )
    require(
        visited_tools_panes != []
        and all(isinstance(value, str) for value in visited_tools_panes)
        and visited_tools_panes[-1] == "activations"
        and len(set(visited_tools_panes)) == len(visited_tools_panes),
        "TUI Tools pane selection path differs",
    )
    require(
        {"visible_text", "visible_text_sha256", "screenshot"}.isdisjoint(tui),
        "TUI proof contains removed single-frame fields",
    )
    frame_values = list_field(tui, "frames", "TUI proof")
    require(frame_values != [], "TUI proof has no frames")
    frame_texts: list[str] = []
    frame_screenshots: dict[str, dict[str, Any]] = {}
    frame_screenshot_paths: list[Path] = []
    for frame_index, frame_value in enumerate(frame_values):
        frame_context = f"TUI frame {frame_index}"
        require(isinstance(frame_value, dict), f"{frame_context} is not an object")
        frame = cast(dict[str, Any], frame_value)
        require(
            set(frame) == {"visible_text", "visible_text_sha256", "screenshot"},
            f"{frame_context} field set differs",
        )
        visible_text = string_field(frame, "visible_text", frame_context)
        require(
            frame.get("visible_text_sha256") == digest(visible_text.encode()),
            f"{frame_context} visible text SHA differs",
        )
        require(
            tui_capture.tools_surface_is_connected(visible_text),
            f"{frame_context} Tools surface is not connected",
        )
        screenshot = object_field(frame, "screenshot", frame_context)
        require(
            set(screenshot) == {"path", "bytes", "sha256"},
            f"{frame_context} screenshot field set differs",
        )
        screenshot_name = string_field(
            screenshot, "path", f"{frame_context} screenshot"
        )
        require(
            screenshot_name not in frame_screenshots,
            "TUI frame screenshot paths are not distinct",
        )
        screenshot_identity, screenshot_payload = verify_file(
            root=tui_root,
            name=screenshot_name,
            expected=screenshot,
            context=f"{frame_context} screenshot",
        )
        validate_png(screenshot_payload, f"{frame_context} screenshot")
        frame_texts.append(visible_text)
        frame_screenshots[screenshot_name] = screenshot_identity
        frame_screenshot_paths.append(tui_root / screenshot_name)
    observations = object_field(tui, "observations", "TUI proof")
    require(
        set(observations) == {"skill_header", "session_line", "receipt_block"},
        "TUI observation field set differs",
    )
    skill_header = string_field(observations, "skill_header", "TUI observations")
    session_line = string_field(observations, "session_line", "TUI observations")
    receipt_block = string_field(observations, "receipt_block", "TUI observations")
    header_match = re.fullmatch(
        rf"Skill Use — {re.escape(str(proof_identity['keeper']))} \(([1-9][0-9]*) receipts\)",
        skill_header,
    )
    require(
        header_match is not None
        and int(header_match.group(1)) == len(durable_activations),
        "TUI observation does not contain the exact Skill header",
    )
    require(
        ledger_projection_matches(
            session_line,
            string_field(proof_identity, "session_id", "proof identity"),
            string_field(proof_identity, "ledger_revision", "proof identity"),
        ),
        "TUI ledger projection differs",
    )
    require(
        receipt_matches_activation(receipt_block, durable_activation, proof_actions),
        "TUI exact receipt observation differs",
    )
    expected_receipt_rows = tui_capture.expected_receipt_lines(
        durable_activation, proof_actions
    )
    require(
        receipt_rows_are_covered_in_order(frame_texts, expected_receipt_rows),
        "TUI frames do not cover the exact receipt rows in order",
    )

    verified_count = (
        len(join_artifacts)
        + len(proof_artifacts_with_dashboard)
        + len(frame_screenshots)
    )
    artifact_paths = [
        *(join_root / name for name in JOIN_ARTIFACTS),
        *(proof_root / name for name in PROOF_ARTIFACTS),
        proof_root / dashboard_name,
        *frame_screenshot_paths,
    ]
    require(
        len(artifact_paths) == verified_count
        and len({path.resolve(strict=True) for path in artifact_paths})
        == verified_count,
        "verified artifact paths are not distinct",
    )
    require(
        len({(path.stat().st_dev, path.stat().st_ino) for path in artifact_paths})
        == verified_count,
        "verified artifacts contain hardlink aliases",
    )
    matrix = {
        "natural_keeper_messages": 1,
        "terminal_keeper_operations_succeeded": 1,
        "exact_turn_skill_activations": 1,
        "selected_skill_tool_use_ids": 1,
        "typed_projection_raw_mismatches": 0,
        "verified_deliveries": delivery_count,
        "later_model_selected_actions": len(proof_actions),
        "invalid_transitions": 0,
        "dashboard_exact_row_screenshots": 1,
        "tui_exact_row_screenshots": len(frame_values),
        "source_server_identity_changes": 0,
        "incomplete_markers": 0,
    }
    return {
        "status": "passed",
        "identity": {
            "source": join_source,
            "server": join_server,
            "keeper": proof_identity["keeper"],
            "skill_use": identity,
        },
        "matrix": matrix,
        "artifacts": {
            "verified_count": verified_count,
            "mismatch_count": 0,
            "join": join_artifacts,
            "proof": proof_artifacts_with_dashboard,
            "tui": frame_screenshots,
        },
    }


def write_json(path: Path, value: Any) -> bytes:
    payload = (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode()
    path.write_bytes(payload)
    return payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--join", required=True, type=Path)
    parser.add_argument("--expected-join-sha256", required=True)
    parser.add_argument("--proof", required=True, type=Path)
    parser.add_argument("--expected-proof-sha256", required=True)
    parser.add_argument("--tui", required=True, type=Path)
    parser.add_argument("--expected-tui-sha256", required=True)
    parser.add_argument("--out", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        require(not args.out.exists(), f"output path already exists: {args.out}")
        args.out.mkdir(parents=True)
        incomplete = args.out / "INCOMPLETE"
        incomplete.write_text("Keeper Skill bundle verification is incomplete\n")
        join, join_raw, join_root = load_manifest(
            args.join,
            expected_sha256=args.expected_join_sha256,
            expected_schema=JOIN_SCHEMA,
            context="join manifest",
        )
        proof, proof_raw, proof_root = load_manifest(
            args.proof,
            expected_sha256=args.expected_proof_sha256,
            expected_schema=PROOF_SCHEMA,
            context="proof manifest",
        )
        tui, tui_raw, tui_root = load_manifest(
            args.tui,
            expected_sha256=args.expected_tui_sha256,
            expected_schema=TUI_SCHEMA,
            context="TUI manifest",
        )
        verified = verify_bundle(
            join=join,
            join_root=join_root,
            proof=proof,
            proof_raw=proof_raw,
            proof_root=proof_root,
            tui=tui,
            tui_root=tui_root,
        )
        verified.update(
            {
                "schema": SCHEMA,
                "generated_at": utc_now(),
                "inputs": {
                    "join_sha256": digest(join_raw),
                    "proof_sha256": digest(proof_raw),
                    "tui_sha256": digest(tui_raw),
                },
            }
        )
        raw = write_json(args.out / "verification.json", verified)
        incomplete.unlink()
        print(
            json.dumps(
                {
                    "status": "passed",
                    "verification": str(args.out / "verification.json"),
                    "sha256": digest(raw),
                    "verified_artifacts": verified["artifacts"]["verified_count"],
                },
                sort_keys=True,
            )
        )
        return 0
    except (VerificationError, OSError) as error:
        print(f"keeper-skill-proof-verifier: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
