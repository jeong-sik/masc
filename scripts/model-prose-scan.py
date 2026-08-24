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
       literal is never counted.

       The rule does not know who reads a slot, so the baseline JSON carries
       `excluded_files`: files whose description fields no model ever reads
       (operator dashboard and settings text, CLI/env help, the HTTP API's
       OpenAPI document, agent-core run labels, inline `let%test` fixtures).
       Each entry maps the path to a one-line reason. Rule (i) is not applied
       there; the slots are still found and reported, and when a file has
       none left --check and --write-baseline say to drop it from the list.

  (ii) ALLOWLIST -- in files listed under `allowlist_files` in the baseline
       JSON, every literal with at least ALLOWLIST_MIN_TOKENS whitespace-
       separated tokens is counted, whatever precedes it, unless it sits in
       a log or exception statement. These are the prompt-assembly, judge and
       tool-result files of RFC section 1.1 B/C/D whose prose is not behind a
       description slot.

       Log/exception context is decided per statement: walking back from the
       literal stops at the nearest boundary token (`let`, `in`, `;`, `;;`,
       `->`, `begin`, `then`, `else`, `match`, `with`, `fun`, `try`); if the
       tokens in between contain an identifier chain starting with `Log.` or
       `Logs.`, or `failwith`, `invalid_arg`, `raise`, `prerr_endline`,
       `Printf.eprintf`, `Fmt.failwith`, the literal is not counted. So
       `| x -> Log.info "..."`, `if c then Log.warn "..."` and
       `Log.info (render "...")` are all excluded, while `Error "..."` and
       `Error (Printf.sprintf "...")` -- tool results the model reads -- are
       not. Because `->` is a boundary, the `Logs`-style `(fun m -> m "...")`
       idiom would not be recognised; the tree has no such log call.

Bytes are the length of the literal's decoded byte sequence, which is what
OCaml stores (escape sequences resolved, `\<newline>` continuations removed,
`\ddd` is one byte). Comments, including nested ones and strings inside
them, are skipped; char literals such as '"' are skipped so they cannot
open a string.

Usage:
    scripts/model-prose-scan.py                       # per-file table, bytes descending
    scripts/model-prose-scan.py --json                # {"files": {path: {bytes, count, structural, allowlist}}, "total"}
    scripts/model-prose-scan.py --markdown            # the same table as Markdown, for the RFC observation section
    scripts/model-prose-scan.py --list                # one line per classified literal (file:line kind bytes)
    scripts/model-prose-scan.py --check               # table + compare against the baseline; exit 0 ok / 2 drift up
    scripts/model-prose-scan.py --write-baseline --commit SHA
    scripts/model-prose-scan.py --self-test           # fixture-based checks of lexer, rules and compare

All modes read `allowlist_files` and `excluded_files` from --baseline
(default scripts/model-prose-baseline.json) and fail when either is missing,
because the lists are part of the metric. --write-baseline keeps both lists
and records the scan plus the given commit; to change a list, edit it and
run --write-baseline again. Output ordering is fixed; no environment
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
KIND_EXCLUDED_SLOT = "excluded-slot"  # a rule (i) slot in an excluded file; reported, never counted
COUNTED_KINDS = (KIND_STRUCTURAL, KIND_ALLOWLIST)

# Rule (ii) log/exception exclusion: walking back from a literal stops at the
# nearest statement boundary; the tokens in between are the statement.
STATEMENT_BOUNDARY_IDENTS = frozenset(
    {"let", "in", "begin", "then", "else", "match", "with", "fun", "try"}
)
STATEMENT_BOUNDARY_PUNCTS = frozenset({";", "->"})
LOG_MODULES = frozenset({"Log", "Logs"})
EXCEPTION_CALLS = frozenset({"failwith", "invalid_arg", "raise", "prerr_endline"})
EXCEPTION_CALL_CHAINS = (("Printf", ".", "eprintf"), ("Fmt", ".", "failwith"))

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


def statement_tokens(tokens: list[Token], idx: int) -> list[Token]:
    """Tokens between the nearest statement boundary and tokens[idx]."""
    j = idx - 1
    while j >= 0:
        tok = tokens[j]
        if tok.kind == TOK_IDENT and tok.text in STATEMENT_BOUNDARY_IDENTS:
            break
        if tok.kind == TOK_PUNCT and tok.text in STATEMENT_BOUNDARY_PUNCTS:
            break
        j -= 1
    return tokens[j + 1 : idx]


