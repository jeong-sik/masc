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

Pull requests that change nothing a user can see (documentation, tests,
comments, compile repairs, or changelog-only work) write `### Exempt` instead
of a release section, with a bullet stating the reason and citing `#<number>`.
Exempt fragments satisfy `missing --strict` without touching a shared file, and
`assemble` deletes them at release without adding anything to `CHANGELOG.md`.

Modes:
  check [--dir D]                      refuse a malformed fragment
  assemble [--dir D] [--changelog C] [--into V]
                                       fold fragments into [Unreleased], delete
                                       them; with --into V, fold them — and
                                       whatever [Unreleased] still holds —
                                       into the existing [V] section instead
  folded [--dir D] [--changelog C] [--delete] [--strict]
                                       list fragments whose pull request
                                       already owns an entry in CHANGELOG.md
                                       (a terminal "(#N)" citation), i.e.
                                       redundant history a release folded
                                       elsewhere left behind; --delete removes
                                       them, --strict exits 3 while any
                                       remain (exit 3, not 1: a crash is 1)
  missing --base B [--head H] [--dir D] [--strict]  (exit 3 on findings)
                                       list PRs merged since B whose changes
                                       carry no fragment — reported once, at
                                       the fold, so the release author can
                                       write the entries; with --strict the
                                       same report also refuses the fold
                                       (exit 3, exemptions aside). When HEAD
                                       has not moved past the release cut the
                                       range is empty and the report passes —
                                       that is a genuinely empty window.
  pr-guard --base B [--head H]         refuse a PR that adds a bullet under
                                       [Unreleased] in CHANGELOG.md instead of
                                       writing a fragment (a release PR, which
                                       bumps the version or assembles
                                       fragments, may)
  check-files [FRAGMENT ...]           refuse a listed fragment that misses
                                       its citation. The CI workflow lists the
                                       fragments a pull request changes, so a
                                       stacked pull request is not refused for
                                       a lower fragment it does not carry
  release-coverage --version V [--base B] [--head H] [--changelog C] [--dir D]
                                       (exit 1 on findings) verify at RC time
                                       that every non-exempt pull request merged
                                       after the version-cut commit B (default:
                                       earliest contiguous commit on H whose
                                       dune-project carries `(version V)`) is
                                       cited in CHANGELOG.md under `## [V]`.
                                       Unlike `missing --strict`, which runs
                                       pre-fold to ensure merged PRs have
                                       fragment files, `release-coverage` runs
                                       post-cut to catch late merges whose
                                       fragments were never folded into `## [V]`
                                       or that merged without a fragment.
"""

import argparse
import os
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

# Section for pull requests that change nothing a user can see (docs, tests,
# comments, compile repairs, or changelog-only work). Validated like any other
# fragment, satisfies `missing --strict`, and is deleted by `assemble` without
# being folded into CHANGELOG.md.
EXEMPT_SECTION = "Exempt"
VALID_SECTIONS = (*SECTIONS, EXEMPT_SECTION)

FRAGMENT_NAME = re.compile(r"^([1-9][0-9]*)\.md$")
VERSION_LINE = re.compile(r"(?m)^\(version ([^)]+)\)$")
# A release heading names its section and may carry a date:
# "## [Unreleased]" or "## [0.78.0] - 2026-11-21".
SECTION_HEADING = "## [{}]"
# The terminal citation of a CHANGELOG entry line: "(#N)" or "(#N, ...)",
# where N is the entry's owner, optionally closed by sentence punctuation
# (English entries end "(#N).", Korean ones "(#N)"). A number named inside
# another entry's text ("fixes #N") is a passing mention, not ownership.
OWNER_CITE = re.compile(r"\(#([1-9][0-9]*)(?:, [^)]*)?\)\s*[.!]?\s*$")
SECTION_PR_CITE = re.compile(r"(?<![A-Za-z0-9_])#([1-9][0-9]*)\b")


# {section heading: [bullet text]}; a bullet keeps its continuation lines.
Sections = dict[str, list[str]]


class FragmentError(Exception):
    pass


def _has_exemption_reason(text: str, cite: re.Pattern[str]) -> bool:
    """Return True when an exempt bullet states a reason beyond citing #<PR>."""
    return any(ch.isalnum() for ch in cite.sub("", text))


