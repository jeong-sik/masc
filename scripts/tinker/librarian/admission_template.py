# pyright: strict
"""The admission prompt template: librarian.md text split at its variables.

`template_from_markdown` reads librarian.md the way frontmatter.ml and
prompt_registry.ml (`split_body`) read it. `make_template` splits the main
template at its `{{variable}}` holes (prompt_registry.ml `render_template`)
and writes in the sections every admission input renders the same way
(keeper_librarian.ml:385-410).

Pure: no I/O.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Literal

from ocaml_text import ocaml_trim

type TextVariable = Literal["keeper_id", "keeper_instructions", "facts_budget"]


type JsonVariable = Literal["memory_limits", "goal_context", "current_memory"]


type Variable = TextVariable | JsonVariable


TEXT_VARIABLES: frozenset[str] = frozenset({"keeper_id", "keeper_instructions", "facts_budget"})


JSON_VARIABLES: frozenset[str] = frozenset({"memory_limits", "goal_context", "current_memory"})


# The text every admission prompt shows for these variables.
EMPTY_WORKING_CONTEXT = '{"sources":[],"previous":null,"unavailable":[]}'


ADMISSION_CONSTANTS: tuple[tuple[str, str], ...] = (
    ("historical_task_contexts", "[]"),
    ("continuity", "null"),
    ("working_context", EMPTY_WORKING_CONTEXT),
    ("conversation_history", "[no messages]"),
    ("turn_tool_observations", "[]"),
    ("counterpart_observations", "[]"),
)


CANDIDATE_HEADER = "\nCandidate data (JSON):\n"


_TEMPLATE_VARIABLE = re.compile(r"\{\{([^}]+)\}\}")


@dataclass(frozen=True, slots=True)
class Hole:
    name: Variable


type Piece = str | Hole


@dataclass(frozen=True, slots=True)
class AdmissionTemplate:
    """The prompt text that does not depend on the request. Build it with `make_template`.

    `main` is the `librarian` group text (the file preamble, trimmed);
    `pieces` is `main` split at its variables, with the admission constants and
    `working_contexts_rule` already written in.
    """

    main: str
    admission_policy: str
    working_contexts_rule: str
    retirement_policy: str | None
    pieces: tuple[Piece, ...]


@dataclass(frozen=True, slots=True)
class TemplateError:
    detail: str


def _as_variable(name: str) -> Variable | None:
    match name:
        case "keeper_id" | "keeper_instructions" | "facts_budget":
            return name
        case "memory_limits" | "goal_context" | "current_memory":
            return name
        case _:
            return None


def _has_variables(text: str) -> bool:
    return any(ocaml_trim(found.group(1)) != "" for found in _TEMPLATE_VARIABLE.finditer(text))


def make_template(
    main: str,
    admission_policy: str,
    working_contexts_rule: str,
    retirement_policy: str | None,
) -> AdmissionTemplate | TemplateError:
    """Split `main` at its variables the way `render_template` substitutes them."""
    if ocaml_trim(main) == "" or ocaml_trim(admission_policy) == "":
        return TemplateError("main template or admission policy is blank")
    rule = ocaml_trim(working_contexts_rule)
    if rule == "":
        return TemplateError("working-context rule rendered empty")
    for name, text in (("admission_policy", admission_policy), ("working_contexts_rule", rule)):
        if _has_variables(text):
            return TemplateError(f"{name} has template variables; MASC renders it with none")
    if retirement_policy is not None and _has_variables(retirement_policy):
        return TemplateError("retirement_policy has template variables; MASC renders it with none")
    constants = dict(ADMISSION_CONSTANTS) | {"working_contexts_rule": rule}
    pieces: list[Piece] = []
    literal: list[str] = []
    seen: set[str] = set()
    last = 0
    for found in _TEMPLATE_VARIABLE.finditer(main):
        literal.append(main[last : found.start()])
        last = found.end()
        name = ocaml_trim(found.group(1))
        constant = constants.get(name)
        variable = _as_variable(name)
        if name == "":
            # render_template leaves a blank placeholder as it is.
            literal.append(found.group())
        elif constant is not None:
            literal.append(constant)
        elif variable is not None:
            if pieces and isinstance(pieces[-1], Hole) and not "".join(literal):
                return TemplateError(f"variable {name} follows another variable with no text between")
            pieces.append("".join(literal))
            literal = []
            pieces.append(Hole(variable))
            seen.add(name)
        else:
            return TemplateError(f"unknown template variable {name}")
    literal.append(main[last:])
    pieces.append("".join(literal))
    missing = (TEXT_VARIABLES | JSON_VARIABLES) - seen
    if missing:
        return TemplateError("template does not show " + ", ".join(sorted(missing)))
    return AdmissionTemplate(main, admission_policy, rule, retirement_policy, tuple(pieces))


def _frontmatter_body(content: str) -> str:
    if len(content) < 3 or content[0] not in "- \t\r":
        return content
    first_end = content.find("\n")
    first = content if first_end < 0 else content[:first_end]
    if ocaml_trim(first) != "---":
        return content
    start = len(content) if first_end < 0 else first_end + 1
    while start < len(content):
        end = content.find("\n", start)
        line_end, next_start = (len(content), len(content)) if end < 0 else (end, end + 1)
        if ocaml_trim(content[start:line_end]) == "---":
            return content[next_start:]
        start = next_start
    # An unclosed block is not frontmatter.
    return content


def _is_slot_marker(marker: str) -> bool:
    return marker != "" and all(char in "abcdefghijklmnopqrstuvwxyz0123456789._-" for char in marker)


def _strip_primary_suffix(rest: str) -> str:
    if not rest.endswith("]"):
        return rest
    open_bracket = rest.rfind("[")
    if open_bracket < 0:
        return rest
    inside = rest[open_bracket + 1 : len(rest) - 1]
    colon = inside.find(":")
    head = ocaml_trim(inside if colon < 0 else inside[:colon])
    return ocaml_trim(rest[:open_bracket]) if head == "primary" else rest


def _slot_marker(line: str) -> str | None:
    if not (len(line) > 4 and line.startswith("### ")):
        return None
    rest = _strip_primary_suffix(ocaml_trim(line[4:]))
    open_paren = rest.find("(")
    marker = rest
    if (
        open_paren >= 0
        and len(rest) >= open_paren + 8
        and rest[open_paren + 1 : open_paren + 7] == "vars: "
        and rest.endswith(")")
    ):
        marker = ocaml_trim(rest[:open_paren])
    return marker if _is_slot_marker(marker) else None


def _split_body(body: str) -> tuple[str, tuple[tuple[str, str], ...]]:
    """The preamble and each (marker, paragraph), both trimmed, in file order."""
    preamble: list[str] = []
    slots: list[tuple[str, str]] = []
    pending: str | None = None
    paragraph: list[str] = []
    for line in body.split("\n"):
        marker = _slot_marker(line)
        if marker is not None:
            if pending is not None:
                slots.append((pending, ocaml_trim("\n".join(paragraph))))
            pending, paragraph = marker, []
        elif pending is not None:
            paragraph.append(line)
        else:
            preamble.append(line)
    if pending is not None:
        slots.append((pending, ocaml_trim("\n".join(paragraph))))
    return ocaml_trim("\n".join(preamble)), tuple(slots)


def template_from_markdown(content: str) -> AdmissionTemplate | TemplateError:
    """The template as MASC resolves `librarian` and its slots from librarian.md, with no override."""
    preamble, slots = _split_body(_frontmatter_body(content))

    def slot(marker: str) -> str | None:
        return next((text for name, text in slots if name == marker), None)

    admission = slot("admission_policy")
    rule = slot("working_contexts_rule")
    if admission is None or rule is None:
        return TemplateError("librarian.md lacks the admission_policy or working_contexts_rule slot")
    return make_template(preamble, admission, rule, slot("retirement_policy"))
