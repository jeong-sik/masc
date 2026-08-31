---
status: reference
---

# Dashboard

> Part of: [SPEC-INDEX](./SPEC-INDEX.md)

## 1. Purpose and authority

The dashboard is an observable projection and interaction surface for MASC. It
does not own Keeper lifecycle, Tool authorization, Task/Goal transitions, or
runtime selection. Writes call the same typed domain APIs used by other clients;
the dashboard never edits persistence directly.

## 2. Source projections

The UI projects source facts from:

- Keeper lanes, turns, transcripts, Jobs, and lifecycle events;
- Task and Goal versions, judgments, and evidence references;
- Board posts, comments, reactions, mentions, and LLM curation snapshots;
- Channel/Connector scope and message correlations;
- Gate pending/resolved records and LLM/operator provenance;
- Fusion panel runs, individual results, Judge results, and failures;
- Memory events and consolidation provenance;
- agent core runtime/provider/model call telemetry.

Every projection retains the source id, version, timestamp, and correlation
needed to trace it back. Missing source data renders as an explicit unavailable
or error state, never as a fabricated empty success.

## 3. Keeper chat

Keeper chat preserves the provider stream order and renders interleaved:

- user/assistant/system text;
- reasoning or thinking parts exposed by the provider contract;
- tool calls and tool results joined by typed call id;
- images, audio, voice, files, and other multimodal parts;
- Job, Fusion, and Gate references;
- errors and cancellation.

The UI does not reconstruct this order from timestamps or string prefixes. It
uses the durable sequence emitted by the turn boundary. Sending a message
appends a typed stimulus to that Keeper's lane; it does not demand an immediate
turn when the Keeper is busy.

## 4. Gate UI

The Gate view exposes the configured mode and durable request state:

- `Always_allow` dispatch evidence;
- `Auto_judge` verdict, rationale, runtime/model, and evidence;
- `Manual` pending request and explicit operator resolution.

The dashboard does not calculate risk tiers, recognize product/tool names, or
invent local vetoes. Resolving one request wakes only its originating Keeper
lane. Pending HITL does not render the Keeper or Workspace as paused.

## 5. Task, Goal, Board, and Fusion

Task and Goal controls send expected versions and display conflicts. Goal
completion shows configured LLM judgment provenance; the UI does not aggregate
votes or assign verifier authority.

Board views render exact source ordering such as recent, updated, discussed,
or voted. Semantic recommendations come from a separately persisted configured
LLM curation snapshot. Karma, flair, reputation, hot/trending formulas, and
author-status inference are not dashboard contracts.

Fusion is asynchronous. The UI shows every panel result/failure followed by the
Judge result. It never treats minimum answer count, majority, cost, or timeout
as semantic authority.

The Fusion run registry owns lifecycle observation. Exact detail is a read-only
join between one retained registry run and the Board typed-origin index. A Board
post is evidence only when `origin.source` is exactly `fusion` and
`origin.fusion_run_id` exactly matches the run. The projection reports Board
evidence as `recorded`, `pending`, or `absent`; only a running registry row may
be `pending`. Clients must not recover this join by searching post titles,
bodies, or `meta_json`. `absent` means no current Board projection; it does not
claim whether a post never existed or expired after its retention window.

Running registry rows also expose a typed process-local stage (`accepted`,
`panel`, `judge`, `computed`, or `recording_evidence`) and producer-observed
panel counts. Stage observation is not resumable: replay drops stale running
workers. Current successful completions may add a bounded decision and resolved
answer summary; legacy success records without those additive fields remain
valid. These previews improve scanning but do not replace the exact Board
evidence join.

## 6. Transport isolation

HTTP snapshots use cursor-based reads. SSE/WebSocket events carry typed event
names and payload codecs shared with the backend. A slow or disconnected client
affects only that connection; it cannot block publishers, Keeper lanes, or other
clients.

Request timeouts and cache eviction are transport-local failures. They are
observed and retried by the client as appropriate, but never change Keeper
lifecycle or product state. The dashboard may cache immutable/versioned
snapshots; it must not create a second mutable SSOT.

## 7. Observability

The dashboard exposes turn duration, time-to-first-token, token throughput,
provider/model, tool latency, Job/Fusion/Gate latency, queue position, failures,
and correlation ids. Metrics explain behavior; they do not authorize it.

All error surfaces include a typed code and trace/correlation where available.
Filtering and text search are presentation functions only and do not reclassify
source state.

## 8. Required invariants

- `INV-DASH-001`: every rendered state is traceable to a typed source fact.
- `INV-DASH-002`: every mutation uses the owning domain API and expected version.
- `INV-DASH-003`: stream order preserves thinking/tool/multimodal interleaving.
- `INV-DASH-004`: connection failure is client-local.
- `INV-DASH-005`: no presentation classifier acquires runtime authority.
- `INV-DASH-006`: Gate decisions and Goal judgments display provenance.
- `INV-DASH-007`: pending HITL never becomes a Keeper/Workspace pause.
