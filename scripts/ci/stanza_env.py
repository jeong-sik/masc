#!/usr/bin/env python3
"""The environment a test suite's dune stanza sets, for a run outside dune.

test.yml's targeted path runs a suite's executable directly so alcotest can
print each case as it finishes. Running it directly means dune's `(action
(setenv ...))` does not apply, and 22 of the 346 stanzas under test/stanzas
declare one. test.yml knew about exactly one of them, hardcoded by name, so a
dispatch naming any of the other 21 ran that suite with the wrong environment
and reported verdicts that do not match what the nightly lane sees.

This reads the stanza instead. Unresolvable values are an error, never a
skip: a suite running under the wrong environment is worse than one that does
not run, because its verdicts look real.

    stanza_env.py <suite>          KEY=VALUE per line, for `env`
    stanza_env.py --deps <suite>   dune targets to build first, from the root

The two forms spell the same file differently on purpose. A stanza writes a
path relative to test/, which is where the runner stands
(_build/default/test), so the environment keeps it as written; `dune build`
takes its targets from the repo root, so --deps normalises them there.
    stanza_env.py --check-all      read every stanza; fail on any it cannot
    stanza_env.py --self-test      run the checker against fixtures
"""

from __future__ import annotations

import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STANZA_DIR = os.path.join(REPO_ROOT, "test", "stanzas")

# %{dep:PATH} is the only dune variable a value may use. Paths in a stanza are
# written relative to test/, which is where the targeted runner stands
# (_build/default/test), so the path passes through unchanged.
DEP_RE = re.compile(r"^%\{dep:([^}]+)\}$")
VAR_RE = re.compile(r"%\{")


class StanzaError(Exception):
    pass


def tokenize(text: str) -> list[str]:
    """S-expression tokens, with comments and strings handled.

    Dune comments run from ';' to end of line. A quoted value keeps its
    spaces and loses its quotes.
    """
    tokens: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == ";":
            while i < n and text[i] != "\n":
                i += 1
        elif c in "()":
            tokens.append(c)
            i += 1
        elif c.isspace():
            i += 1
        elif c == '"':
            i += 1
            start = i
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                i += 1
            if i >= n:
                raise StanzaError("unterminated string in stanza")
            tokens.append(text[start:i])
            i += 1
        else:
            start = i
            while i < n and not text[i].isspace() and text[i] not in '();"':
                i += 1
            tokens.append(text[start:i])
    return tokens


def parse(tokens: list[str]) -> list:
    """Tokens to nested lists. Atoms stay strings."""
    pos = 0

    def walk():
        nonlocal pos
        out = []
        while pos < len(tokens):
            tok = tokens[pos]
            pos += 1
            if tok == "(":
                out.append(walk())
            elif tok == ")":
                return out
            else:
                out.append(tok)
        return out

    return walk()


def stanza_names(form: list) -> list[str]:
    """The executables a (test ...) or (tests ...) stanza declares."""
    names: list[str] = []
    for item in form:
        if isinstance(item, list) and item:
            if item[0] == "name" and len(item) > 1:
                names.append(item[1])
            elif item[0] == "names":
                names.extend(x for x in item[1:] if isinstance(x, str))
    return names


def collect_setenv(form) -> list[tuple[str, str]]:
    """Every (setenv KEY VALUE ...) in a form, outermost first.

    dune applies them outside-in, so a repeated key takes its innermost
    value; returning them in source order and letting the caller assign in
    order reproduces that.
    """
    found: list[tuple[str, str]] = []
    if not isinstance(form, list):
        return found
    if form and form[0] == "setenv":
        if len(form) < 3:
            raise StanzaError(f"setenv with no key/value pair: {form}")
        key, value = form[1], form[2]
        if not isinstance(key, str) or not isinstance(value, str):
            raise StanzaError(f"setenv key and value must be atoms: {form}")
        found.append((key, value))
        for sub in form[3:]:
            found.extend(collect_setenv(sub))
        return found
    for sub in form:
        found.extend(collect_setenv(sub))
    return found


def resolve(key: str, value: str) -> tuple[str, str | None]:
    """(value for env, dune target to build first).

    A value naming a dune variable other than %{dep:...} cannot be resolved
    here, and guessing would run the suite with a literal '%{...}' in its
    environment.
    """
    match = DEP_RE.match(value)
    if match:
        return match.group(1), match.group(1)
    if VAR_RE.search(value):
        raise StanzaError(
            f"{key} uses a dune variable this cannot resolve: {value!r}. "
            "Only %{dep:PATH} is supported; add support or move the value "
            "out of the stanza."
        )
    return value, None


