#!/usr/bin/env python3
"""RFC v5 Phase T0 — Analyze exec corpus JSONL into a risk-distribution report.

Input: $MASC_EXEC_TAP_OUT or audits/exec-corpus.jsonl (default).
Output: markdown on stdout.  With --write, also updates
        audits/local-exec-core-inventory.md in place.

Risk buckets (argv-based; the T0 tap has no bash parser):
- git_mut        argv[0]=='git' and argv[1] in a mutating subcommand
- git_read       argv[0]=='git' and argv[1] in a read-only subcommand
- git_other      argv[0]=='git' with an unclassified subcommand
- bin_audited    argv[0] in the AUDITED set (docker/curl/ssh/tar/...)
- bin_simple    argv[0] in the SAFE set (ls/cat/pwd/echo/...)
- bin_unknown    everything else

A0 proceed gate (RFC v5 T0 exit criteria):
  known_class_ratio = (git_* + bin_audited + bin_simple) / total >= 0.85
"""
import argparse
import json
import os
import sys
from collections import Counter
from pathlib import Path

GIT_MUT = {
    "commit", "merge", "rebase", "pull", "push", "fetch",
    "reset", "clean", "tag", "stash",
    "checkout", "switch", "branch", "remote", "apply",
    "cherry-pick", "revert",
}
GIT_READ = {
    "status", "log", "diff", "show", "ls-files", "rev-parse",
    "blame", "describe", "config", "for-each-ref", "cat-file",
    "ls-tree", "reflog", "grep", "shortlog",
}

BIN_AUDITED = {
    "docker", "curl", "wget", "ssh", "scp",
    "tar", "rsync", "make", "cmake",
    "npm", "yarn", "pnpm", "pip", "opam", "cargo",
    "gh", "glab", "terminal-notifier", "osascript", "play", "rec",
    "ffplay", "mpg123", "open", "claude", "gemini", "codex",
}
BIN_SAFE = {
    "ls", "cat", "pwd", "echo", "head", "tail",
    "grep", "rg", "find", "which", "test", "file",
    "basename", "dirname", "stat", "du", "df",
    "sort", "uniq", "wc", "cut", "tr",
    "date", "env", "printenv", "hostname", "whoami", "uname", "ps", "tty",
}

def normalize_git_args(argv):
    if not argv or argv[0] != "git":
        return argv
    args = list(argv[1:])
    i = 0
    while i < len(args):
        token = args[i]
        if token in {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}:
            i += 2
            continue
        if token in {"--no-pager", "--literal-pathspecs"}:
            i += 1
            continue
        break
    return ["git"] + args[i:]


def classify(argv):
    if not argv:
        return "bin_unknown"
    argv = normalize_git_args(argv)
    head = argv[0]
    if head == "git" and len(argv) > 1:
        sub = argv[1]
        if sub in GIT_MUT:
            return "git_mut"
        if sub in GIT_READ:
            return "git_read"
        return "git_other"
    if head in BIN_AUDITED:
        return "bin_audited"
    if head in BIN_SAFE:
        return "bin_simple"
    return "bin_unknown"


def read_corpus(path):
    if not path.exists():
        sys.exit(f"error: {path} does not exist")
    rows = []
    with path.open() as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            try:
                rows.append(json.loads(ln))
            except json.JSONDecodeError as e:
                print(f"warning: malformed line skipped: {e}", file=sys.stderr)
    return rows


def build_report(entries):
    kinds = Counter()
    buckets = Counter()
    bin_top = Counter()
    git_sub = Counter()
    for e in entries:
        kind = e.get("kind", "?")
        kinds[kind] += 1
        if kind == "Exec_gate.decision":
            continue
        argv = e.get("argv") or []
        buckets[classify(argv)] += 1
        if argv:
            bin_top[argv[0]] += 1
            if argv[0] == "git" and len(argv) > 1:
                git_sub[argv[1]] += 1
    total = sum(buckets.values())
    known = (
        buckets["git_mut"]
        + buckets["git_read"]
        + buckets["git_other"]
        + buckets["bin_audited"]
        + buckets["bin_simple"]
    )
    return {
        "total": total,
        "kinds": dict(kinds),
        "buckets": dict(buckets),
        "bin_top20": bin_top.most_common(20),
        "git_top20": git_sub.most_common(20),
        "known_class_ratio": (known / total) if total else 0.0,
    }


def render_markdown(report):
    t = report["total"] or 1
    md = []
    md += [
        "# Local Exec Core Inventory \u2014 RFC v5 T0",
        "",
        f"Total captured invocations: **{report['total']}**",
        "",
        "## Call kinds",
        "| kind | count |",
        "|------|------:|",
    ]
    for k, v in sorted(report["kinds"].items(), key=lambda x: -x[1]):
        md.append(f"| `{k}` | {v} |")
    md += [
        "",
        "## Risk buckets",
        "| bucket | count | pct |",
        "|--------|------:|----:|",
    ]
    for b in [
        "git_mut", "git_read", "git_other",
        "bin_audited", "bin_simple", "bin_unknown",
    ]:
        c = report["buckets"].get(b, 0)
        md.append(f"| {b} | {c} | {100 * c / t:.1f}% |")
    w = report["known_class_ratio"]
    gate = "PROCEED" if w >= 0.85 else "RE-EVALUATE"
    md += [
        "",
        f"Known-class ratio (A0 gate \u2265 0.85): **{w:.3f}** \u2014 **{gate}**",
        "",
        "## Top 20 binaries",
        "| bin | count |",
        "|-----|------:|",
    ]
    for b, c in report["bin_top20"]:
        md.append(f"| `{b}` | {c} |")
    md += [
        "",
        "## Top 20 git subcommands",
        "| subcmd | count |",
        "|--------|------:|",
    ]
    for s, c in report["git_top20"]:
        md.append(f"| `{s}` | {c} |")
    md.append("")
    return "\n".join(md)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    default_in = os.environ.get("MASC_EXEC_TAP_OUT", "audits/exec-corpus.jsonl")
    ap.add_argument("--input", "-i", default=default_in,
                    help=f"JSONL input file (default: {default_in})")
    ap.add_argument("--write", "-w", action="store_true",
                    help="Write markdown to audits/local-exec-core-inventory.md")
    args = ap.parse_args()
    entries = read_corpus(Path(args.input))
    report = build_report(entries)
    md = render_markdown(report)
    print(md)
    if args.write:
        out = Path("audits/local-exec-core-inventory.md")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(md + "\n")
        print(f"\n[report] written to {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
