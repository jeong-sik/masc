#!/usr/bin/env python3
"""rfc-generate-index.py — Generate RFC index table from frontmatter.

Usage:
  scripts/rfc-generate-index.py              # print to stdout
  scripts/rfc-generate-index.py --check       # exit 1 if stale
  scripts/rfc-generate-index.py --update      # overwrite README table
"""

from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

RFC_DIR = Path("docs/rfc")
README = RFC_DIR / "README.md"
TABLE_HEADER = "| RFC | Title | Status | Sub-docs |"
TABLE_SEP = "|---|---|---|---|"
RFC_NUMBERED_FILE_RE = re.compile(r"^RFC-(?P<number>\d{4})-(?P<slug>.+)\.md$")
RFC_PHASE_FILE_RE = re.compile(
    r"^RFC-(?P<number>\d{4})-phase-(?P<phase>[A-Za-z0-9]+)-"
    r"(?P<slug>.+)\.md$"
)
RFC_SLUG_FILE_RE = re.compile(r"^RFC-(?P<slug>[a-z0-9]+(?:-[a-z0-9]+)*)\.md$")
RFC_REFERENCE_RE = re.compile(
    r"^(?:RFC-)?(?P<number>\d{4})(?:-phase-(?P<phase>[A-Za-z0-9]+))?$"
)
RFC_REFERENCE_SLUG_RE = re.compile(r"^(?:RFC-)?(?P<slug>[a-z0-9]+(?:-[a-z0-9]+)*)$")
# Numbers that two documents hold, measured on 2026-09-05. Each renders as one
# row naming both files; their citations in the code are split by meaning
# already, so renumbering is a separate change. The set is exact: a new clash
# is refused, and a number that returns to one document has to leave it.
NUMBERS_HELD_TWICE = frozenset({"0037", "0108", "0235"})


@dataclass(frozen=True)
class RfcDocument:
    filename: str
    title: str
    status: str


@dataclass
class RfcEntry:
    key: str
    display_key: str
    is_numeric: bool
    documents: list[RfcDocument] = field(default_factory=list)
    sub_docs: list[RfcDocument] = field(default_factory=list)


@dataclass(frozen=True)
class RfcReference:
    number: str | None
    slug: str | None
    phase: str | None


@dataclass(frozen=True)
class FileIdentity:
    key: str
    display_key: str
    number: str | None
    slug: str | None
    phase: str | None


def extract_frontmatter(filepath: Path) -> dict[str, str]:
    """Extract YAML frontmatter key:value pairs."""
    result: dict[str, str] = {}
    in_fm = False
    for line in filepath.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped == "---":
            if in_fm:
                break
            in_fm = True
            continue
        if in_fm and ":" in stripped:
            key, _, value = stripped.partition(":")
            result[key.strip()] = value.strip().strip('"')
    return result


def parse_reference(raw: str) -> RfcReference | None:
    value = raw.strip().strip('"').strip("'")
    numeric = RFC_REFERENCE_RE.fullmatch(value)
    if numeric is not None:
        return RfcReference(
            number=numeric.group("number"),
            slug=None,
            phase=numeric.group("phase"),
        )
    slug = RFC_REFERENCE_SLUG_RE.fullmatch(value)
    if slug is not None:
        return RfcReference(number=None, slug=slug.group("slug"), phase=None)
    return None


def parse_file_identity(name: str) -> FileIdentity:
    phase = RFC_PHASE_FILE_RE.fullmatch(name)
    if phase is not None:
        number = phase.group("number")
        return FileIdentity(
            key=f"number:{number}",
            display_key=number,
            number=number,
            slug=None,
            phase=phase.group("phase"),
        )

    numbered = RFC_NUMBERED_FILE_RE.fullmatch(name)
    if numbered is not None:
        number = numbered.group("number")
        return FileIdentity(
            key=f"number:{number}",
            display_key=number,
            number=number,
            slug=None,
            phase=None,
        )

    slug = RFC_SLUG_FILE_RE.fullmatch(name)
    if slug is not None:
        value = slug.group("slug")
        return FileIdentity(
            key=f"slug:{value}",
            display_key=f"RFC-{value}",
            number=None,
            slug=value,
            phase=None,
        )

    raise ValueError(
        f"{name}: filename must use RFC-NNNN-<slug>.md, "
        "RFC-NNNN-phase-<phase>-<slug>.md, or RFC-<slug>.md"
    )


