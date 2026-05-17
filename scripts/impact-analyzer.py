#!/usr/bin/env python3
"""
Impact Analyzer for PR Comments

Given a list of changed files, query Neo4j for affected BDDs and calculate risk score.

Usage:
    python impact-analyzer.py <file1> <file2> ...
    echo "server.py models.py" | python impact-analyzer.py

Output:
    Markdown formatted PR comment with risk score and affected BDDs.

Environment:
    NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD (from shell env via sb)
    Optional: MASC_SB_SCRIPT or SB_SCRIPT, otherwise ME_ROOT/scripts/sb,
    MASC_WORKSPACE_ROOT/scripts/sb, or sb from PATH.
"""

import os
import sys
import json
import subprocess
from typing import List, Dict, Any
from pathlib import Path


def resolve_sb_script() -> str:
    explicit = os.environ.get("MASC_SB_SCRIPT") or os.environ.get("SB_SCRIPT")
    if explicit:
        return explicit
    root = os.environ.get("ME_ROOT") or os.environ.get("MASC_WORKSPACE_ROOT")
    if root:
        return str(Path(root) / "scripts" / "sb")
    return "sb"


SB_SCRIPT = resolve_sb_script()

# Risk weights by category
CATEGORY_WEIGHTS = {
    "CRITICAL": 3,
    "FEATURE": 2,
    "EDGE": 1,
}

# Risk score thresholds
RISK_THRESHOLDS = {
    "HIGH": 50,
    "MEDIUM": 20,
}


def run_neo4j_query(cypher: str) -> List[List[Any]]:
    """
    Run Cypher query via sb neo4j query.

    Returns:
        List of rows (each row is a list of values)

    Example output format from neo4j_client:
        {"records":[[[value1, value2, ...], ...]]}
    """
    cmd = [str(SB_SCRIPT), "neo4j", "query", cypher]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
    except subprocess.CalledProcessError as e:
        print(f"Error running query: {e}", file=sys.stderr)
        print(f"stderr: {e.stderr}", file=sys.stderr)
        return []
    except subprocess.TimeoutExpired:
        print("Query timed out", file=sys.stderr)
        return []

    # Parse JSON output from neo4j_client
    try:
        data = json.loads(result.stdout)
        # neo4j_client returns {"records": [[[values...], ...]]}
        if "records" in data:
            records = data["records"]
            # Handle nested structure
            if isinstance(records, list) and len(records) > 0:
                first = records[0]
                if isinstance(first, list):
                    return first
        return []
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON: {e}", file=sys.stderr)
        print(f"stdout: {result.stdout}", file=sys.stderr)
        return []


def get_affected_bdds(file_patterns: List[str]) -> List[Dict[str, Any]]:
    """
    Query affected BDDs for given file patterns.

    Args:
        file_patterns: List of file path substrings to match

    Returns:
        List of BDD dicts with keys: id, title, category, quality
    """
    # Build Cypher query with any() for multiple file patterns
    patterns_json = json.dumps(file_patterns)
    cypher = f"""MATCH (b:BDD)
WHERE any(file IN {patterns_json} WHERE b.source_file CONTAINS file)
RETURN b.bdd_id as id, b.title as title, b.category as category, b.quality as quality
ORDER BY b.category DESC"""

    rows = run_neo4j_query(cypher)

    bdds = []
    for row in rows:
        if len(row) >= 4:
            bdds.append(
                {
                    "id": row[0],
                    "title": row[1] if row[1] else "",
                    "category": row[2] if row[2] else "UNKNOWN",
                    "quality": row[3] if row[3] else 0,
                }
            )
    return bdds


