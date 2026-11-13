# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# pyright: strict
"""Check the admission prompt parser and validator against MASC's retained records.

Reads `<base>/.masc/lane-addons` read-only and prints counts only: no prompt,
memory or answer text and no ids. Run from the repository root:

    MASC_BASE_PATH=<base> uv run --quiet --python 3.12 python -I \
        scripts/tinker/librarian/check_validator_on_store.py

Checks:
1. `render(parse(text)) == text` for every retained admission prompt, parsed
   with the template its own execution capture recorded. Each parsed section
   must also equal the captured variable value, and facts_budget and
   memory_limits must equal what the typed facts give.
2. Every answer MASC accepted passes `validate`. Accepted means the execution
   owner record has `judgment_retained`: MASC writes it only after the final
   answer passed `confirm_final` and `Capture.validate_proposal`
   (keeper_librarian_admission_owner.ml). Requests without it are counted
   apart, with their last owner event. The E-real selection
   (`exact_store.answered_admissions`) may list only accepted answers, each
   equal to the retained one; an accepted request it leaves out is counted.
3. Answers MASC refused are counted by the reason MASC recorded. MASC keeps
   only a digest of a refused answer (`http.semantic[].raw_sha`), so their
   text cannot be validated again.

Exits 1 when a check in 1 or 2 fails.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import time
from collections import Counter
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parent))

import admission_request as R
import admission_validator as V
import exact_store as E
from yojson_wire import (
    Absent,
    Json,
    JsonObject,
    member,
    write,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_TEMPLATE = REPO_ROOT / "config" / "prompts" / "librarian.md"
EXECUTION_SCOPE_PREFIX = "keeper-librarian-execution-"
ADMISSION_TOOL = "admit_memory"
ADMISSION_OUTPUT = "admission"
# Recorded reasons whose text has no variable part, by the kind that gives that text.
FIXED_REASONS: dict[str, str] = {
    "admission_invalid: new Memory claim has no incorporated supporting candidate": V.Kind.NEW_CLAIM_WITHOUT_SUPPORT.value,
    "claim_schema_mismatch": "claim_schema_mismatch (claim_* kinds)",
    "dropped_schema_mismatch": "dropped_schema_mismatch (dropped_* kinds)",
    "duplicate object member": V.Kind.DUPLICATE_MEMBER.value,
    "non-finite JSON number": V.Kind.NON_FINITE_NUMBER.value,
}
SCHEMA_NOTE = "the answer does not match the declared schema: "


# ---------------------------------------------------------------- store reading


def read_record(path: Path) -> Json | None:
    """A record MASC wrote with `Yojson.Safe.to_string`, or None when unreadable."""
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    return E.read_json(raw)


def field(value: Json | Absent, *path: str) -> Json | Absent:
    for name in path:
        if not isinstance(value, JsonObject):
            return Absent()
        value = member(value, name)
    return value


def text_field(value: Json | Absent, *path: str) -> str | None:
    found = field(value, *path)
    return found if isinstance(found, str) else None


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------- checks


def captured_template(capture: Json) -> R.AdmissionTemplate | R.TemplateError:
    """The prompt texts the capture recorded (`preparation.*.effective`)."""
    main = text_field(capture, "preparation", "prompt", "effective")
    admission = text_field(capture, "preparation", "admission_prompt", "effective")
    rule = text_field(capture, "preparation", "rule_prompt", "effective")
    retirement_prompt = field(capture, "preparation", "retirement_prompt")
    retirement = text_field(retirement_prompt, "effective")
    if main is None or admission is None or rule is None:
        return R.TemplateError("capture lacks a prompt resolution")
    if retirement_prompt is not None and retirement is None:
        return R.TemplateError("capture has an unreadable retirement prompt")
    return R.make_template(main, admission, rule, retirement)


def captured_variables(capture: Json) -> dict[str, str]:
    rows = field(capture, "preparation", "variables")
    found: dict[str, str] = {}
    for row in rows if isinstance(rows, tuple) else ():
        key = text_field(row, "key")
        value = text_field(row, "value")
        if key is not None and value is not None:
            found[key] = value
    return found


def policy_int(capture: Json, name: str) -> int | None:
    value = field(capture, "preparation", "policy", name)
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def check_sections(prompt: R.AdmissionPrompt, capture: Json, counts: Counter[str]) -> None:
    variables = captured_variables(capture)
    sections = {
        "keeper_id": prompt.keeper_id,
        "keeper_instructions": prompt.keeper_instructions,
        "facts_budget": prompt.facts_budget,
        "memory_limits": prompt.memory_limits,
        "goal_context": prompt.goal_context,
        "current_memory": write(R.current_memory_json(prompt.current_memory)),
    }
    differing = sorted(name for name, text in sections.items() if variables.get(name) != text)
    counts[
        "1 sections equal to captured variables"
        if not differing
        else "1 FAIL section differs: " + ",".join(differing)
    ] += 1
    max_bytes = policy_int(capture, "facts_max_bytes")
    category_cap = policy_int(capture, "category_cap")
    per_category = policy_int(capture, "facts_per_category_cap")
    if max_bytes is None or category_cap is None or per_category is None:
        counts["1 FAIL capture policy unreadable"] += 1
        return
    budget = R.facts_budget_for(max_bytes, prompt.current_memory) == prompt.facts_budget
    limits = R.memory_limits_for(category_cap, per_category, prompt.current_memory) == prompt.memory_limits
    counts[
        "1 facts_budget recomputed from typed facts" if budget else "1 FAIL facts_budget recomputed differs"
    ] += 1
    counts[
        "1 memory_limits recomputed from typed facts" if limits else "1 FAIL memory_limits recomputed differs"
    ] += 1


def accepted_answer(owner: Json, counts: Counter[str]) -> Json | Absent:
    """The answer the owner record retained, or Absent with the reason counted."""
    progress = field(owner, "progress")
    events = progress if isinstance(progress, tuple) else ()
    names = [text_field(event, "event") or "?" for event in events]
    retained = [event for event in events if text_field(event, "event") == "judgment_retained"]
    if not retained:
        counts[
            "2 acceptance unknown: no judgment_retained, last owner event " + (names[-1] if names else "none")
        ] += 1
        return Absent()
    judgment = field(retained[-1], "judgment")
    if text_field(judgment, "status") != "answered":
        counts["2 acceptance unknown: retained judgment is not answered"] += 1
        return Absent()
    output = field(judgment, "output")
    if isinstance(output, Absent):
        counts["2 acceptance unknown: retained judgment has no output"] += 1
        return output
    later = [name for name in names if name in ("commit_observed", "commit_conflicted")]
    counts["2 accepted, then " + (later[-1] if later else "not committed yet")] += 1
    return output


def check_selection(
    accepted: Json | Absent, listed: E.AnsweredAdmission | None, counts: Counter[str]
) -> None:
    """The E-real selection reads `final.status`; acceptance comes from the owner record."""
    match accepted, listed:
        case Absent(), None:
            pass
        case Absent(), E.AnsweredAdmission():
            counts["2 FAIL exact_store lists an answer the owner did not accept"] += 1
        case _, None:
            counts["2 accepted, but exact_store does not list it"] += 1
        case _, E.AnsweredAdmission(answer=answer):
            same = answer == accepted
            counts[
                "2 exact_store lists it with the accepted answer"
                if same
                else "2 FAIL exact_store lists another answer than the accepted one"
            ] += 1


def check_acceptance(
    prompt: R.AdmissionPrompt, owner: Json, listed: E.AnsweredAdmission | None, counts: Counter[str]
) -> None:
    output = accepted_answer(owner, counts)
    check_selection(output, listed, counts)
    if isinstance(output, Absent):
        return
    result = V.validate(prompt, write(output))
    match result:
        case V.Valid(answer=answer):
            counts["2 accepted and passes validate" + (" (deferred)" if answer.deferred else "")] += 1
        case V.Invalid(violations=violations):
            counts["2 FAIL accepted but validate refuses: " + violations[0].kind.value] += 1


def check_request(
    record: Json,
    owners: dict[str, Json],
    listed: E.AnsweredAdmission | None,
    lane: Path,
    file_template: R.AdmissionTemplate | R.TemplateError,
    counts: Counter[str],
) -> None:
    request = field(record, "request")
    counts["0 admission requests"] += 1
    schema = field(request, "schema")
    counts[
        "0 request schema equals admission_output_schema"
        if schema == V.admission_output_schema()
        else "0 FAIL request schema differs"
    ] += 1
    messages = field(request, "messages")
    text = text_field(messages[0], "text") if isinstance(messages, tuple) and len(messages) == 1 else None
    request_id = text_field(record, "request_id")
    owner = owners.get(request_id) if request_id is not None else None
    if text is None or owner is None:
        counts["1 FAIL no single prompt message or no execution owner record"] += 1
        return
    scope = text_field(owner, "scope")
    digest = text_field(owner, "request_digest")
    capture = None
    if scope is not None and digest is not None:
        capture = read_record(lane / "tool-request-bodies" / sha256_hex(scope) / (digest + ".json"))
    if capture is None:
        counts["1 FAIL execution capture unreadable"] += 1
        return
    counts[
        "1 captured rendered_prompt equals request text"
        if text_field(capture, "preparation", "rendered_prompt") == text
        else "1 FAIL captured rendered_prompt differs"
    ] += 1
    template = captured_template(capture)
    if isinstance(template, R.TemplateError):
        counts["1 FAIL captured template: " + template.detail] += 1
        return
    prompt = R.parse(text, template)
    if isinstance(prompt, R.ParseError):
        counts["1 FAIL parse: " + prompt.detail] += 1
        return
    counts["1 render(parse(text)) == text" if R.render(prompt) == text else "1 FAIL round trip differs"] += 1
    counts[
        "1 retirement section present" if prompt.retirement is not None else "1 no retirement section"
    ] += 1
    check_sections(prompt, capture, counts)
    if isinstance(file_template, R.AdmissionTemplate):
        same = (
            template.main == file_template.main
            and template.admission_policy == file_template.admission_policy
        )
        counts[
            "1 captured template equals librarian.md"
            if same
            else "1 captured template differs from librarian.md"
        ] += 1
        parsed = not isinstance(R.parse(text, file_template), R.ParseError)
        counts[
            "1 parses with librarian.md template" if parsed else "1 does not parse with librarian.md template"
        ] += 1
    check_acceptance(prompt, owner, listed, counts)


def refusal_label(detail: str) -> str:
    """The MASC rule a recorded refusal names, never its variable part."""
    reason = detail.removeprefix(SCHEMA_NOTE)
    fixed = FIXED_REASONS.get(reason)
    return fixed if fixed is not None else "other: " + reason.split(":")[0]


def count_refusals(lane: Path, counts: Counter[str]) -> None:
    requests: set[str] = set()
    for path in sorted((lane / "host-results").rglob("*.json")):
        record = read_record(path)
        executions = field(record, "executions") if record is not None else Absent()
        for execution in executions if isinstance(executions, tuple) else ():
            if text_field(execution, "request", "output") != ADMISSION_OUTPUT:
                continue
            semantic = field(execution, "receipt", "http", "semantic")
            for refusal in semantic if isinstance(semantic, tuple) else ():
                detail = text_field(refusal, "detail")
                label = refusal_label(detail) if detail is not None else "unreadable"
                counts["3 refused attempts (text not retained, not re-validated), MASC reason " + label] += 1
                request_id = text_field(execution, "request_id")
                if request_id is not None:
                    requests.add(request_id)
    counts["3 admission requests with a refused attempt"] += len(requests)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--base", default=None, help="MASC base path (default: MASC_BASE_PATH)")
    parser.add_argument("--template", type=Path, default=DEFAULT_TEMPLATE)
    args = parser.parse_args()
    base = E.base_path(cast(str | None, args.base))
    template_path = cast(Path, args.template)
    started = time.monotonic()
    lane = E.store_dir(base).parent
    answered = {record.digest: record for record in E.answered_admissions(base)}
    read_digests: set[str] = set()
    file_template = R.template_from_markdown(template_path.read_text(encoding="utf-8"))
    counts: Counter[str] = Counter()
    if isinstance(file_template, R.TemplateError):
        counts["1 librarian.md template unreadable: " + file_template.detail] += 1

    owners: dict[str, Json] = {}
    for path in sorted((lane / "tool-request-owners").rglob("*.json")):
        record = read_record(path)
        scope = text_field(record, "scope") if record is not None else None
        request_id = text_field(record, "request_id") if record is not None else None
        if (
            record is not None
            and text_field(record, "tool") == ADMISSION_TOOL
            and scope is not None
            and scope.startswith(EXECUTION_SCOPE_PREFIX)
            and request_id is not None
        ):
            owners[request_id] = record

    for path in sorted(E.store_dir(base).rglob("*.json")):
        record = read_record(path)
        if record is None:
            counts["0 unreadable exact-request record"] += 1
            continue
        if text_field(record, "request", "output") == ADMISSION_OUTPUT:
            digest = text_field(record, "digest")
            if digest is not None:
                read_digests.add(digest)
            listed = answered.get(digest) if digest is not None else None
            check_request(record, owners, listed, lane, file_template, counts)
    unread = len(answered.keys() - read_digests)
    if unread:
        counts["0 FAIL exact_store lists a record this check did not read"] += unread

    count_refusals(lane, counts)
    for label, count in sorted(counts.items()):
        print(f"{count:6d}  {label[2:]}" if label[:1].isdigit() else f"{count:6d}  {label}")
    print(f"elapsed {time.monotonic() - started:.1f}s")
    return 1 if any("FAIL" in label and count for label, count in counts.items()) else 0


if __name__ == "__main__":
    sys.exit(main())
