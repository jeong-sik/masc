#!/usr/bin/env python3
"""Search-quality regression bench: fixed queries, deterministic scoring.

Answers "did search quality move?" with numbers instead of anecdotes.
Each case pairs a fixed query with the evidence a good result must show:
an expected domain in the top ranks, or (for Korean prose queries) a
minimum hangul ratio in the returned content. Scoring is deterministic;
only the web behind the providers varies between runs, which is exactly
the drift this file exists to track over time.

Providers measured per run:
  - ollama          when OLLAMA_API_KEY is present (same endpoint, auth,
                    and body shape as fetch_ollama in
                    lib/tool_misc_web_search.ml)
  - brave_grounded  when BRAVE_SEARCH_API_KEY is present (the Brave LLM
                    Context endpoint fetch_brave_llm_context dispatches
                    to); absent key records a skip, so the A/B side
                    activates the moment the key lands
  - searxng         always probed (no credential), as the availability
                    time-series baseline

Metrics per case: hit@1, hit@5 (expected-domain containment by rank),
result_count, hangul_ratio where required, elapsed_ms. Aggregates per
provider and per category. No thresholds and no exit-code gating: this
is a measuring instrument, and the evidence JSON is the product.

Usage:
  python3 scripts/bench-web-quality.py -o docs/evidence/web-quality-<date>-rN.json
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import time
import urllib.parse
from pathlib import Path
from typing import Any

_spec = importlib.util.spec_from_file_location(
    "bench_web_tools", Path(__file__).parent / "bench-web-tools.py"
)
assert _spec is not None and _spec.loader is not None
_tools = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_tools)

http = _tools.http
probe = _tools.probe
SEARXNG_URL = _tools.SEARXNG_URL

# Each case: query, category, and the deterministic evidence of a good
# answer. expected_domains matches against the registrable host suffix of
# each result URL. min_hangul_ratio applies to concatenated result content.
CASES: list[dict[str, Any]] = [
    {
        "query": "OCaml 5.5 effect handlers tutorial",
        "category": "official-docs",
        "expected_domains": ["ocaml.org"],
    },
    {
        "query": "python asyncio TaskGroup documentation",
        "category": "official-docs",
        "expected_domains": ["docs.python.org"],
    },
    {
        "query": "RFC 9110 HTTP semantics status codes",
        "category": "reference",
        "expected_domains": ["rfc-editor.org", "datatracker.ietf.org", "httpwg.org"],
    },
    {
        "query": "git rebase autostash pop conflict behavior",
        "category": "technical-qa",
        "expected_domains": ["stackoverflow.com", "git-scm.com"],
    },
    {
        "query": "Eio Switch cancellation semantics OCaml",
        "category": "niche",
        "expected_domains": ["ocaml.org", "github.com"],
    },
    {
        "query": "Anthropic Claude latest model announcement",
        "category": "recency",
        "expected_domains": ["anthropic.com"],
    },
    {
        "query": "장마철 제습기 원리",
        "category": "korean",
        "expected_domains": [],
        "min_hangul_ratio": 0.2,
    },
    {
        "query": "전세 계약 갱신 청구권 조건",
        "category": "korean",
        "expected_domains": [],
        "min_hangul_ratio": 0.2,
    },
]

TOP_K = 5


def host_of(url: str) -> str:
    try:
        return (urllib.parse.urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""


def domain_matches(host: str, expected: str) -> bool:
    return host == expected or host.endswith("." + expected)


def hangul_ratio(text: str) -> float:
    if not text:
        return 0.0
    hangul = sum(1 for ch in text if "가" <= ch <= "힣")
    letters = sum(1 for ch in text if not ch.isspace())
    return hangul / letters if letters else 0.0


def score_case(case: dict[str, Any], ranked: list[dict[str, str]]) -> dict[str, Any]:
    """ranked: [{url, content}] in provider rank order. Deterministic."""
    expected = case["expected_domains"]
    hosts = [host_of(r["url"]) for r in ranked[:TOP_K]]
    first_match_rank = None
    for rank, host in enumerate(hosts, start=1):
        if any(domain_matches(host, e) for e in expected):
            first_match_rank = rank
            break
    record: dict[str, Any] = {
        "result_count": len(ranked),
        "top_hosts": hosts,
    }
    if expected:
        record["hit_at_1"] = first_match_rank == 1
        record["hit_at_5"] = first_match_rank is not None
        record["first_match_rank"] = first_match_rank
    if "min_hangul_ratio" in case:
        ratio = hangul_ratio("".join(r["content"] for r in ranked[:TOP_K]))
        record["hangul_ratio"] = round(ratio, 3)
        record["hangul_ok"] = ratio >= case["min_hangul_ratio"]
    return record


def run_ollama(api_key: str, case: dict[str, Any]) -> dict[str, Any]:
    status, _, body, ms = http(
        "https://ollama.com/api/web_search",
        body=json.dumps({"query": case["query"], "max_results": TOP_K}).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    parsed = json.loads(body)
    results = parsed.get("results")
    if results is None:
        return {"http_status": status, "elapsed_ms": round(ms, 1), "error_payload": parsed}
    ranked = [
        {"url": r.get("url", ""), "content": r.get("content", "")} for r in results
    ]
    return {
        "http_status": status,
        "elapsed_ms": round(ms, 1),
        **score_case(case, ranked),
    }


def run_brave_grounded(api_key: str, case: dict[str, Any]) -> dict[str, Any]:
    query = urllib.parse.quote(case["query"])
    status, _, body, ms = http(
        f"https://api.search.brave.com/res/v1/llm/context?q={query}",
        headers={"X-Subscription-Token": api_key, "Accept": "application/json"},
    )
    parsed = json.loads(body)
    generic = (parsed.get("grounding") or {}).get("generic")
    if generic is None:
        return {"http_status": status, "elapsed_ms": round(ms, 1), "error_payload": parsed}
    ranked = [
        {
            "url": entry.get("url", ""),
            "content": "".join(entry.get("snippets") or []),
        }
        for entry in generic
    ]
    return {
        "http_status": status,
        "elapsed_ms": round(ms, 1),
        **score_case(case, ranked),
    }


def run_searxng(case: dict[str, Any]) -> dict[str, Any]:
    query = urllib.parse.quote(case["query"])
    status, _, body, ms = http(f"{SEARXNG_URL}/search?q={query}&format=json")
    parsed = json.loads(body)
    results = parsed.get("results", [])
    ranked = [
        {"url": r.get("url", ""), "content": r.get("content", "")} for r in results
    ]
    return {
        "http_status": status,
        "elapsed_ms": round(ms, 1),
        **score_case(case, ranked),
    }


def aggregate(rows: list[tuple[dict[str, Any], dict[str, Any]]]) -> dict[str, Any]:
    scored = [r for _, r in rows if "error" not in r and "error_payload" not in r]
    hit1 = [r["hit_at_1"] for r in scored if "hit_at_1" in r]
    hit5 = [r["hit_at_5"] for r in scored if "hit_at_5" in r]
    hangul = [r["hangul_ok"] for r in scored if "hangul_ok" in r]
    ms = [r["elapsed_ms"] for r in scored if "elapsed_ms" in r]
    return {
        "cases_scored": len(scored),
        "cases_errored": len(rows) - len(scored),
        "hit_at_1": f"{sum(hit1)}/{len(hit1)}" if hit1 else None,
        "hit_at_5": f"{sum(hit5)}/{len(hit5)}" if hit5 else None,
        "hangul_ok": f"{sum(hangul)}/{len(hangul)}" if hangul else None,
        "median_elapsed_ms": sorted(ms)[len(ms) // 2] if ms else None,
    }


def run_provider(runner) -> dict[str, Any]:
    rows = [(case, probe(runner, case)) for case in CASES]
    return {
        "summary": aggregate(rows),
        "cases": [
            {"query": case["query"], "category": case["category"], **result}
            for case, result in rows
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--output", required=True, help="evidence JSON path")
    args = parser.parse_args()

    providers: dict[str, Any] = {}
    ollama_key = os.environ.get("OLLAMA_API_KEY")
    providers["ollama"] = (
        run_provider(lambda case: run_ollama(ollama_key, case))
        if ollama_key
        else {"skipped": "OLLAMA_API_KEY absent"}
    )
    brave_key = os.environ.get("BRAVE_SEARCH_API_KEY")
    providers["brave_grounded"] = (
        run_provider(lambda case: run_brave_grounded(brave_key, case))
        if brave_key
        else {"skipped": "BRAVE_SEARCH_API_KEY absent"}
    )
    providers["searxng"] = run_provider(run_searxng)

    evidence = {
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "script": "scripts/bench-web-quality.py",
        "top_k": TOP_K,
        "case_count": len(CASES),
        "providers": providers,
    }
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(evidence, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    for name, block in providers.items():
        print(name, "->", json.dumps(block.get("summary", block), ensure_ascii=False))
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