def is_exempt(sections: Sections) -> bool:
    """Return True when a parsed fragment declares an exemption."""
    return len(sections) == 1 and EXEMPT_SECTION in sections


def parse_fragment_text(path: pathlib.Path, content: str) -> Sections:
    """Return {section: [bullet text]} from fragment text or raise FragmentError."""
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
    first_lineno: int | None = None

    def close_bullet() -> None:
        if bullet is None or section is None:
            return
        text = "\n".join(bullet).rstrip()
        if not cite.search(text):
            where = f":{first_lineno}" if first_lineno is not None else ""
            raise FragmentError(
                f"{path}{where}: bullet does not cite #{number}: {bullet[0]}"
            )
        if section == EXEMPT_SECTION and not _has_exemption_reason(text, cite):
            where = f":{first_lineno}" if first_lineno is not None else ""
            raise FragmentError(
                f"{path}{where}: exempt bullet must state a reason alongside "
                f"#{number}: {bullet[0]}"
            )
        sections[section].append(text)

    for lineno, raw in enumerate(content.splitlines(), 1):
        line = raw.rstrip()
        if re.match(r"^#+ ", line):
            close_bullet()
            bullet = None
            first_lineno = None
            heading = re.match(r"^### (.+)$", line)
            if heading is None or heading.group(1) not in VALID_SECTIONS:
                raise FragmentError(
                    f"{path}:{lineno}: expected '### <Section>' with Section one of "
                    f"{', '.join(VALID_SECTIONS)}; got {line!r}"
                )
            name: str = heading.group(1)
            if name in sections:
                raise FragmentError(f"{path}:{lineno}: section {name!r} appears twice")
            if (name == EXEMPT_SECTION and sections) or EXEMPT_SECTION in sections:
                raise FragmentError(
                    f"{path}:{lineno}: section {EXEMPT_SECTION!r} cannot be combined "
                    f"with release sections"
                )
            sections[name] = []
            section = name
        elif line.startswith("- "):
            if section is None:
                raise FragmentError(f"{path}:{lineno}: bullet before any '### <Section>'")
            close_bullet()
            first_lineno = lineno
            bullet = [line]
        elif line == "":
            close_bullet()
            bullet = None
            first_lineno = None
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


def parse_fragment(path: pathlib.Path) -> Sections:
    """Return {section: [bullet text]} or raise FragmentError."""
    return parse_fragment_text(path, path.read_text(encoding="utf-8"))


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


def split_section(lines: list[str], heading: str) -> tuple[list[str], list[str], list[str]]:
    """Return (before, section body, after) around the first `## [<heading>]`.

    The heading may carry a date ("## [0.78.0] - 2026-11-21"). The section
    runs to the next `## [` heading. A section of the same name further down
    (an old `## [Unreleased]` sits under 0.2.x) is history and is left
    alone."""
    wanted = re.escape(SECTION_HEADING.format(heading))
    match = re.compile(rf"^{wanted}(?: - .*)?$")
    start = next((i for i, line in enumerate(lines) if match.match(line.strip())), None)
    if start is None:
        raise FragmentError(f"{CHANGELOG}: no section '{SECTION_HEADING.format(heading)}'")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## [")),
               len(lines))
    return lines[: start + 1], lines[start + 1 : end], lines[end:]


def split_unreleased(lines: list[str]) -> tuple[list[str], list[str], list[str]]:
    """Return (before, unreleased body, after) around the [Unreleased] section.

    The live section is the first `## [` heading of the file; any other
    heading there is a malformed changelog."""
    releases = [i for i, line in enumerate(lines) if line.startswith("## [")]
    if not releases or lines[releases[0]].rstrip() != UNRELEASED:
        raise FragmentError(f"{CHANGELOG}: the first release heading must be '{UNRELEASED}'")
    # UNRELEASED carries its own "## [...]" wrapper; split_section wants the
    # bare section name.
    return split_section(lines, "Unreleased")


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


