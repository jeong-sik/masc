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

Build targets include literal files in the stanza's (deps ...) as well as
%{dep:...} environment values. This is not a Dune dependency-expression
evaluator: source_tree, glob, alias and variable-bearing deps remain owned by
Dune's runtest action.

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
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# The directory a suite's stanza lives in. test/ is the default because that is
# where all but a handful are, but 43 suites are not there -- every one under
# packages/agent_core/test, plus tools/ -- and reading test/dune for those
# finds a different suite's stanza or none at all. The targeted runner passes
# --dir once it has resolved the name.
DEFAULT_SUITE_DIR = "test"

# %{dep:PATH} is the only dune variable a value may use. Paths in a stanza are
# written relative to the stanza's own directory, which is where the targeted
# runner stands (_build/default/<dir>), so the path passes through unchanged.
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


def collect_literal_deps(form) -> list[str]:
    """Literal file targets required by a directly executed test action.

    Building the test executable does not build these action dependencies.
    In particular, a suite can spawn a sibling executable declared here.
    """
    if not isinstance(form, list) or not form:
        return []
    if form[0] == "deps":
        return [
            item for item in form[1:]
            if isinstance(item, str) and not VAR_RE.search(item)
        ]
    return [dep for item in form for dep in collect_literal_deps(item)]


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


def directory_env_vars(suite_dir: str = DEFAULT_SUITE_DIR) -> list[tuple[str, str]]:
    """The directory-wide `(env (_ (env-vars ...)))` block.

    Dune applies it to every action under that directory; running a suite's
    executable directly does not. test/dune declares five: an empty
    MASC_BASE_PATH and two empty API keys, so a suite cannot reach the
    operator's workspace or the network, and the two sandbox flags that keep a
    suite off Docker. Without them the targeted runner judged
    test_heartbeat_integration against the runner's own Docker and reported
    `docker_preflight_failed: masc-sandbox:general is not available locally`
    as a suite failure, which is the wrong-environment verdict this reader
    exists to stop.
    """
    path = os.path.join(REPO_ROOT, suite_dir, "dune")
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        forms = parse(tokenize(handle.read()))
    return directory_env_pairs(forms, suite_dir)


def directory_env_pairs(forms: list, suite_dir: str) -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []
    for form in forms:
        if not (isinstance(form, list) and form and form[0] == "env"):
            continue
        for selector in form[1:]:
            if not (isinstance(selector, list) and selector):
                continue
            if selector[0] != "_":
                # A profile-scoped block would apply to some runs and not
                # others, and this runner has no profile to match on. Guessing
                # either way hands a suite an environment nobody chose.
                raise StanzaError(
                    f"{suite_dir}/dune scopes an env block to profile "
                    f"{selector[0]!r}; extend this reader rather than running a "
                    "suite under a partial environment"
                )
            for entry in selector[1:]:
                if not (isinstance(entry, list) and entry and entry[0] == "env-vars"):
                    continue
                for var in entry[1:]:
                    if not (isinstance(var, list) and len(var) == 2):
                        raise StanzaError(
                            f"{suite_dir}/dune has an env-vars entry this cannot "
                            f"read: {var!r}"
                        )
                    pairs.append((var[0], var[1]))
    return pairs


def stanza_dir(suite_dir: str) -> str:
    return os.path.join(REPO_ROOT, suite_dir, "stanzas")


def included_stanza_sources(path: str, ancestors: tuple[str, ...] = ()):
    """Read literal includes without changing the suite's Dune directory.

    Include filenames are relative to their containing file. Dependencies and
    actions inside those files still belong to the original dune directory.
    Keep each source separate so an unrelated included rule cannot donate its
    environment to the requested suite.
    """
    path = os.path.realpath(path)
    if path in ancestors:
        raise StanzaError("include cycle: " + " -> ".join((*ancestors, path)))
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        raise StanzaError(f"cannot read included stanza {path}: {exc}") from exc
    forms = parse(tokenize(text))
    yield text, forms
    for form in forms:
        if not isinstance(form, list) or not form or form[0] != "include":
            continue
        if len(form) != 2 or not isinstance(form[1], str) or VAR_RE.search(form[1]):
            raise StanzaError(f"unsupported include in {path}: {form}")
        yield from included_stanza_sources(
            os.path.join(os.path.dirname(path), form[1]), (*ancestors, path)
        )


def named_suites(forms: list) -> list[str]:
    return [
        name
        for form in forms
        if isinstance(form, list) and form and form[0] in ("test", "tests")
        for name in stanza_names(form)
    ]