def stanza_text(suite: str) -> tuple[str, bool]:
    """(text, whether it is this suite's own file).

    A file under test/stanzas belongs to one suite, so every setenv in it is
    that suite's -- including the ones in a (rule (alias runtest) ...), which
    carries no (name ...) to match on. A suite with no such file is declared
    inline in test/dune among many others, so there the stanza has to be
    found by name.
    """
    path = os.path.join(STANZA_DIR, f"{suite}.inc")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            return handle.read(), True
    with open(os.path.join(REPO_ROOT, "test", "dune"), encoding="utf-8") as handle:
        return handle.read(), False


def suite_env(
    suite: str, text: str, own_file: bool = True
) -> tuple[list[tuple[str, str]], list[str]]:
    forms = parse(tokenize(text))
    if own_file:
        pairs = collect_setenv(forms)
    else:
        pairs = []
        for form in forms:
            if not isinstance(form, list) or not form:
                continue
            if form[0] not in ("test", "tests"):
                continue
            if suite not in stanza_names(form):
                continue
            pairs.extend(collect_setenv(form))
        # test/dune declares hundreds of suites. Finding a setenv there that
        # this could not attribute would mean running with a partial
        # environment, which is the failure this whole script exists to stop.
        if not pairs and "(setenv" in text and suite in text:
            raise StanzaError(
                "declared inline in test/dune next to a setenv this could not "
                "attribute; give the suite its own test/stanzas file or extend "
                "this reader"
            )
    env: list[tuple[str, str]] = []
    deps: list[str] = []
    for key, value in pairs:
        resolved, dep = resolve(key, value)
        env.append((key, resolved))
        if dep is not None and dep not in deps:
            deps.append(dep)
    return env, deps


FIXTURE_PLAIN = """
(test
 (name test_alpha)
 (modules test_alpha)
 (action
  (setenv MASC_EXEC_ALLOW_LOCAL_PLAYGROUND true
   (setenv MASC_BASE_PATH /tmp/test-alpha
    (setenv MASC_BASE_PATH_INPUT /tmp/test-alpha
     (run %{test})))))
 (libraries alcotest))
"""

FIXTURE_SPLIT = """
; a comment mentioning (setenv NOT_A_KEY value) must not be read
(test
 (name test_beta)
 (action
  (setenv
   HOME
   /tmp/beta-home
   (run %{test}))))
"""

FIXTURE_DEP = """
(test
 (name test_gamma)
 (action
  (setenv MASC_MAIN_EIO_EXE %{dep:../bin/main_eio.exe} (run %{test}))))
"""

FIXTURE_UNKNOWN_VAR = """
(test
 (name test_delta)
 (action
  (setenv SOMETHING %{exe:../bin/other.exe} (run %{test}))))
"""

FIXTURE_RULE = """
(rule
 (alias runtest)
 (deps test_epsilon.py ../bin/manifest.exe)
 (action
  (setenv KEEPER_STORE_LAYOUT_MANIFEST_EXE
   %{dep:../bin/manifest.exe}
   (run python3 test_epsilon.py))))
"""

FIXTURE_GROUP = """
(tests
 (names test_one test_two)
 (libraries alcotest))
"""


