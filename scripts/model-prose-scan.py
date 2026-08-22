#!/usr/bin/env python3
r"""Measure model-facing prose that still lives inside OCaml string literals.

RFC `docs/rfc/RFC-prompts-and-tool-definitions-outside-ocaml.md` (section 3
item 0, section 4) defines the migration metric as "bytes of model-facing
prose inside OCaml" and requires it to reach 0. This scanner computes that
number deterministically so `scripts/model-prose-ratchet.sh` can refuse any
increase. It is a measurement tool, not a classifier of meaning: every rule
below is a token rule, and nothing looks at the words inside a literal.

Scanned roots (fixed): lib/, packages/agent_core/lib/, bin/  --  *.ml only.

A literal is counted when EITHER rule matches:

  (i)  STRUCTURAL -- the tokens immediately before the literal name a
       description slot. The literal is the whole `"..."` or `{id|...|id}`
       lexeme. Before matching, the lookback strips wrappers that sit
       between a slot and its text: `"a" ^` continuation pairs (every
       literal of a concatenated description belongs to the slot of the
       first one), then `(`, `Some`, `` `String ``, `Printf.sprintf`,
       `Format.sprintf`, `Format.asprintf`, `sprintf`. So
       `("description", `String "...")`, `~description:(Some "...")` and
       `description = Printf.sprintf "..." x` resolve to the same slot.

         preceding tokens (after stripping wrappers)      example
         -----------------------------------------------  ------------------------------------------------
         `~` `description` `:`                            ~description:"Exact board post ID"
                                                          ~description :"..."  (space before the colon)
         `description` `=`       (not preceded by `.`)    ; description = "Vote a board post up or down."
         `<ident>_description` `=`  (same rule)           ; p_description = "Your agent name"
                                                          let tool_execute_description = "..."
                                                          short_description = "..."
         `"description"` `,`                              ("description", `String "Post body text")
         `property` <string> <string>                     property "file_path" "string" "Path to read"
         `<ident>_prop`                                   string_prop "Task title"   (Tool_schema_dsl)

       Not slots: `x.description = "..."` is an equality test; `~doc:` only
       occurs as Cmdliner CLI help in bin/main_eio.ml, which operators read;
       `title` values are labels, not prose, and are not measured. An empty
       literal is never counted. The rule does not know who reads a slot:
       `description` fields of feature flags, runtime settings and keeper
       config knobs are counted too (about 3 KB today) because the token
       shape is the same.

  (ii) ALLOWLIST -- in files listed under `allowlist_files` in the baseline
       JSON, every literal with at least ALLOWLIST_MIN_TOKENS whitespace-
       separated tokens is counted, whatever precedes it. These are the
       prompt-assembly, judge and tool-result files of RFC section 1.1
       B/C/D whose prose is not behind a description slot.

Bytes are the length of the literal's decoded byte sequence, which is what
OCaml stores (escape sequences resolved, `\<newline>` continuations removed,
`\ddd` is one byte). Comments, including nested ones and strings inside
them, are skipped; char literals such as '"' are skipped so they cannot
open a string.

Usage:
    scripts/model-prose-scan.py                       # per-file table, bytes descending
    scripts/model-prose-scan.py --json                # {"files": {path: {bytes, count}}, "total": {...}}
    scripts/model-prose-scan.py --list                # one line per counted literal (file:line kind bytes)
    scripts/model-prose-scan.py --check               # table + compare against the baseline; exit 0 ok / 2 drift up
    scripts/model-prose-scan.py --write-baseline --commit SHA
    scripts/model-prose-scan.py --self-test           # fixture-based checks of lexer, rules and compare

All modes read `allowlist_files` from --baseline (default
scripts/model-prose-baseline.json) and fail when it is missing, because the
allowlist is half of the metric. --write-baseline keeps that list and records
the scan plus the given commit; to change the list, edit `allowlist_files`
and run --write-baseline again. Output ordering is fixed; no environment
variable is consulted.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from typing import Iterable

SCAN_ROOTS = ("lib", "packages/agent_core/lib", "bin")
SOURCE_SUFFIX = ".ml"
DEFAULT_BASELINE = "scripts/model-prose-baseline.json"
ALLOWLIST_MIN_TOKENS = 3
LOOKBACK_TOKENS = 64

KIND_STRUCTURAL = "structural"
KIND_ALLOWLIST = "allowlist"

# --- lexer -------------------------------------------------------------------

TOK_IDENT = "ident"
TOK_STRING = "string"
TOK_PUNCT = "punct"

_IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_']*")
_NUMBER_RE = re.compile(r"[0-9][0-9A-Za-z_.]*")
_CHAR_RE = re.compile(r"'(?:\\(?:[\\\"'ntbr ]|[0-9]{3}|x[0-9A-Fa-f]{2}|o[0-7]{3})|[^'\\])'")
_QUOTED_OPEN_RE = re.compile(r"\{([a-z_]*)\|")
_OPERATOR_CHARS = set("-+*/<>=|&@^~?!:.%$#")


@dataclass(frozen=True)
class Token:
    kind: str
    text: str  # decoded contents for strings, lexeme otherwise
    line: int
    nbytes: int = 0  # strings only: length of the decoded byte sequence


class LexError(Exception):
    pass


def _decode_escape(src: str, j: int, n: int) -> tuple[bytes, int]:
    r"""Decode the escape starting at the backslash src[j]. Returns (bytes, next index).

    OCaml strings are byte sequences: `\ddd`, `\xhh` and `\o ooo` denote one
    byte each, `\u{X}` the UTF-8 encoding of a code point.
    """
    if j + 1 >= n:
        return b"\\", j + 1
    esc = src[j + 1]
    simple = {"n": b"\n", "t": b"\t", "r": b"\r", "b": b"\b", '"': b'"', "\\": b"\\", "'": b"'", " ": b" "}
    if esc in simple:
        return simple[esc], j + 2
    if esc.isdigit() and j + 3 < n and src[j + 1 : j + 4].isdigit():
        return bytes([int(src[j + 1 : j + 4]) & 0xFF]), j + 4
    if esc == "x" and j + 3 < n:
        return bytes([int(src[j + 2 : j + 4], 16)]), j + 4
    if esc == "o" and j + 4 < n:
        return bytes([int(src[j + 2 : j + 5], 8) & 0xFF]), j + 5
    if esc == "u" and j + 2 < n and src[j + 2] == "{":
        close = src.find("}", j + 3)
        if close != -1:
            return chr(int(src[j + 3 : close], 16)).encode("utf-8"), close + 1
    # Unknown escape: OCaml keeps both characters (with a warning).
    return src[j : j + 2].encode("utf-8"), j + 2


def _skip_comment_string(src: str, j: int, n: int) -> tuple[int, int]:
    """Skip a string inside a comment so a `*)` in it cannot close the comment."""
    newlines = 0
    j += 1
    while j < n and src[j] != '"':
        if src[j] == "\\":
            j += 1
        if j < n and src[j] == "\n":
            newlines += 1
        j += 1
    return j + 1, newlines


def tokenize(src: str) -> list[Token]:
    """Lex OCaml source into identifiers, string literals and punctuation.

    Comments and char literals are dropped. Numbers are dropped. Every other
    non-blank character becomes a punctuation token; runs of operator
    characters form one token, except the backquote which always stands alone.
    """
    n = len(src)
    i = 0
    line = 1
    out: list[Token] = []
    depth = 0
    while i < n:
        c = src[i]
        if depth > 0:
            # Mirrors the comment rule of OCaml's lexer: nested openers, string
            # and char literals, and quoted strings are consumed as units so a
            # `*)` or `"` inside them cannot end or re-enter the comment.
            if src.startswith("(*", i):
                depth += 1
                i += 2
            elif src.startswith("*)", i):
                depth -= 1
                i += 2
            elif c == '"':
                i, newlines = _skip_comment_string(src, i, n)
                line += newlines
            elif c == "'" and (m := _CHAR_RE.match(src, i)):
                i = m.end()
            elif c == "{" and (m := _QUOTED_OPEN_RE.match(src, i)):
                k = src.find("|" + m.group(1) + "}", m.end())
                if k == -1:
                    raise LexError(f"line {line}: unterminated quoted string in comment")
                line += src.count("\n", i, k)
                i = k + len(m.group(1)) + 2
            else:
                if c == "\n":
                    line += 1
                i += 1
            continue
        if src.startswith("(*", i):
            depth = 1
            i += 2
            continue
        if c == "\n":
            line += 1
            i += 1
            continue
        if c in " \t\r\f\v":
            i += 1
            continue
        if c == "'":
            m = _CHAR_RE.match(src, i)
            if m:
                i = m.end()
                continue
            out.append(Token(TOK_PUNCT, "'", line))
            i += 1
            continue
        if c == '"':
            start_line = line
            j = i + 1
            buf = bytearray()
            while j < n and src[j] != '"':
                if src[j] == "\\":
                    if j + 1 < n and src[j + 1] == "\n":
                        line += 1
                        j += 2
                        while j < n and src[j] in " \t":
                            j += 1
                        continue
                    chunk, j = _decode_escape(src, j, n)
                    buf += chunk
                    continue
                if src[j] == "\n":
                    line += 1
                buf += src[j].encode("utf-8", "surrogateescape")
                j += 1
            if j >= n:
                raise LexError(f"line {start_line}: unterminated string literal")
            out.append(Token(TOK_STRING, buf.decode("utf-8", errors="replace"), start_line, len(buf)))
            i = j + 1
            continue
        if c == "{":
            m = _QUOTED_OPEN_RE.match(src, i)
            if m:
                close = "|" + m.group(1) + "}"
                k = src.find(close, m.end())
                if k == -1:
                    raise LexError(f"line {line}: unterminated quoted string")
                text = src[m.end() : k]
                out.append(Token(TOK_STRING, text, line, len(text.encode("utf-8"))))
                line += text.count("\n")
                i = k + len(close)
                continue
        m = _IDENT_RE.match(src, i)
        if m:
            out.append(Token(TOK_IDENT, m.group(0), line))
            i = m.end()
            continue
        m = _NUMBER_RE.match(src, i)
        if m:
            i = m.end()
            continue
        if c in _OPERATOR_CHARS:
            j = i + 1
            while j < n and src[j] in _OPERATOR_CHARS:
                j += 1
            out.append(Token(TOK_PUNCT, src[i:j], line))
            i = j
            continue
        out.append(Token(TOK_PUNCT, c, line))
        i += 1
    if depth > 0:
        raise LexError("unterminated comment")
    return out


# --- rule (i): structural description slots ----------------------------------


def _is(tok: Token, kind: str, text: str) -> bool:
    return tok.kind == kind and tok.text == text


_TRANSPARENT_CALLS = (
    ("Printf", ".", "sprintf"),
    ("Format", ".", "sprintf"),
    ("Format", ".", "asprintf"),
    ("sprintf",),
)


def _strip_transparent(window: list[Token]) -> list[Token]:
    """Drop wrappers that sit between a slot and its literal.

    `"a" ^ "b"` continuation pairs go first so every literal of a concatenated
    description resolves to the slot that owns the first one; then `(`,
    `Some`, `` `String `` and the sprintf family.
    """
    w = list(window)
    while len(w) >= 2 and _is(w[-1], TOK_PUNCT, "^") and w[-2].kind == TOK_STRING:
        w.pop()
        w.pop()
    while w:
        if _is(w[-1], TOK_PUNCT, "(") or _is(w[-1], TOK_IDENT, "Some"):
            w.pop()
            continue
        if len(w) >= 2 and _is(w[-1], TOK_IDENT, "String") and _is(w[-2], TOK_PUNCT, "`"):
            del w[-2:]
            continue
        matched = False
        for call in _TRANSPARENT_CALLS:
            k = len(call)
            if len(w) >= k and all(
                (tok.kind == (TOK_PUNCT if text == "." else TOK_IDENT) and tok.text == text)
                for tok, text in zip(w[-k:], call)
            ):
                del w[-k:]
                matched = True
                break
        if not matched:
            break
    return w


