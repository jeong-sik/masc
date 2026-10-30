"""Check literal-shaped getenv calls and report unresolved binding candidates.

The settings registry marks a setting `Toml_only` when `runtime.toml` is its
only input. `Env_config_core.raw_value_opt` answers such a name from the boot
override store and never from the process environment, so the shell that
started the server cannot change what the file says. A read that goes around
it, such as `Sys.getenv_opt "MASC_KEEPER_DEBUG"`, makes that shell an owner of
the setting again.

The blocking rule is syntactic: a function whose written name contains `getenv`
is applied to a literal spelling of a file-owned name (comments removed).
Parentheses and type constraints around the literal are accepted. It does not
resolve the called function: a local function named `getenv` or a shadowed
`Sys` module has the same syntax and is also reported.

The scan also reports advisory candidates when the argument is

  - a name bound to it, `let debug_env = "MASC_KEEPER_DEBUG"` and then
    `Sys.getenv_opt debug_env` in the file that binds it (a local
    `let ... in` included), or through a module path from any file,
    `Sys.getenv_opt Env_config_keeper.KeeperRuntime.debug_env`.

A name read through `Env_config_core` (`get_bool`, `get_int`, `raw_value_opt`)
is the supported path and is not reported. A name in a list, such as the ones a
keeper's environment is scrubbed of, and a name inside another string, such as an
embedded script, are not reads.

The names come from the settings registry, one per line, in the file given
first, so a setting that becomes file-owned is covered without a line here.
Reads built from pieces (`"MASC_" ^ suffix`) and a bound name used unqualified
in another file, after an `open`, are not seen.

The binding lookup is by identifier, not lexical scope or module ownership.
It can flag unrelated bindings that happen to have the same name, so these
candidates do not fail the check. It does not follow aliases such as
`let alias = key`. Neither a successful check nor an empty candidate list proves
that all process-environment reads are blocked.

usage: test_file_owned_env_reads.py <names file> <source root>...
"""

import re
import sys
from dataclasses import dataclass
from enum import Enum

# The OCaml lexer helpers of the byte-cut scan: comments removed with literals
# kept, string and quoted-string skipping. The scan files sit side by side.
from test_byte_cut_previews import (
    CHAR_LITERAL,
    IDENT_CHAR,
    IDENT_START,
    QUOTED_OPEN,
    blank_comments,
    skip_quoted,
    skip_string,
    source_files,
)

# Any function that reads one variable: `Sys.getenv_opt`, `Unix.getenv`, a local
# `let getenv = Sys.getenv_opt`, a wrapper such as `Process_env.getenv_opt`.
READ = r"(?:[A-Z][A-Za-z0-9_']*\.)*[A-Za-z0-9_']*getenv[A-Za-z0-9_']*"
# The argument: an optional parenthesis, then a literal placeholder or a name.
OPEN = r"\s*\(?\s*"
# `let debug_env = "MASC_X"` and `let debug_env : string = "MASC_X"`; the last
# group is set for `let debug_env = "MASC_X" in`, which no module path reaches.
CONSTANT = re.compile(
    r"\blet\s+(?:rec\s+)?([a-z_][A-Za-z0-9_']*)\s*(?::\s*string\s*)?=\s*\"#(\d+)\"(\s+in\b)?"
)
# Capture the literal and its enclosing opening parentheses. The rest of the
# argument is checked below: a type constraint preserves the literal, whereas
# [("MASC_..." ^ suffix)] computes a different expression.
LITERAL_READ = re.compile(
    READ
    + r'(?P<opens>(?:\s*\()*)\s*"#(?P<literal>\d+)"'
)


class Evidence(Enum):
    LITERAL = "literal syntax"
    BINDING_CANDIDATE = "unresolved binding"


@dataclass(frozen=True)
class Finding:
    line: int
    snippet: str
    evidence: Evidence


