#!/usr/bin/env python3
"""Lint: a wildcard exception catch that can absorb [Eio.Cancel.Cancelled].

A handler that catches everything and returns a value swallows the fiber's
own cancellation, so the fiber carries on working after it was told to stop.
This repo modelled that bug in TLA+ as [CancelledAbsorbed] and hit it at
runtime as an [Assert_failure], which is why the guard exists.

Replaces scripts/lint-cancel-guard.sh. The rule it enforces is unchanged.
What changed is how it decides a handler is already guarded, because the
shell version answered that with line distance and a fixed lookahead, and
seven sites on main were flagged with nothing wrong with them:

  * four had an arm of the *same* handler taking [Eio.Cancel.Cancelled], 4,
    7, 7 and 14 lines up, while the context window read 3 lines;
  * one re-raises its binder, but the binder was extracted with a pattern
    requiring the literal `with`, so `| exception exn ->` never got the
    re-raise lookahead at all;
  * one was flagged because the author's own justification comment pushed
    the [Eio.Cancel.Cancelled] literal out of the 3-line window -- the
    better the explanation, the more likely the guard fails;
  * one was prose inside a comment that spells the pattern out.

The first three are answered structurally here: the context is the arm list
of the enclosing handler rather than a line count, and the binder is read
from any of the arm forms.

Comments are still read as code, on purpose, and the shell version's
reasoning for that is kept verbatim because it still holds: blanking
comments needs an OCaml lexer, and a lexer that gets a nested comment or a
quote wrong stops reporting real catches -- a false negative in the guard
for the bug above. Prose that has to name the pattern says "a bare wildcard
catch" instead of spelling it; a line that really is exempt carries
cancel-guard-ok with a reason.

Exit 0 = no violations, exit 1 = violations found.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

# Libraries that link no eio: a Cancelled cannot arise inside them.
NO_EIO_DIRS = {
    "dashboard_utils", "masc_log", "types", "response", "config",
    "tool_schemas", "mcp_session", "ag_ui", "compression",
    "mcp_transport_protocol",
}

MARKER = "cancel-guard-ok"
CANCELLED = "Eio.Cancel.Cancelled"

# The shapes an exception handler's wildcard arm takes.
WITH_ARM = re.compile(r"\bwith\s+(_|[a-z][A-Za-z0-9_']*)\s*->")
EXCEPTION_ARM = re.compile(r"\|\s*exception\s+(_|[a-z][A-Za-z0-9_']*)\s*->")
# A `try ... with` arm written as `| binder ->` on a later line. The two
# patterns above need `with` or `exception` on the arm's own line, so this
# shape was outside the scan. The enclosing construct decides whether it is
# a handler: see [enclosing_construct].
ARM_PLAIN = re.compile(r"^\s*\|\s*(_|[a-z][A-Za-z0-9_']*)\s*->")

# The construct keywords that introduce a `with` arm list.
CONSTRUCT_KW = re.compile(r"\b(try|match)\b")
# `function` is `match` sugar: its arms follow with no `with` keyword.
FUNCTION_KW = re.compile(r"\bfunction\b")

# A marker must say why. A bare one asserts and nothing more.
EXPLAINED = re.compile(r"cancel-guard-ok:\s*[^\s*]")

# How far up to look for sibling arms of the same handler. The widest real
# gap measured on main was 14 lines; this is bounded so a malformed file
# cannot walk the whole buffer.
ARM_SCAN_LIMIT = 60

# Kept from the shell version: a handler that binds the exception and
# re-raises that same value cannot absorb Cancelled, whatever else it does.
RERAISE = r"\braise\s+{b}\b|raise_with_backtrace\s+{b}\b"

# The budget bounds exemptions: places where a wildcard catch could absorb
# Cancelled and we accept it anyway. It was 37 while the scan only saw arms
# whose `with`/`exception` sat on the arm's own line. Widening the scan to
# arms on a later line surfaced markers that were already in the tree but
# invisible to the old scan. Counting only arms whose own body names an Eio
# operation -- the arms that can actually suspend -- and reading that body
# correctly (the marker's own line excluded, the body bounded at the arm's
# indent) leaves 2. The old 37 was the contaminated definition's number: its
# counter counted the marker line itself, and let the last arm's body run
# into the next function's code.
EXEMPTION_BUDGET = 2


def repo_root() -> Path:
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=True,
    )
    return Path(out.stdout.strip())


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip())


def arm_binder(line: str) -> str | None:
    """The name this arm binds, or None when it binds nothing useful."""
    for pattern in (EXCEPTION_ARM, WITH_ARM, ARM_PLAIN):
        m = pattern.search(line)
        if m:
            name = m.group(1)
            return None if name == "_" else name
    return None


def handler_arms(lines: list[str], index: int) -> list[str]:
    """Sibling arms of the handler the arm at [index] belongs to.

    The shell version read three lines back, which cannot see an arm seven
    lines up with a comment between. Arms of one handler share an
    indentation and each starts with '|', so walking up at that indentation
    finds them however far apart they sit.
    """
    arm_indent = indent_of(lines[index])
    arms: list[str] = []
    for j in range(index - 1, max(-1, index - ARM_SCAN_LIMIT), -1):
        line = lines[j]
        stripped = line.strip()
        if not stripped:
            continue
        here = indent_of(line)
        if stripped.startswith("|") and here == arm_indent:
            arms.append(line)
            continue
        if stripped.startswith("*") or stripped.startswith("(*"):
            # A comment between arms does not end the arm list.
            continue
        if here < arm_indent:
            # The construct header (try / match ... with) or the code above
            # it. Include it: `try f () with` carries no arm of its own but
            # `match x with | Eio.Cancel.Cancelled _ -> ...` can.
            arms.append(line)
            break
        # Deeper than the arms: part of the previous arm's body.
    return arms


def last_construct_keyword(before: str) -> str | None:
    """The last construct keyword in [before], or None."""
    last = None
    for m in CONSTRUCT_KW.finditer(before):
        last = m.group(1)
    return last


def with_owner(line: str) -> str | None:
    """The construct keyword owning the last `with` on this line, or None.

    `try f () with` is a handler; `match x with` is not. When both appear on
    one line -- `try match x with`, or `match (try ... with ...) with` -- the
    keyword at the same parenthesis depth as the `with`, nearest to its left,
    owns it. A bare `with` on a line of its own has no owner here; the caller
    reads the construct from the line above.
    """
    idx = line.rfind("with")
    if idx < 0:
        return None
    depth = 0
    keywords: list[tuple[str, int]] = []
    i = 0
    while i < idx:
        char = line[i]
        if char == "(":
            depth += 1
            i += 1
            continue
        if char == ")":
            depth -= 1
            i += 1
            continue
        m = CONSTRUCT_KW.match(line, i)
        if m:
            keywords.append((m.group(1), depth))
            i = m.end()
            continue
        i += 1
    for keyword, keyword_depth in reversed(keywords):
        if keyword_depth == depth:
            return keyword
    return None


def enclosing_construct(lines: list[str], index: int) -> str | None:
    """The construct whose arm list the arm at [index] belongs to.

    Returns "try" for a handler arm, "match" for a match arm, or None when
    neither can be found. The `with` may sit on the header line (`try f ()
    with`), on a line of its own, or after a `try` on a line of its own; the
    construct keyword may be on the `with` line or above it.
    """
    arm_indent = indent_of(lines[index])
    saw_with = False
    for j in range(index - 1, max(-1, index - ARM_SCAN_LIMIT), -1):
        line = lines[j]
        stripped = line.strip()
        if not stripped or stripped.startswith("*") or stripped.startswith("(*"):
            continue
        if stripped.startswith("|") and not stripped.startswith("|>"):
            # A sibling arm, not the construct header. `|>` is the pipe
            # operator, not an arm.
            continue
        if indent_of(line) > arm_indent:
            continue
        if not saw_with:
            if re.search(r"\bwith\b", line):
                owner = with_owner(line)
                if owner:
                    return owner
                # A bare `with`: the construct keyword is above it.
                saw_with = True
                continue
            if FUNCTION_KW.search(line):
                return "match"
            continue
        keyword = last_construct_keyword(line)
        if keyword:
            return keyword
    return None


def reraise_scope(lines: list[str], index: int) -> list[str]:
    """Where a re-raise of this arm's binder may live.

    Two shapes qualify and they end in different places. `with exn -> ...
    raise exn` ends with the arm. The capture form stores `(exn, bt)` and a
    *later* piece of code -- past the end of the arm -- ends with
    `Printexc.raise_with_backtrace exn bt`; the shell version's fixed eight
    lines reached that and an arm-bounded scan does not. Take both: the arm
    for the first shape, the eight lines for the second.
    """
    arm_indent = indent_of(lines[index])
    end = index + 1
    for j in range(index + 1, min(len(lines), index + ARM_SCAN_LIMIT)):
        stripped = lines[j].strip()
        if not stripped:
            continue
        here = indent_of(lines[j])
        if here <= arm_indent and (stripped.startswith("|") or here < arm_indent):
            break
        end = j + 1
    return lines[index: max(end, min(len(lines), index + 9))]


def arm_body(lines: list[str], index: int) -> list[str]:
    """The lines of the arm at [index], up to the next sibling arm.

    Used to decide whether the arm's own body can suspend. A helper it calls
    may suspend without naming Eio here, so this is a lower bound on risk,
    not a proof; the marker's reason carries the human judgement.

    The body ends at the first line that dedents to the arm's own indent or
    less: a sibling arm, or the enclosing construct's close. Stopping only
    at a sibling `|` let the last arm of a handler run into whatever followed
    it -- [atomic_write.ml]'s last arm swallowed a different function's
    [Eio.] twelve lines down.
    """
    arm_indent = indent_of(lines[index])
    body = [lines[index]]
    for j in range(index + 1, min(len(lines), index + ARM_SCAN_LIMIT)):
        stripped = lines[j].strip()
        if stripped and indent_of(lines[j]) <= arm_indent:
            break
        body.append(lines[j])
    return body


def body_mentions_eio(lines: list[str], index: int) -> bool:
    """Whether the arm's own body names an Eio operation.

    The arm's own line is skipped: a marker's reason usually names the Eio
    operation it is exempt from ("the body is Eio.Cancel.protect"), and
    counting that line made the justification spend the budget it was
    justifying.
    """
    return any(re.search(r"\bEio\.", l) for l in arm_body(lines, index)[1:])


def scan(path: Path) -> tuple[list[str], int]:
    """Violations and exemption count for one file."""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return scan_lines(lines, str(path))


def scan_lines(lines: list[str], path: str) -> tuple[list[str], int]:
    """Violations and exemption count for one source given as lines.

    Split out of [scan] so --self-test drives the classifier CI runs rather
    than a copy of it. Fixtures against a second implementation prove
    nothing about the first.
    """
    violations: list[str] = []
    exemptions = 0
    for i, line in enumerate(lines):
        if not (WITH_ARM.search(line) or EXCEPTION_ARM.search(line)):
            # A `| binder ->` arm is a candidate only when its enclosing
            # construct is a `try`: a `match` arm binds a value, not an
            # exception, and flagging those would report every match in the
            # tree. See [enclosing_construct].
            if not (ARM_PLAIN.match(line) and enclosing_construct(lines, i) == "try"):
                continue
        lineno = i + 1
        binder = arm_binder(line)
        if binder:
            pattern = re.compile(RERAISE.format(b=re.escape(binder)))
            if any(pattern.search(l) for l in reraise_scope(lines, i)):
                continue
        if MARKER in line:
            if not EXPLAINED.search(line):
                violations.append(f"UNEXPLAINED EXEMPTION: {path}:{lineno}: {line.strip()}")
            elif body_mentions_eio(lines, i):
                # An exemption is a place where a wildcard catch could absorb
                # Cancelled and we accept it anyway. A marker on an arm whose
                # body names no Eio operation is a proof that Cancelled cannot
                # arise there, not an exemption, so it does not spend budget.
                exemptions += 1
            continue
        # Guarded when any arm of the same handler names the exception, or
        # when the three lines above do -- the second is kept so nothing the
        # shell version accepted starts failing here.
        context = lines[max(0, i - 3): i + 1] + handler_arms(lines, i)
        if not any(CANCELLED in l for l in context):
            violations.append(f"VIOLATION: {path}:{lineno}: {line.strip()}")
    return violations, exemptions


# Each fixture is (name, expect_violation, source). Every must-pass case is a
# shape the shell version reported with nothing wrong with it, and every
# must-fail case is a swallow that has to stay reported. A guard that only
# proves it passes clean code has not been shown to catch anything.
FIXTURES: list[tuple[str, bool, str]] = [
    ("bare swallow", True, """
  try f () with _ -> ()
