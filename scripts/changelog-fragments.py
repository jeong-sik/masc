#!/usr/bin/env python3
# pyright: strict
"""Per-PR changelog fragments: check them, fold them into CHANGELOG.md.

Every pull request used to insert its line at the same spot under
`## [Unreleased]`, so each merge made every other open pull request conflict
and re-run CI. A pull request now writes `changelog.d/<PR number>.md` instead,
and the release folds the fragments into `## [Unreleased]`.

A fragment is one or more `### <Section>` headings, each followed by bullets.
A bullet starts with `- ` and may continue on following non-blank lines. Every
bullet cites the fragment's own pull request as `#<number>`.

Modes:
  check [--dir D]                      refuse a malformed fragment
  assemble [--dir D] [--changelog C]   fold fragments into [Unreleased], delete them
  missing --base B [--head H] [--dir D]
                                       list PRs merged since B whose changes
                                       carry no fragment — reported once, at
                                       the fold, so the release author can
                                       write the entries; never a refusal
  pr-guard --base B [--head H]         refuse a PR that adds a bullet under
                                       [Unreleased] in CHANGELOG.md instead of
                                       writing a fragment (a release PR, which
                                       bumps the version or assembles
                                       fragments, may)
  lane-guard --base B [--head H]       refuse a PR that stops accepting an
                                       exact-output lane id in runtime.toml
                                       unless its fragment has an `Upgrade
                                       notes` bullet naming that id
  check-files [FRAGMENT ...]           refuse a listed fragment that misses
                                       its citation. The CI workflow lists the
                                       fragments a pull request changes, so a
                                       stacked pull request is not refused for
                                       a lower fragment it does not carry
"""

import argparse
import pathlib
import re
import subprocess
import sys

FRAGMENT_DIR = "changelog.d"
CHANGELOG = "CHANGELOG.md"
UNRELEASED = "## [Unreleased]"

# The headings CHANGELOG.md releases already use, in the order a release
# section lists them.
SECTIONS = (
    "Upgrade notes",
    "Fresh state required",
    "Known issues",
    "Added",
    "Changed",
    "Deprecated",
    "Removed",
    "Fixed",
    "Performance",
    "Documentation",
    "Internal",
)

UPGRADE_NOTES = "Upgrade notes"

# The closed list of lane ids a runtime.toml `[runtime.exact_output_lanes.<id>]`
# table may name, and the file that spells each id.
STANDALONE_LANE = "lib/runtime/standalone_lane.ml"
LANE_IDENTITY = "lib/runtime/lane_run_identity.ml"
LANE_TYPE = re.compile(r"(?ms)^type t =\n((?:  \| [A-Z][A-Za-z_]*\n)+)\[@@deriving enumerate\]")
LANE_CONSTRUCTOR = re.compile(r"  \| ([A-Z][A-Za-z_]*)\n")

FRAGMENT_NAME = re.compile(r"^([1-9][0-9]*)\.md$")
VERSION_LINE = re.compile(r"(?m)^\(version ([^)]+)\)$")


# {section heading: [bullet text]}; a bullet keeps its continuation lines.
Sections = dict[str, list[str]]


class FragmentError(Exception):
    pass


