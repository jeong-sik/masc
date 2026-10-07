#!/usr/bin/env python3
"""Write the GitHub release body for one version from its CHANGELOG.md section.

A release page is the first thing a reader meets, and the tag workflow used to
hand it nothing but GitHub's generated pull-request list. An upgrade that asks
for an action before installing -- 0.35.21 asks for a stopped server and a
deleted turn-records directory -- is invisible there. The body opens with the
version's own section, followed by one compare link to the previous release.

The page lists what a reader acts on and counts the rest. Upgrade notes, known
issues and what was added, changed, deprecated, removed or made faster are
printed entry by entry. The headings in COUNTED are named with their entry
count and a link to CHANGELOG.md, which keeps every entry: a release folds
several hundred pull requests, and 0.50.0's fixes alone (651 entries, 125,100
characters) were longer than the page can hold.

Failing loudly is the point: a tag whose version has no section would publish a
page that says nothing about the release, so this exits non-zero instead. A
section with no entries -- the bare stub a version bump leaves -- fails too.

A body longer than the page can hold fails the same way. GitHub keeps the first
125,000 characters of a release body and drops the rest without an error: the
v0.37.0 page (run 35889074765, success) stopped mid-word in "- Audit how Boa",
and the Documentation and Internal sections never reached the reader. With
--max-chars this refuses to write such a body. The limit is measured on the
body GitHub will store, so text appended after the section -- the compare
link -- is passed with --append and counted too.

The heading's date is a prediction when it is written: the fold pull request
names the day it expects the tag, and the tag's day is decided when the
commit lands. KST evenings are the previous day in UTC, and v0.35.7 and
v0.35.8 shipped headed 2026-09-11 on commits dated 2026-09-10 UTC. With
--expect-date the caller passes the UTC date of the commit that will be
tagged, and a heading that names another day, or none, fails before the tag.
"""

import argparse
import pathlib
import sys

# Headings whose entries the release page counts instead of listing.
COUNTED = ("Fixed", "Documentation", "Internal")


def split_sections(body: list[str]) -> tuple[list[str], list[tuple[str, list[str]]]]:
    """(lines before the first heading, [(heading, its lines)]) of a section body."""
    preamble: list[str] = []
    sections: list[tuple[str, list[str]]] = []
    for line in body:
        if line.startswith("### "):
            sections.append((line[len("### "):].strip(), []))
        elif sections:
            sections[-1][1].append(line)
        else:
            preamble.append(line)
    return preamble, sections


def release_page(heading: str, body: list[str], changelog_url: str | None) -> str:
    preamble, sections = split_sections(body)
    listed = [heading, *preamble]
    counted: list[tuple[str, int]] = []
    for name, lines in sections:
        if name in COUNTED:
            entries = sum(1 for line in lines if line.startswith("- "))
            if entries:
                counted.append((name, entries))
        else:
            listed += [f"### {name}", *lines]
    page = "\n".join(listed).strip()
    if counted:
        where = f"[CHANGELOG.md]({changelog_url})" if changelog_url else "CHANGELOG.md"
        rows = "\n".join(
            f"- {name}: {entries} {'entry' if entries == 1 else 'entries'}"
            for name, entries in counted
        )
        page += (
            f"\n\n### Also in this release\n\n{rows}\n\n"
            f"Every entry is in {where} under `{heading}`."
        )
    return page


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Cut one version's CHANGELOG section for a release body."
    )
    parser.add_argument("version")
    parser.add_argument("changelog", type=pathlib.Path)
    parser.add_argument("out", type=pathlib.Path)
    parser.add_argument(
        "--append",
        type=pathlib.Path,
        help="text placed after the section, separated by a blank line, "
        "and counted against --max-chars",
    )
    parser.add_argument(
        "--max-chars",
        type=int,
        help="refuse a body longer than this many characters",
    )
    parser.add_argument(
        "--changelog-url",
        help="where the page links for the entries it only counts",
    )
    parser.add_argument(
        "--expect-date",
        help="refuse a section whose heading date is not this YYYY-MM-DD, "
        "the UTC date of the commit the tag will name",
    )
    args = parser.parse_args(argv)
    version, changelog, out = args.version, args.changelog, args.out

    lines = changelog.read_text(encoding="utf-8").splitlines()
    header = f"## [{version}]"
    starts = [i for i, line in enumerate(lines) if line.startswith(header)]
    if not starts:
        print(
            f"{changelog} has no {header} section; refusing to publish a "
            f"release body that does not describe {version}",
            file=sys.stderr,
        )
        return 1
    if len(starts) > 1:
        line_numbers = ", ".join(str(i + 1) for i in starts)
        print(
            f"{changelog} has {len(starts)} {header} sections at lines "
            f"{line_numbers}; refusing to publish only the first",
            file=sys.stderr,
        )
        return 1
    start = starts[0]
    if args.expect_date is not None:
        heading = lines[start]
        dated = heading[len(header):]
        date = dated[len(" - "):].strip() if dated.startswith(" - ") else ""
        if date != args.expect_date:
            named = f"names {date}" if date else "names no date"
            print(
                f"{changelog} heading {heading!r} {named}, but the commit the "
                f"tag will name is dated {args.expect_date} in UTC. Write "
                f"'{header} - {args.expect_date}' before tagging {version}.",
                file=sys.stderr,
            )
            return 1
    end = next(
        (i for i in range(start + 1, len(lines)) if lines[i].startswith("## [")),
        len(lines),
    )
    # A heading with no entries under it is as empty as a missing one: the
    # version bump adds a bare stub, and a release cut before its entries are
    # moved in would publish a page that says nothing about the release.
    if not any(line.startswith("- ") for line in lines[start + 1 : end]):
        print(
            f"{changelog} {header} has no '- ' entries; move the release's "
            f"entries into it before tagging {version}",
            file=sys.stderr,
        )
        return 1
    section = release_page(lines[start], lines[start + 1 : end], args.changelog_url)
    appended = (
        args.append.read_text(encoding="utf-8").strip() if args.append else ""
    )
    body = section + ("\n\n" + appended if appended else "") + "\n"
    if args.max_chars is not None and len(body) > args.max_chars:
        print(
            f"release body for {version} is {len(body)} characters "
            f"({len(section)} from the {header} section, {len(appended)} "
            f"appended); the limit is {args.max_chars}, so "
            f"{len(body) - args.max_chars} characters would be cut from the "
            f"published page without an error. Shorten the listed entries "
            f"before tagging {version}; {', '.join(COUNTED)} are counted, "
            f"not listed.",
            file=sys.stderr,
        )
        return 1
    out.write_text(body, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
