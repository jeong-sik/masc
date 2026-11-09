# pyright: strict
"""Keeper-librarian admission prompts: read the text MASC sent, write it back.

`render(parse(text, template)) == text`, byte for byte. The current-memory
facts and the candidates are typed, and `render` writes them from those typed
values, so a generator can build a new prompt from typed values. Every other
variable section keeps its exact text.

MASC builds every admission input with no messages, tool or counterpart
observations, task contexts or working context, and `continuity` is always
`null` (keeper_librarian_admission_owner.ml:101-139,
keeper_librarian.ml:385-410). Those sections render the same text in every
admission prompt, so they are part of the template here, and `parse` refuses a
prompt where they differ.

Where MASC renders each part (main 4b770e51972c):
- whole prompt: keeper_librarian_runtime.ml:537-560 `prepare_admission`
  = main template rendered with the variables, then `admission_suffix` (368-381)
  (here)
- variables: keeper_librarian.ml:385-410 `prompt_variables_with_policy`;
  facts_budget and memory_limits in memory_variables.py
- current memory and candidates: prompt_facts.py
- retirement: keeper_memory_admission_judgment.ml:159-204 (here)
- template text: config/prompts/librarian.md, read the way frontmatter.ml and
  prompt_registry.ml (`split_body`, `render_template`) read it (admission_template.py)

Pure: no I/O. Callers read files and pass their text.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import assert_never

from admission_template import (
    ADMISSION_CONSTANTS,
    CANDIDATE_HEADER,
    EMPTY_WORKING_CONTEXT,
    JSON_VARIABLES,
    TEXT_VARIABLES,
    AdmissionTemplate,
    Hole,
    JsonVariable,
    Piece,
    TemplateError,
    TextVariable,
    Variable,
    make_template,
    template_from_markdown,
)
from memory_variables import (
    facts_budget_for,
    memory_limits_for,
    rfc3339_of_unix,
    utf8_length,
)
from ocaml_text import ocaml_trim
from prompt_facts import (
    Board,
    Candidate,
    CurrentBasis,
    CurrentFact,
    CurrentMemory,
    Derivation,
    Derived,
    Origin,
    OriginKind,
    ParseError,
    PremisePaths,
    ProposedBasis,
    ProposedFact,
    Transcript,
    candidates_json,
    candidates_of,
    current_memory_json,
    current_memory_of,
    proposed_fact_json,
    surrogate_id,
)
from yojson_wire import JsonError, read_value_at, write

__all__ = [
    "ADMISSION_CONSTANTS",
    "CANDIDATE_HEADER",
    "EMPTY_WORKING_CONTEXT",
    "JSON_VARIABLES",
    "TEXT_VARIABLES",
    "AdmissionPrompt",
    "AdmissionTemplate",
    "Board",
    "Candidate",
    "CurrentBasis",
    "CurrentFact",
    "CurrentMemory",
    "Derivation",
    "Derived",
    "Hole",
    "JsonVariable",
    "Origin",
    "OriginKind",
    "ParseError",
    "Piece",
    "PremisePaths",
    "ProposedBasis",
    "ProposedFact",
    "RetirementSection",
    "TemplateError",
    "TextVariable",
    "Transcript",
    "Variable",
    "candidates_json",
    "current_memory_json",
    "facts_budget_for",
    "make_template",
    "memory_limits_for",
    "ocaml_trim",
    "parse",
    "proposed_fact_json",
    "render",
    "rfc3339_of_unix",
    "surrogate_id",
    "template_from_markdown",
    "utf8_length",
]


@dataclass(frozen=True, slots=True)
class RetirementSection:
    """The retirement evidence MASC appends only when it has some.

    `payload` is the exact JSON text of `retirement_prompt_payload`.
    """

    policy: str
    payload: str


@dataclass(frozen=True, slots=True)
class AdmissionPrompt:
    template: AdmissionTemplate
    keeper_id: str
    keeper_instructions: str
    facts_budget: str
    memory_limits: str
    goal_context: str
    current_memory: CurrentMemory | None
    candidates: tuple[Candidate, ...]
    retirement: RetirementSection | None


def _variable_text(prompt: AdmissionPrompt, name: Variable) -> str:
    match name:
        case "keeper_id":
            return prompt.keeper_id
        case "keeper_instructions":
            return prompt.keeper_instructions
        case "facts_budget":
            return prompt.facts_budget
        case "memory_limits":
            return prompt.memory_limits
        case "goal_context":
            return prompt.goal_context
        case "current_memory":
            return write(current_memory_json(prompt.current_memory))
        case _:
            assert_never(name)


def render(prompt: AdmissionPrompt) -> str:
    """The text MASC sends: main template, admission policy, candidates, retirement."""
    parts: list[str] = []
    for piece in prompt.template.pieces:
        match piece:
            case str():
                parts.append(piece)
            case Hole(name=name):
                parts.append(_variable_text(prompt, name))
            case _:
                assert_never(piece)
    parts.append("\n\n" + prompt.template.admission_policy + CANDIDATE_HEADER)
    parts.append(write(candidates_json(prompt.candidates)))
    if prompt.retirement is not None:
        parts.append("\n\n" + prompt.retirement.policy + "\n" + prompt.retirement.payload)
    return "".join(parts)


type _Bound = tuple[tuple[str, str], ...]


@dataclass(frozen=True, slots=True)
class _CandidateList:
    """The candidate JSON after the admission policy."""


@dataclass(frozen=True, slots=True)
class _Tail:
    """Nothing, or the retirement section, up to the end of the text."""


type _ParsePiece = str | Hole | _CandidateList | _Tail


_CANDIDATES_KEY = "\x00candidates"


_RETIREMENT_KEY = "\x00retirement"


def _bound_value(bound: _Bound, name: str) -> str | None:
    return next((value for key, value in bound if key == name), None)


def _tail_end(text: str, pos: int, policy: str | None) -> tuple[str, int] | None:
    if pos == len(text):
        return "", pos
    if policy is None:
        return None
    head = "\n\n" + policy + "\n"
    if not text.startswith(head, pos):
        return None
    read = read_value_at(text, pos + len(head))
    if isinstance(read, JsonError) or read[1] != len(text):
        return None
    return text[pos + len(head) :], len(text)


def _match(
    text: str,
    pos: int,
    pieces: tuple[_ParsePiece, ...],
    index: int,
    bound: _Bound,
    retirement_policy: str | None,
) -> _Bound | None:
    """Bind each variable to its text; backtrack only over where a text variable ends."""
    if index == len(pieces):
        return bound if pos == len(text) else None
    piece = pieces[index]
    match piece:
        case str():
            if not text.startswith(piece, pos):
                return None
            return _match(text, pos + len(piece), pieces, index + 1, bound, retirement_policy)
        case _CandidateList():
            read = read_value_at(text, pos)
            if isinstance(read, JsonError):
                return None
            entry = ((_CANDIDATES_KEY, text[pos : read[1]]),)
            return _match(text, read[1], pieces, index + 1, bound + entry, retirement_policy)
        case _Tail():
            tail = _tail_end(text, pos, retirement_policy)
            if tail is None:
                return None
            entry = ((_RETIREMENT_KEY, tail[0]),)
            return _match(text, tail[1], pieces, index + 1, bound + entry, retirement_policy)
        case Hole(name=name):
            previous = _bound_value(bound, name)
            if previous is not None:
                if not text.startswith(previous, pos):
                    return None
                return _match(text, pos + len(previous), pieces, index + 1, bound, retirement_policy)
            if name in JSON_VARIABLES:
                read = read_value_at(text, pos)
                if isinstance(read, JsonError):
                    return None
                entry = ((name, text[pos : read[1]]),)
                return _match(text, read[1], pieces, index + 1, bound + entry, retirement_policy)
            following = pieces[index + 1]
            if not isinstance(following, str):
                return None
            start = pos
            while (at := text.find(following, start)) >= 0:
                entry = ((name, text[pos:at]),)
                found = _match(text, at, pieces, index + 1, bound + entry, retirement_policy)
                if found is not None:
                    return found
                start = at + 1
            return None
        case _:
            assert_never(piece)


def parse(text: str, template: AdmissionTemplate) -> AdmissionPrompt | ParseError:
    """The typed prompt, or why `text` is not an admission prompt of this template.

    A prompt parses only when `render` gives `text` back: typed sections must
    be in MASC's exact rendering.
    """
    head = "\n\n" + template.admission_policy + CANDIDATE_HEADER
    pieces: tuple[_ParsePiece, ...] = (*template.pieces, head, _CandidateList(), _Tail())
    bound = _match(text, 0, pieces, 0, (), template.retirement_policy)
    if bound is None:
        return ParseError("text does not follow the template")
    values = dict(bound)
    memory = current_memory_of(values["current_memory"])
    if isinstance(memory, ParseError):
        return memory
    candidates = candidates_of(values[_CANDIDATES_KEY])
    if isinstance(candidates, ParseError):
        return candidates
    tail = values[_RETIREMENT_KEY]
    retirement = None
    if tail != "" and template.retirement_policy is not None:
        retirement = RetirementSection(template.retirement_policy, tail)
    prompt = AdmissionPrompt(
        template=template,
        keeper_id=values["keeper_id"],
        keeper_instructions=values["keeper_instructions"],
        facts_budget=values["facts_budget"],
        memory_limits=values["memory_limits"],
        goal_context=values["goal_context"],
        current_memory=memory,
        candidates=candidates,
        retirement=retirement,
    )
    if write(current_memory_json(memory)) != values["current_memory"]:
        return ParseError("current_memory is not in MASC's rendering")
    if write(candidates_json(candidates)) != values[_CANDIDATES_KEY]:
        return ParseError("candidate data is not in MASC's rendering")
    return prompt
