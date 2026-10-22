"""No OCaml binding cuts a string at a byte offset and marks the cut with an ellipsis.

`String.sub s 0 n ^ "..."` splits a multi-byte character whenever one straddles
byte `n`. Korean text is three bytes a character, so the preview ends in a
broken character, and the broken bytes travel on to whatever decodes the
payload (issue #44179, after #35509). `String_util.utf8_prefix` and
`String_util.utf8_suffix` (lib, bin), `Agent_core_strings.utf8_prefix` and
`Util.clip` (packages/agent_core) cut at a character boundary.

The rule looks at the text around each cut, not at one expression shape. A call
to `String.sub`, `Bytes.sub_string`, `Bytes.sub`, `Buffer.sub`,
`StringLabels.sub` or `Str.string_before` is reported when, inside one top-level
binding and within WINDOW characters of it (comments removed),

  - there is an ellipsis or truncation-note string literal, `".."` joined with
    `^`, or a constant bound to one (`let cut_mark = "…"`, or a name such as
    `body_truncation_suffix`), and
  - the cut's length does not come from a UTF-8 boundary helper, directly or
    through a name bound to one (`let cut = String_util.utf8_char_boundary s n`),
    nor from a search for an ASCII byte (`String.index_opt s '\n'`), which is
    never inside a multi-byte character.

A helper called elsewhere in the window does not clear a cut: a head cut by
`String_util.utf8_prefix` beside a raw tail cut is still reported.

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
MARKER = (
    r"(?:\.\.\.|…|\\[xX][eE]2\\[xX]80\\[xX][aA]6|\\226\\128\\166|\\u\{2026\}"
    r"|[\[(<]truncated[\])>])"
)
ELLIPSIS_LITERAL = re.compile('"' + LITERAL_BODY + MARKER + LITERAL_BODY + '"', re.I)
# `".."` is a path component and a comparison operand too, so it marks a cut
# only when it is joined to the cut text with `^`.
DOTS_JOINED = re.compile(r'\^\s*"\.\."|"\.\."\s*\^')
# A name that says it is a suffix or mark, wherever it is bound.
ELLIPSIS_NAME = re.compile(r"\b[a-z_0-9']*(?:ellipsis|trunc[a-z]*_suffix)[a-z_0-9']*\b")
# `let cut_mark = "…"`: the constants whose value is an ellipsis, by file.
ELLIPSIS_BINDING = re.compile(
    r'\blet\s+([a-z_][A-Za-z0-9_\']*)\s*(?::\s*string\s*)?=\s*("' + LITERAL_BODY + MARKER + LITERAL_BODY + '")',
    re.I,
)
# How far from the cut an ellipsis still belongs to it, in characters of code
# with the comments removed, inside one top-level binding.
WINDOW = 240
BYTE_CUT = re.compile(
    r"\b(?:String\.sub|Bytes\.sub_string|Bytes\.sub|Buffer\.sub|StringLabels\.sub|Str\.string_before)\b"
)
# The calls that cut at a character boundary. The set is closed on purpose:
# a name that merely starts with `utf8_` is not one.
BOUNDARY_HELPER = re.compile(
    r"\bString_util\.utf8_(?:prefix|suffix|safe|char_boundary|complete_prefix)\b"
    r"|\bAgent_core_strings\.utf8_prefix\b"
    r"|\bUtil\.clip\b"
    r"|\btruncate_utf8_prefix\b"
)
IDENTIFIER = re.compile(r"[a-z_][A-Za-z0-9_']*")
# A character literal for one ASCII byte: 'x', '\n', '\\', '\000'..'\127', '\x00'..'\x7f'.
ASCII_CHAR = (
    r"'(?:[\x00-\x26\x28-\x5b\x5d-\x7f]|\\[ntbr\\'\" ]|\\(?:0[0-9]{2}|1[01][0-9]|12[0-7])|\\x[0-7][0-9a-fA-F])'"
)
# A top-level item starts at column 0.
ITEM_START = re.compile(r"^(?:let|and|module|type|exception|external|class|val)\b", re.M)

CHAR_LITERAL = re.compile(
    r"'(?:[^\\'\n\r]|\\[\\\"'ntbr ]|\\[0-9]{3}|\\x[0-9a-fA-F]{2}|\\o[0-7]{3}|\\u\{[0-9a-fA-F]{1,6}\})'"
)
# {id|...|id} and the extension form {%ext id|...|id}.
QUOTED_OPEN = re.compile(r"\{(?:%%?[A-Za-z_][A-Za-z0-9_'.]*[ \t]*)?([a-z_]*)\|")
IDENT_CHAR = re.compile(r"[A-Za-z0-9_']")
IDENT_START = re.compile(r"[A-Za-z_]")


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


def blank_comments(text, keep_width=True):
    """Remove OCaml comments, keeping newlines and every literal.

    A comment becomes spaces of the same width when [keep_width], nothing
    otherwise (newlines stay either way, so line numbers hold). Follows OCaml's
    lexer: strings, {id|...|id} literals and character literals are skipped
    inside code and inside comments, identifiers swallow their primes, and
    comments nest.
    """
    out = []
    i = 0
    n = len(text)
    depth = 0

    def blank(piece):
        return re.sub(r"[^\n]", " " if keep_width else "", piece)

    while i < n:
        char = text[i]
        if depth == 0 and IDENT_START.match(char):
            j = i + 1
            while j < n and IDENT_CHAR.match(text[j]):
                j += 1
            out.append(text[i:j])
            i = j
            continue
        if char == '"':
            j = skip_string(text, i)
            out.append(text[i:j] if depth == 0 else blank(text[i:j]))
            i = j
            continue
        if char == "{":
            opener = QUOTED_OPEN.match(text, i)
            if opener:
                j = skip_quoted(text, opener.end(), opener.group(1))
                out.append(text[i:j] if depth == 0 else blank(text[i:j]))
                i = j
                continue
        if char == "'":
            literal = CHAR_LITERAL.match(text, i)
            if literal:
                j = literal.end()
                out.append(text[i:j] if depth == 0 else blank(text[i:j]))
                i = j
                continue
        if text.startswith("(*", i):
            depth += 1
            out.append(blank("(*"))
            i += 2
            continue
        if depth > 0 and text.startswith("*)", i):
            depth -= 1
            out.append(blank("*)"))
            i += 2
            continue
        out.append(char if depth == 0 or char == "\n" else blank(char))
        i += 1
    return "".join(out)


def items(code):
    starts = [match.start() for match in ITEM_START.finditer(code)]
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(code)
        yield start, code[start:end]


def balanced_end(text, i):
    """Index just past the parenthesised expression that opens at text[i]."""
    depth = 0
    n = len(text)
    while i < n:
        char = text[i]
        if char == '"':
            i = skip_string(text, i)
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def cut_arguments(item, after_call, count=3):
    """The first [count] arguments of the call that ends at item[after_call]."""
    args = []
    i = after_call
    n = len(item)
    while len(args) < count:
        while i < n and item[i] in " \t\r\n":
            i += 1
        if i >= n or item[i] in ")];,|" or item.startswith("^", i) or item.startswith("in ", i):
            break
        start = i
        if item[i] == "~":
            # a labelled argument: `~pos:expr` or `~len`
            i += 1
            while i < n and (item[i].isalnum() or item[i] in "_'"):
                i += 1
            if i < n and item[i] == ":":
                i += 1
        if i < n and item[i] == "(":
            i = balanced_end(item, i)
        else:
            while i < n and item[i] not in " \t\r\n);]," and not item.startswith("^", i):
                i += 1
        args.append(item[start:i])
    return args


def bound_to_helper(item, name, before):
    """Whether [name] is bound in item[:before] to an expression that calls a helper."""
    for binding in re.finditer(r"\blet\s+(?:rec\s+)?" + re.escape(name) + r"\b[^=\n]*=", item[:before]):
        tail = item[binding.end() : binding.end() + 200]
        end = re.search(r"\bin\b|;;|\n\s*\n", tail)
        if BOUNDARY_HELPER.search(tail[: end.start()] if end else tail):
            return True
    return False


def length_argument(args):
    """The argument that fixes where the cut ends, without its label."""
    labelled = [arg for arg in args if arg.startswith("~len")]
    positional = [arg for arg in args if not arg.startswith("~")]
    if labelled:
        chosen = labelled[0]
    elif len(positional) >= 3:
        chosen = positional[2]
    else:
        chosen = positional[-1] if positional else ""
    return re.sub(r"^~[A-Za-z_]+:?", "", chosen)


def bound_to_ascii_search(item, name, before):
    """Whether [name] in item[:before] is the result of looking for an ASCII byte."""
    search = r"String\.r?index(?:_from)?(?:_opt)?\b[^|;]{0,80}?" + ASCII_CHAR
    bound = re.compile(
        search + r"\s+with\s*\|?\s*Some\s+" + re.escape(name) + r"\b"
        + r"|\blet\s+" + re.escape(name) + r"\s*=\s*" + search
    )
    return bound.search(item[:before]) is not None


def cut_is_boundary_safe(item, cut):
    """Whether the cut ends where a UTF-8 helper or an ASCII byte put it."""
    length = length_argument(cut_arguments(item, cut.end()))
    if BOUNDARY_HELPER.search(length):
        return True
    return any(
        bound_to_helper(item, name, cut.start()) or bound_to_ascii_search(item, name, cut.start())
        for name in IDENTIFIER.findall(length)
    )


def findings(text):
    code = blank_comments(text, keep_width=False)
    file_marks = {match.group(1) for match in ELLIPSIS_BINDING.finditer(code)}
    mark_name = (
        re.compile(r"\b(?:" + "|".join(re.escape(name) for name in sorted(file_marks)) + r")\b")
        if file_marks
        else None
    )
    found = []
    for start, item in items(code):
        for cut in BYTE_CUT.finditer(item):
            window = item[max(0, cut.start() - WINDOW) : cut.end() + WINDOW]
            marked = (
                ELLIPSIS_LITERAL.search(window)
                or DOTS_JOINED.search(window)
                or ELLIPSIS_NAME.search(window)
                or (mark_name is not None and mark_name.search(window))
            )
            if not marked:
                continue
            if cut_is_boundary_safe(item, cut):
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
    'let f s = String.sub s 0 n ^ "\\xE2\\x80\\xA6"',
    'let f s = String.sub s 0 n ^ "\\226\\128\\166"',
    'let f s = String.sub s 0 n ^ "<TRUNCATED>"',
    'let f s = let p = String.sub s 0 n in p ^ "..."',
    'let f s = String.concat "" [ String.sub s 0 n; "..." ]',
    'let f b = Bytes.sub_string b 0 n ^ "..."',
    'let f b = Bytes.sub b 0 n |> Bytes.to_string |> fun p -> p ^ "..."',
    'let f b = Buffer.sub b 0 n ^ "..."',
    'let f s = StringLabels.sub s ~pos:0 ~len:n ^ "..."',
    'let f s = Printf.sprintf "%s... (%d bytes)" (String.sub s 0 32) (String.length s)',
    'let f s = Printf.sprintf "%s: %s..." name (String.sub s 0 n)',
    'let f s = Printf.ksprintf log "%s [truncated]" (String.sub s 0 n)',
    'let f s = "..." ^ String.sub s (String.length s - k) k',
    'let f s = String.sub s 0 8 ^ ".." ^ String.sub s (String.length s - 14) 14',
    'let suffix = "..."\nlet f s = String.sub s 0 n ^ body_truncation_suffix',
    'let cut_mark = "…"\nlet f s = String.sub s 0 n ^ cut_mark',
    'let f s = String.sub s 0 n ^ ellipsis',
    'let f s = String_util.utf8_prefix ~max_bytes:8 s ^ "…" ^ String.sub s (String.length s - 8) 8',
    'let f s = String.sub s (String_util.utf8_char_boundary s 3) 4 ^ "..."',
    'let f s = match String.index_opt s \'\\200\' with Some i -> String.sub s 0 i ^ "..." | None -> s',
    'let f s = let utf8_cut = n in String.sub s 0 utf8_cut ^ "..."',
    'let f s = Log.info "utf8_ok"; String.sub s 0 n ^ "..."',
    'let f s = let head = String.sub s 0 n in (* ' + "x" * 400 + ' *) head ^ "..."',
    "let f s = (* it's *) String.sub s 0 n ^ \"...\"",
    'let f s = String.sub s 0 n ^ "..." (* \'"\' *)',
    'let script = {|def g(*args): pass|}\nlet f s = String.sub s 0 n ^ "..."',
    'let re = {|["\']|}\nlet f s = String.sub s 0 n ^ "..."',
    'let a = {%ext|(* nope |}\nlet f s = String.sub s 0 n ^ "..."',
    'let x\'"\'(*c*)\nlet f s = String.sub s 0 n ^ "..."',
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
    'let f s = String.sub s 0 (String_util.utf8_char_boundary s n) ^ "..."',
    'let f s =\n  let start = String_util.utf8_char_boundary s 3 in\n  String.sub s start (String.length s - start) ^ "..."',
    'let f s = match String.index_opt s \'\\n\' with Some i -> String.sub s 0 i ^ "..." | None -> s',
    'let f s = let i = String.index s \':\' in String.sub s 0 i ^ "..."',
    'let f s = match String.index_from_opt s 2 \'/\' with Some i -> String.sub s 0 i ^ "..." | None -> s',
    'let first_word s = String.sub s 0 (String.index s \' \')\nlet usage = "foo ..."',
    'let parent = Filename.concat dir ".."\nlet f s = String.sub s 0 n',
    'let f s = if s = ".." then s else String.sub s 0 n',
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