def assemble(directory: pathlib.Path, changelog: pathlib.Path,
             into: str | None = None) -> int:
    fragments = load_all(directory)
    if not fragments:
        print(f"no fragments in {directory}; {changelog} unchanged")
        return 0
    lines = changelog.read_text(encoding="utf-8").splitlines()
    # Both splits run before anything is deleted: a malformed changelog (no
    # [Unreleased], or no [into] section) leaves every fragment in place.
    unrel_before, unrel_body, _ = split_unreleased(lines)
    if into is None:
        before, body, after = split_unreleased(lines)
        moved_preamble: list[str] = []
        moved: list[tuple[str, list[str]]] = []
    else:
        # With --into V the fold targets the existing [V] section, and
        # whatever [Unreleased] still holds moves into it in the same run:
        # one command, no hand-moved entries.
        before, body, after = split_section(lines, into)
        # The gap slice below assumes the target section sits after
        # [Unreleased]. split_unreleased already refuses a changelog whose
        # first heading is a release, so the degenerate reach here is
        # --into Unreleased itself; reject that loudly instead of letting
        # the index arithmetic silently reorder sections.
        if len(before) <= len(unrel_before) + len(unrel_body):
            raise FragmentError(
                f"{CHANGELOG}: section '{SECTION_HEADING.format(into)}' must come "
                f"after '{UNRELEASED}' - refusing to fold"
            )
        moved_preamble, moved = parse_body(unrel_body)
    release_fragments = [(path, sections) for path, sections in fragments if not is_exempt(sections)]
    exempt_fragments = [path for path, sections in fragments if is_exempt(sections)]
    moved_count = sum(len(bullets) for _, bullets in moved)
    if not release_fragments and not moved_count:
        for path in exempt_fragments:
            path.unlink()
        print(
            f"removed {len(exempt_fragments)} exempt fragment(s); "
            f"{changelog} unchanged"
        )
        return 0
    preamble, existing = parse_body(body)

    if into is None:
        merged: Sections = {}
        order: list[str] = []
        seen: dict[str, set[str]] = {}
        # A heading repeated in [Unreleased] merges into its first occurrence.
        sources: list[Sections] = [{name: bullets} for name, bullets in existing]
        sources += [sections for _, sections in release_fragments]
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
    else:
        # A release section already reads in its own voice: existing headings
        # keep their order and position (a hand-written summary stays first),
        # folded bullets append within their section, and a section no source
        # had yet is appended at the end, in vocabulary order among the new
        # ones. A section the stub left as "- TBD" placeholders keeps them
        # only while nothing real arrives.
        merged = {name: list(bullets) for name, bullets in existing}
        order = [name for name, _ in existing]
        seen = {name: {normalize(b) for b in bullets} for name, bullets in existing}
        new_order: list[str] = []
        sources = [{name: bullets} for name, bullets in moved]
        sources += [sections for _, sections in release_fragments]
        for sections in sources:
            for name, bullets in sections.items():
                if name not in merged:
                    merged[name], seen[name] = [], set()
                    new_order.append(name)
                for bullet in bullets:
                    key = normalize(bullet)
                    if key not in seen[name]:
                        seen[name].add(key)
                        merged[name].append(bullet)
        rank = {name: i for i, name in enumerate(SECTIONS)}
        new_order.sort(key=lambda name: rank.get(name, len(rank)))
        # Prose found in [Unreleased] before its first heading moves to the
        # end of the section rather than being dropped.
        out_body = [line for line in preamble if line.strip()]
        for name in order + new_order:
            bullets = merged[name]
            if all(bullet == "- TBD" for bullet in bullets):
                if not bullets:
                    continue
            else:
                bullets = [b for b in bullets if b != "- TBD"]
            out_body += ["", f"### {name}", ""]
            out_body += [line for bullet in bullets for line in bullet.split("\n")]
        out_body += [line for line in moved_preamble if line.strip()]

    if into is None:
        text = "\n".join(before + out_body + ([""] if after else []) + after) + "\n"
    else:
        # [Unreleased] is emptied by the move; the sections between it and
        # the target (and the target heading itself) pass through unchanged.
        head = unrel_before
        gap = before[len(unrel_before) + len(unrel_body):]
        text = "\n".join(
            head + ([""] if gap else []) + gap
            + out_body + ([""] if after else []) + after
        ) + "\n"
    # Replace CHANGELOG.md atomically: writing in place would leave a
    # truncated changelog behind if the process dies mid-write, and the
    # fragments are only unlinked after this succeeds. A sibling temp file
    # keeps os.replace on the same filesystem.
    tmp = changelog.with_name(changelog.name + ".tmp")
    try:
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, changelog)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    for path, _ in fragments:
        path.unlink()
    suffix = f" ({len(exempt_fragments)} exempt removed)" if exempt_fragments else ""
    target = UNRELEASED if into is None else SECTION_HEADING.format(into)
    moved_note = f", moved {moved_count} [Unreleased] bullet(s)" if moved_count else ""
    print(
        f"folded {len(release_fragments)} fragment(s) into {target} "
        f"of {changelog}{suffix}{moved_note}"
    )
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


