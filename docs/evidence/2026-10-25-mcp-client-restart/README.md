# External MCP credential across server restart — 2026-10-25

Relates #25890. Installed executable build commit:
`d98835aec86ae8c302b4cc43474c249ef1425d29` (also the source base inspected).
The executable SHA-256 and actual results are in [result.json](result.json).

## Actual scope

[probe.py](probe.py) invokes the installed `masc mcp-config` command once with a
fresh, private workspace, dedicated Worker agent and `claude-desktop` config
renderer. It parses that real emitted config, uses its actual bearer, and checks
the generated URL and authorization-header template. It never remints the client
credential between server processes. This probe implements the HTTP MCP client;
it does not launch npx/mcp-remote, Claude Desktop or Codex.

Two real `masc start` processes run sequentially on the same private base/port.
Each process must reach `/health/ready`, and `/health?full=1` must identify the
expected base and `.masc` root. Each process rejects an unauthenticated initialize
with401. The same static client bearer then succeeds at initialize, initialized
notification, tools/list (54 tools), and tools/call for `masc_tool_help` about
`masc_status`. The two returned session IDs must differ. The original raw client
credential value (after stripping surrounding whitespace) must remain unchanged, while the internal Keeper token hash
must change between server processes. Both server processes are terminated and
reaped, and the private credentials, raw responses and server logs are deleted.
Only non-secret assertions, counts and executable identity are published.

The protocol client supports the actual JSON and SSE response forms. The
[official Streamable HTTP contract](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports)
requires both response forms and distinguishes bearer authentication from the
MCP session ID. This is actual HTTP behavior against the installed binary, not a
fixture server, source-only test, CI run or production restart.

## Reproduce

Run from the repository root with Python3 and an installed MASC binary:

```bash
python3 docs/evidence/2026-10-25-mcp-client-restart/probe.py \
  --binary "$(command -v masc)" \
  --output /tmp/masc-mcp-restart-result.json
```

The probe selects a currently free loopback port, clears inherited server bearer
variables for its own subprocesses, and uses a fresh temporary base. A competing
process taking that port makes this execution fail; it does not take over or stop
an existing listener. The60-second readiness observation bound is a harness
failure boundary, not a Keeper behavior or credential-lifetime gate.

## Failed probe revisions and limits

Four initial probe executions failed before a complete restart verdict: macOS
`/var` versus `/private/var` path comparison; using liveness before MCP readiness
(which correctly returned503); failing to recognize an SSE response with an
initial id/comment line; and assuming the obsolete tool name `masc_help` instead
of reading current `masc_tool_help` metadata. These are probe failures and are
not passing executions or product authentication defects. The final probe waits
for readiness, canonicalizes its own temp root, handles SSE data rows and calls
the actual registered tool with its required argument. A subsequent run adds an
explicit distinct-session assertion; its final result is recorded separately in
result.json rather than claiming an older run executed that assertion.

#25890 remains open for actual configured external-client recovery, including
app-specific restart/reconnect behavior. This proof establishes that the current
per-client credential survives a server-process restart while the internal token
rotates; it does not inspect every user config, change the production runtime,
or prove an app reconnects automatically. The referenced `/Users/dancer/me/.mcp.json`
was inspected without reading/publishing credential values: the MASC entry now
uses headersHelper and has no static Authorization header. No user config was
modified. No local builds, full regression or CI were requested.