def self_test() -> int:
    failures = 0

    def check(label, got, want):
        nonlocal failures
        if got != want:
            failures += 1
            print(f"FAIL {label}\n  got  {got!r}\n  want {want!r}", file=sys.stderr)
        else:
            print(f"pass {label}")

    env, deps = suite_env("test_alpha", FIXTURE_PLAIN)
    check(
        "nested setenv keeps source order",
        env,
        [
            ("MASC_EXEC_ALLOW_LOCAL_PLAYGROUND", "true"),
            ("MASC_BASE_PATH", "/tmp/test-alpha"),
            ("MASC_BASE_PATH_INPUT", "/tmp/test-alpha"),
        ],
    )
    check("plain values need nothing built", deps, [])

    env, _ = suite_env("test_beta", FIXTURE_SPLIT)
    check("a setenv split across lines is one pair", env, [("HOME", "/tmp/beta-home")])

    env, deps = suite_env("test_gamma", FIXTURE_DEP)
    check("a dep value becomes its path", env, [("MASC_MAIN_EIO_EXE", "../bin/main_eio.exe")])
    check("and is reported as a target to build", deps, ["../bin/main_eio.exe"])
    check(
        "which dune takes from the root, not from test/",
        [os.path.normpath(os.path.join("test", d)) for d in deps],
        ["bin/main_eio.exe"],
    )

    try:
        suite_env("test_delta", FIXTURE_UNKNOWN_VAR)
        failures += 1
        print("FAIL an unresolvable dune variable was accepted", file=sys.stderr)
    except StanzaError as exc:
        if "%{exe:" not in str(exc):
            failures += 1
            print(f"FAIL the error does not name the value: {exc}", file=sys.stderr)
        else:
            print("pass an unresolvable dune variable is an error, not a skip")

    env, _ = suite_env("test_one", FIXTURE_GROUP, own_file=False)
    check("a group stanza with no action yields nothing", env, [])

    env, _ = suite_env("test_absent", FIXTURE_PLAIN, own_file=False)
    check("a suite this text does not declare yields nothing", env, [])

    env, deps = suite_env("test_epsilon", FIXTURE_RULE)
    check(
        "a (rule (alias runtest)) stanza is read like any other",
        env,
        [("KEEPER_STORE_LAYOUT_MANIFEST_EXE", "../bin/manifest.exe")],
    )
    check("and its dep is a target", deps, ["../bin/manifest.exe"])

    try:
        suite_env("test_zeta", "(tests (names test_zeta))\n(setenv OTHER x (run y))", own_file=False)
        failures += 1
        print("FAIL an unattributable inline setenv was accepted", file=sys.stderr)
    except StanzaError:
        print("pass an unattributable inline setenv is an error, not an empty result")

    # The one suite test.yml used to hardcode still reads the same three.
    real = os.path.join(STANZA_DIR, "test_heartbeat_integration.inc")
    if os.path.exists(real):
        with open(real, encoding="utf-8") as handle:
            env, _ = suite_env("test_heartbeat_integration", handle.read())
        check(
            "the real stanza reads what test.yml hardcoded",
            env,
            [
                ("MASC_EXEC_ALLOW_LOCAL_PLAYGROUND", "true"),
                ("MASC_BASE_PATH", "/tmp/test-heartbeat-integ"),
                ("MASC_BASE_PATH_INPUT", "/tmp/test-heartbeat-integ"),
            ],
        )

    if failures:
        print(f"stanza env self-test: {failures} case(s) wrong", file=sys.stderr)
        return 1
    print("stanza env self-test: the reader parses every stanza shape and refuses the rest")
    return 0


def check_all() -> int:
    """Every stanza file, so a new one this cannot read fails at PR time.

    The alternative is finding out during a dispatch, where the symptom is a
    suite that ran under an environment nobody chose.
    """
    names = sorted(
        name[: -len(".inc")]
        for name in os.listdir(STANZA_DIR)
        if name.endswith(".inc")
    )
    broken = 0
    with_env = 0
    for suite in names:
        try:
            text, own_file = stanza_text(suite)
            env, _ = suite_env(suite, text, own_file=own_file)
        except StanzaError as exc:
            print(f"{suite}: {exc}", file=sys.stderr)
            broken += 1
            continue
        if env:
            with_env += 1
    if broken:
        print(f"stanza env: {broken} stanza(s) this cannot read", file=sys.stderr)
        return 1
    print(
        f"stanza env: read all {len(names)} stanzas; {with_env} declare an environment"
    )
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) == 2 and argv[1] == "--check-all":
        return check_all()
    want_deps = len(argv) == 3 and argv[1] == "--deps"
    if not (len(argv) == 2 or want_deps):
        print(__doc__, file=sys.stderr)
        return 2
    suite = argv[2] if want_deps else argv[1]
    try:
        text, own_file = stanza_text(suite)
        env, deps = suite_env(suite, text, own_file=own_file)
    except StanzaError as exc:
        print(f"{suite}: {exc}", file=sys.stderr)
        return 1
    if want_deps:
        lines = [os.path.normpath(os.path.join("test", dep)) for dep in deps]
    else:
        lines = [f"{k}={v}" for k, v in env]
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
