"""No OCaml binding cuts a string at a byte offset and marks the cut with an ellipsis.

`String.sub s 0 n ^ "..."` splits a multi-byte character whenever one straddles
byte `n`. Korean text is three bytes a character, so the preview ends in a
broken character, and the broken bytes travel on to whatever decodes the
payload (issue #44179, after #35509). `String_util.utf8_prefix` and
`String_util.utf8_suffix` (lib, bin), `Agent_core_strings.utf8_prefix` and
`Util.clip` (packages/agent_core) cut at a character boundary.

The rule looks at the text around each cut, not at one expression shape, so a
cut bound to a name first, a cut that is not the first format argument, a tail
cut (`"..." ^ String.sub s (n - k) k`) and a suffix kept in a named constant
are all seen. A call to `String.sub`, `Bytes.sub_string` or `StringLabels.sub`
is reported when, within a top-level binding and WINDOW characters of it,

  - there is an ellipsis or truncation-note string literal (or a suffix
    constant such as `body_truncation_suffix`), and
  - there is no UTF-8 aware helper.

usage: test_byte_cut_previews.py <source root>...
"""

import os
import re
import sys

SKIPPED_DIRECTORIES = {"_build", "test", ".git", "node_modules"}

# Characters of a string literal body: anything but a quote, or an escape pair.
LITERAL_BODY = r'(?:[^"\\]|\\.)*'
# What marks a cut as a preview: an ellipsis (ASCII, Unicode or escaped bytes)
# or a truncation note.
ELLIPSIS_LITERAL = re.compile(
    '"' + LITERAL_BODY + r'(?:\.\.\.|…|\\xe2\\x80\\xa6|\\u\{2026\}|\[truncated\]|\(truncated\))' + LITERAL_BODY + '"'
)
# A suffix kept in a named constant, e.g. `body_truncation_suffix`.
ELLIPSIS_NAME = re.compile(r"\b[a-z_0-9']*(?:ellipsis|trunc[a-z]*_suffix)[a-z_0-9']*\b")
# How far from the cut an ellipsis or a UTF-8 helper still belongs to it, in
# characters, inside one top-level binding.
WINDOW = 240
BYTE_CUT = re.compile(r"\b(?:String\.sub|Bytes\.sub_string|StringLabels\.sub)\b")
CHARACTER_AWARE = re.compile(
    r"\butf8_[a-z_]+|\bAgent_core_strings\.|\bUtil\.clip\b|\btruncate_utf8_prefix\b"
)
# A top-level item starts at column 0.
ITEM_START = re.compile(r"^(?:let|and|module|type|exception|external|class|val)\b", re.M)

CHAR_LITERAL = re.compile(
    r"'(?:[^\\'\n\r]|\\[\\\"'ntbr ]|\\[0-9]{3}|\\x[0-9a-fA-F]{2}|\\o[0-7]{3}|\\u\{[0-9a-fA-F]{1,6}\})'"
)
QUOTED_OPEN = re.compile(r"\{([a-z_]*)\|")


def skip_string(text, i):
    """Index just past the string literal that opens at text[i] == '"'."""
    n = len(text)
    i += 1
    while i < n and text[i] != '"':
        i += 2 if text[i] == "\\" else 1
    return min(i + 1, n)


def skip_quoted(text, i, identifier):
    """Index just past the {id|...|id} literal whose opener ends at text[i]."""
    close = "|" + identifier + "}"
    end = text.find(close, i)
    return len(text) if end < 0 else end + len(close)


def blank_comments(text):
    """Replace OCaml comments with spaces, keeping newlines and every literal.

    Follows OCaml's lexer: strings, {id|...|id} literals and character
    literals are skipped inside code and inside comments, and comments nest.
    """
    out = []
    i = 0
    n = len(text)
    depth = 0
    while i < n:
        char = text[i]
        if char == '"':
            j = skip_string(text, i)
            out.append(text[i:j] if depth == 0 else re.sub(r"[^\n]", " ", text[i:j]))
            i = j
            continue
        if char == "{":
            opener = QUOTED_OPEN.match(text, i)
            if opener:
                j = skip_quoted(text, opener.end(), opener.group(1))
                out.append(text[i:j] if depth == 0 else re.sub(r"[^\n]", " ", text[i:j]))
                i = j
                continue
        if char == "'":
            literal = CHAR_LITERAL.match(text, i)
            if literal:
                j = literal.end()
                out.append(text[i:j] if depth == 0 else " " * (j - i))
                i = j
                continue
        if text.startswith("(*", i):
            depth += 1
            out.append("  ")
            i += 2
            continue
        if depth > 0 and text.startswith("*)", i):
            depth -= 1
            out.append("  ")
            i += 2
            continue
        out.append(char if depth == 0 or char == "\n" else " ")
        i += 1
    return "".join(out)


def items(code):
    starts = [match.start() for match in ITEM_START.finditer(code)]
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(code)
        yield start, code[start:end]


