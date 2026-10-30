"""Reproduce the audit census; this is an inventory, not a CI size/style gate."""

import argparse
import collections
import csv
import io
import pathlib
import re
import subprocess
import sys
import tarfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("revision")
parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[3])
args = parser.parse_args()
excluded = {
    "test", "tests", "__tests__", "fixtures", "evidence", "node_modules",
    "vendor", "generated", "dist", "build", "_build",
}
extensions = {".ml", ".mli", ".ts", ".tsx", ".js", ".mjs", ".c", ".cpp", ".h", ".swift", ".rs"}
archive_bytes = subprocess.check_output(
    ["git", "-C", str(args.repo), "archive", args.revision, "lib", "bin", "dashboard/src", "tools"]
)
rows = []
with tarfile.open(fileobj=io.BytesIO(archive_bytes)) as archive:
    for member in archive:
        path = pathlib.PurePosixPath(member.name)
        if not member.isfile() or path.suffix not in extensions or excluded.intersection(path.parts):
            continue
        if path.name.startswith(("test_", "test-")) or re.search(r"\.(test|spec)\.", path.name):
            continue
        source = archive.extractfile(member).read().decode("utf-8")
        rows.append({
            "path": str(path), "lines": len(source.splitlines()),
            # These are lexical navigation aids, including comments/strings.
            # They are not counts of unsafe state, fields or race conditions.
            "mutable_markers": len(re.findall(r"\bmutable\b", source)),
            "ref_markers": len(re.findall(r"\bref\b", source)),
            "atomic_make_markers": source.count("Atomic.make"),
            "hashtbl_create_markers": source.count("Hashtbl.create"),
            "include_lines": len(re.findall(r"^include\b", source, re.M)),
            "interface": path.suffix == ".mli",
        })
rows.sort(key=lambda row: (-row["lines"], row["path"]))
candidates = [row for row in rows if row["lines"] >= 2000 and not row["interface"]]
writer = csv.DictWriter(sys.stdout, fieldnames=list(rows[0]), lineterminator="\n")
writer.writeheader()
writer.writerows(candidates)
print(f"revision={args.revision} files={len(rows)} lines={sum(row['lines'] for row in rows)} "
      f"implementation_candidates={len(candidates)}", file=sys.stderr)
print(dict(collections.Counter(row["path"].split("/")[0] for row in rows)), file=sys.stderr)