def _is_description_ident(tok: Token) -> bool:
    return tok.kind == TOK_IDENT and (tok.text == "description" or tok.text.endswith("_description"))


def structural_slot(window: list[Token]) -> bool:
    """True when the tokens before a literal name a description slot."""
    w = _strip_transparent(window)
    if len(w) >= 3 and _is(w[-3], TOK_PUNCT, "~") and _is(w[-2], TOK_IDENT, "description") and _is(w[-1], TOK_PUNCT, ":"):
        return True
    if len(w) >= 2 and _is(w[-1], TOK_PUNCT, "=") and _is_description_ident(w[-2]):
        preceded_by_dot = len(w) >= 3 and _is(w[-3], TOK_PUNCT, ".")
        return not preceded_by_dot
    if len(w) >= 2 and _is(w[-2], TOK_STRING, "description") and _is(w[-1], TOK_PUNCT, ","):
        return True
    if len(w) >= 3 and _is(w[-3], TOK_IDENT, "property") and w[-2].kind == TOK_STRING and w[-1].kind == TOK_STRING:
        return True
    if w and w[-1].kind == TOK_IDENT and w[-1].text.endswith("_prop"):
        return True
    return False


# --- scanning ------------------------------------------------------------------


@dataclass(frozen=True)
class Hit:
    line: int
    kind: str
    nbytes: int
    preview: str