def parse_fragment(path: pathlib.Path) -> Sections:
    """Return {section: [bullet text]} or raise FragmentError."""
    match = FRAGMENT_NAME.match(path.name)
    if match is None:
        raise FragmentError(
            f"{path}: a fragment is named <PR number>.md, e.g. changelog.d/38130.md"
        )
    number = match.group(1)
    cite = re.compile(rf"#{number}(?![0-9])")
    sections: Sections = {}
    section: str | None = None
    bullet: list[str] | None = None

    def close_bullet() -> None:
        if bullet is None or section is None:
            return
        text = "\n".join(bullet).rstrip()
        if not cite.search(text):
            raise FragmentError(f"{path}: bullet does not cite #{number}: {bullet[0]}")
        sections[section].append(text)

    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.rstrip()
        if re.match(r"^#+ ", line):
            close_bullet()
            bullet = None
            heading = re.match(r"^### (.+)$", line)
            if heading is None or heading.group(1) not in SECTIONS:
                raise FragmentError(
                    f"{path}:{lineno}: expected '### <Section>' with Section one of "
                    f"{', '.join(SECTIONS)}; got {line!r}"
                )
            name: str = heading.group(1)
            if name in sections:
                raise FragmentError(f"{path}:{lineno}: section {name!r} appears twice")
            sections[name] = []
            section = name
        elif line.startswith("- "):
            if section is None:
                raise FragmentError(f"{path}:{lineno}: bullet before any '### <Section>'")
            close_bullet()
            bullet = [line]
        elif line == "":
            close_bullet()
            bullet = None
        else:
            if bullet is None:
                raise FragmentError(f"{path}:{lineno}: text outside a bullet: {line!r}")
            bullet.append(line)
    close_bullet()

    if not any(sections.values()):
        raise FragmentError(f"{path}: no bullets")
    empty = [name for name, bullets in sections.items() if not bullets]
    if empty:
        raise FragmentError(f"{path}: section without bullets: {', '.join(empty)}")
    return sections


def fragment_paths(directory: pathlib.Path) -> list[pathlib.Path]:
    if not directory.is_dir():
        return []
    def order(path: pathlib.Path) -> tuple[int, str]:
        # A misnamed file sorts first; parse_fragment refuses it.
        match = FRAGMENT_NAME.match(path.name)
        return (int(match.group(1)) if match is not None else -1, path.name)

    return sorted(
        (p for p in directory.iterdir() if p.is_file() and p.name != "README.md"),
        key=order,
    )


def load_all(directory: pathlib.Path) -> list[tuple[pathlib.Path, Sections]]:
    """[(path, sections)] in PR-number order, or raise listing every error."""
    loaded: list[tuple[pathlib.Path, Sections]] = []
    errors: list[str] = []
    for path in fragment_paths(directory):
        try:
            loaded.append((path, parse_fragment(path)))
        except FragmentError as err:
            errors.append(str(err))
    if errors:
        raise FragmentError("\n".join(errors))
    return loaded


def split_unreleased(lines: list[str]) -> tuple[list[str], list[str], list[str]]:
    """Return (before, unreleased body, after) around the [Unreleased] section.

    The live section is the first `## [` heading of the file. An older
    `## [Unreleased]` further down is history (one sits under 0.2.x) and is
    left alone."""
    releases = [i for i, line in enumerate(lines) if line.startswith("## [")]
    if not releases or lines[releases[0]].rstrip() != UNRELEASED:
        raise FragmentError(f"{CHANGELOG}: the first release heading must be '{UNRELEASED}'")
    start = releases[0]
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## [")),
               len(lines))
    return lines[: start + 1], lines[start + 1 : end], lines[end:]


def parse_body(body: list[str]) -> tuple[list[str], list[tuple[str, list[str]]]]:
    """Split an [Unreleased] body into (preamble, [(heading, [bullet text])]).

    A bullet keeps its continuation lines; blank lines separate nothing but
    bullets and are rewritten on output."""
    preamble: list[str] = []
    sections: list[tuple[str, list[list[str]]]] = []
    current: tuple[str, list[list[str]]] | None = None
    for line in body:
        heading = re.match(r"^### (.+)$", line.rstrip())
        if heading:
            current = (heading.group(1), [])
            sections.append(current)
        elif current is None:
            preamble.append(line)
        elif line.startswith("- "):
            current[1].append([line.rstrip()])
        elif line.strip() == "":
            continue
        elif current[1]:
            current[1][-1].append(line.rstrip())
        else:
            # Prose under a heading before its first bullet stays as a bullet
            # of its own so nothing is dropped.
            current[1].append([line.rstrip()])
    return preamble, [(name, ["\n".join(b) for b in bullets]) for name, bullets in sections]


def normalize(text: str) -> str:
    return " ".join(text.split())