def literalize(code):
    """The code with every string literal replaced by "#n", and the literals.

    Reads are looked for in code, never inside a string: an embedded shell or
    Python script that says `getenv "MASC_X"` is data. Character literals and
    identifiers with primes are skipped the way OCaml's lexer skips them, so a
    `'"'` does not open a string.
    """
    out = []
    literals = []
    i = 0
    n = len(code)

    def put(body):
        literals.append(body)
        out.append('"#%d"' % (len(literals) - 1))

    while i < n:
        char = code[i]
        if IDENT_START.match(char):
            j = i + 1
            while j < n and IDENT_CHAR.match(code[j]):
                j += 1
            out.append(code[i:j])
            i = j
            continue
        if char == '"':
            j = skip_string(code, i)
            put(code[i + 1 : j - 1])
            i = j
            continue
        if char == "{":
            opener = QUOTED_OPEN.match(code, i)
            if opener:
                j = skip_quoted(code, opener.end(), opener.group(1))
                put(code[opener.end() : j - len(opener.group(1)) - 2])
                i = j
                continue
        if char == "'":
            literal = CHAR_LITERAL.match(code, i)
            if literal:
                out.append(" ")
                i = literal.end()
                continue
        out.append(char)
        i += 1
    return "".join(out), literals


def bindings_of(text, names):
    """The identifiers bound to a file-owned name: (everywhere, reachable).

    `everywhere` holds every binding, for reads in the file itself. `reachable`
    leaves out `let x = "..." in`, which belongs to its expression and which no
    module path names, for reads written `Module.x` in any file.
    """
    code, literals = literalize(blank_comments(text, keep_width=False))
    everywhere = {}
    reachable = {}
    for match in CONSTANT.finditer(code):
        name = literals[int(match.group(2))]
        if name not in names:
            continue
        everywhere[match.group(1)] = name
        if not match.group(3):
            reachable[match.group(1)] = name
    return everywhere, reachable


def alternation(identifiers):
    return "|".join(re.escape(identifier) for identifier in sorted(identifiers))


def literal_argument_end(code, match):
    """End of a transparent parenthesized literal, or None for an expression.

    A type ascription can contain nested parentheses and quoted attribute data;
    neither closes the expression that contains the annotation. This scanner
    does not validate the type syntax or expand PPX transformations.
    """
    pos = match.end()
    for _ in range(match.group("opens").count("(")):
        while pos < len(code) and code[pos].isspace():
            pos += 1
        if pos < len(code) and code[pos] == ":":
            pos += 1
            nesting = 0
            while pos < len(code):
                if code[pos] == '"':
                    pos = skip_string(code, pos)
                    continue
                if code[pos] == "(":
                    nesting += 1
                elif code[pos] == ")":
                    if nesting == 0:
                        break
                    nesting -= 1
                pos += 1
        if pos >= len(code) or code[pos] != ")":
            return None
        pos += 1
    return pos


def findings(text, names, own, reachable):
    """Literal-shaped calls and advisory binding candidates in [text].

    [own] are the identifiers bound to one in this file, [reachable] the ones a
    module path names in any file.
    """
    code, literals = literalize(blank_comments(text, keep_width=False))
    found = [
        (match, Evidence.LITERAL)
        for match in LITERAL_READ.finditer(code)
        if literals[int(match.group("literal"))] in names
        and literal_argument_end(code, match) is not None
    ]
    if own:
        found.extend((match, Evidence.BINDING_CANDIDATE) for match in
                     re.finditer(READ + OPEN + r"(?:" + alternation(own) + r")\b", code))
    if reachable:
        found.extend(
            (match, Evidence.BINDING_CANDIDATE) for match in
            re.finditer(READ + OPEN + r"(?:[A-Z][A-Za-z0-9_']*\.)+(?:" + alternation(reachable) + r")\b", code)
        )

    def shown(match):
        text = match.group(0)
        if match.re is LITERAL_READ:
            # Extra closing parentheses can belong to an enclosing expression,
            # not to this argument. Do not attribute them to the reported call.
            end = literal_argument_end(code, match)
            assert end is not None
            text = code[match.start() : end]
        text = re.sub(r'"#(\d+)"', lambda hole: '"' + literals[int(hole.group(1))] + '"', text)
        return " ".join(text.split())

    return [
        Finding(code.count("\n", 0, match.start()) + 1, shown(match), evidence)
        for match, evidence in sorted(found, key=lambda item: item[0].start())
    ]


def read_names(path):
    with open(path, encoding="utf-8") as handle:
        names = {line.strip() for line in handle if line.strip()}
    if not names:
        sys.exit(f"{path} names no file-owned setting: the registry or the dump is wrong")
    return names


SELF_NAMES = {"MASC_KEEPER_DEBUG", "MASC_H2_MAX_CONCURRENT_STREAMS"}