"""),
    # Closed: a `try ... with` arm written as `| binder ->` on a later line
    # is now a candidate. The enclosing construct decides -- a `match` arm
    # binds a value, not an exception, so it stays outside the scan.
    ("try/with arm on a later line", True, """
  try f () with
  | exn -> Error (Printexc.to_string exn)
"""),
    ("try/with arm on a later line, guarded by a sibling", False, """
  try f () with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printexc.to_string exn)
"""),
    ("match arm on a later line is not a handler", False, """
  match read () with
  | Ok value -> value
  | Error e -> raise e
"""),
    ("try match: the inner match's arms are not handlers", False, """
  (try match Unix.lstat file with
     | _ -> Error (Unavailable detail)
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
   with Unix.Unix_error (error, operation, _) -> Error (Unavailable operation))
"""),
    ("marker without a reason", True, """
  try f () with _ -> () (* cancel-guard-ok *)
"""),
    ("sibling arm seven lines up, comment between", False, """
  (match read conn with
   | exception Eio.Cancel.Cancelled _ -> ()
   | exception End_of_file ->
     let (_ : bool) = enqueue conn Closed in
     ()
   (* Any other failure is reported the same way, which is why this arm
      does not name it. *)
   | exception e ->
     let (_ : bool) = enqueue conn (Closed (Printexc.to_string e)) in
     ())