def assemble(directory: pathlib.Path, changelog: pathlib.Path) -> int:
    fragments = load_all(directory)
    if not fragments:
        print(f"no fragments in {directory}; {changelog} unchanged")
        return 0
    lines = changelog.read_text(encoding="utf-8").splitlines()
    before, body, after = split_unreleased(lines)
    preamble, existing = parse_body(body)

    merged: Sections = {}
    order: list[str] = []
    seen: dict[str, set[str]] = {}
    # A heading repeated in [Unreleased] merges into its first occurrence.
    sources: list[Sections] = [{name: bullets} for name, bullets in existing]
    sources += [sections for _, sections in fragments]
    for sections in sources:
        for name, bullets in sections.items():
            if name not in merged:
                merged[name], seen[name] = [], set()
                order.append(name)
            for bullet in bullets:
                key = normalize(bullet)
                if key not in seen[name]:
                    seen[name].add(key)
                    merged[name].append(bullet)

    # Headings follow the vocabulary order; a heading outside it keeps its
    # place after them.
    rank = {name: i for i, name in enumerate(SECTIONS)}
    known = sorted((n for n in order if n in rank), key=rank.__getitem__)
    extra = [n for n in order if n not in rank]
    out_body = [line for line in preamble if line.strip()]
    for name in known + extra:
        if not merged[name]:
            continue
        out_body += ["", f"### {name}", ""]
        out_body += [line for bullet in merged[name] for line in bullet.split("\n")]
    text = "\n".join(before + out_body + ([""] if after else []) + after) + "\n"
    changelog.write_text(text, encoding="utf-8")
    for path, _ in fragments:
        path.unlink()
    print(f"folded {len(fragments)} fragment(s) into {UNRELEASED} of {changelog}")
    return 0


def git_show(rev: str, path: str) -> str:
    result = subprocess.run(["git", "show", f"{rev}:{path}"], text=True,
                            capture_output=True)
    if result.returncode != 0:
        raise FragmentError(f"cannot read {path} at {rev}: {result.stderr.strip()}")
    return result.stdout


def package_version(rev: str) -> str:
    match = VERSION_LINE.search(git_show(rev, "dune-project"))
    if match is None:
        raise FragmentError(f"dune-project at {rev} has no (version ...) line")
    return match.group(1)


def unreleased_bullets(text: str) -> int:
    _, body, _ = split_unreleased(text.splitlines())
    return sum(1 for line in body if line.startswith("- "))


def pr_guard(base: str, head: str) -> int:
    # Compare against the point the branch left main. Main moves after it:
    # fragments merged there would read as ones this branch deleted, and a
    # bullet main dropped would read as one this branch added.
    merge_base = subprocess.run(["git", "merge-base", base, head], text=True,
                                capture_output=True)
    if merge_base.returncode != 0:
        raise FragmentError(f"no merge base for {base} and {head}: {merge_base.stderr.strip()}")
    base = merge_base.stdout.strip()
    if package_version(base) != package_version(head):
        return 0
    removed = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=D", base, head, "--", FRAGMENT_DIR],
        text=True, capture_output=True, check=True).stdout.split()
    if removed:
        return 0
    # Net count: a reworded bullet keeps the count, so this cannot tell a
    # bullet added alongside one removed from a rewording.
    base_count = unreleased_bullets(git_show(base, CHANGELOG))
    head_count = unreleased_bullets(git_show(head, CHANGELOG))
    if head_count <= base_count:
        return 0
    print(
        f"{CHANGELOG} {UNRELEASED} gained {head_count - base_count} bullet(s). "
        f"Write the entry to {FRAGMENT_DIR}/<PR number>.md instead; "
        f"scripts/changelog-fragments.py assemble folds fragments at release.",
        file=sys.stderr,
    )
    return 1


