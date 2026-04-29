# masc-mcp performance baseline — report template

This template is the **canonical layout** that `scripts/perf-baseline.sh`
emits and that every optimisation PR (RFC PR-0.2 follow-ups: cache,
GC, WebSocket framing, MCP latency) must reuse for its before/after
table. Copy it verbatim, fill the values, and link the source dump.

> **Operating context** (RFC PR-0.2 Q&A)
> - 12+ keepers on a single Railway instance.
> - 50+ keepers is aspirational, not the target.
> - All threshold rationale must reference the **measured** baseline,
>   not the strategy doc's fictitious estimates (cache 41x, GC 18%, etc.).

## 1. Run metadata

| field | value |
|-------|-------|
| date (UTC) | `YYYY-MM-DD` |
| timestamp (UTC) | `YYYY-MM-DDThh:mm:ssZ` |
| git sha | `<12-char>` |
| label | `default` \| `cold` \| `warm` \| `<custom>` |
| host | `railway-prod` \| `local-mac-m3` |
| keeper count (live) | `<int>` |
| process uptime | `<duration>` |
| OCAMLRUNPARAM | e.g. `e=1` (runtime_events on?) |

## 2. Required metric table

Every PR submission must populate **all rows below**. Cells that
cannot be measured yet must read `not exported` plus a link to the
follow-up issue, never `0` or `n/a` without justification.

### 2.1 Cache hit ratio

| metric | baseline | after | delta | source |
|--------|---------:|------:|------:|--------|
| `masc_ws_parse_cache_hits_total / (hits+misses)` |  |  |  | `/metrics` |
| `masc_ws_bytes_cache_hits_total / (hits+misses)` |  |  |  | `/metrics` |
| `dashboard_cache_*` (Phase 0.2.A) | not exported | | | `lib/dashboard/dashboard_cache.ml` |
| `cache_eio_*` (Phase 0.2.A) | not exported | | | `lib/cache_eio.ml` |

### 2.2 WebSocket framing

| metric | baseline | after | delta | source |
|--------|---------:|------:|------:|--------|
| `masc_ws_sessions_total` |  |  |  | counter |
| `masc_ws_bytes_sent_total` |  |  |  | counter (bytes) |
| `masc_ws_client_buffered_bytes` |  |  |  | gauge |
| `masc_ws_throttled_deliveries_total` |  |  |  | counter |
| message size P50/P95/P99 (Phase 0.2.B) | not histogrammed | | | `masc_ws_message_bytes` |
| RTT P50/P95/P99 (Phase 0.2.B) | not histogrammed | | | `masc_ws_rtt_seconds` |

### 2.3 MCP tool-call latency

| metric | baseline | after | delta | source |
|--------|---------:|------:|------:|--------|
| `masc_tool_call_total` |  |  |  | counter |
| `masc_tool_call_duration_seconds` P50 |  |  |  | histogram |
| `masc_tool_call_duration_seconds` P95 |  |  |  | histogram |
| `masc_tool_call_duration_seconds` P99 |  |  |  | histogram |
| cold-call P95 (Phase 0.2.C) | not labelled | | | needs `phase=cold` |
| warm-call P95 (Phase 0.2.C) | not labelled | | | needs `phase=warm` |

### 2.4 GC pauses and RSS

| metric | baseline | after | delta | source |
|--------|---------:|------:|------:|--------|
| host RSS (kB) |  |  |  | `/proc/<pid>/status` or `ps -o rss=` |
| `masc_process_open_fds` |  |  |  | gauge |
| GC minor pause P99 (Phase 0.2.D) | not exported | | | `Gc.quick_stat` sampler |
| GC major pause P99 (Phase 0.2.D) | not exported | | | `Gc.quick_stat` sampler |
| heap_words (Phase 0.2.D) | not exported | | | `Gc.quick_stat` sampler |
| live_words (Phase 0.2.D) | not exported | | | `Gc.quick_stat` sampler |

### 2.5 Eio runtime / fibers

| metric | baseline | after | delta | source |
|--------|---------:|------:|------:|--------|
| `masc_active_agents` |  |  |  | gauge |
| `masc_keeper_alive_total` |  |  |  | counter |
| `masc_keeper_turns_total` |  |  |  | counter |
| active-fiber count (Phase 0.2.E) | not exported | | | needs runtime_events extension |
| io-wait P95 (Phase 0.2.E) | not exported | | | needs runtime_events extension |

## 3. Acceptance gate (template wording for follow-up PRs)

A follow-up optimisation PR is mergeable only if **every claim in the
PR description is backed by the table above**. The expected wording:

> Baseline (sha `<12>`, label=`default`, ${N} keepers): `<row>` =
> `<value>`. After: `<value>`. Delta: `<absolute>` (`<percent>`).
> Source dump: `reports/perf-baseline-YYYY-MM-DD.md`.

PRs that cite the strategy-doc estimates (cache 41x, GC 18% etc.)
without a concrete row from this table fail the gate. The gate is
enforced by reviewer judgement; no CI check is wired yet (Phase
0.2.F).

## 4. Known measurement gaps (as of 2026-04)

| area | gap | follow-up phase |
|------|-----|----------------|
| cache | only WS parse/bytes caches export hit/miss; in-process caches do not | 0.2.A |
| websocket | only counters; no message-size or RTT histograms | 0.2.B |
| mcp latency | no cold-vs-warm split | 0.2.C |
| gc | OCaml `Gc.quick_stat` not exported as gauge family | 0.2.D |
| eio | runtime_events emits turn span only; no io-wait or fiber-count span | 0.2.E |
| ci | no automatic baseline diff in PR check | 0.2.F |

## 5. Reading the daily file

`scripts/perf-baseline.sh` appends one snapshot block per run to
`reports/perf-baseline-YYYY-MM-DD.md`. To compare two snapshots
(e.g. before/after a PR landed), use the index table at the top of
the daily file plus the section headers (`## Cache hit ratios
(<ts>, label=<l>, sha=<sha>)`). The 14-day window means the latest
14 daily files form the rolling baseline; older files may be archived.