"""),
    ("sibling arm fourteen lines up", False, """
  (match run () with
   | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
   | exception exn when is_operator_interrupt exn ->
     let detail = summary exn in
     publish detail;
     settle detail;
     record detail;
     emit detail;
     flush detail;
     close detail;
     drain detail;
     ack detail;
     note detail
   | exception exn ->
     let detail = summary exn in
     publish detail)
"""),
    ("justification comment pushes the literal out of three lines", False, """
  match commit () with
  | () -> Ok Committed
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    (* Propagating costs no half-written state: the transaction and both
       lease confirmations are already complete when this runs, which is why
       the success branch above can raise a pending cancellation too. Using
       raise rather than raise_with_backtrace keeps the original frames,
       because OCaml compiles a raise of the handler's own binding as a
       re-raise. *)
    raise exn
  | exception exn ->
    Ok (Committed_but_observer_failed (exn, Printexc.get_raw_backtrace ()))
"""),
    ("exception arm that re-raises its own binder", False, """
  (match fork_daemon ~sw body with
   | () -> Ok accepted
   | exception exn ->
     let backtrace = Printexc.get_raw_backtrace () in
     let outcome = start_failed (Printexc.to_string exn) in
     (match exn with
      | Eio.Cancel.Cancelled _ -> Printexc.raise_with_backtrace exn backtrace
      | _ -> outcome))