# One file each; what the file itself binds is read from the file.
SHOULD_MATCH = [
    'let f () = Sys.getenv_opt "MASC_KEEPER_DEBUG"',
    'let f () = Sys.getenv "MASC_KEEPER_DEBUG"',
    'let f () = Unix.getenv "MASC_KEEPER_DEBUG"',
    'let f () = Stdlib.Sys.getenv_opt "MASC_KEEPER_DEBUG"',
    'let f () = Sys.getenv_opt\n    "MASC_KEEPER_DEBUG"',
    'let f () = Sys.getenv_opt ("MASC_KEEPER_DEBUG")',
    'let f () = Sys.getenv_opt (("MASC_KEEPER_DEBUG"))',
    'let f () = Sys.getenv_opt ( (* outer *) ( ("MASC_KEEPER_DEBUG") ) )',
    'let f () = Sys.getenv_opt ("MASC_KEEPER_DEBUG" : string)',
    'let f () = Sys.getenv_opt ((("MASC_KEEPER_DEBUG" : (string)) : string))',
    'module T = struct type t = string end\nlet f () = Sys.getenv_opt ("MASC_KEEPER_DEBUG" : T.t)',
    'let f () = Sys.getenv "MASC_KEEPER_DEBUG" ^ "_OTHER"',
    'let f () = Sys.getenv ("MASC_KEEPER_DEBUG") ^ "_OTHER"',
    'let f () = Sys.getenv_opt (* why *) "MASC_KEEPER_DEBUG"',
    'let f () = Sys.getenv_opt {|MASC_KEEPER_DEBUG|}',
    'let getenv = Sys.getenv_opt\nlet f () = getenv "MASC_KEEPER_DEBUG"',
    'let f () = Process_env.getenv_opt "MASC_KEEPER_DEBUG"',
    'let f () = match Sys.getenv_opt "MASC_H2_MAX_CONCURRENT_STREAMS" with Some v -> v | None -> ""',
    'let debug_env = "MASC_KEEPER_DEBUG"\nlet f () = Sys.getenv_opt debug_env',
    'let debug_env : string = "MASC_KEEPER_DEBUG"\nlet f () = Sys.getenv_opt debug_env',
    'let rec k = "MASC_KEEPER_DEBUG"\nlet f () = Sys.getenv_opt (k)',
    'let f () =\n  let env_name = "MASC_KEEPER_DEBUG" in\n  Sys.getenv_opt env_name',
    'module K = struct let debug_env = "MASC_KEEPER_DEBUG" end\nlet f () = Sys.getenv_opt K.debug_env',
    'let c = \'"\'\nlet f () = Sys.getenv_opt "MASC_KEEPER_DEBUG"',
]

SHOULD_NOT_MATCH = [
    'let f () = Env_config_core.get_bool ~default:false "MASC_KEEPER_DEBUG"',
    'let f () = raw_value_opt "MASC_KEEPER_DEBUG"',
    'let f () = Env_config_core.raw_value_opt "MASC_H2_MAX_CONCURRENT_STREAMS"',
    'let f () = Sys.getenv_opt "HOME"',
    'let f () = Sys.getenv_opt (("HOME"))',
    # This is outside the direct-literal rule, even though an empty suffix
    # evaluates to the file-owned name and the old prefix match caught it.
    'let f () = Sys.getenv_opt ("MASC_KEEPER_DEBUG" ^ "")',
    'let f () = Sys.getenv_opt ("MASC_KEEPER_DEBUG" ^ "_OTHER")',
    'let f () = Sys.getenv_opt (("MASC_KEEPER_DEBUG" ^ "_OTHER"))',
    'let f () = Sys.getenv_opt (("MASC_KEEPER_DEBUG") ^ "_OTHER")',
    'let f () = Sys.getenv_opt ((("MASC_KEEPER_DEBUG")) ^ "_OTHER")',
    'let f () = Sys.getenv_opt (("MASC_KEEPER_DEBUG" : string) ^ "_OTHER")',
    'let f () = Sys.getenv_opt (("MASC_KEEPER_DEBUG" : string); "MASC_KEEPER_DEBUG_OTHER")',
    'let f () = Sys.getenv_opt "MASC_KEEPER_DEBUG_LEVEL"',
    'let f () = Sys.getenv_opt "XMASC_KEEPER_DEBUG"',
    '(* Sys.getenv_opt "MASC_KEEPER_DEBUG" *)\nlet f () = ()',
    'let scrubbed = [ "MASC_KEEPER_DEBUG"; "HOME" ]',
    'let debug_env = "MASC_KEEPER_DEBUG"\nlet f () = Env_config_core.raw_value_opt debug_env',
    'let debug_env = "MASC_KEEPER_DEBUG"\nlet f () = Sys.getenv_opt other_env',
    'let debug_env = "MASC_KEEPER_DEBUG"\nlet f () = Sys.getenv_opt debug_envelope',
    'let f ?(getenv = Sys.getenv_opt) name = getenv name',
    'let doc = "Sys.getenv_opt \\"MASC_KEEPER_DEBUG\\""',
    'let script = {|getenv "MASC_KEEPER_DEBUG"|}',
    'let script = {sh|Sys.getenv_opt "MASC_KEEPER_DEBUG"|sh}',
    'let c = \'"\'\nlet f () = Sys.getenv_opt "HOME"',
    'let other = "MASC_KEEPER_TIMEOUT"\nlet f () = Sys.getenv_opt other',
    'let f () =\n  let env_name = "MASC_KEEPER_DEBUG" in\n  Env_config_core.raw_value_opt env_name',
]