def accepted_lane_ids(rev: str) -> set[str]:
    """Lane ids a runtime.toml exact-output table may name at `rev`.

    Reads the constructors of `Standalone_lane.t` and the id each one has in
    `to_id`, which sat in standalone_lane.ml before it moved to
    lane_run_identity.ml. A shape this cannot read is an error, not an empty
    set: a guard that skips what it cannot parse never fires.
    """
    lane_source = git_show(rev, STANDALONE_LANE)
    block = LANE_TYPE.search(lane_source)
    if block is None:
        raise FragmentError(f"{STANDALONE_LANE} at {rev}: no `type t = | ... [@@deriving enumerate]`")
    constructors = LANE_CONSTRUCTOR.findall(block.group(1))
    exists = subprocess.run(["git", "cat-file", "-e", f"{rev}:{LANE_IDENTITY}"],
                            capture_output=True).returncode == 0
    spelling = lane_source + ("\n" + git_show(rev, LANE_IDENTITY) if exists else "")
    ids: set[str] = set()
    for constructor in constructors:
        found = re.search(rf'\| {constructor} -> "([a-z_]+)"', spelling)
        if found is None:
            raise FragmentError(
                f"{STANDALONE_LANE} at {rev}: no `| {constructor} -> \"<id>\"` in "
                f"{STANDALONE_LANE} or {LANE_IDENTITY}"
            )
        ids.add(found.group(1))
    return ids


def lane_guard(base: str, head: str) -> int:
    """Refuse a PR that stops accepting a lane id without telling the operator.

    A live runtime.toml is operator-owned and never rewritten by a release. A
    table under an id the new build no longer accepts makes the build refuse
    the whole file, and the operator learns it at deploy time with nothing said
    about what replaced it (#44911 removed `workspace_curator_exact` that way).
    Other retired runtime.toml keys are not covered here.

    `base` is the commit the PR is measured against, not a merge base: for a
    stacked PR it is the parent layer's head.
    """
    dropped = sorted(accepted_lane_ids(base) - accepted_lane_ids(head))
    if not dropped:
        return 0
    changed = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=AM", base, head, "--", FRAGMENT_DIR],
        text=True, capture_output=True, check=True).stdout.split()
    notes: list[str] = []
    for name in changed:
        path = pathlib.Path(name)
        if path.name == "README.md":
            continue
        notes += parse_fragment(path).get(UPGRADE_NOTES, [])
    unannounced = [lane for lane in dropped if not any(lane in note for note in notes)]
    if not unannounced:
        print(f"lane id(s) no longer accepted, each named in an {UPGRADE_NOTES} bullet: "
              f"{', '.join(dropped)}")
        return 0
    for lane in unannounced:
        print(
            f"{STANDALONE_LANE}: `{lane}` is no longer an accepted exact-output lane id, "
            f"so a live runtime.toml with `[runtime.exact_output_lanes.{lane}]` is refused "
            f"at deploy. Add a `### {UPGRADE_NOTES}` bullet to this PR's "
            f"{FRAGMENT_DIR}/<PR number>.md that names `{lane}`, says to delete that table, "
            f"and says where the setting lives now.",
            file=sys.stderr,
        )
    return 1


def merged_squashes(base: str, head: str) -> list[tuple[int, str]]:
    """[(PR number, subject)] of squash commits merged into `head` since `base`.

    Squash subjects end in (#<number>). This repo has no merge commits, so the
    number is the only PR identity in the history.
    """
    log = subprocess.run(
        ["git", "log", "--format=%H %s", f"{base}..{head}"], text=True,
        capture_output=True, check=True).stdout
    merged: list[tuple[int, str]] = []
    for line in log.splitlines():
        match = re.search(r"\(#([1-9][0-9]*)\)$", line)
        if match is not None:
            merged.append((int(match.group(1)), line.split(" ", 1)[1]))
    return merged


