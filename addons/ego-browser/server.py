"""Read captured native ego results. This isolated worker sends no input."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import InvalidInput, Source, object_value, row, serve
sys.path.insert(0, str(Path(__file__).resolve().parent / "skills/ego-native/scripts"))
from contract import InvalidResult, RESULT_FIELDS, validate_result


def observe(binding: dict, sources: tuple[Source, ...]) -> dict:
    rows, coverage = [], []
    if not sources:
        return {"rows": [], "coverage": [{"source_id": "ego-browser", "incarnation": "unobserved",
            "cursor": None, "complete": False, "detail": "No native ego result supplied"}]}
    for source in sources:
        accepted, skipped = 0, set()
        for observation in source.observations:
            if observation.get("kind") != "ego_browser":
                skipped.add(str(observation.get("kind", "untyped")))
                continue
            fields = object_value(observation.get("fields"), "ego fields")
            try:
                validate_result(fields)
            except InvalidResult as error:
                raise InvalidInput(str(error)) from error
            status = fields["status"]
            session = fields["session"]
            if session is not None:
                if session["epoch"] != source.incarnation:
                    raise InvalidInput("ego observation belongs to another session incarnation")
            rows.append(row(source, observation, lane="browser/session", subject=source.incarnation,
                title=f"ego: {status}", kind="value", fields={
                    **{key: fields[key] for key in RESULT_FIELDS}, "scope": "latest_native_ego_observation",
                    "task_completion_verified": False}))
            accepted += 1
        current = source.coverage(skipped)
        current["complete"] = current["complete"] and accepted > 0 and not skipped
        if not accepted:
            current["detail"] = "; ".join(filter(None, (current["detail"], "No native ego observation supplied")))
        coverage.append(current)
    return {"rows": rows, "coverage": coverage}


if __name__ == "__main__":
    serve("masc-ego-browser", observe)