# Two files: (the file that binds, the file that reads, whether the read is flagged).
# A local binding is not reachable from another file, and an unqualified name is
# the other file's own variable.
PAIRS = [
    ('module K = struct let debug_env = "MASC_KEEPER_DEBUG" end', 'let f () = Sys.getenv_opt K.debug_env', True),
    ('module K = struct let debug_env = "MASC_KEEPER_DEBUG" end', 'let f () = Sys.getenv_opt Env_config_keeper.K.debug_env', True),
    ('let f () = let env_name = "MASC_KEEPER_DEBUG" in Env_config_core.raw_value_opt env_name', 'let g env_name = Sys.getenv_opt env_name', False),
    ('let f () = let env_name = "MASC_KEEPER_DEBUG" in Env_config_core.raw_value_opt env_name', 'let g () = Sys.getenv_opt Other.env_name', False),
    ('module K = struct let debug_env = "MASC_KEEPER_DEBUG" end', 'let g () = Sys.getenv_opt Other.timeout_env', False),
]


def findings_of(texts, names):
    """A finding list per file, keeping certainty separate from detection."""
    bound = [bindings_of(text, names) for text in texts]
    reachable = {}
    for _, reach in bound:
        reachable.update(reach)
    return [findings(text, names, own, reachable) for text, (own, _) in zip(texts, bound)]


def self_test():
    for sample in SHOULD_MATCH:
        if not findings_of([sample], SELF_NAMES)[0]:
            sys.exit(f"the scanner misses a known shape: {sample!r}")
    for sample in SHOULD_NOT_MATCH:
        if findings_of([sample], SELF_NAMES)[0]:
            sys.exit(f"the scanner flags an allowed form: {sample!r}")
    for binder, reader, flagged in PAIRS:
        if bool(findings_of([binder, reader], SELF_NAMES)[1]) != flagged:
            verdict = "misses" if flagged else "flags"
            sys.exit(f"the scanner {verdict} a read across files: {binder!r} / {reader!r}")


def raise_walk_error(error):
    raise error


def main(names_path, roots):
    self_test()
    names = read_names(names_path)
    try:
        paths = sorted(source_files(roots, onerror=raise_walk_error))
    except OSError as error:
        sys.exit(f"cannot enumerate OCaml source files: {error}")
    if not paths:
        sys.exit(f"no .ml file found under {roots}: the roots are wrong")
    texts = []
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as handle:
            texts.append(handle.read())
    flagged = []
    advisory = []
    for path, found in zip(paths, findings_of(texts, names)):
        for finding in found:
            rendered = f"{path}:{finding.line}: {finding.snippet}"
            match finding.evidence:
                case Evidence.LITERAL:
                    flagged.append(rendered)
                case Evidence.BINDING_CANDIDATE:
                    advisory.append(rendered)
    if advisory:
        print(
            "Advisory: unresolved binding candidates; lexical scope and module ownership "
            "are not checked. These candidates do not fail the check:\n  "
            + "\n  ".join(advisory), file=sys.stderr
        )
    if flagged:
        sys.exit(
            "Prohibited literal-shaped getenv calls (function and module identity are "
            "not resolved).\n"
            "For environment reads, use Env_config_core (get_bool, get_int, raw_value_opt), "
            "which respects file ownership:\n  "
            + "\n  ".join(flagged)
        )
    print(f"{len(paths)} .ml files scanned, {len(names)} file-owned names, "
          f"no prohibited literal-shaped call; {len(advisory)} unresolved binding candidates "
          "(advisory). This is not proof of no process-environment reads.")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2:])