def merged_squashes_with_sha(base: str, head: str) -> list[tuple[int, str, str]]:
    """[(PR number, commit sha, subject)] of squash commits merged into `head` since `base`.

    Squash subjects end in (#<number>). This repo has no merge commits, so the
    number is the only PR identity in the history.
    """
    log = subprocess.run(
        ["git", "log", "--format=%H %s", f"{base}..{head}"], text=True,
        capture_output=True, check=True).stdout
    merged: list[tuple[int, str, str]] = []
    for line in log.splitlines():
        match = re.search(r"\(#([1-9][0-9]*)\)$", line)
        if match is not None:
            sha, subject = line.split(" ", 1)
            merged.append((int(match.group(1)), sha, subject))
    return merged


def merged_squashes(base: str, head: str) -> list[tuple[int, str]]:
    """[(PR number, subject)] of squash commits merged into `head` since `base`."""
    return [(num, subj) for num, _sha, subj in merged_squashes_with_sha(base, head)]


def find_version_cut(version: str, head: str = "HEAD") -> str:
    """Return the earliest contiguous commit on `head` whose dune-project carries `version`."""
    head_ver = package_version(head)
    if head_ver != version:
        raise FragmentError(
            f"dune-project at {head} has version {head_ver!r}, expected {version!r}"
        )
    log = subprocess.run(
        ["git", "log", "--first-parent", "--format=%H", head, "--", "dune-project"],
        text=True, capture_output=True, check=True,
    ).stdout
    cut: str | None = None
    for rev in log.splitlines():
        rev = rev.strip()
        if not rev:
            continue
        if package_version(rev) == version:
            cut = rev
        else:
            break
    if cut is None:
        raise FragmentError(
            f"could not locate version-cut commit for {version!r} in dune-project history of {head}"
        )
    return cut


def section_cited_prs(changelog: pathlib.Path, version: str) -> set[int]:
    """Return all PR numbers cited inside CHANGELOG.md's `## [<version>]` section."""
    lines = changelog.read_text(encoding="utf-8").splitlines(keepends=True)
    _before, body, _after = split_section(lines, version)
    cited: set[int] = set()
    for line in body:
        for match in SECTION_PR_CITE.finditer(line):
            cited.add(int(match.group(1)))
    return cited


def _commit_has_exempt_fragment(sha: str, number: int) -> bool:
    """Return True when `sha` carries a valid `### Exempt` fragment for `number`."""
    rel = f"{FRAGMENT_DIR}/{number}.md"
    try:
        raw = git_show(sha, rel)
        if not raw:
            return False
        return is_exempt(parse_fragment_text(pathlib.Path(rel), raw))
    except FragmentError:
        return False


def _disk_has_exempt_fragment(directory: pathlib.Path, number: int) -> bool:
    """Return True when `directory/<number>.md` exists on disk as a valid `### Exempt` fragment."""
    path = directory / f"{number}.md"
    if not path.is_file():
        return False
    try:
        return is_exempt(parse_fragment(path))
    except FragmentError:
        return False