def calculate_risk_score(bdds: List[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Calculate risk score from affected BDDs.

    Args:
        bdds: List of BDD dicts

    Returns:
        Dict with risk_score, total_bdds, critical_count, category_breakdown
    """
    total_score = 0
    category_counts: Dict[str, int] = {}
    critical_count = 0

    for bdd in bdds:
        category = bdd.get("category", "UNKNOWN")
        weight = CATEGORY_WEIGHTS.get(category, 1)
        total_score += weight

        category_counts[category] = category_counts.get(category, 0) + 1

        if category == "CRITICAL":
            critical_count += 1

    return {
        "risk_score": total_score,
        "total_bdds": len(bdds),
        "critical_count": critical_count,
        "category_breakdown": category_counts,
    }


def get_risk_level(risk_score: int) -> tuple[str, str]:
    """
    Get risk level from score.

    Returns:
        (level, emoji) tuple
    """
    if risk_score >= RISK_THRESHOLDS["HIGH"]:
        return ("HIGH", "")
    elif risk_score >= RISK_THRESHOLDS["MEDIUM"]:
        return ("MEDIUM", "")
    else:
        return ("LOW", "")


def format_pr_comment(
    changed_files: List[str], bdds: List[Dict[str, Any]], risk: Dict[str, Any]
) -> str:
    """
    Format analysis as PR comment in markdown.

    Args:
        changed_files: List of changed file paths
        bdds: List of affected BDDs
        risk: Risk analysis dict

    Returns:
        Markdown formatted string
    """
    risk_score = risk["risk_score"]
    risk_level, risk_emoji = get_risk_level(risk_score)

    lines = [
        "## Impact Analysis",
        "",
        f"**Risk Score**: {risk_score} ({risk_emoji} {risk_level})",
        "",
        f"**Affected BDDs**: {risk['total_bdds']} (CRITICAL: {risk['critical_count']})",
        "",
    ]

    # Category breakdown
    if risk["category_breakdown"]:
        lines.append("**Category Breakdown**:")
        for cat, count in sorted(
            risk["category_breakdown"].items(),
            key=lambda x: CATEGORY_WEIGHTS.get(x[0], 0),
            reverse=True,
        ):
            emoji = ""
            if cat == "CRITICAL":
                emoji = ""
            elif cat == "FEATURE":
                emoji = ""
            lines.append(f"- {emoji} {cat}: {count}")
        lines.append("")

    # Changed files
    if changed_files:
        lines.append("### Changed Files")
        for f in changed_files[:20]:  # Limit to 20 files
            lines.append(f"- `{f}`")
        if len(changed_files) > 20:
            lines.append(f"- ... and {len(changed_files) - 20} more")
        lines.append("")

    # Affected BDDs (top 15)
    lines.append("### Affected BDDs (Top 15)")
    for bdd in bdds[:15]:
        cat = bdd.get("category", "?")
        emoji = ""
        if cat == "CRITICAL":
            emoji = ""
        elif cat == "FEATURE":
            emoji = ""
        else:
            emoji = ""

        quality = bdd.get("quality", 0)
        lines.append(
            f"- {emoji} **{bdd['id']}**: {bdd['title']} ({cat}, quality: {quality})"
        )

    if len(bdds) > 15:
        lines.append(f"- ... and {len(bdds) - 15} more")

    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append(
        "<sub>Generated by [Impact Analyzer](https://github.com/jeong-sik/masc-mcp) "
        "using Neo4j BDD graph</sub>"
    )

    return "\n".join(lines)


def analyze_impact(changed_files: List[str]) -> str:
    """
    Main analysis function.

    Args:
        changed_files: List of changed file paths

    Returns:
        Markdown formatted PR comment
    """
    if not changed_files:
        return "## Impact Analysis\n\nNo changed files provided."

    # Get affected BDDs
    bdds = get_affected_bdds(changed_files)

    # Calculate risk
    risk = calculate_risk_score(bdds)

    # Format comment
    return format_pr_comment(changed_files, bdds, risk)


def main():
    """CLI entry point."""
    # Parse arguments
    if len(sys.argv) < 2:
        # Check stdin
        if not sys.stdin.isatty():
            input_data = sys.stdin.read().strip()
            files = input_data.split() if input_data else []
        else:
            print("Usage: impact-analyzer.py <file1> <file2> ...", file=sys.stderr)
            print("   or: echo 'file1 file2' | impact-analyzer.py", file=sys.stderr)
            sys.exit(1)
    else:
        files = sys.argv[1:]

    # Run analysis
    comment = analyze_impact(files)
    print(comment)


if __name__ == "__main__":
    main()