def relation_parent(
    identity: FileIdentity, frontmatter: dict[str, str], filename: str
) -> tuple[str | None, list[str]]:
    issues: list[str] = []
    parents: set[str] = set()

    raw_rfc = frontmatter.get("rfc")
    if raw_rfc is not None:
        reference = parse_reference(raw_rfc)
        if reference is None:
            issues.append(f"{filename}: invalid frontmatter rfc: {raw_rfc!r}")
        elif identity.number is not None:
            if reference.number != identity.number:
                issues.append(
                    f"{filename}: frontmatter rfc {raw_rfc!r} does not match "
                    f"filename RFC-{identity.number}"
                )
        elif identity.slug is None or reference.slug != identity.slug:
            issues.append(
                f"{filename}: frontmatter rfc {raw_rfc!r} does not match "
                f"filename {identity.display_key}"
            )
        if reference is not None:
            if reference.number is not None and reference.phase is not None:
                parents.add(reference.number)

    for field_name in ("extends", "supplement_of"):
        raw_parent = frontmatter.get(field_name)
        if raw_parent is None:
            continue
        reference = parse_reference(raw_parent)
        if reference is None or reference.number is None:
            issues.append(
                f"{filename}: {field_name} must name a numbered RFC: {raw_parent!r}"
            )
        else:
            parents.add(reference.number)

    if identity.number is not None and identity.phase is not None:
        parents.add(identity.number)

    if len(parents) > 1:
        issues.append(
            f"{filename}: conflicting sub-document parents: {sorted(parents)}"
        )
    parent = next(iter(parents), None)
    if parent is not None and identity.number != parent:
        issues.append(
            f"{filename}: sub-document parent RFC-{parent} does not match "
            f"filename identity {identity.display_key}"
        )
    return parent, issues


def document_for(filepath: Path, frontmatter: dict[str, str]) -> RfcDocument:
    title = frontmatter.get("title", "")
    if not title:
        first_line = ""
        lines = filepath.read_text(encoding="utf-8").splitlines()
        in_frontmatter = bool(lines and lines[0].strip() == "---")
        for index, line in enumerate(lines):
            if index > 0 and line.strip() == "---" and in_frontmatter:
                in_frontmatter = False
                continue
            if in_frontmatter:
                continue
            if line.startswith("# "):
                first_line = line
                break
        title = re.sub(r"^# RFC(?::\s*|[- ]*\d+[.: —–-]*\s*)", "", first_line)
        if not title:
            title = "(untitled)"

    return RfcDocument(
        filename=filepath.name,
        title=title,
        status=frontmatter.get("status", "Draft"),
    )


def collect_entries() -> tuple[dict[str, RfcEntry], list[str]]:
    entries: dict[str, RfcEntry] = {}
    issues: list[str] = []

    for fpath in sorted(RFC_DIR.glob("RFC-*.md")):
        name = fpath.name
        fm = extract_frontmatter(fpath)
        try:
            identity = parse_file_identity(name)
        except ValueError as error:
            issues.append(str(error))
            continue
        parent, relation_issues = relation_parent(identity, fm, name)
        issues.extend(relation_issues)
        entry_key = f"number:{parent}" if parent is not None else identity.key
        entry = entries.setdefault(
            entry_key,
            RfcEntry(
                key=entry_key,
                display_key=identity.display_key if parent is None else parent,
                is_numeric=identity.number is not None or parent is not None,
            ),
        )
        document = document_for(fpath, fm)

        if parent is not None:
            entry.sub_docs.append(document)
            continue

        entry.documents.append(document)

    for entry in entries.values():
        entry.documents.sort(key=lambda document: document.filename)
        entry.sub_docs.sort(key=lambda document: document.filename)
        # One number, one RFC: a "RFC-NNNN §4.1" citation in the code has to
        # name exactly one file. A second document claiming a number is a
        # clash to refuse, not a row to render, except for the numbers in
        # NUMBERS_HELD_TWICE, which hold exactly two.
        count = len(entry.documents)
        filenames = ", ".join(document.filename for document in entry.documents)
        if entry.display_key in NUMBERS_HELD_TWICE:
            if count < 2:
                issues.append(
                    f"{entry.display_key}: fewer than two documents hold it "
                    "now; drop it from NUMBERS_HELD_TWICE"
                )
            elif count > 2:
                issues.append(
                    f"{entry.display_key}: number carried by {count} documents, "
                    f"NUMBERS_HELD_TWICE allows two: {filenames}"
                )
        elif count > 1:
            issues.append(
                f"{entry.display_key}: number carried by {count} documents: "
                f"{filenames}"
            )

    return entries, issues


