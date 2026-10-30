"""Project the native companion's latest phrase snapshot; never load VSTs here."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import InvalidInput, Source, object_value, row, serve, string

STATES = frozenset(("rendering", "rendered", "failed", "player_started", "player_finished",
                    "player_ended", "stop_requested", "pause_requested", "resume_requested",
                    "exported", "export_failed"))


def observe(binding: dict, sources: tuple[Source, ...]) -> dict:
    rows, coverage = [], []
    if not sources:
        return {"rows": [], "coverage": [{"source_id": "vst-phrase", "incarnation": "unobserved",
            "cursor": None, "complete": False, "detail": "No native phrase snapshot supplied"}]}
    for source in sources:
        accepted = 0
        skipped = set()
        for observation in source.observations:
            if observation.get("kind") != "vst_phrase":
                skipped.add(str(observation.get("kind", "untyped")))
                continue
            fields = object_value(observation.get("fields"), "phrase fields")
            state = string(fields.get("state"), "phrase state")
            if state not in STATES:
                raise InvalidInput("Unknown native phrase state")
            selection = fields.get("selection")
            if selection is not None:
                selection = object_value(selection, "selection")
                string(selection.get("name"), "selection.name")
                string(selection.get("plugin_path"), "selection.plugin_path")
            render = fields.get("render")
            if render is not None:
                render = object_value(render, "render")
                for key in ("midi_sha256", "wav_sha256"):
                    digest = string(render.get(key), f"render.{key}")
                    if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
                        raise InvalidInput(f"render.{key} is not a SHA-256 digest")
            if state in ("rendered", "exported") and render is None:
                raise InvalidInput("Rendered state requires retained render evidence")
            if state in ("failed", "export_failed"):
                string(fields.get("error"), "phrase error")
            if state in ("exported", "export_failed"):
                destination = string(fields.get("export_path"), "export destination")
                if state == "exported" and render.get("output_path") != destination:
                    raise InvalidInput("Export render must reference its destination")
                if state == "export_failed" and (render is not None or observation.get("evidence")):
                    raise InvalidInput("Failed export cannot claim published render evidence")
            event_id = string(observation.get("id"), "observation.id")
            name = selection["name"] if selection is not None else "SoundFont"
            rows.append(row(source, observation, lane="phrase",
                subject=render["midi_sha256"] if render else event_id,
                title=f"{name}: {state}", kind="value", fields={**fields,
                    "scope": "latest_local_phrase_state",
                    "playback_evidence": "local player process events; device audibility is not measured",
                    "action_receipt": False}))
            accepted += 1
        status = source.coverage(skipped)
        status["complete"] = status["complete"] and bool(accepted) and not skipped
        if not accepted:
            status["detail"] = "; ".join(filter(None, (status["detail"], "No native phrase observation supplied")))
        coverage.append(status)
    return {"rows": rows, "coverage": coverage}


if __name__ == "__main__":
    serve("masc-vst-phrase", observe)