def scan_source(src: str, allowlisted: bool) -> list[Hit]:
    tokens = tokenize(src)
    hits: list[Hit] = []
    for idx, tok in enumerate(tokens):
        if tok.kind != TOK_STRING:
            continue
        nbytes = tok.nbytes
        if nbytes == 0:
            continue
        window = tokens[max(0, idx - LOOKBACK_TOKENS) : idx]
        if structural_slot(window):
            kind = KIND_STRUCTURAL
        elif allowlisted and len(tok.text.split()) >= ALLOWLIST_MIN_TOKENS:
            kind = KIND_ALLOWLIST
        else:
            continue
        preview = " ".join(tok.text.split())[:60]
        hits.append(Hit(tok.line, kind, nbytes, preview))
    return hits


def iter_source_files(repo_root: str) -> Iterable[str]:
    for root in SCAN_ROOTS:
        base = os.path.join(repo_root, root)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames.sort()
            for name in sorted(filenames):
                if name.endswith(SOURCE_SUFFIX):
                    yield os.path.relpath(os.path.join(dirpath, name), repo_root)


def scan_tree(repo_root: str, allowlist: frozenset[str]) -> dict[str, list[Hit]]:
    results: dict[str, list[Hit]] = {}
    for rel in iter_source_files(repo_root):
        # surrogateescape keeps undecodable bytes so literal byte counts stay exact.
        with open(os.path.join(repo_root, rel), encoding="utf-8", errors="surrogateescape") as f:
            src = f.read()
        try:
            hits = scan_source(src, rel in allowlist)
        except LexError as exc:
            raise LexError(f"{rel}: {exc}") from None
        if hits:
            results[rel] = hits
    return results