def generate_table(entries: dict[str, RfcEntry]) -> str:
    lines = [TABLE_HEADER, TABLE_SEP]
    ordered_entries = sorted(
        entries.values(), key=lambda entry: (not entry.is_numeric, entry.key)
    )
    for e in ordered_entries:
        if not e.documents:
            title = "(missing main document)"
            status = "Invalid"
            subs = ", ".join(document.filename for document in e.sub_docs) or "-"
            lines.append(f"| {e.display_key} | {title} | {status} | {subs} |")
            continue

        duplicate_number = len(e.documents) > 1
        rendered_titles: list[str] = []
        for document in e.documents:
            title = document.title
            if len(title) > 80:
                title = title[:77] + "..."
            if duplicate_number:
                title = f"{title} (`{document.filename}`)"
            rendered_titles.append(title)

        title = "<br>".join(rendered_titles)
        status = "<br>".join(document.status for document in e.documents)
        rendered_sub_docs: list[str] = []
        for document in e.sub_docs:
            sub_title = document.title
            if len(sub_title) > 80:
                sub_title = sub_title[:77] + "..."
            rendered_sub_docs.append(
                f"{sub_title} (`{document.filename}`, {document.status})"
            )
        subs = "<br>".join(rendered_sub_docs) if rendered_sub_docs else "-"
        lines.append(f"| {e.display_key} | {title} | {status} | {subs} |")
    return "\n".join(lines)


def check_mode(table: str) -> int:
    text = README.read_text(encoding="utf-8")
    start = text.find(TABLE_HEADER)
    if start == -1:
        print("ERROR: Table header not found in README.md", file=sys.stderr)
        return 1
    end = text.find("\n\n", start)
    if end == -1:
        end = len(text)
    existing = text[start:end].rstrip("\n")
    if existing == table:
        print("OK: RFC index table is up to date")
        return 0
    print(
        "MISMATCH: RFC index table is stale. Run: scripts/rfc-generate-index.py --update"
    )
    for i, (a, b) in enumerate(zip(existing.splitlines(), table.splitlines())):
        if a != b:
            print(f"  line {i + 1}: {a!r} != {b!r}")
    return 1


def update_mode(table: str) -> int:
    text = README.read_text(encoding="utf-8")
    start = text.find(TABLE_HEADER)
    if start == -1:
        print("ERROR: Table header not found in README.md", file=sys.stderr)
        return 1
    end = text.find("\n\n", start)
    if end == -1:
        end = len(text)
    suffix = text[end:].lstrip("\n")
    new_text = text[:start] + table + "\n\n" + suffix
    README.write_text(new_text, encoding="utf-8")
    print(f"Updated RFC index table in {README}")
    return 0


def main() -> int:
    import os

    os.chdir(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    )
    entries, issues = collect_entries()
    if issues:
        for issue in issues:
            print(f"ERROR: {issue}", file=sys.stderr)
        return 1
    table = generate_table(entries)

    if "--check" in sys.argv:
        return check_mode(table)
    if "--update" in sys.argv:
        return update_mode(table)
    print(table)
    return 0


if __name__ == "__main__":
    sys.exit(main())
