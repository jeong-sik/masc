#!/usr/bin/env python3
"""CI gate: an H2 route arm must not read server state without authorizing.

Background
    Server_bootstrap_http.serve_auto sniffs the connection preface on ONE port
    and hands h2c connections to Server_h2_gateway while everything else goes
    to the HTTP/1 router. The two route tables are written by hand, so the
    wrapper a route gets is decided independently on each side.

    That let POST /graphql diverge: the H1 route wrapped it in
    [with_read_auth], the H2 arm used [with_server_state] -- which fetches the
    server state and applies no authorization at all. An unauthenticated caller
    got 401 over HTTP/1 and an executed query over h2c, so the client's
    protocol choice decided whether authorization applied.

Contract
    Every ``| `METHOD, "/path" ->`` arm whose body calls [with_server_state]
    must either
      (a) authorize itself -- the body names an authorize_*_request call, as
          POST /webrtc/* does, or
      (b) run the MCP admission gate via [verify_mcp_auth].
    Anything else must use [with_h2_public_read], [with_h2_read_auth], or
    [with_h2_token_permission_auth], which mirror the H1 wrappers.

Why source analysis, and why comments are stripped first
    The runtime proof lives in
    scripts/harness/contract/graphql_transport_auth_parity_contract.sh, which
    probes a live server over both transports. That contract can only assert
    the routes it names; this gate is the part that scales to every arm and
    fires when a NEW arm is written.

    Comments are removed before scanning because the first draft of this gate
    counted the word [with_server_state] inside a comment that *documented* the
    fix, and reported a route that was already correctly wrapped. OCaml
    comments nest and can contain string literals, so the stripper below tracks
    depth and quotes rather than pattern-matching (* ... *).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATEWAY = ROOT / "lib" / "server" / "server_h2_gateway.ml"

NON_AUTHORIZING_HELPER = "with_server_state"
SELF_AUTHORIZING = re.compile(r"authorize_[a-z_]+_request|verify_mcp_auth")
ROUTE_ARM = re.compile(r"^\s*\|\s*`(GET|POST|PUT|DELETE|PATCH),")
MIRRORED_WRAPPERS = (
    "with_h2_public_read",
    "with_h2_read_auth",
    "with_h2_token_permission_auth",
)


def strip_comments(source: str) -> str:
    """Blank out OCaml comments, preserving every byte offset and newline.

    Handles nesting ((* a (* b *) c *)) and skips string literals so that a
    "(*" inside a string does not open a comment. Characters are replaced with
    spaces rather than deleted so reported line numbers stay true to the file.
    """
    out = list(source)
    i = 0
    depth = 0
    n = len(source)
    while i < n:
        if depth == 0 and source.startswith('"', i):
            # Skip a string literal verbatim.
            i += 1
            while i < n:
                if source[i] == "\\":
                    i += 2
                    continue
                if source[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if source.startswith("(*", i):
            depth += 1
            out[i] = out[i + 1] = " "
            i += 2
            continue
        if depth > 0 and source.startswith("*)", i):
            depth -= 1
            out[i] = out[i + 1] = " "
            i += 2
            continue
        if depth > 0 and source[i] != "\n":
            out[i] = " "
        i += 1
    return "".join(out)


def main() -> int:
    if not GATEWAY.is_file():
        print(f"FAIL: {GATEWAY} not found (did the H2 gateway move?)", file=sys.stderr)
        return 1

    raw = GATEWAY.read_text(encoding="utf-8")
    code = strip_comments(raw)
    raw_lines = raw.splitlines()
    code_lines = code.splitlines()

    print("=== H2 route auth parity gate ===")

    # Collect (line_index, arm_text) for every route arm, then treat the span
    # up to the next arm as that arm's body.
    arms = [i for i, line in enumerate(code_lines) if ROUTE_ARM.match(line)]
    violations = []
    for pos, start in enumerate(arms):
        end = arms[pos + 1] if pos + 1 < len(arms) else len(code_lines)
        body = "\n".join(code_lines[start:end])
        if NON_AUTHORIZING_HELPER not in body:
            continue
        if SELF_AUTHORIZING.search(body):
            continue
        violations.append((start + 1, raw_lines[start].strip()))

    for lineno, arm in violations:
        rel = GATEWAY.relative_to(ROOT)
        print(
            "FAIL: H2 arm reads server state with no authorization wrapper",
            file=sys.stderr,
        )
        print(f"  {rel}:{lineno}: {arm}", file=sys.stderr)
        print(
            "  Use " + " / ".join(MIRRORED_WRAPPERS)
            + " to mirror the wrapper the HTTP/1 route for this path applies.",
            file=sys.stderr,
        )

    if violations:
        print(
            f"=== H2 route auth parity gate: FAIL ({len(violations)}) ===",
            file=sys.stderr,
        )
        return 1

    scanned = len(arms)
    print(f"PASS: {scanned} H2 route arms scanned; none read state unauthorized")
    print("=== H2 route auth parity gate: PASS ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