def log_or_exception_context(statement: list[Token]) -> bool:
    """True when the statement calls a logger or raises.

    Recognised: an identifier chain starting with `Log.`/`Logs.`, the bare
    calls `failwith`/`invalid_arg`/`raise`/`prerr_endline`, and
    `Printf.eprintf`/`Fmt.failwith`.
    """
    for k, tok in enumerate(statement):
        if tok.kind != TOK_IDENT:
            continue
        if tok.text in EXCEPTION_CALLS:
            return True
        nxt = statement[k + 1] if k + 1 < len(statement) else None
        if tok.text in LOG_MODULES and nxt is not None and _is(nxt, TOK_PUNCT, "."):
            return True
        for chain in EXCEPTION_CALL_CHAINS:
            if tok.text == chain[0] and len(statement) - k >= len(chain):
                if all(
                    (t.kind == (TOK_PUNCT if text == "." else TOK_IDENT) and t.text == text)
                    for t, text in zip(statement[k : k + len(chain)], chain)
                ):
                    return True
    return False


def scan_source(src: str, allowlisted: bool = False, excluded: bool = False) -> list[Hit]:
    """Classify every literal of one source file.

    Counted kinds: rule (i) `structural` and rule (ii) `allowlist`. In an
    excluded file a rule (i) slot is reported as `excluded-slot` so the
    ratchet can say when the file no longer needs the exclusion.
    """
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
            kind = KIND_EXCLUDED_SLOT if excluded else KIND_STRUCTURAL
        elif (
            allowlisted
            and len(tok.text.split()) >= ALLOWLIST_MIN_TOKENS
            and not log_or_exception_context(statement_tokens(tokens, idx))
        ):
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


@dataclass(frozen=True)
class Lists:
    """The two file lists that complete the metric definition."""

    allowlist: frozenset[str]
    excluded: dict[str, str]  # path -> one-line reason


def scan_tree(repo_root: str, lists: Lists) -> dict[str, list[Hit]]:
    results: dict[str, list[Hit]] = {}
    for rel in iter_source_files(repo_root):
        # surrogateescape keeps undecodable bytes so literal byte counts stay exact.
        with open(os.path.join(repo_root, rel), encoding="utf-8", errors="surrogateescape") as f:
            src = f.read()
        try:
            hits = scan_source(src, allowlisted=rel in lists.allowlist, excluded=rel in lists.excluded)
        except LexError as exc:
            raise LexError(f"{rel}: {exc}") from None
        if hits:
            results[rel] = hits
    return results


def _bucket(hits: list[Hit], kind: str) -> dict:
    chosen = [h for h in hits if h.kind == kind]
    return {"bytes": sum(h.nbytes for h in chosen), "count": len(chosen)}


def summarize(results: dict[str, list[Hit]]) -> dict:
    """Per-file totals over the counted kinds, plus the rule (i)/(ii) split."""
    files = {}
    for rel, hits in sorted(results.items()):
        counted = [h for h in hits if h.kind in COUNTED_KINDS]
        if not counted:
            continue
        files[rel] = {
            "bytes": sum(h.nbytes for h in counted),
            "count": len(counted),
            "structural": _bucket(hits, KIND_STRUCTURAL),
            "allowlist": _bucket(hits, KIND_ALLOWLIST),
        }
    total = {
        "bytes": sum(v["bytes"] for v in files.values()),
        "count": sum(v["count"] for v in files.values()),
    }
    return {"files": files, "total": total}


def list_advisories(results: dict[str, list[Hit]], lists: Lists) -> list[str]:
    """Entries of either list that no longer earn their place."""
    out: list[str] = []
    for rel in sorted(lists.excluded):
        if not any(h.kind == KIND_EXCLUDED_SLOT for h in results.get(rel, [])):
            out.append(f"excluded file has no description slot left: remove it from excluded_files: {rel}")
    for rel in sorted(lists.allowlist):
        if not any(h.kind in COUNTED_KINDS for h in results.get(rel, [])):
            out.append(f"allowlisted file has no prose left: remove it from allowlist_files: {rel}")
    return out


# --- baseline ------------------------------------------------------------------