def release_coverage(
    version: str,
    base: str | None,
    head: str,
    changelog: pathlib.Path,
    directory: pathlib.Path,
) -> int:
    """Verify every non-exempt post-cut PR in `base..head` is cited in `## [<version>]`.

    Relationship with `missing --strict`:
    - `missing --strict` runs pre-fold (at `bump-version.sh`) and ensures each
      merged PR since the previous tag has a `changelog.d/<N>.md` file or
      exemption.
    - `release-coverage` runs post-cut (at RC time in `release-build.yml`) and
      ensures every non-exempt PR merged after the version-cut commit is
      actually cited in `CHANGELOG.md`'s `## [<version>]` section, catching
      both late unfolded fragments and unfragmented post-cut merges.
    """
    cut = base if base is not None else find_version_cut(version, head)
    merged = merged_squashes_with_sha(cut, head)
    cited = section_cited_prs(changelog, version)
    legacy_exempt = _exempt_numbers()
    missing_prs: list[tuple[int, str, str]] = []
    for number, sha, subject in merged:
        if number in cited:
            continue
        if (
            number in legacy_exempt
            or _disk_has_exempt_fragment(directory, number)
            or _commit_has_exempt_fragment(sha, number)
        ):
            continue
        missing_prs.append((number, sha, subject))
    if not missing_prs:
        print(
            f"release-coverage OK: all {len(merged)} post-cut pull request(s) in "
            f"{cut[:12]}..{head} are recorded in ## [{version}] (or exempt)"
        )
        return 0
    missing_prs.sort(key=lambda item: item[0])
    print(
        f"release-coverage FAILED: {len(missing_prs)} post-cut pull request(s) "
        f"merged in {cut[:12]}..{head} are missing from {changelog} section ## [{version}]:",
        file=sys.stderr,
    )
    for number, _sha, subject in missing_prs:
        frag_path = directory / f"{number}.md"
        detail = (
            f"unfolded fragment: {frag_path}"
            if frag_path.is_file()
            else "no fragment"
        )
        print(f"  #{number} {subject}  [{detail}]", file=sys.stderr)
    print(
        f"Fold pending fragments with `python3 scripts/changelog-fragments.py "
        f"assemble --into {version}` (or add a '### {EXEMPT_SECTION}' fragment "
        f"for non-user-facing PRs) before cutting the release tag.",
        file=sys.stderr,
    )
    return 1


def _exempt_numbers() -> set[int]:
    """Legacy PR numbers the strict gate may not count as blocking findings.

    Read-only compatibility list in changelog-fragments-exempt.txt beside this
    script for pull requests merged before per-PR `### Exempt` fragments. New
    exempt pull requests write `changelog.d/<PR>.md` with a `### Exempt`
    section instead of appending to the shared file.
    """
    path = pathlib.Path(__file__).resolve().parent / "changelog-fragments-exempt.txt"
    if not path.exists():
        return set()
    out: set[int] = set()
    for line in path.read_text().splitlines():
        head = line.split("#", 1)[0].strip()
        if head.isdigit():
            out.add(int(head))
        elif head:
            print(
                f"warning: changelog-fragments-exempt.txt: ignoring"
                f" unrecognized line: {line!r}",
                file=sys.stderr,
            )
    return out


