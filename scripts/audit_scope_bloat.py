#!/usr/bin/env python3
"""Audit tasks/goals for scope bloat and unnecessary complexity.

Detects common scope-creep indicators in task descriptions:
- Vague scope markers (etc, and more, future work, TBD, TODO, placeholder)
- Excessive word count (>50 words flagged, >80 words critical)
- Multiple objectives (and/also/plus + verb patterns)
- Missing acceptance criteria (no "acceptance", "criteria", "done when")
- Nested subtask references (numbered lists, bullet points, sub-)
- Overly broad verbs ("improve", "enhance", "optimize" without metrics)

Usage:
    python audit_scope_bloat.py <tasks.json>
    python audit_scope_bloat.py  # reads from stdin as JSON array
"""

import json
import re
import sys
from dataclasses import dataclass
from typing import List, Optional


@dataclass
class BloatFinding:
    task_id: str
    title: str
    severity: str  # "low", "medium", "high", "critical"
    category: str
    message: str
    evidence: str


VAGUE_MARKERS = [
    "etc", "and so on", "and more", "future work", "TBD", "TODO",
    "placeholder", "stub", "coming soon", "not yet defined",
    "to be determined", "to be decided", "flesh out", "fill in",
    "eventually", "later", "at some point", "when needed",
]

BROAD_VERBS = [
    "improve", "enhance", "optimize", "refactor", "clean up",
    "make better", "streamline", "simplify", "modernize",
]

ACCEPTANCE_KEYWORDS = [
    "acceptance", "criteria", "done when", "definition of done",
    "verify", "checklist", "measurable", "metric", "benchmark",
    "test passes", "ci green", "reviewed", "approved",
]


def count_words(text: str) -> int:
    return len(text.split())


def find_vague_markers(text: str) -> List[str]:
    found = []
    lower = text.lower()
    for marker in VAGUE_MARKERS:
        if marker in lower:
            found.append(marker)
    return found


def find_broad_verbs(text: str) -> List[str]:
    found = []
    lower = text.lower()
    for verb in BROAD_VERBS:
        if re.search(rf"\b{verb}\b", lower):
            found.append(verb)
    return found


def has_acceptance_criteria(text: str) -> bool:
    lower = text.lower()
    return any(kw in lower for kw in ACCEPTANCE_KEYWORDS)


def count_objectives(text: str) -> int:
    """Rough count of distinct objectives by conjunction + verb patterns."""
    # Split on sentence boundaries and conjunctions that introduce new actions
    splits = re.split(r'[.!?;]|\band\b|\balso\b|\bplus\b|\badditionally\b', text.lower())
    # Count segments that contain a verb-like word
    verbish = re.compile(r'\b(implement|build|create|fix|add|remove|update|write|design|integrate|deploy|test|audit|refactor|optimize|migrate)\b')
    return sum(1 for s in splits if verbish.search(s))


def has_nested_subtasks(text: str) -> bool:
    """Detect numbered lists, bullet patterns, or explicit subtask references."""
    patterns = [
        r'^\s*[-*•]\s+',           # bullet points
        r'^\s*\d+[.)]\s+',         # numbered lists
        r'\bsubtask\b|\bsub-task\b|\bchild task\b',
        r'\bstep\s+\d+\b|\bphase\s+\d+\b',
    ]
    for pat in patterns:
        if re.search(pat, text, re.MULTILINE | re.IGNORECASE):
            return True
    return False


