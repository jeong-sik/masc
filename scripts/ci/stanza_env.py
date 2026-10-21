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
    stanza_env.py --action-alias <suite>   custom named-test action alias, if any

The action-alias query does not evaluate an action's variables or arguments.
Dune 3.20+ generates runtest-NAME for named tests; the repository requires 3.22.
Running that alias preserves custom arguments, wrappers and dependency expansion.

Build targets include literal files in the stanza's (deps ...), the files a
(glob_files ...)/(glob_files_rec ...) dep matches, and %{dep:...} environment
values. This is not a Dune dependency-expression evaluator: alias deps and
deps under any variable other than %{project_root}/ and %{workspace_root}/
remain owned by Dune's runtest action. A (source_tree DIR) dep is expanded
here into the files under DIR: `dune build DIR` accepts the directory and
exits 0, but it copies nothing, so only the file targets bring the tree into
_build for a targeted run.

A glob dep is expanded here for the same reason. Dune materialises a stanza's
deps inside its runtest action; a targeted run builds the executable instead,
so a suite whose only fixture dep was a glob stood in _build/default/<dir>
with the fixture directory absent and died on the first read
("No such file or directory") -- a FAIL the nightly lane never sees.

The two forms spell the same file differently on purpose. A stanza writes a
path relative to test/, which is where the runner stands
(_build/default/test), so the environment keeps it as written; `dune build`
takes its targets from the repo root, so --deps normalises them there.
"""

from __future__ import annotations

import glob
import os
import re
import sys

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


# Dune variables that name the checkout root. This repository has one
# dune-project and its dune-workspace at the root, so the project root and the
# workspace root are both REPO_ROOT, and rewriting either prefix is not a guess.
ROOT_VARS = ("%{project_root}/", "%{workspace_root}/")


def literal_target(path: str, suite_dir: str) -> str | None:
    """PATH as the stanza directory sees it, or None when only dune can name it.

    A root variable becomes the way back from SUITE_DIR to the checkout root,
    because main() prefixes every dep with SUITE_DIR. Any other variable stays
    with Dune's runtest action: guessing it would hand `dune build` a literal
    '%{...}', which fails the whole targeted build rather than the one suite.
    """
    if not VAR_RE.search(path):
        return path
    for var in ROOT_VARS:
        rest = path[len(var):]
        if path.startswith(var) and not VAR_RE.search(rest):
            return os.path.join(
                os.path.relpath(REPO_ROOT, os.path.join(REPO_ROOT, suite_dir)), rest
            )
    return None


def glob_files_targets(patterns: list, suite_dir: str, recursive: bool) -> list[str]:
    """The files a (glob_files ...)/(glob_files_rec ...) dep names.

    Dune expands the pattern inside its runtest action, whose sandbox holds
    the matches; a targeted run builds the executable instead, so the files
    are never copied into _build and the suite reads a directory that is not
    there. Expanding the same pattern against the checkout produces the file
    targets that copy them.

    Paths come back relative to SUITE_DIR, the spelling main() expects, and a
    pattern only Dune can resolve contributes nothing rather than a guess.
    """
    root = os.path.join(REPO_ROOT, suite_dir)
    found: list[str] = []
    for pattern in patterns:
        if not isinstance(pattern, str):
            continue
        target = literal_target(pattern, suite_dir)
        if target is None:
            continue
        for match in sorted(
            glob.glob(os.path.join(root, target), recursive=recursive)
        ):
            if os.path.isfile(match):
                found.append(os.path.relpath(match, root))
    return found


def collect_literal_deps(form, suite_dir: str) -> list[str]:
    """Literal file targets required by a directly executed test action.

    Building the test executable does not build these action dependencies.
    In particular, a suite can spawn a sibling executable declared here.
    """
    if not isinstance(form, list) or not form:
        return []
    if form[0] == "deps":
        collected = []
        for item in form[1:]:
            if isinstance(item, str):
                paths = [item]
            elif item and item[0] == "source_tree":
                # A list dep is a dependency expression: (source_tree DIR),
                # (glob_files ...), (alias ...). `dune build DIR` is not a way
                # to copy the tree: it exits 0 and leaves _build/default/DIR
                # absent, because dune materialises a source tree only inside
                # the runtest action that reads it. A suite that opens a file
                # under DIR therefore fails only in the targeted lane. Name
                # the files instead -- a file target is copied. (alias ...)
                # names nothing a build target can be, so it stays with
                # Dune's runtest action.
                paths = []
                for dir_path in item[1:]:
                    if not isinstance(dir_path, str):
                        continue
                    paths.extend(
                        glob_files_targets(
                            [os.path.join(dir_path, "**", "*")],
                            suite_dir,
                            recursive=True,
                        )
                    )
            elif item and item[0] in ("glob_files", "glob_files_rec"):
                paths = glob_files_targets(
                    item[1:], suite_dir, recursive=item[0] == "glob_files_rec"
                )
            else:
                continue
            for path in paths:
                target = literal_target(path, suite_dir)
                if target is not None:
                    collected.append(target)
        return collected
    return [dep for item in form for dep in collect_literal_deps(item, suite_dir)]


def resolve(key: str, value: str, *, allow_dependency_values: bool = True) -> tuple[str, str | None]:
    """(value for env, dune target to build first).

    A value naming a dune variable other than %{dep:...} cannot be resolved
    here, and guessing would run the suite with a literal '%{...}' in its
    environment.
    """
    match = DEP_RE.match(value)
    if match:
        if not allow_dependency_values:
            raise StanzaError(
                f"{key} needs a Dune action dependency: {value!r}; "
                "this runner has no Dune action directory"
            )
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

    Named tests are selected by stanza, even in a per-suite include: that file
    may also declare unrelated test or alias actions. Rule-only per-suite files
    retain their existing action handling.
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
    suite: str, text: str, own_file: bool = True, *, suite_dir: str,
    allow_dependency_values: bool = True,
) -> tuple[list[tuple[str, str]], list[str]]:
    forms = parse(tokenize(text))
    named = [
        form for form in forms
        if isinstance(form, list) and form
        and form[0] in ("test", "tests") and stanza_names(form)
    ]
    if not named and own_file:
        pairs = collect_setenv(forms)
        deps = collect_literal_deps(forms, suite_dir)
    else:
        pairs = []
        deps = []
        matched = False
        # Top-level alias rules and sibling tests have independent actions.
        # Neither their environment nor their deps belongs to this test's run.
        for form in named:
            if suite not in stanza_names(form):
                continue
            matched = True
            pairs.extend(collect_setenv(form))
            deps.extend(collect_literal_deps(form, suite_dir))
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
        resolved, dep = resolve(key, value, allow_dependency_values=allow_dependency_values)
        env.append((key, resolved))
        if dep is not None and dep not in deps:
            deps.append(dep)
    return env, deps


def main(argv: list[str]) -> int:
    # --dir names the directory the suite's stanza lives in; without it the
    # reader looks in test/, which is right for all but the 43 suites that
    # live elsewhere.
    args = argv[1:]
    suite_dir = DEFAULT_SUITE_DIR
    if len(args) >= 2 and args[0] == "--dir":
        suite_dir = args[1]
        args = args[2:]
    want_deps = len(args) == 2 and args[0] == "--deps"
    want_action_alias = len(args) == 2 and args[0] == "--action-alias"
    if not (len(args) == 1 or want_deps or want_action_alias):
        print(__doc__, file=sys.stderr)
        return 2
    suite = args[1] if want_deps or want_action_alias else args[0]
    try:
        text, own_file = stanza_text(suite, suite_dir)
        if want_action_alias:
            for form in parse(tokenize(text)):
                if not (isinstance(form, list) and form
                        and form[0] in ("test", "tests")
                        and suite in stanza_names(form)):
                    continue
                if any(isinstance(field, list) and field and field[0] == "action"
                       for field in form[1:]):
                    print(f"@@{suite_dir}/runtest-{suite}")
                    return 0
            return 0
        env, deps = suite_env(suite, text, own_file=own_file, suite_dir=suite_dir)
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