def missing(
    base: str,
    head: str,
    directory: pathlib.Path,
    strict: bool = False,
    changelog: pathlib.Path | None = None,
) -> int:
    """Report PRs merged since `base` whose history carries no fragment.

    A PR is accounted for when any of these holds:
    - its `changelog.d/<N>.md` file still sits on disk awaiting the next fold,
    - its number already owns an entry in `CHANGELOG.md` (terminal `OWNER_CITE`
      — a passing mention inside another entry does not count), or
    - its merge commit carried a valid `### Exempt` fragment (which an
      intervening fold deletes without writing to `CHANGELOG.md`).

    A file whose name is not <PR number>.md proves nothing about any PR, so it
    is ignored here; `check` is the mode that refuses it, and bump-version.sh
    runs check before this.
    """
    have: set[int] = set()
    for path in fragment_paths(directory):
        match = FRAGMENT_NAME.match(path.name)
        if match is not None:
            have.add(int(match.group(1)))
    if changelog is not None:
        if not changelog.is_file():
            raise FragmentError(f"changelog not found: {changelog}")
        owners = entry_owners(changelog)
    else:
        sibling = directory.parent / CHANGELOG
        changelog_path = sibling if sibling.is_file() else pathlib.Path(CHANGELOG)
        owners = entry_owners(changelog_path) if changelog_path.is_file() else {}
    unfragmented: list[tuple[int, str]] = []
    for number, sha, subject in merged_squashes_with_sha(base, head):
        if (
            number in have
            or number in owners
            or _commit_has_exempt_fragment(sha, number)
        ):
            continue
        unfragmented.append((number, subject))
    if not unfragmented:
        print(f"every pull request merged since {base} has a changelog fragment")
        return 0
    unfragmented.sort()
    exempt = _exempt_numbers()
    blocking = [pair for pair in unfragmented if pair[0] not in exempt]
    print(
        f"{len(unfragmented)} pull request(s) merged since {base} without a "
        f"changelog fragment:"
    )
    for number, subject in unfragmented:
        marker = "" if number not in exempt else "  (exempt)"
        print(f"  #{number} {subject}{marker}")
    print(
        "Write the entries to "
        f"{FRAGMENT_DIR}/<PR number>.md before folding (or use '### {EXEMPT_SECTION}' "
        "for non-user-facing PRs), or note here why a release omits one."
    )
    if strict and blocking:
        # Exit 3, not 1: a Python crash also exits 1, and callers must tell
        # "findings" from "broken report" apart.
        return 3
    return 0