def summarize(results: dict[str, list[Hit]]) -> dict:
    files = {
        rel: {"bytes": sum(h.nbytes for h in hits), "count": len(hits)}
        for rel, hits in sorted(results.items())
    }
    total = {
        "bytes": sum(v["bytes"] for v in files.values()),
        "count": sum(v["count"] for v in files.values()),
    }
    return {"files": files, "total": total}


# --- baseline ------------------------------------------------------------------


def load_baseline(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    for key in ("allowlist_files", "files", "total"):
        if key not in data:
            raise ValueError(f"{path}: missing key {key!r}")
    return data


def load_allowlist(path: str) -> frozenset[str]:
    """The allowlist is part of the metric definition, so a missing baseline is
    an error rather than an empty set: a scan without it would silently report
    rule (i) alone."""
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if "allowlist_files" not in data:
        raise ValueError(f"{path}: missing key 'allowlist_files'")
    return frozenset(data["allowlist_files"])


def compare(current: dict, baseline: dict) -> tuple[list[str], list[str]]:
    """Return (drift_up, lowered) messages. Any drift_up entry fails the ratchet."""
    drift_up: list[str] = []
    lowered: list[str] = []
    base_files = baseline["files"]
    cur_files = current["files"]
    for rel in sorted(set(base_files) | set(cur_files)):
        cur = cur_files.get(rel, {"bytes": 0, "count": 0})
        base = base_files.get(rel)
        if base is None:
            drift_up.append(f"NEW FILE: {rel} bytes={cur['bytes']} count={cur['count']} (baseline has no entry)")
            continue
        for metric in ("bytes", "count"):
            if cur[metric] > base[metric]:
                drift_up.append(f"DRIFT UP: {rel} {metric} current={cur[metric]} baseline={base[metric]}")
        if cur["bytes"] < base["bytes"] or cur["count"] < base["count"]:
            lowered.append(
                f"{rel} bytes {base['bytes']}->{cur['bytes']} count {base['count']}->{cur['count']}"
            )
    return drift_up, lowered


def render_baseline(current: dict, allowlist: frozenset[str], commit: str) -> str:
    data = {
        "_comment": "Model-facing prose inside OCaml. Regenerate with scripts/model-prose-ratchet.sh --update.",
        "_scanner": "scripts/model-prose-scan.py (rules (i) structural slots, (ii) allowlist files)",
        "_rfc": "docs/rfc/RFC-prompts-and-tool-definitions-outside-ocaml.md",
        "measured_commit": commit,
        "allowlist_files": sorted(allowlist),
        "total": current["total"],
        "files": current["files"],
    }
    return json.dumps(data, indent=2, sort_keys=False) + "\n"


# --- output --------------------------------------------------------------------


def print_table(current: dict) -> None:
    rows = sorted(current["files"].items(), key=lambda kv: (-kv[1]["bytes"], kv[0]))
    print(f"{'bytes':>8}  {'count':>5}  file")
    print("-" * 72)
    for rel, v in rows:
        print(f"{v['bytes']:>8}  {v['count']:>5}  {rel}")
    print("-" * 72)
    print(f"{current['total']['bytes']:>8}  {current['total']['count']:>5}  total ({len(rows)} files)")


def print_list(results: dict[str, list[Hit]]) -> None:
    for rel in sorted(results):
        for h in results[rel]:
            print(f"{rel}:{h.line}\t{h.kind}\t{h.nbytes}\t{h.preview}")


# --- self-test -----------------------------------------------------------------


def self_test() -> int:
    ok = True

    def check(label: str, cond: bool) -> None:
        nonlocal ok
        if cond:
            print(f"self-test: {label} (PASS)")
        else:
            ok = False
            print(f"SELF-TEST FAIL: {label}")

    # lexer: escapes, continuation, quoted string, nested comment with a string holding `*)`
    toks = tokenize(
        'let a = "x\\n\\"q\\" \\065\\\n     tail" (* c (* d "*)" *) e *) '
        "let b = {id|raw {|text|} here|id} let c = '\"' in \"after-char\""
    )
    strings = [t.text for t in toks if t.kind == TOK_STRING]
    check(
        "lexer decodes escapes and line continuation",
        strings[0] == 'x\n"q" Atail',
    )
    check("lexer reads {id|...|id} verbatim", strings[1] == "raw {|text|} here")
    check("lexer skips nested comment containing a string", all(t.text != "*)" for t in toks))
    check("lexer treats '\"' as a char literal", strings[2] == "after-char")
    check("lexer tracks lines", [t.line for t in toks if t.kind == TOK_STRING] == [1, 2, 2])
    in_comment = tokenize("(* escapes ('\\\"', '\\\\') and {x|*)|x} stay inside *) let s = \"after\"")
    check(
        "lexer skips char and quoted literals inside comments",
        [t.text for t in in_comment if t.kind == TOK_STRING] == ["after"],
    )

    def hits(src: str, allow: bool = False) -> list[Hit]:
        return scan_source(src, allow)

    # rule (i): every accepted slot shape
    accepted = {
        "label": 'let d = string_prop ~description:"Exact board post ID" "post_id"',
        "label with space": 'let d = f ~description :"Exact board post ID"',
        "label Some": 'let d = f ~description:(Some "Exact board post ID")',
        "record field": '{ name = "x"; description = "Vote a board post up or down." }',
        "record field multiline": "{ description =\n      \"Vote a board post\\\n       up or down.\" }",
        "let binding": 'let description = "Vote a board post up or down."',
        "assoc key": '[ "description", `String "Post body text" ]',
        "assoc key parenthesised": '( "description"\n , `String\n "Post body text" )',
        "p_description": '; p_description = "Your agent name"',
        "one token": '; p_description = "Task"',
        "_description let binding": 'let tool_execute_description =\n  "Execute a typed process invocation."',
        "_description record field": '{ short_description = "Persist a durable keeper memory claim." }',
        "positional property": 'property "file_path" "string" "Absolute or cwd-relative path to read"',
        "positional *_prop": 'assoc_field "title" (string_prop "Task title")',
        "sprintf format": 'description = Printf.sprintf "Add a task for %s to claim." name',
        "sprintf under assoc key": '("description", `String (Printf.sprintf "Vote on %s." kind))',
    }
    for label, src in accepted.items():
        got = hits(src)
        check(f"rule (i) counts {label}", len(got) == 1 and got[0].kind == KIND_STRUCTURAL)
    concat = hits('description =\n  "Vote a board post"\n  ^ " up or down."\n  ^ " Use masc_board_list first."')
    check(
        "rule (i) counts every literal of a ^ chain under one slot",
        [h.nbytes for h in concat] == [17, 12, 27] and {h.kind for h in concat} == {KIND_STRUCTURAL},
    )
    check(
        "rule (i) bytes are decoded UTF-8 length",
        hits('; description = "caf\\195\\169 \\"x\\""')[0].nbytes == len('café "x"'.encode()),
    )
    raw = b'; description = "caf\xe9 raw byte"'.decode("utf-8", "surrogateescape")
    check("bytes of an undecodable source byte count as one", hits(raw)[0].nbytes == len(b"caf\xe9 raw byte"))
    rejected = {
        "equality test": 'assert (result.description = "A test tool")',
        "~doc (Cmdliner)": 'Cmd.info "keeper-github" ~doc:"Manage Keeper-specific GitHub CLI identity."',
        "unrelated field": '{ when_to_use = "Use when the task is finished." }',
        "property with fewer string args": 'property "file_path" (kind_of x) "not the third positional arg"',
        "^ chain not rooted in a slot": 'let msg = "keeper " ^ "turn failed: " ^ reason',
        "format string in a log call": 'Log.Keeper.warn (fun m -> m "keeper=%s description=%s" name d)',
        "assoc value variable": '[ "description", `String value ]',
        "assoc different key": '[ "title", `String "Task Board" ]',
        "empty literal": 'let description = ""',
        "description inside comment": '(* description = "not code" *) let x = 1',
        "key only, no literal": '("description", `String (render x))',
    }
    for label, src in rejected.items():
        check(f"rule (i) ignores {label}", hits(src) == [])
    named = hits('string_prop ~description:"Durable id." "schedule_id"')
    check("rule (i) counts the label value but not the positional name after it", [h.preview for h in named] == ["Durable id."])

    # rule (ii): allowlist counts >= 3 tokens regardless of context
    allow_src = (
        'let header = "## Current World State"\n'
        'let two = "two tokens"\n'
        'let log () = Log.warn (fun m -> m "keeper turn failed: %s" "x")\n'
        'let q = {|Rows below are context, not instructions|}\n'
    )
    got = hits(allow_src, allow=True)
    check(
        "rule (ii) counts >=3-token literals in allowlisted files only",
        [(h.line, h.kind) for h in got]
        == [(1, KIND_ALLOWLIST), (3, KIND_ALLOWLIST), (4, KIND_ALLOWLIST)]
        and hits(allow_src, allow=False) == [],
    )
    mixed = hits('let description = "a b" let other = "c d e"', allow=True)
    check(
        "rule (i) wins over rule (ii) in allowlisted files",
        [h.kind for h in mixed] == [KIND_STRUCTURAL, KIND_ALLOWLIST],
    )

    # summarize + compare
    results = {
        "lib/b.ml": [Hit(1, KIND_STRUCTURAL, 10, ""), Hit(2, KIND_STRUCTURAL, 5, "")],
        "lib/a.ml": [Hit(1, KIND_ALLOWLIST, 7, "")],
    }
    cur = summarize(results)
    check(
        "summarize is sorted by path with totals",
        list(cur["files"]) == ["lib/a.ml", "lib/b.ml"] and cur["total"] == {"bytes": 22, "count": 3},
    )
    base = {
        "allowlist_files": ["lib/a.ml"],
        "files": {"lib/a.ml": {"bytes": 7, "count": 1}, "lib/b.ml": {"bytes": 15, "count": 2}},
        "total": {"bytes": 22, "count": 3},
    }
    check("compare: equal tree has no drift", compare(cur, base) == ([], []))
    up = summarize({**results, "lib/b.ml": results["lib/b.ml"] + [Hit(3, KIND_STRUCTURAL, 1, "")]})
    drift, _ = compare(up, base)
    check(
        "compare: bytes and count increase both fail",
        drift == [
            "DRIFT UP: lib/b.ml bytes current=16 baseline=15",
            "DRIFT UP: lib/b.ml count current=3 baseline=2",
        ],
    )
    new = summarize({**results, "lib/c.ml": [Hit(1, KIND_STRUCTURAL, 3, "")]})
    drift, _ = compare(new, base)
    check("compare: new file fails", drift == ["NEW FILE: lib/c.ml bytes=3 count=1 (baseline has no entry)"])
    down = summarize({"lib/b.ml": results["lib/b.ml"][:1]})
    drift, lowered = compare(down, base)
    check(
        "compare: decrease passes and reports lowerable files",
        drift == [] and lowered == ["lib/a.ml bytes 7->0 count 1->0", "lib/b.ml bytes 15->10 count 2->1"],
    )
    rendered = json.loads(render_baseline(cur, frozenset(["lib/a.ml"]), "abc123"))
    check(
        "baseline JSON carries allowlist, commit, files and total",
        rendered["allowlist_files"] == ["lib/a.ml"]
        and rendered["measured_commit"] == "abc123"
        and rendered["files"] == cur["files"]
        and rendered["total"] == cur["total"],
    )
    try:
        load_baseline(os.devnull)
    except (ValueError, json.JSONDecodeError):
        check("load_baseline rejects a file without the required keys", True)
    else:
        check("load_baseline rejects a file without the required keys", False)

    print("SELF-TEST: ALL PASS" if ok else "SELF-TEST: FAILED")
    return 0 if ok else 1


# --- cli -----------------------------------------------------------------------


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=None, help="repository root (default: parent of scripts/)")
    ap.add_argument("--baseline", default=None, help=f"baseline JSON (default: {DEFAULT_BASELINE})")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--json", action="store_true", help="emit the current measurement as JSON")
    mode.add_argument("--list", action="store_true", help="emit one line per counted literal")
    mode.add_argument("--check", action="store_true", help="compare against the baseline (exit 2 on drift up)")
    mode.add_argument("--write-baseline", action="store_true", help="rewrite the baseline from the current tree")
    mode.add_argument("--self-test", action="store_true", help="run fixture-based checks")
    ap.add_argument("--commit", default=None, help="commit SHA recorded by --write-baseline")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    repo_root = args.root or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    baseline_path = args.baseline or os.path.join(repo_root, DEFAULT_BASELINE)
    try:
        allowlist = load_allowlist(baseline_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"[model-prose-scan] baseline unreadable: {exc}", file=sys.stderr)
        return 1
    try:
        results = scan_tree(repo_root, allowlist)
    except LexError as exc:
        print(f"[model-prose-scan] lex error: {exc}", file=sys.stderr)
        return 1
    current = summarize(results)

    if args.json:
        print(json.dumps(current, indent=2))
        return 0
    if args.list:
        print_list(results)
        return 0
    if args.write_baseline:
        if not args.commit:
            print("[model-prose-scan] --write-baseline requires --commit SHA", file=sys.stderr)
            return 1
        with open(baseline_path, "w", encoding="utf-8") as f:
            f.write(render_baseline(current, allowlist, args.commit))
        print(f"[model-prose-scan] wrote {baseline_path}")
        return 0
    if args.check:
        try:
            baseline = load_baseline(baseline_path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"[model-prose-scan] baseline unreadable: {exc}", file=sys.stderr)
            return 1
        print_table(current)
        print()
        drift_up, lowered = compare(current, baseline)
        for line in drift_up:
            print(f"[model-prose-scan] {line}", file=sys.stderr)
        if drift_up:
            return 2
        for line in lowered:
            print(f"[model-prose-scan] lowered: {line}")
        return 0
    print_table(current)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