"""),
    ("capture form re-raised past the end of the arm", False, """
  let outcome =
    try Ok (f ()) with
    | exn -> Error (exn, Printexc.get_raw_backtrace ())
  in
  match outcome with
  | Ok value -> value
  | Error (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
"""),
    ("explained marker", False, """
  try f () with
  | _ -> () (* cancel-guard-ok: this module links no eio *)
"""),
]


def self_test() -> int:
    failures = 0
    for name, expect_violation, source in FIXTURES:
        violations, _ = scan_lines(source.splitlines(), f"<{name}>")
        got = bool(violations)
        if got != expect_violation:
            failures += 1
            want = "a violation" if expect_violation else "no violation"
            print(f"FAIL {name}: expected {want}, got {violations or 'none'}")
        else:
            print(f"ok   {name}")
    if failures:
        print(f"{failures} fixture(s) failed.")
        return 1
    print(f"{len(FIXTURES)} fixtures passed.")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    root = repo_root()
    violations: list[str] = []
    exemptions = 0
    for path in sorted((root / "lib").rglob("*.ml")):
        if any(part in NO_EIO_DIRS for part in path.parts):
            continue
        file_violations, file_exemptions = scan(path)
        violations.extend(file_violations)
        exemptions += file_exemptions

    for entry in violations:
        print(entry)
    print(f"cancel-guard exemptions: {exemptions} (budget {EXEMPTION_BUDGET})")

    if violations:
        print(f"Found {len(violations)} wildcard catch(es) without Eio.Cancel guard.")
        return 1
    if exemptions > EXEMPTION_BUDGET:
        print("A new cancel-guard-ok exemption was added.", file=sys.stderr)
        print("  An exempt line is exempt whatever it does, so each one is a place",
              file=sys.stderr)
        print("  Cancelled can be absorbed without this guard saying so. If the line",
              file=sys.stderr)
        print("  really is outside Eio or re-raises, say which on the line itself and",
              file=sys.stderr)
        print("  raise EXEMPTION_BUDGET in this script in the same diff.", file=sys.stderr)
        return 1
    if exemptions < EXEMPTION_BUDGET:
        print(f"An exemption is gone: lower EXEMPTION_BUDGET to {exemptions}.",
              file=sys.stderr)
        return 1
    print("No wildcard catch violations found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