def missing(base: str, head: str, directory: pathlib.Path) -> int:
    """Report PRs merged since `base` whose history carries no fragment.

    A PR not yet folded still carries its own changelog.d/<N>.md on main, so a
    missing number means either a squash that merged without a fragment or a
    fragment already folded away by an earlier release. Scanning from the
    last tag limits the second case to entries written before that tag's
    CHANGELOG section existed, which #39079 and #39095 were still backfilling.
    A file whose name is not <PR number>.md proves nothing about any PR, so it
    is ignored here; `check` is the mode that refuses it, and bump-version.sh
    runs check before this.
    """
    have: set[int] = set()
    for path in fragment_paths(directory):
        match = FRAGMENT_NAME.match(path.name)
        if match is not None:
            have.add(int(match.group(1)))
    unfragmented: list[tuple[int, str]] = []
    for number, subject in merged_squashes(base, head):
        if number not in have:
            unfragmented.append((number, subject))
    if not unfragmented:
        print(f"every pull request merged since {base} has a changelog fragment")
        return 0
    unfragmented.sort()
    print(
        f"{len(unfragmented)} pull request(s) merged since {base} without a "
        f"changelog fragment:"
    )
    for number, subject in unfragmented:
        print(f"  #{number} {subject}")
    print(
        "Write the entries to "
        f"{FRAGMENT_DIR}/<PR number>.md before folding, or note here why a "
        "release omits one."
    )
    return 0


def check_files(names: list[str]) -> int:
    """Refuse a listed fragment that misses its own citation.

    A pull request carries only the fragments it adds or edits — stacked
    pull requests keep the lower fragments on their base branch — so the
    caller (the CI workflow) lists this change's fragments instead of
    checking the whole tree. `check` without a list remains what a release
    fold runs over every fragment.
    """
    errors: list[str] = []
    checked = 0
    for name in names:
        rel = pathlib.PurePosixPath(name)
        if len(rel.parts) != 2 or rel.parts[0] != FRAGMENT_DIR:
            errors.append(f"{name}: not a {FRAGMENT_DIR}/<PR number>.md path")
            continue
        if rel.name == "README.md":
            continue
        if not pathlib.Path(name).is_file():
            errors.append(f"{name}: not in the tree (deleted or renamed away?)")
            continue
        try:
            parse_fragment(pathlib.Path(name))
        except FragmentError as err:
            errors.append(str(err))
            continue
        checked += 1
    if errors:
        raise FragmentError("\n".join(errors))
    if checked == 0:
        print("no fragment to check")
    else:
        print(f"{checked} changed fragment(s) OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Per-PR changelog fragments.")
    sub = parser.add_subparsers(dest="mode", required=True)
    check = sub.add_parser("check")
    check.add_argument("--dir", default=FRAGMENT_DIR)
    fold = sub.add_parser("assemble")
    fold.add_argument("--dir", default=FRAGMENT_DIR)
    fold.add_argument("--changelog", default=CHANGELOG)
    miss = sub.add_parser("missing")
    miss.add_argument("--base", required=True)
    miss.add_argument("--head", default="HEAD")
    miss.add_argument("--dir", default=FRAGMENT_DIR)
    guard = sub.add_parser("pr-guard")
    guard.add_argument("--base", required=True)
    guard.add_argument("--head", default="HEAD")
    lanes = sub.add_parser("lane-guard")
    lanes.add_argument("--base", required=True)
    lanes.add_argument("--head", default="HEAD")
    listed = sub.add_parser("check-files")
    listed.add_argument("files", nargs="*", metavar="FRAGMENT")
    args = parser.parse_args()
    try:
        if args.mode == "check":
            loaded = load_all(pathlib.Path(args.dir))
            print(f"{len(loaded)} changelog fragment(s) OK")
            return 0
        if args.mode == "lane-guard":
            return lane_guard(args.base, args.head)
        if args.mode == "check-files":
            return check_files(args.files)
        if args.mode == "assemble":
            return assemble(pathlib.Path(args.dir), pathlib.Path(args.changelog))
        if args.mode == "missing":
            return missing(base=args.base, head=args.head,
                           directory=pathlib.Path(args.dir))
        return pr_guard(args.base, args.head)
    except FragmentError as err:
        print(err, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