def load_baseline(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    for key in ("allowlist_files", "excluded_files", "files", "total"):
        if key not in data:
            raise ValueError(f"{path}: missing key {key!r}")
    return data


def lists_of(data: dict, path: str) -> Lists:
    """The lists are part of the metric definition, so a baseline without them
    is an error rather than an empty set: a scan without them would silently
    report rule (i) alone over every file."""
    for key in ("allowlist_files", "excluded_files"):
        if key not in data:
            raise ValueError(f"{path}: missing key {key!r}")
    allowlist = frozenset(data["allowlist_files"])
    excluded = data["excluded_files"]
    if not isinstance(excluded, dict) or not all(isinstance(v, str) and v for v in excluded.values()):
        raise ValueError(f"{path}: excluded_files must map each path to a one-line reason")
    both = sorted(allowlist & set(excluded))
    if both:
        raise ValueError(f"{path}: listed as both allowlisted and excluded: {', '.join(both)}")
    return Lists(allowlist=allowlist, excluded=dict(sorted(excluded.items())))


def load_lists(path: str) -> Lists:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return lists_of(data, path)


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


def render_baseline(current: dict, lists: Lists, commit: str) -> str:
    data = {
        "_comment": "Model-facing prose inside OCaml. Regenerate with scripts/model-prose-ratchet.sh --update.",
        "_scanner": "scripts/model-prose-scan.py (rules (i) structural slots, (ii) allowlist files)",
        "_rfc": "docs/rfc/RFC-prompts-and-tool-definitions-outside-ocaml.md",
        "measured_commit": commit,
        "allowlist_files": sorted(lists.allowlist),
        "excluded_files": lists.excluded,
        "total": current["total"],
        "files": {rel: {"bytes": v["bytes"], "count": v["count"]} for rel, v in current["files"].items()},
    }
    return json.dumps(data, indent=2, sort_keys=False, ensure_ascii=False) + "\n"


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


def print_markdown(current: dict) -> None:
    """The per-file table the RFC observation section embeds."""
    rows = sorted(current["files"].items(), key=lambda kv: (-kv[1]["bytes"], kv[0]))
    print("| 파일 | bytes | n | (i) bytes / n | (ii) bytes / n |")
    print("|---|---:|---:|---:|---:|")
    for rel, v in rows:
        s_, a_ = v["structural"], v["allowlist"]
        print(
            f"| `{rel}` | {v['bytes']:,} | {v['count']} "
            f"| {s_['bytes']:,} / {s_['count']} | {a_['bytes']:,} / {a_['count']} |"
        )
    t = current["total"]
    print(f"| **합계 ({len(rows)}개 파일)** | **{t['bytes']:,}** | **{t['count']:,}** | | |")


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
        'let hint () = render "Rows below are context" "x"\n'
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

    # rule (ii): log / exception statements are not prose
    excluded_statements = {
        "match arm Log call": '| Error e -> Log.Keeper.error "keeper turn failed: %s" e',
        "if-then Log call": 'if stale then Log.warn "world observation is stale now"',
        "Log call with parenthesised render": 'Log.info (render "rows below are context")',
        "Log call after labelled args": 'Log.Server.emit ~category:Log.Boundary ~details "publication recovery settled"',
        "failwith": 'let x = failwith "unreachable: no runtime for lane" in',
        "raise Failure": 'raise (Failure "gate replay lost its journal")',
        "Printf.eprintf": 'Printf.eprintf "keeper %s: prompt override unreadable\\n" name',
        "Fmt.failwith": 'Fmt.failwith "unexpected resource kind %a" pp kind',
        "Logs.err": 'Logs.err "agent core request dropped on the floor"',
    }
    for label, src in excluded_statements.items():
        check(f"rule (ii) excludes {label}", hits(src, allow=True) == [])
    kept_statements = {
        "statement before a log statement": (
            'let header = "## Current World State" in\n'
            'Log.Keeper.info "world state header rendered for %s" name'
        ),
        "description slot next to a log statement": (
            'Log.Keeper.info "keeper tool surface built" ; string_prop ~description:"Exact board post ID" "post_id"'
        ),
        "prose arm after a log arm": '| A -> Log.info "a b c" | B -> "Rows below are context, not instructions"',
        "Error result the model reads": 'Error (Printf.sprintf "old_string occurs %d times. Pass replace_all=true." n)',
    }
    expected_kinds = {
        "statement before a log statement": [KIND_ALLOWLIST],
        "description slot next to a log statement": [KIND_STRUCTURAL],
        "prose arm after a log arm": [KIND_ALLOWLIST],
        "Error result the model reads": [KIND_ALLOWLIST],
    }
    for label, src in kept_statements.items():
        check(f"rule (ii) keeps {label}", [h.kind for h in hits(src, allow=True)] == expected_kinds[label])

    # excluded_files: rule (i) reported, never counted
    excluded_src = '{ name = "flag"; description = "Route Execute commands through Docker container" }'
    got = scan_source(excluded_src, allowlisted=False, excluded=True)
    check(
        "excluded file reports the slot as excluded-slot",
        [h.kind for h in got] == [KIND_EXCLUDED_SLOT] and summarize({"lib/x.ml": got})["files"] == {},
    )
    lists = Lists(allowlist=frozenset(["lib/p.ml"]), excluded={"lib/x.ml": "operator text", "lib/y.ml": "gone"})
    advice = list_advisories({"lib/x.ml": got, "lib/p.ml": [Hit(1, KIND_ALLOWLIST, 9, "")]}, lists)
    check(
        "advisory names an excluded file with no slot left and nothing else",
        advice == ["excluded file has no description slot left: remove it from excluded_files: lib/y.ml"],
    )
    advice = list_advisories({}, lists)
    check(
        "advisory names an allowlisted file with no prose left",
        "allowlisted file has no prose left: remove it from allowlist_files: lib/p.ml" in advice,
    )
    try:
        lists_of({"allowlist_files": ["lib/x.ml"], "excluded_files": {"lib/x.ml": "r"}}, "b.json")
    except ValueError:
        check("a file in both lists is rejected", True)
    else:
        check("a file in both lists is rejected", False)
    try:
        lists_of({"allowlist_files": [], "excluded_files": {"lib/x.ml": ""}}, "b.json")
    except ValueError:
        check("an excluded file without a reason is rejected", True)
    else:
        check("an excluded file without a reason is rejected", False)

    # summarize + compare
    results = {
        "lib/b.ml": [Hit(1, KIND_STRUCTURAL, 10, ""), Hit(2, KIND_STRUCTURAL, 5, "")],
        "lib/a.ml": [Hit(1, KIND_ALLOWLIST, 7, ""), Hit(2, KIND_STRUCTURAL, 4, "")],
    }
    cur = summarize(results)
    check(
        "summarize is sorted by path with totals and the rule split",
        list(cur["files"]) == ["lib/a.ml", "lib/b.ml"]
        and cur["total"] == {"bytes": 26, "count": 4}
        and cur["files"]["lib/a.ml"]["structural"] == {"bytes": 4, "count": 1}
        and cur["files"]["lib/a.ml"]["allowlist"] == {"bytes": 7, "count": 1},
    )
    base = {
        "allowlist_files": ["lib/a.ml"],
        "excluded_files": {},
        "files": {"lib/a.ml": {"bytes": 11, "count": 2}, "lib/b.ml": {"bytes": 15, "count": 2}},
        "total": {"bytes": 26, "count": 4},
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
        drift == [] and lowered == ["lib/a.ml bytes 11->0 count 2->0", "lib/b.ml bytes 15->10 count 2->1"],
    )
    rendered = json.loads(render_baseline(cur, Lists(frozenset(["lib/a.ml"]), {"lib/z.ml": "why"}), "abc123"))
    check(
        "baseline JSON carries both lists, commit, bytes/count per file and total",
        rendered["allowlist_files"] == ["lib/a.ml"]
        and rendered["excluded_files"] == {"lib/z.ml": "why"}
        and rendered["measured_commit"] == "abc123"
        and rendered["files"] == {"lib/a.ml": {"bytes": 11, "count": 2}, "lib/b.ml": {"bytes": 15, "count": 2}}
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
    mode.add_argument("--markdown", action="store_true", help="emit the per-file table as Markdown")
    mode.add_argument("--list", action="store_true", help="emit one line per classified literal")
    mode.add_argument("--check", action="store_true", help="table + compare against the baseline (exit 2 on drift up)")
    mode.add_argument("--write-baseline", action="store_true", help="rewrite the baseline from the current tree")
    mode.add_argument("--self-test", action="store_true", help="run fixture-based checks")
    ap.add_argument("--commit", default=None, help="commit SHA recorded by --write-baseline")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    repo_root = args.root or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    baseline_path = args.baseline or os.path.join(repo_root, DEFAULT_BASELINE)
    try:
        lists = load_lists(baseline_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"[model-prose-scan] baseline unreadable: {exc}", file=sys.stderr)
        return 1
    try:
        results = scan_tree(repo_root, lists)
    except LexError as exc:
        print(f"[model-prose-scan] lex error: {exc}", file=sys.stderr)
        return 1
    current = summarize(results)
    advisories = list_advisories(results, lists)

    if args.json:
        print(json.dumps(current, indent=2))
        return 0
    if args.markdown:
        print_markdown(current)
        return 0
    if args.list:
        print_list(results)
        return 0
    if args.write_baseline:
        if not args.commit:
            print("[model-prose-scan] --write-baseline requires --commit SHA", file=sys.stderr)
            return 1
        with open(baseline_path, "w", encoding="utf-8") as f:
            f.write(render_baseline(current, lists, args.commit))
        print(f"[model-prose-scan] wrote {baseline_path}")
        for line in advisories:
            print(f"[model-prose-scan] {line}")
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
        for line in advisories:
            print(f"[model-prose-scan] {line}")
        return 0
    print_table(current)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
