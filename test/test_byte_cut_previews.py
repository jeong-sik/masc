"""No OCaml source cuts a string at a byte offset and appends an ellipsis.

`String.sub s 0 n ^ "..."` splits a multi-byte character whenever one straddles
byte `n`. Korean text is three bytes a character, so the preview ends in a
broken character, and the broken bytes travel on to whatever decodes the
payload (issue #44179, after #35509). `String_util.utf8_prefix` (lib, bin) and
`Agent_core_strings.utf8_prefix` or `Util.clip` (packages/agent_core) cut at a
character boundary.

usage: test_byte_cut_previews.py <source root>...
"""

import os
import re
import sys

SKIPPED_DIRECTORIES = {"_build", "test", ".git", "node_modules"}

# The text that makes a cut a preview: an ellipsis or a truncation note.
LITERAL = r'"(?:[^"\\]|\\.)*?(?:\.\.\.|…|truncated)(?:[^"\\]|\\.)*"'
SUB_HEAD = r"String\.sub\s+(?:[^\s()]+|\([^()]*\))\s+0\s+"
LENGTH = r"(?:\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)|[^\s()^]+)"

CONCATENATED = re.compile(SUB_HEAD + LENGTH + r"\s*\)?\s*\^\s*" + LITERAL)
# A format whose first argument is the cut: `sprintf "%s... (%d bytes)" (String.sub s 0 n)`.
FORMAT_WITH_CUT = r'"(?:[^"\\]|\\.)*?%s\s?(?:\.\.\.|…)(?:[^"\\]|\\.)*"'
FORMATTED = re.compile(
    r"(?:Printf|Format)\.s?printf\s+" + FORMAT_WITH_CUT + r"\s*\(\s*" + SUB_HEAD
)
SHAPES = (CONCATENATED, FORMATTED)


def blank_comments(text):
    """Replace OCaml comments with spaces, keeping newlines and string literals."""
    out = []
    i = 0
    depth = 0
    n = len(text)
    while i < n:
        two = text[i : i + 2]
        char = text[i]
        if depth == 0 and char == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i : j + 1])
            i = j + 1
        elif depth == 0 and text[i : i + 3] in ("'\"'", "'\\\"'"):
            out.append(text[i : i + 3])
            i += 3
        elif two == "(*":
            depth += 1
            out.append("  ")
            i += 2
        elif depth > 0 and two == "*)":
            depth -= 1
            out.append("  ")
            i += 2
        elif depth > 0 and char == '"':
            # A string inside a comment can hold a comment delimiter.
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(re.sub(r"[^\n]", " ", text[i : j + 1]))
            i = j + 1
        else:
            out.append(char if depth == 0 or char == "\n" else " ")
            i += 1
    return "".join(out)


def findings(text):
    code = blank_comments(text)
    found = []
    for shape in SHAPES:
        for match in shape.finditer(code):
            line = code.count("\n", 0, match.start()) + 1
            found.append((line, " ".join(match.group(0).split())))
    return sorted(set(found))


def source_files(roots):
    for root in roots:
        for directory, names, files in os.walk(root):
            names[:] = [name for name in names if name not in SKIPPED_DIRECTORIES]
            for name in files:
                if name.endswith(".ml"):
                    yield os.path.join(directory, name)


SHOULD_MATCH = [
    's ^ String.sub s 0 n ^ "..."',
    'String.sub rendered 0 240 ^ "..."',
    'String.sub s 0 120 ^ "…"',
    'String.sub text 0 (cut 0) ^ "..."',
    'String.sub mapped 0 (utf8_cut mapped (limit + 1)) ^ "…"',
    'String.sub name 0 !cut ^ "..."',
    'String.sub bs.title 0 limit ^ "...[truncated]"',
    'String.sub text 0 max_bytes ^ "\\n[truncated]"',
    '(String.sub s 0 n) ^ "..."',
    'else\n  String.sub s 0 n\n  ^ "..."',
    'Printf.sprintf "%s... (%d bytes)" (String.sub s 0 32) (String.length s)',
    'Printf.sprintf "%s...(%dB)" (String.sub value 0 !cut) len',
]

SHOULD_NOT_MATCH = [
    'String.sub s 0 n ^ "x"',
    'String.sub s 0 n ^ suffix',
    'String_util.utf8_prefix ~max_bytes:n s ^ "..."',
    'Agent_core_strings.utf8_prefix ~max_bytes:n s ^ "..."',
    'String.sub s 1 n ^ "..."',
    'Printf.sprintf "%s: %s" (String.sub s 0 8) rest',
    'Printf.sprintf "\\n… truncated, %d bytes" n in let cut = boundary d r in String.sub d 0 cut',
    '(* String.sub s 0 n ^ "..." *)',
    '(* a note (* nested *) String.sub s 0 n ^ "..." *)',
    '(* "(*" String.sub s 0 n ^ "..." *) let x = 1',
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
        with open(path, encoding="utf-8") as handle:
            for line, snippet in findings(handle.read()):
                flagged.append(f"{path}:{line}: {snippet}")
    if scanned == 0:
        sys.exit(f"no .ml file found under {roots}: the roots are wrong")
    if flagged:
        sys.exit(
            "These sites cut a string at a byte offset and append an ellipsis, "
            "which splits a multi-byte character.\n"
            "Use String_util.utf8_prefix (lib, bin), or Agent_core_strings.utf8_prefix "
            "or Util.clip (packages/agent_core):\n  "
            + "\n  ".join(flagged)
        )
    print(f"{scanned} .ml files scanned, no byte-offset preview cut")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
