# Runtime ERROR audit, 2026-09-29

## Measured scope

Read `/Users/dancer/me/.masc/logs/system_log_2026-09-{28,29}.jsonl` once,
selecting `level == "ERROR"` within **2026-09-28 01:08:51 through
2026-09-29 01:08:51 UTC, inclusive** (10:08:51 KST to 10:08:51 KST).
The same window contained 306,311 INFO, 20,169 WARN and **1,554 ERROR rows**.
No malformed JSON rows were encountered. This is a recent 24-hour baseline,
not an all-history audit. Stderr and restart logs were inspected for context
but excluded from totals to avoid counting the same sink event again.

`summary.json` contains the partitioned totals and tool counts.
`error-index.jsonl` preserves all 1,554 source file/line/sequence identities.
Raw prompts, tool arguments and provider response bodies are not republished.
The source logs remain in the runtime directory. The local extraction is also
available at `/tmp/masc-error-audit/errors.json` while that temporary directory
is retained.

The `/health?full=1` snapshot in `health.json` confirms base path
`/Users/dancer/me` and runtime root `/Users/dancer/me/.masc`. The server answered
`status=ok` but `overall_status=degraded`, with runnable backlog 36 and
recoverable backlog 4. This snapshot was during startup (96 seconds uptime).
It does not establish a persistent backlog failure.

The running binary reported **c183bd896cdc4b7ad4b3a2addd4865ef643220cd**;
the audited source base is **0f70e5fe8bf3d94d687e51e08f56ce8e5c8b8ae4**.
The 24-hour window spans multiple starts; the health commit identifies only
the instance observed at collection, not every historical row.

To reselect the same ERROR rows from retained source files:

```sh
jq -c 'select(.level == "ERROR" and .ts >= "2026-09-28T01:08:51Z" and .ts <= "2026-09-29T01:08:51Z")' \
  /Users/dancer/me/.masc/logs/system_log_2026-09-28.jsonl \
  /Users/dancer/me/.masc/logs/system_log_2026-09-29.jsonl
```

## ERROR partition

| Family | Rows | Interpretation |
|---|---:|---|
| Keeper cycle FAILED | 310 | Terminal turn failure logs, potentially after multiple provider attempts |
| Board recovery generation mismatch | 315 | 105 worker-failure reports, each logged at three layers; 12 Keepers affected |
| Tool-call error | 687 | Canonical per-call error lines; includes expected argument/state rejections |
| Inner tool error | 66 | Frequently duplicates the canonical per-call error line |
| Keeper request error | 39 | `keeper tool call failed: masc_keeper_msg` |
| Other | 137 | Includes 90 owner-inventory-stopping messages; remaining MCP and runtime errors |
| Total | 1,554 | Log rows, **not 1,554 independent incidents** |

Most frequent tools in the 687 call rows: Read 174, WebFetch 54, Edit 46,
masc_board_post_get 43, Execute 43, github_pull_request_read 37, Grep 32,
keeper_artifact_read 26, keeper_skill 23 and BrowserRead 22.
Tool rejection is not evidence of a server crash. For example, comment_tail=0
violates the documented minimum, edits can fail to match, and Read can request
a nonexistent or unauthorized path. No permission rules were weakened.

## Actions and remaining work

| Priority | Finding | Evidence and disposition |
|---|---|---|
| P1 | Board worker recovery stops on a later authorized Ready generation | 315 rows / 105 worker-failure reports. Already addressed in source by [#39784](https://github.com/jeong-sik/masc/pull/39784). The observed binary predates it. Deployment and a post-start worker check remain required. Do not manually rewrite the persisted generation. |
| P1 | Provider attempts end in network/timeout/quota/credential/effect-fence failures | 310 cycle failures. Final runtime labels include Ollama Cloud 86, Muse 72, Kimi 30 and Codex sol-high 30. These are final selected runtimes, not attribution of all failed attempts. Preserve the effect fence where an upstream turn may still commit; do not blindly replay side effects. Network and account readiness need separate live investigation. |
| P2 | Web search conflates a valid zero-hit response with malformed provider output | 15 WebSearch calls, 30 rows across two logging layers, with `searxng: transport: search endpoint unavailable (curl exit code 7); ollama: parse: no results`. First inner row: `system_log_2026-09-28.jsonl:87323`; last canonical row: `system_log_2026-09-29.jsonl:7046`. This PR repairs the parsing and fallback contract described below. |
| P2 | SSH shim cannot read its config | 11 Read calls / 22 rows mention `/opt/masc-exec-shim/masc-exec-shim.conf`. [#39788](https://github.com/jeong-sik/masc/pull/39788) was already open to preserve the OS cause. Config provisioning/reachability itself is not proven fixed. |
| P2 | GitHub credential no longer accepted | 40 tool-call rows, including 37 github_pull_request_read calls. Keep the credential value private; confirm the affected account before reattaching it. This change does not rotate credentials. |
| P2 | Antigravity managed OAuth config invalid | Two cycle rows explicitly mention `antigravity_home`; truncated messages do not establish the exact account-file defect. Inspect the typed/config evidence before changing it. |
| P3 | Owner inventory stopping errors | 90 rows in the other category. The text is consistent with shutdown races, but the audit does not prove shutdown is their only cause. Reproduce lifecycle ordering before changing severity or suppressing errors. |

## Web search change

The old parsers turned invalid JSON, absent result arrays, unusable entries,
and valid empty arrays into the same empty list. The provider chain then
manufactured `Parse "no results"`. The log cannot tell which payload produced
the 15 observed failures; no raw provider response was captured, so claiming
all 15 were false positives would be unsupported.

The changed parsers return typed `Parse` errors for malformed/absent result
arrays and nonempty arrays with no usable entries. Valid empty arrays stay
successful. The chain still tries later providers for hits, then returns the
first valid empty answer if there are none. `provider_errors` retains failures
alongside successful fallback results. No provider configured and every
provider failed remain explicit errors. A SearxNG empty answer with
`unresponsive_engines` stays an error instead of caching an engine outage.

The response shape is grounded in the [Ollama API documentation](https://docs.ollama.com/capabilities/web-search)
and [SearxNG search API](https://docs.searxng.org/dev/search_api.html).
The [SearxNG JSON formatter](https://github.com/searxng/searxng/blob/master/searx/webutils.py)
provides the `unresponsive_engines` evidence. Provider-specific absence forms,
such as Brave's nullable `web` section, remain rejected as before; this change
recognizes explicit empty arrays rather than claiming to cover every no-hit
representation.
The production and simulated provider chains now share the same traversal.

## Validation boundary

- `git diff --check`, source text integrity, cancel guard and wildcard-only
  match lint: passed. The initially attempted `scripts/lint-cancel-guard.sh`
  path was absent; the current `scripts/ci/check-cancel-guard.py` passed.
- Audit index consistency: 1,554 distinct file/line identities, family totals
  reconcile, and tool counts sum to 687.
- Added scenarios for empty plus failed providers in either order, empty then
  later hits, malformed versus explicit empty arrays, and SearxNG engine outage.
  A dispatch/cache scenario covers failure, recovery to a grounded empty answer,
  and a repeated cached read with the original provider-error evidence.
- Existing parser and failure scenarios updated to the typed result contract.
- No local Dune build, runtime restart, credential change or live queue mutation.
- OCaml build and scenario execution require the PR's CI. A source change or
  green build alone does not prove the running fleet recovered. Recollect the
  same window after deployment and verify provider/Board continuity separately.
