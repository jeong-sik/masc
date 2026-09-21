#!/usr/bin/env python3
"""Cut one version's section out of CHANGELOG.md for the GitHub release body.

A release page is the first thing a reader meets, and the tag workflow used to
hand it nothing but GitHub's generated pull-request list. An upgrade that asks
for an action before installing -- 0.35.21 asks for a stopped server and a
deleted turn-records directory -- is invisible there. This lifts the version's
own section to the top of the body; the generated list still follows it.

Failing loudly is the point: a tag whose version has no section would publish a
page that says nothing about the release, so this exits non-zero instead.
"""

import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: changelog-section.py <version> <changelog> <out>", file=sys.stderr
        )
        return 2
    version, changelog, out = sys.argv[1], sys.argv[2], sys.argv[3]
    lines = pathlib.Path(changelog).read_text(encoding="utf-8").splitlines()
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
    end = next(
        (i for i in range(start + 1, len(lines)) if lines[i].startswith("## [")),
        len(lines),
    )
    body = "\n".join(lines[start:end]).strip() + "\n"
    pathlib.Path(out).write_text(body, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