def audit_task(task: dict) -> List[BloatFinding]:
    findings = []
    task_id = task.get("id", task.get("task_id", "unknown"))
    title = task.get("title", "")
    description = task.get("description", task.get("body", ""))
    full_text = f"{title} {description}"

    # 1. Word count
    word_count = count_words(full_text)
    if word_count > 80:
        findings.append(BloatFinding(
            task_id=task_id, title=title, severity="critical",
            category="word_count",
            message=f"Description is {word_count} words — likely contains multiple objectives or excessive detail",
            evidence=f"word_count={word_count}"
        ))
    elif word_count > 50:
        findings.append(BloatFinding(
            task_id=task_id, title=title, severity="high",
            category="word_count",
            message=f"Description is {word_count} words — consider splitting into smaller tasks",
            evidence=f"word_count={word_count}"
        ))

    # 2. Vague markers
    vague = find_vague_markers(full_text)
    if vague:
        findings.append(BloatFinding(
            task_id=task_id, title=title, severity="high",
            category="vague_scope",
            message=f"Contains vague scope markers: {', '.join(vague)}",
            evidence=f"markers={vague}"
        ))

    # 3. Broad verbs without metrics
    broad = find_broad_verbs(full_text)
    has_metrics = bool(re.search(r'\b\d+%?\b|\b[0-9]+\s*(ms|sec|min|hour|day|req|qps|rps)\b', full_text.lower()))
    if broad and not has_metrics:
        findings.append(BloatFinding(
            task_id=task_id, title=title, severity="medium",
            category="broad_objective",
            message=f"Uses broad verb(s) without measurable target: {', '.join(broad)}",
            evidence=f"verbs={broad}, has_metrics={has_metrics}"
        ))

    # 4. Missing acceptance criteria
    if not has_acceptance_criteria(full_text):
        findings.append(BloatFinding(
            task_id=task_id, title=title, severity="medium",
            category="missing_acceptance",
            message="No acceptance criteria or 'done when' clause detected",
            evidence="No keywords: " + ", ".join(ACCEPTANCE_KEYWORDS[:5]) + "..."
        ))

    # 5. Multiple objectives
    obj_count = count_objectives(description)
    if obj_count > 3:
        findings.append(BloatFinding(
            task_id=task_id, title=title, severity="high",
            category="multiple_objectives",
            message=f"Appears to contain {obj_count} distinct objectives — consider splitting",
            evidence=f"estimated_objectives={obj_count}"
        ))
    elif obj_count > 2:
        findings.append(BloatFinding(
            task_id=task_id, title=title, severity="medium",
            category="multiple_objectives",
            message=f"May contain {obj_count} objectives — verify scope is focused",
            evidence=f"estimated_objectives={obj_count}"
        ))

    # 6. Nested subtasks
    if has_nested_subtasks(description):
        findings.append(BloatFinding(
            task_id=task_id, title=title, severity="high",
            category="nested_subtasks",
            message="Description contains list items or explicit subtask references — this task may be an epic",
            evidence="Detected bullet/number/subtask patterns"
        ))

    return findings


def score_task(findings: List[BloatFinding]) -> int:
    """Calculate a bloat score: higher = more bloated."""
    severity_weights = {"low": 1, "medium": 3, "high": 6, "critical": 10}
    return sum(severity_weights.get(f.severity, 1) for f in findings)


def print_report(all_findings: List[BloatFinding], total_tasks: int):
    if not all_findings:
        print(f"✅ Audited {total_tasks} tasks: no scope bloat detected.")
        return

    by_task = {}
    for f in all_findings:
        by_task.setdefault(f.task_id, []).append(f)

    print(f"\n{'='*60}")
    print(f"SCOPE BLOAT AUDIT REPORT — {total_tasks} tasks scanned")
    print(f"{'='*60}")

    # Sort by bloat score descending
    scored = [(tid, score_task(fs), fs) for tid, fs in by_task.items()]
    scored.sort(key=lambda x: x[1], reverse=True)

    for tid, score, findings in scored:
        print(f"\n🔍 Task: {tid} | Bloat Score: {score}")
        print(f"   Title: {findings[0].title}")
        for f in findings:
            icon = {"low": "⚪", "medium": "🟡", "high": "🔴", "critical": "🚨"}.get(f.severity, "⚪")
            print(f"   {icon} [{f.severity.upper()}] {f.category}: {f.message}")
            print(f"      Evidence: {f.evidence}")

    # Summary stats
    critical = sum(1 for f in all_findings if f.severity == "critical")
    high = sum(1 for f in all_findings if f.severity == "high")
    medium = sum(1 for f in all_findings if f.severity == "medium")
    low = sum(1 for f in all_findings if f.severity == "low")

    print(f"\n{'='*60}")
    print(f"SUMMARY: {len(by_task)}/{total_tasks} tasks flagged")
    print(f"  Critical: {critical} | High: {high} | Medium: {medium} | Low: {low}")
    print(f"{'='*60}")


def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as f:
            data = json.load(f)
    else:
        data = json.load(sys.stdin)

    # Accept either a list of tasks or a dict with a "tasks" key
    if isinstance(data, dict):
        tasks = data.get("tasks", data.get("goals", data.get("items", [])))
    else:
        tasks = data

    if not tasks:
        print("No tasks found in input.", file=sys.stderr)
        sys.exit(1)

    all_findings = []
    for task in tasks:
        findings = audit_task(task)
        all_findings.extend(findings)

    print_report(all_findings, len(tasks))


if __name__ == "__main__":
    main()