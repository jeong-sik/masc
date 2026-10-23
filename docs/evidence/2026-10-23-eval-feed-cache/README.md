# Eval Feed cache selection

## Installed reproduction

On 2026-10-23 the installed server `107c58401723313611f7c599bbe15225de5910da`
returned the wrong response shape for an exact-agent query after a fleet read.
All four authenticated read-only requests returned HTTP 200 in the same runtime.
The selected response fields and binary/runtime identities are retained in
`live-baseline.json`; no private eval rows or credentials are published.

| Query | Observed response | Wall time ms |
| --- | --- | ---: |
| `limit=47` | Fleet (`agent_count`, `agents`) | 7.04 |
| `limit=47&agent_name=-` | **Fleet; expected exact-agent result** | 2.12 |
| `limit=48&agent_name=-` | Exact agent `-` (`count`, `snapshots`) | 6.64 |
| `limit=47` | Fleet | 3.22 |

The third request uses a distinct old cache key to demonstrate the endpoint's
existing exact-agent response contract. The fast second answer is incorrect,
not a latency improvement. These samples do not estimate an error rate.

## Repair and controlled before/after

The old key used `-` for an omitted agent, colliding with that literal agent
name. It also included the requested limit for fleet reads, although those
always read one latest snapshot per agent. Absent, empty and whitespace-only
selectors all selected the fleet but prepared redundant entries.

A single match now produces both a tagged JSON identity and its read closure.
Fleet identity has no unused limit; exact-agent identity keeps name and effective
limit. Workspace partitioning, trim/empty behavior, default/clamped limits,
retained reader, TTL, auth and response schemas keep their existing meaning.

| Native router scenario | Before | After |
| --- | --- | --- |
| Fleet followed by literal `-` agent | Wrong fleet shape | Correct agent shape |
| Reverse warmup order | Not reached after original failure | Correct fleet shape |
| Five equivalent fleet reads: preparations | 5 | 1 |
| Exact-agent counts for limits 1 and 2 | 1, 2 | 1, 2 |
| Exact-agent aliases/default/clamp: preparations | 4 | 4 |

The fixture has two agents (`-`, `eval-other`) with two real retained JSON
snapshots each. Both warmup orders, agent names, snapshot ordering, exact row
counts and preparation counts are checked through the actual HTTP router/cache.
No key substitute is used. The two individual baseline logs retain their
original trailing blank line; `git diff --check` reports those two raw-log
EOF whitespace warnings. The old handler fails two cases and passes the
exact-agent control. The candidate passes all three plus eight parent checks:
**11 focused PASS**. Raw failure/candidate logs and SHA-256 bindings are included.

```sh
opam exec --switch=5.5.1 -- dune build test/test_dashboard_http_core.exe
_build/default/test/test_dashboard_http_core.exe test eval_feed_cache_selection
_build/default/test/test_dashboard_http_core.exe test effective_tool_quality_sampling
_build/default/test/test_dashboard_http_core.exe test exact_query_cache_identity
```

Only the explicit test executable was prepared. Full regression and CI were not
run. This computation-count/correctness result is isolated; no candidate
installation, production latency change, UI readiness or screenshot speedup is
claimed. The source/consumer/target chain is the eval-feed HTTP route,
`respond_cached_read` / `Dashboard_cache`, and `test_dashboard_http_core.exe`.

## Separate audit candidate

The existing eval reader concatenates caller-supplied agent names into paths.
Its path boundary needs separate producer/reader contract inspection and an
isolated reproduction. This repair leaves that contract unchanged; no path
security fix or absence of a path issue is claimed here.