def entry_owners(changelog: pathlib.Path) -> dict[int, tuple[int, str]]:
    """{PR number: (1-based line, section heading)} of each CHANGELOG entry.

    An entry line ends with a terminal citation whose first number is the
    entry's owner; a number named inside another entry's text ("fixes #N")
    is a passing mention and owns nothing."""
    section = "(top)"
    owners: dict[int, tuple[int, str]] = {}
    for lineno, raw in enumerate(changelog.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.rstrip()
        if line.startswith("## "):
            section = line.strip()
        match = OWNER_CITE.search(line)
        if match is not None:
            number = int(match.group(1))
            if number not in owners:
                owners[number] = (lineno, section)
    return owners


def folded(directory: pathlib.Path, changelog: pathlib.Path,
           delete: bool = False, strict: bool = False) -> int:
    """Report (and with --delete remove) fragments already in CHANGELOG.md.

    A release that folds on its own branch and lands back on main as a
    squash leaves main's fragment files behind: their entries are already in
    CHANGELOG.md, so folding the fragments again would duplicate them. A
    fragment counts as folded when its number owns a CHANGELOG entry — a
    terminal "(#N)" citation — which a passing mention never is."""
    owners = entry_owners(changelog)
    stale: list[tuple[pathlib.Path, int, int, str]] = []
    kept = 0
    for path in fragment_paths(directory):
        match = FRAGMENT_NAME.match(path.name)
        if match is None:
            continue  # `check` is the mode that refuses a misnamed file
        owner = owners.get(int(match.group(1)))
        if owner is None:
            kept += 1
            continue
        stale.append((path, int(match.group(1)), owner[0], owner[1]))
    for path, number, lineno, section in stale:
        note = f"  ->  {changelog}:{lineno} {section}"
        if delete:
            path.unlink()
            print(f"deleted {path}{note}")
        else:
            print(f"{path}{note}")
    print(
        f"{len(stale)} fragment(s) already folded into {changelog}, "
        f"{kept} not folded"
    )
    if strict and stale:
        # Exit 3, not 1: same contract as `missing --strict` — a caller must
        # tell "findings" from "broken report" apart, and a crash is 1.
        return 3
    return 0


def _escape_annotation_data(value: str) -> str:
    """Escape a workflow-command message like actions/toolkit `escapeData`."""
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _escape_annotation_property(value: str) -> str:
    """Escape a workflow-command property like actions/toolkit `escapeProperty`.

    Property values live inside `::error file=...,line=...::` where `,`
    separates properties and `:` separates name from value, so those two
    characters are escaped on top of the data escapes.
    """
    return (
        value.replace("%", "%25")
        .replace("\r", "%0D")
        .replace("\n", "%0A")
        .replace(":", "%3A")
        .replace(",", "%2C")
    )


def workflow_error(message: str) -> str:
    """Render one diagnostic as a GitHub Actions error annotation command.

    A `path:line: detail` diagnostic becomes
    `::error file=path,line=N::detail` so the failing line is annotated on
    the pull request instead of living only in the raw job log. Anything
    without that shape is emitted as a plain file-less error annotation.
    Message and property values are escaped with the percent rules the
    runner applies in reverse, so a literal `%0A` in a bullet or a comma in
    a filename survives the round trip verbatim.
    """
    match = re.match(r"^(changelog\.d/[^\s:]+)(?::(\d+))?: (.*)$", message, re.S)
    if match is None:
        return f"::error::{_escape_annotation_data(message)}"
    filepart, line, detail = match.groups()
    location = f"file={_escape_annotation_property(filepart)}"
    if line is not None:
        location += f",line={line}"
    return f"::error {location}::{_escape_annotation_data(detail)}"


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
        for message in errors:
            print(workflow_error(message))
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
    fold.add_argument("--into", metavar="VERSION", default=None,
                       help="fold into the existing [VERSION] section (with what "
                            "[Unreleased] holds) instead of into [Unreleased]")
    stale = sub.add_parser("folded")
    stale.add_argument("--dir", default=FRAGMENT_DIR)
    stale.add_argument("--changelog", default=CHANGELOG)
    stale.add_argument("--delete", action="store_true",
                        help="delete the fragment files already folded into CHANGELOG.md")
    stale.add_argument("--strict", action="store_true",
                        help="exit 3 while any already-folded fragment remains")
    miss = sub.add_parser("missing")
    miss.add_argument("--base", required=True)
    miss.add_argument("--head", default="HEAD")
    miss.add_argument("--strict", action="store_true",
                        help="exit 3 when any non-exempt merged pull request lacks a fragment")
    miss.add_argument("--dir", default=FRAGMENT_DIR)
    miss.add_argument("--changelog", default=None,
                        help="CHANGELOG.md path for already-folded owner check")
    guard = sub.add_parser("pr-guard")
    guard.add_argument("--base", required=True)
    guard.add_argument("--head", default="HEAD")
    listed = sub.add_parser("check-files")
    listed.add_argument("files", nargs="*", metavar="FRAGMENT")
    cov = sub.add_parser("release-coverage")
    cov.add_argument("--version", required=True, metavar="VERSION",
                     help="release version section to verify in CHANGELOG.md (e.g. 0.81.0)")
    cov.add_argument("--base", default=None,
                     help="version-cut commit SHA/ref (default: auto-detected from dune-project)")
    cov.add_argument("--head", default="HEAD")
    cov.add_argument("--changelog", default=CHANGELOG)
    cov.add_argument("--dir", default=FRAGMENT_DIR)
    args = parser.parse_args()
    try:
        if args.mode == "check":
            loaded = load_all(pathlib.Path(args.dir))
            print(f"{len(loaded)} changelog fragment(s) OK")
            return 0
        if args.mode == "check-files":
            return check_files(args.files)
        if args.mode == "assemble":
            return assemble(pathlib.Path(args.dir), pathlib.Path(args.changelog),
                            into=args.into)
        if args.mode == "folded":
            return folded(pathlib.Path(args.dir), pathlib.Path(args.changelog),
                          delete=args.delete, strict=args.strict)
        if args.mode == "missing":
            return missing(
                base=args.base,
                head=args.head,
                strict=args.strict,
                directory=pathlib.Path(args.dir),
                changelog=(
                    pathlib.Path(args.changelog)
                    if args.changelog is not None
                    else None
                ),
            )
        if args.mode == "release-coverage":
            return release_coverage(
                version=args.version,
                base=args.base,
                head=args.head,
                changelog=pathlib.Path(args.changelog),
                directory=pathlib.Path(args.dir),
            )
        return pr_guard(args.base, args.head)
    except FragmentError as err:
        print(err, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