def stanza_text(suite: str, suite_dir: str = DEFAULT_SUITE_DIR) -> tuple[str, bool]:
    """Find the named suite in its dune file or a literal shared include.

    Per-suite files retain their rule-action handling. Shared files must select
    the named stanza, since sibling tests may have different environments.
    """
    path = os.path.join(stanza_dir(suite_dir), f"{suite}.inc")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            return handle.read(), True
    root = os.path.join(REPO_ROOT, suite_dir, "dune")
    root_text = None
    for text, forms in included_stanza_sources(root):
        if root_text is None:
            root_text = text
        if suite in named_suites(forms):
            return text, False
    # Preserve the unknown-suite error from suite_env instead of silently
    # answering with an empty environment.
    return root_text or "", False


def suite_env(
    suite: str, text: str, own_file: bool = True
) -> tuple[list[tuple[str, str]], list[str]]:
    forms = parse(tokenize(text))
    if own_file:
        pairs = collect_setenv(forms)
        deps = collect_literal_deps(forms)
    else:
        pairs = []
        deps = []
        unattributable = False
        matched = False
        for form in forms:
            named = (
                isinstance(form, list)
                and form
                and form[0] in ("test", "tests")
                and stanza_names(form)
            )
            if not named:
                # A setenv that belongs to no named stanza belongs to no
                # suite this can name -- a (rule (alias runtest) ...) carries
                # no (name ...) to match on. Running any suite from this file
                # would then risk a partial environment, which is the failure
                # this whole script exists to stop.
                if collect_setenv(form):
                    unattributable = True
                continue
            if suite not in stanza_names(form):
                continue
            matched = True
            pairs.extend(collect_setenv(form))
            deps.extend(collect_literal_deps(form))
        if unattributable:
            raise StanzaError(
                "declared inline in this directory's dune next to a setenv "
                "this could not attribute; give the suite its own stanzas "
                "file or extend this reader"
            )
        if not matched:
            # A name this file does not declare used to answer "no
            # environment", exit 0 -- the same answer as a suite that truly
            # declares none. So a misspelling, or a suite read against the
            # wrong directory, ran with a partial environment and reported a
            # verdict the nightly lane would not agree with, which is the
            # outcome the header says this reader exists to stop.
            raise StanzaError(
                "no (test)/(tests) stanza declares this suite here; check the "
                "name and the directory it lives in"
            )
    env: list[tuple[str, str]] = []
    deps = list(dict.fromkeys(deps))
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
  (setenv MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED false
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
            ("MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED", "false"),
            ("MASC_BASE_PATH", "/tmp/test-alpha"),
            ("MASC_BASE_PATH_INPUT", "/tmp/test-alpha"),
        ],
    )
    check("plain values need nothing built", deps, [])

    directory = """
(env
 (_
  (env-vars
   ; a comment between entries
   (MASC_BASE_PATH "")
   (MASC_KEEPER_DOCKER_PLAYGROUND false))))
(test (name test_alpha))
"""
    check(
        "the directory block is read, empty values included",
        directory_env_pairs(parse(tokenize(directory)), "test"),
        [("MASC_BASE_PATH", ""), ("MASC_KEEPER_DOCKER_PLAYGROUND", "false")],
    )
    profiled = "(env (dev (env-vars (MASC_BASE_PATH \"\"))))"
    try:
        directory_env_pairs(parse(tokenize(profiled)), "test")
        check("a profile-scoped env block is refused", "read", "refused")
    except StanzaError:
        check("a profile-scoped env block is refused", "refused", "refused")
    check(
        "test/dune's own block still carries the sandbox flags",
        [key for key, _ in directory_env_vars("test")],
        [
            "MASC_BASE_PATH",
            "ZAI_API_KEY",
            "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED",
            "MASC_KEEPER_DOCKER_PLAYGROUND",
        ],
    )

    sibling = "(test (name test_spawn) (deps sibling.exe ../config/runtime.toml))"
    env, deps = suite_env("test_spawn", sibling)
    check(
        "literal action dependencies need building without setenv", deps,
        ["sibling.exe", "../config/runtime.toml"],
    )
    check("action dependencies do not invent environment values", env, [])
    _, deps = suite_env(
        "test_spawn", sibling + "(test (name test_other) (deps other.exe))",
        own_file=False,
    )
    check(
        "neighboring suite dependencies do not leak", deps,
        ["sibling.exe", "../config/runtime.toml"],
    )
    _, deps = suite_env(
        "test_two", "(tests (names test_one test_two) (deps shared.exe))",
        own_file=False,
    )
    check("group members receive the group's action dependencies", deps, ["shared.exe"])
    _, deps = suite_env(
        "test_spawn", "(test (name test_spawn) (deps sibling.exe)"
        " (action (setenv RUNNER %{dep:sibling.exe} (run %{test}))))",
    )
    check("the same target declared twice is built once", deps, ["sibling.exe"])

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

    # This used to assert the empty environment, which pinned the silent
    # failure in place: a name the text does not declare answered exactly
    # like a suite that declares no environment, so a misspelling or a read
    # against the wrong directory ran the suite with a partial environment
    # and said nothing. Refusing is the only answer that separates the two.
    try:
        suite_env("test_absent", FIXTURE_PLAIN, own_file=False)
        check("a suite this text does not declare is refused", "answered", "refused")
    except StanzaError:
        check("a suite this text does not declare is refused", "refused", "refused")

    env, deps = suite_env("test_epsilon", FIXTURE_RULE)
    check(
        "a (rule (alias runtest)) stanza is read like any other",
        env,
        [("KEEPER_STORE_LAYOUT_MANIFEST_EXE", "../bin/manifest.exe")],
    )
    check(
        "its script and executable deps are targets", deps,
        ["test_epsilon.py", "../bin/manifest.exe"],
    )

    try:
        suite_env("test_zeta", "(tests (names test_zeta))\n(setenv OTHER x (run y))", own_file=False)
        failures += 1
        print("FAIL an unattributable inline setenv was accepted", file=sys.stderr)
    except StanzaError:
        print("pass an unattributable inline setenv is an error, not an empty result")

    # test/dune declares hundreds of suites and three of them set an
    # environment. A suite that sets none stands beside those three, and its
    # empty environment is the answer rather than a gap: every setenv in the
    # file is inside a named stanza, so nothing was left unassigned. Asking
    # only whether the file contained "(setenv" anywhere refused every one of
    # them, and test_tui_turn_rail could not be dispatched at all.
    neighbours = FIXTURE_PLAIN + "\n" + FIXTURE_GROUP
    env, _ = suite_env("test_one", neighbours, own_file=False)
    check("a suite with no setenv beside one that has some", env, [])

    # Shared includes are real test declarations, not one suite named after
    # the include file. Exercise the same lookup used by workflow_dispatch.
    with tempfile.TemporaryDirectory(prefix="stanza-env-") as fixture:
        os.makedirs(os.path.join(fixture, "stanzas", "nested"))

        def write(relative, text):
            with open(os.path.join(fixture, relative), "w", encoding="utf-8") as handle:
                handle.write(text)

        write("dune", "(include stanzas/shared.inc)\n")
        write("stanzas/shared.inc", "(include nested/group.inc)\n" + FIXTURE_PLAIN)
        write("stanzas/nested/group.inc",
              "(tests (names test_shared_one test_shared_two)"
              " (deps sibling.exe ../config/runtime.toml)"
              " (action (setenv SHARED_RUNNER %{dep:sibling.exe} (run %{test}))))"
              + FIXTURE_PLAIN)
        text, own_file = stanza_text("test_shared_two", fixture)
        check("shared include selects named group", own_file, False)
        env, deps = suite_env("test_shared_two", text, own_file=own_file)
        check("nested include preserves group environment", env,
              [("SHARED_RUNNER", "sibling.exe")])
        check("included deps keep the suite directory as their base", deps,
              ["sibling.exe", "../config/runtime.toml"])
        text, own_file = stanza_text("test_alpha", fixture)
        env, _ = suite_env("test_alpha", text, own_file=own_file)
        check("shared-file sibling environment does not leak", env,
              [("MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED", "false"),
               ("MASC_BASE_PATH", "/tmp/test-alpha"),
               ("MASC_BASE_PATH_INPUT", "/tmp/test-alpha")])
        write("stanzas/nested/group.inc", "(include ../shared.inc)")
        try:
            stanza_text("test_absent", fixture)
            check("include cycle fails explicitly", "accepted", "refused")
        except StanzaError as exc:
            check("include cycle names its cause", "include cycle:" in str(exc), True)
        write("stanzas/nested/group.inc", "(include missing.inc)")
        try:
            stanza_text("test_absent", fixture)
            check("missing included source fails explicitly", "accepted", "refused")
        except StanzaError as exc:
            check("missing include names its cause", "missing.inc" in str(exc), True)

    text, own_file = stanza_text("test_types_coverage")
    check("real shared coverage suite is discoverable",
          suite_env("test_types_coverage", text, own_file=own_file), ([], []))
    check("coverage members are included in check-all",
          "test_types_coverage" in inline_suite_names(), True)

    # The one suite test.yml used to hardcode still reads the same three.
    real = os.path.join(stanza_dir(DEFAULT_SUITE_DIR), "test_heartbeat_integration.inc")
    if os.path.exists(real):
        with open(real, encoding="utf-8") as handle:
            env, _ = suite_env("test_heartbeat_integration", handle.read())
        check(
            "the real stanza reads what test.yml hardcoded",
            env,
            [
                ("MASC_BASE_PATH", "/tmp/test-heartbeat-integ"),
                ("MASC_BASE_PATH_INPUT", "/tmp/test-heartbeat-integ"),
            ],
        )

    # A suite outside test/ reads its own directory's dune, not test/dune.
    # Before --dir the reader looked in test/ for every name, so a suite in
    # packages/agent_core/test either matched a different suite's stanza
    # there or none, and the runner could not call it at all.
    outside = os.path.join(REPO_ROOT, "packages", "agent_core", "test", "dune")
    if os.path.exists(outside):
        text, own_file = stanza_text("test_provider", "packages/agent_core/test")
        check("a suite outside test/ has no stanzas file", own_file, False)
        env, _deps = suite_env("test_provider", text, own_file=own_file)
        check("its own directory answers for it", env, [])
        # The discriminating half. Reading the same suite against test/ has
        # to refuse rather than answer "no environment" -- an earlier version
        # of this case asserted the env was empty either way, which the wrong
        # directory also satisfies, so it passed with --dir ignored.
        wrong_text, wrong_own = stanza_text("test_provider", DEFAULT_SUITE_DIR)
        try:
            suite_env("test_provider", wrong_text, own_file=wrong_own)
            check("test/ refuses a suite it does not declare", "answered", "refused")
        except StanzaError:
            check("test/ refuses a suite it does not declare", "refused", "refused")
    if failures:
        print(f"stanza env self-test: {failures} case(s) wrong", file=sys.stderr)
        return 1
    print("stanza env self-test: the reader parses every stanza shape and refuses the rest")
    return 0


