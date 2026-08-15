#!/usr/bin/env python3
"""Measure the live web tool surface: provider endpoints and MCP tool calls.

Captures, per run, into one JSON evidence file:
  - provider_direct: SearXNG / DuckDuckGo HTML / Bing RSS reachability,
    latency, and result counts measured against the real endpoints.
    When OLLAMA_API_KEY is present, the Ollama cloud web_search endpoint
    is probed with the same auth and body shape the server uses.
  - mcp_tool: masc web search/fetch calls against the running MASC server
    (default http://localhost:8935/mcp), with wall time, serialized payload
    bytes, and the body-duplication factor of the includeContent path
    (page_content chars vs content_text chars carried in one payload).

The DuckDuckGo/Bing probes measure external endpoints masc no longer
uses as providers — their run-to-run instability is the evidence the
provider cut rests on, so the probes stay as time-series instruments.

Stdlib only. Every failure is recorded as data, never swallowed:
each probe result carries either measurements or an "error" field.

Usage:
  python3 scripts/bench-web-tools.py -o docs/evidence/web-tools-bench.json
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

SEARXNG_URL = os.environ.get("MASC_SEARXNG_URL", "http://localhost:8888")
MCP_URL = os.environ.get("MASC_MCP_URL", "http://localhost:8935/mcp")
HEALTH_URL = os.environ.get("MASC_HEALTH_URL", "http://localhost:8935/health")
BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
)
TIMEOUT_SEC = 25

QUERIES = [
    "OCaml 5.5 effect handlers tutorial",
    "Claude Opus latest model context window",
    "장마철 제습기 원리",
]
FETCH_URL = "https://ocaml.org/manual/5.4/index.html"


def http(
    url: str,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, dict[str, str], bytes, float]:
    """One HTTP round trip. Returns (status, headers, body, elapsed_ms)."""
    req = urllib.request.Request(url, data=body, headers=headers or {})
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SEC) as resp:
            payload = resp.read()
            elapsed = (time.monotonic() - start) * 1000.0
            return resp.status, dict(resp.headers.items()), payload, elapsed
    except urllib.error.HTTPError as err:
        payload = err.read()
        elapsed = (time.monotonic() - start) * 1000.0
        return err.code, dict(err.headers.items()), payload, elapsed


def probe(fn, *args) -> dict[str, Any]:
    """Run one probe; transport-level failure becomes an error record."""
    try:
        return fn(*args)
    except Exception as exn:  # record, never swallow
        return {"error": f"{type(exn).__name__}: {exn}"}


def probe_searxng(query: str) -> dict[str, Any]:
    url = f"{SEARXNG_URL}/search?q={urllib.parse.quote(query)}&format=json"
    status, _, body, ms = http(url)
    record: dict[str, Any] = {
        "query": query,
        "http_status": status,
        "elapsed_ms": round(ms, 1),
        "bytes": len(body),
    }
    parsed = json.loads(body)
    results = parsed.get("results", [])
    engines = sorted({r.get("engine", "?") for r in results})
    record.update({"result_count": len(results), "engines": engines})
    return record


def probe_ddg_html(query: str) -> dict[str, Any]:
    url = f"https://html.duckduckgo.com/html/?q={urllib.parse.quote(query)}"
    status, _, body, ms = http(url, headers={"User-Agent": BROWSER_UA})
    text = body.decode("utf-8", errors="replace")
    return {
        "query": query,
        "http_status": status,
        "elapsed_ms": round(ms, 1),
        "bytes": len(body),
        "result_anchor_count": len(re.findall(r'class="result__a"', text)),
    }


def probe_bing_rss(query: str) -> dict[str, Any]:
    url = f"https://www.bing.com/search?format=rss&q={urllib.parse.quote(query)}"
    status, _, body, ms = http(url, headers={"User-Agent": BROWSER_UA})
    text = body.decode("utf-8", errors="replace")
    return {
        "query": query,
        "http_status": status,
        "elapsed_ms": round(ms, 1),
        "bytes": len(body),
        "item_count": text.count("<item>"),
    }


def probe_ollama(api_key: str, query: str) -> dict[str, Any]:
    """One live call against the credentialed provider masc dispatches to.

    Same endpoint, auth header, and body shape as fetch_ollama in
    lib/tool_misc_web_search.ml, so the numbers here measure the provider
    the server actually uses rather than a lookalike.
    """
    status, _, body, ms = http(
        "https://ollama.com/api/web_search",
        body=json.dumps({"query": query, "max_results": 5}).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    record: dict[str, Any] = {
        "query": query,
        "http_status": status,
        "elapsed_ms": round(ms, 1),
        "bytes": len(body),
    }
    parsed = json.loads(body)
    results = parsed.get("results")
    if results is None:
        record["error_payload"] = parsed
        return record
    record.update(
        {
            "result_count": len(results),
            "content_chars_total": sum(len(r.get("content", "")) for r in results),
            "top_urls": [r.get("url", "") for r in results[:3]],
        }
    )
    return record


def token_candidates() -> list[tuple[str, str]]:
    """Bearer token candidates, most likely first: MASC_MCP_TOKEN env,
    then every ``<base>/.masc/auth/*.token`` file newest-first (tokens
    rotate, so a stale env value must not end the search). Returns
    (label-for-evidence, token value) pairs; labels never carry the value."""
    pairs: list[tuple[str, str]] = []
    from_env = os.environ.get("MASC_MCP_TOKEN")
    if from_env:
        pairs.append(("env:MASC_MCP_TOKEN", from_env.strip()))
    base = os.environ.get("MASC_BASE_PATH", os.path.expanduser("~/me"))
    files = glob.glob(os.path.join(base, ".masc", "auth", "*.token"))
    for path in sorted(files, key=os.path.getmtime, reverse=True):
        with open(path, encoding="utf-8") as handle:
            pairs.append((os.path.basename(path), handle.read().strip()))
    return pairs


class McpClient:
    """Minimal JSON-RPC client for the MASC streamable-HTTP MCP endpoint."""

    def __init__(self, url: str, token: str | None):
        self.url = url
        self.token = token
        self.session_id: str | None = None
        self.next_id = 0

    def rpc(self, method: str, params: dict[str, Any]) -> tuple[dict[str, Any], float, int]:
        """Returns (parsed JSON-RPC response, elapsed_ms, raw_body_bytes)."""
        self.next_id += 1
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        body = json.dumps(
            {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}
        ).encode()
        status, resp_headers, payload, ms = http(self.url, body=body, headers=headers)
        for key, value in resp_headers.items():
            if key.lower() == "mcp-session-id":
                self.session_id = value
        text = payload.decode("utf-8", errors="replace")
        content_type = next(
            (v for k, v in resp_headers.items() if k.lower() == "content-type"), ""
        )
        if status >= 400:
            raise RuntimeError(f"HTTP {status}: {text[:300]}")
        if "text/event-stream" in content_type:
            data_lines = [
                line[len("data:"):].strip()
                for line in text.splitlines()
                if line.startswith("data:")
            ]
            if not data_lines:
                raise RuntimeError(f"SSE response without data lines: {text[:300]}")
            text = data_lines[-1]
        try:
            return json.loads(text), ms, len(payload)
        except json.JSONDecodeError as err:
            raise RuntimeError(
                f"{method}: non-JSON body status={status} "
                f"content_type={content_type!r} head={text[:160]!r}"
            ) from err


def tool_text_payload(rpc_result: dict[str, Any]) -> str:
    """Concatenate the text content blocks the model would receive."""
    content = rpc_result.get("result", {}).get("content", [])
    return "".join(
        block.get("text", "") for block in content if block.get("type") == "text"
    )


def content_duplication(payload_text: str) -> dict[str, Any]:
    """Measure how many times the fetched bodies ride in one payload."""
    try:
        parsed = json.loads(payload_text)
    except json.JSONDecodeError:
        return {"parse": "non-json payload"}
    result = parsed.get("result", parsed)
    hits = result.get("results", [])
    page_content_chars = sum(
        len(hit.get("page_content", "")) for hit in hits if isinstance(hit, dict)
    )
    content_text_chars = len(result.get("content_text", ""))
    return {
        "hit_count": len(hits),
        "page_content_chars_total": page_content_chars,
        "content_text_chars": content_text_chars,
        "both_fields_present": page_content_chars > 0 and content_text_chars > 0,
    }


def authenticated_client(url: str) -> tuple[McpClient, dict[str, Any]]:
    """Try each token candidate until initialize succeeds. Auth failures
    per candidate are recorded, not swallowed; exhausting all candidates
    raises with the full attempt trail."""
    attempts: list[str] = []
    for label, token in token_candidates() or [("no-token", "")]:
        client = McpClient(url, token or None)
        try:
            init, ms, _ = client.rpc(
                "initialize",
                {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "bench-web-tools", "version": "0"},
                },
            )
        except RuntimeError as err:
            attempts.append(f"{label}: {err}")
            continue
        return client, {
            "auth_source": label,
            "auth_attempts_rejected": len(attempts),
            "initialize_ms": round(ms, 1),
            "server_info": init.get("result", {}).get("serverInfo", {}),
        }
    raise RuntimeError("no token candidate accepted: " + " | ".join(attempts))


def probe_mcp(url: str) -> dict[str, Any]:
    client, record = authenticated_client(url)
    record["url"] = url

    listing, _, _ = client.rpc("tools/list", {})
    tool_names = [t.get("name", "") for t in listing.get("result", {}).get("tools", [])]
    web_search = next((n for n in tool_names if re.fullmatch(r"(?i)(masc_)?web_?search", n)), None)
    web_fetch = next((n for n in tool_names if re.fullmatch(r"(?i)(masc_)?web_?fetch", n)), None)
    record["tool_count"] = len(tool_names)
    record["web_search_tool"] = web_search
    record["web_fetch_tool"] = web_fetch
    if web_search is None or web_fetch is None:
        # Absence claim needs the untrimmed listing: record every name so
        # "no web tool on this surface" is verifiable from the evidence.
        record["tool_names"] = sorted(tool_names)

    if web_search:
        args = {"query": QUERIES[0], "limit": 5}
        plain, ms, raw = client.rpc("tools/call", {"name": web_search, "arguments": args})
        text = tool_text_payload(plain)
        record["web_search_plain"] = {
            "elapsed_ms": round(ms, 1),
            "raw_response_bytes": raw,
            "payload_chars": len(text),
            "is_error": plain.get("result", {}).get("isError", False),
        }
        enriched_args = {**args, "includeContent": True, "contentMaxChars": 2000}
        enriched, ms, raw = client.rpc(
            "tools/call", {"name": web_search, "arguments": enriched_args}
        )
        text = tool_text_payload(enriched)
        record["web_search_enriched"] = {
            "elapsed_ms": round(ms, 1),
            "raw_response_bytes": raw,
            "payload_chars": len(text),
            "is_error": enriched.get("result", {}).get("isError", False),
            "duplication": content_duplication(text),
        }

    if web_fetch:
        fetched, ms, raw = client.rpc(
            "tools/call", {"name": web_fetch, "arguments": {"url": FETCH_URL}}
        )
        text = tool_text_payload(fetched)
        record["web_fetch"] = {
            "url": FETCH_URL,
            "elapsed_ms": round(ms, 1),
            "raw_response_bytes": raw,
            "payload_chars": len(text),
            "is_error": fetched.get("result", {}).get("isError", False),
        }
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--output", required=True, help="evidence JSON path")
    args = parser.parse_args()

    health = probe(lambda: dict(json.loads(http(HEALTH_URL)[2])))
    evidence = {
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "script": "scripts/bench-web-tools.py",
        "server_health": {
            key: health.get(key)
            for key in ("status", "version", "commit", "commit_source")
        }
        if "error" not in health
        else health,
        "provider_direct": {
            "searxng": [probe(probe_searxng, q) for q in QUERIES],
            "duckduckgo_html": probe(probe_ddg_html, QUERIES[0]),
            "bing_rss": probe(probe_bing_rss, QUERIES[0]),
            "ollama": [probe(probe_ollama, ollama_key, q) for q in QUERIES]
            if (ollama_key := os.environ.get("OLLAMA_API_KEY"))
            else {"skipped": "OLLAMA_API_KEY absent"},
        },
        "mcp_tool": probe(probe_mcp, MCP_URL),
    }
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(evidence, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