def findings(text):
    code = blank_comments(text)
    found = []
    for start, item in items(code):
        for cut in BYTE_CUT.finditer(item):
            window = item[max(0, cut.start() - WINDOW) : cut.end() + WINDOW]
            if not (ELLIPSIS_LITERAL.search(window) or ELLIPSIS_NAME.search(window)):
                continue
            if CHARACTER_AWARE.search(window):
                continue
            line = code.count("\n", 0, start + cut.start()) + 1
            found.append((line, " ".join(item[cut.start() : cut.start() + 90].split())))
    return found


def source_files(roots):
    for root in roots:
        if not os.path.isdir(root):
            sys.exit(f"source root {root} is not a directory")
        for directory, names, files in os.walk(root):
            names[:] = [name for name in names if name not in SKIPPED_DIRECTORIES]
            for name in files:
                if name.endswith(".ml"):
                    yield os.path.join(directory, name)


SHOULD_MATCH = [
    'let f s n = if String.length s > n then String.sub s 0 n ^ "..." else s',
    'let f s = String.sub s 0 240 ^ "…"',
    'let f s = String.sub s 0 (cut 0) ^ "..."',
    'let f s = String.sub (String.trim (g s)) 0 n ^ "..."',
    'let f s = (String.sub s 0 n) ^ "..."',
    'let f s =\n  String.sub s 0 n\n  ^ "..."',
    'let f s = String.sub s 0 n ^ "...[truncated]"',
    'let f s = String.sub s 0 n ^ "\\n[truncated]"',
    'let f s = String.sub s 0 n ^ "\\xe2\\x80\\xa6"',
    'let f s = let p = String.sub s 0 n in p ^ "..."',
    'let f s = String.concat "" [ String.sub s 0 n; "..." ]',
    'let f b = Bytes.sub_string b 0 n ^ "..."',
    'let f s = StringLabels.sub s ~pos:0 ~len:n ^ "..."',
    'let f s = Printf.sprintf "%s... (%d bytes)" (String.sub s 0 32) (String.length s)',
    'let f s = Printf.sprintf "%s: %s..." name (String.sub s 0 n)',
    'let f s = Printf.ksprintf log "%s [truncated]" (String.sub s 0 n)',
    'let f s = "..." ^ String.sub s (String.length s - k) k',
    'let suffix = "..."\nlet f s = String.sub s 0 n ^ body_truncation_suffix',
    'let f s = String.sub s 0 n ^ ellipsis',
    "let f s = (* it's *) String.sub s 0 n ^ \"...\"",
    'let f s = String.sub s 0 n ^ "..." (* \'"\' *)',
    'let script = {|def g(*args): pass|}\nlet f s = String.sub s 0 n ^ "..."',
    'let re = {|["\']|}\nlet f s = String.sub s 0 n ^ "..."',
]

SHOULD_NOT_MATCH = [
    'let f s = String.sub s 0 n ^ "x"',
    'let f s = String.sub s 0 n ^ suffix',
    'let f s = String_util.utf8_prefix ~max_bytes:n s ^ "..."',
    'let f s = Agent_core_strings.utf8_prefix ~max_bytes:n s ^ "..."',
    'let f s = Util.clip s 20',
    'let f s = "..." ^ String_util.utf8_suffix ~max_bytes:n s',
    'let f s = String.sub s 1 n |> String.trim',
    'let f s = (* String.sub s 0 n ^ "..." *) s',
    'let f s = (* a note (* nested *) String.sub s 0 n ^ "..." *) s',
    'let f s = (* "(*" String.sub s 0 n ^ "..." *) s',
    'let f s = (* \'"\' String.sub s 0 n ^ "..." *) s',
    'let re = {|["\']|}\nlet f s = (* String.sub s 0 n ^ "..." *) s',
    'let script = {|def g(*args): pass|}\nlet f s = s',
    'let f s =\n  let cut = String_util.utf8_char_boundary s n in\n  String.sub s 0 cut ^ "..."',
    'let first_word s = String.sub s 0 (String.index s \' \')\nlet usage = "foo ..."',
]


def self_test():
    for sample in SHOULD_MATCH:
        if not findings(sample):
            sys.exit(f"the scanner misses a known shape: {sample!r}")
    for sample in SHOULD_NOT_MATCH:
        if findings(sample):
            sys.exit(f"the scanner flags an allowed form: {sample!r}")


def main(roots):
    self_test()
    flagged = []
    scanned = 0
    for path in sorted(source_files(roots)):
        scanned += 1
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line, snippet in findings(handle.read()):
                flagged.append(f"{path}:{line}: {snippet}")
    if scanned == 0:
        sys.exit(f"no .ml file found under {roots}: the roots are wrong")
    if flagged:
        sys.exit(
            "These bindings cut a string at a byte offset and mark the cut with an "
            "ellipsis, which splits a multi-byte character.\n"
            "Use String_util.utf8_prefix or String_util.utf8_suffix (lib, bin), or "
            "Agent_core_strings.utf8_prefix or Util.clip (packages/agent_core):\n  "
            + "\n  ".join(flagged)
        )
    print(f"{scanned} .ml files scanned, no byte-offset preview cut")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