def inline_suite_names() -> list[str]:
    """Suites declared by test/dune, including its shared include files."""
    names = [
        name
        for _text, forms in included_stanza_sources(os.path.join(REPO_ROOT, "test", "dune"))
        for name in named_suites(forms)
    ]
    return sorted(set(names))


def check_all() -> int:
    """Every suite a dispatch can name, so one this cannot read fails at PR
    time.

    The alternative is finding out during a dispatch, where the symptom is a
    suite that ran under an environment nobody chose -- or, as happened on
    2026-09-06, a suite that could not be dispatched at all. Reading only the
    stanza files left the 800-odd suites test/dune declares inline unchecked,
    which is where that one was.
    """
    names = sorted(
        name[: -len(".inc")]
        for name in os.listdir(stanza_dir(DEFAULT_SUITE_DIR))
        if name.endswith(".inc")
    )
    inline = [name for name in inline_suite_names() if name not in set(names)]
    broken = 0
    with_env = 0
    for suite in names + inline:
        try:
            text, own_file = stanza_text(suite)
            env, _ = suite_env(suite, text, own_file=own_file)
        except StanzaError as exc:
            print(f"{suite}: {exc}", file=sys.stderr)
            broken += 1
            continue
        if env:
            with_env += 1
    try:
        directory = directory_env_vars(DEFAULT_SUITE_DIR)
    except StanzaError as exc:
        print(f"{DEFAULT_SUITE_DIR}/dune: {exc}", file=sys.stderr)
        return 1
    if broken:
        print(f"stanza env: {broken} stanza(s) this cannot read", file=sys.stderr)
        return 1
    print(
        f"stanza env: read all {len(names)} stanza files and {len(inline)} suites "
        f"declared in test/dune and its includes; {with_env} declare an environment, "
        f"and the directory block adds {len(directory)} variable(s) to every one"
    )
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) == 2 and argv[1] == "--check-all":
        return check_all()
    # --dir names the directory the suite's stanza lives in; without it the
    # reader looks in test/, which is right for all but the 43 suites that
    # live elsewhere.
    args = argv[1:]
    suite_dir = DEFAULT_SUITE_DIR
    if len(args) >= 2 and args[0] == "--dir":
        suite_dir = args[1]
        args = args[2:]
    want_deps = len(args) == 2 and args[0] == "--deps"
    if not (len(args) == 1 or want_deps):
        print(__doc__, file=sys.stderr)
        return 2
    suite = args[1] if want_deps else args[0]
    try:
        text, own_file = stanza_text(suite, suite_dir)
        env, deps = suite_env(suite, text, own_file=own_file)
    except StanzaError as exc:
        print(f"{suite}: {exc}", file=sys.stderr)
        return 1
    if want_deps:
        # A dep is written relative to its stanza's directory, and dune build
        # takes targets from the repo root, so it is prefixed with that
        # directory rather than with test/.
        lines = [os.path.normpath(os.path.join(suite_dir, dep)) for dep in deps]
    else:
        # The suite's own (setenv ...) wins over the directory block, the way
        # dune's action-level environment wins over its (env ...) stanza.
        try:
            directory = directory_env_vars(suite_dir)
        except StanzaError as exc:
            print(f"{suite}: {exc}", file=sys.stderr)
            return 1
        overridden = {key for key, _ in env}
        lines = [f"{k}={v}" for k, v in directory if k not in overridden]
        lines += [f"{k}={v}" for k, v in env]
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
