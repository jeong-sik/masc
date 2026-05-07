# Server HTTP Routes Surface Audit — Phase 2 (verdict refinement)

**Date**: 2026-04-30
**Scope**: same as Phase 1 — 16 domain route modules + ~10 infrastructure files
**Pattern**: 4-phase audit (`docs/process/AUDIT-CHAIN-4-PHASE-PATTERN.md`)
**Phase 1**: PR #12213

## 1. Phase 1 → Phase 2 deltas

| Class | Phase 1 estimate | Phase 2 actual | Direction |
|---|---|---|---|
| C1 — no body size-limit guard | 8–12 | **gap real, no platform enforcement** | confirmed |
| C2 — no per-request telemetry | 14–16 | **14 silent / 2 emit** | confirmed in middle of range |
| C3 — error envelope inconsistency | 10–14 | **3 distinct shapes** | narrowed by ~3× |
| C4 — no auth check | 3–5 | **0** (100% covered) | gap collapse |
| C5 — anchors | 4–6 | **2** (`channel_gate`, `frontend`) | narrowed |

Two collapses (C4 to 0, C5 to 2 from 4–6), one significant narrowing (C3 from 10–14 to 3), one confirmation (C2 in the middle of the range). C1 is the inverse: Phase 2 confirms the gap is real because no platform-level enforcement exists.

## 2. Per-class structural findings

### 2.1 C1 — Body size-limit (gap real, no platform fallback)

Searched `lib/http_server*.ml`, `lib/server/server_bootstrap_http.ml`, and `Http_server_eio` callsites for `max_body_size|body_limit|content_length_limit|Body.length` enforcement at the platform layer.

Result: **none found**. Neither `http_server_eio.ml` nor `http_server_h2.ml` enforces body size limits globally. Per-route enforcement is also absent for upload-heavy routes (`legendary_bash`, `multimodal`, `artifacts`).

Implication: the C1 ratchet stays. Recommend Phase 3 implements a single shared middleware in `server_routes_http_common.ml` that takes a domain-specific cap, then caps `legendary_bash` at command-arg max length, `multimodal` at upload max, `artifacts` at blob max.

### 2.2 C2 — Telemetry (14 silent, 2 emit)

Per-domain-module Prometheus search:

| Module | Prometheus calls | Status |
|---|---|---|
| `channel_gate` | 2 | C5 anchor |
| `frontend` | 1 | C5 anchor |
| `activity` | 0 | C2 silent |
| `artifacts` | 0 | C2 silent |
| `attribution` | 0 | C2 silent |
| `autonomous` | 0 | C2 silent |
| `cascade` | 0 | C2 silent |
| `dashboard` | 0 | C2 silent |
| `git_graph` | 0 | C2 silent |
| `legendary_bash` | 0 | C2 silent |
| `multimodal` | 0 | C2 silent |
| `provider_runs` | 0 | C2 silent |
| `resilience` | 0 | C2 silent |
| `room` | 0 | C2 silent |
| `sidecar` | 0 | C2 silent |
| `verification` | 0 | C2 silent |

`server_routes_http_common.ml` — does **not** provide telemetry middleware. There is no shared instrumentation hook; each module would need to emit per-handler counters explicitly.

Total silent: **14**. Phase 1 estimated 14–16 — confirmed at the lower bound.

### 2.3 C3 — Error envelope shapes (3 distinct)

Sampled error returns across activity, artifacts, cascade, dashboard, room:

| Shape | Example | Modules |
|---|---|---|
| A | `{"error": "<string>"}` | activity, dashboard, room |
| B | `{"error": "<string>", "<field>": ...}` extended | artifacts |
| C | `{"ok": false, "error": "<string>"}` wrapper | cascade |

Phase 1 estimated 10–14 inconsistencies. Phase 2 finds **3 shape classes** (a 3-4× narrowing), some of which differ across modules but cluster into a small set. Convergence to one envelope is feasible in Phase 3 with a shared `error_response` helper.

### 2.4 C4 — Auth check coverage (gap collapse)

All 16 domain route modules use `with_tool_auth` or `with_public_read` guards. The intentionally-public routes (`/health`, `/metrics`, frontend assets) are inside `frontend.ml` and properly use `with_public_read`.

C4 collapses to **0 unprotected routes**. Phase 1 estimated 3–5 candidates — that estimate was **wrong in over-counting**, the opposite of the usual conservative-bias direction. The pattern doc notes Phase 1 estimates can err in either direction; this is a clear instance.

### 2.5 C5 — Anchors (2 confirmed)

Only `channel_gate` and `frontend` have telemetry **and** auth. Phase 1 estimate of 4–6 anchors was based on filename-keyword inference. Phase 2 narrows to 2 via Prometheus-call grep. These two modules become Phase 3's reference patterns for the 14 silent modules.

## 3. Refined ratchet floors

```
http_routes_with_telemetry          (INC, floor 2)
  Current: 2 (channel_gate, frontend). Each Phase 3 PR should
  raise this monotonically as silent modules add counters.

http_routes_error_envelope_shapes   (DEC, floor 3)
  Current: 3 distinct shapes. Phase 3 collapses via shared
  error_response helper toward floor 1.

http_routes_size_limit_coverage     (INC, floor 0)
  Current: 0 routes have explicit caps. Phase 3 adds at least
  3 (legendary_bash, multimodal, artifacts) to break the floor.

http_routes_without_auth_check      (drop entirely)
  C4 collapsed to 0. No ratchet needed.
```

## 4. Phase 3 priorities (deferred to follow-up PRs)

Tier P1 — high leverage:
- Shared telemetry middleware in `server_routes_http_common.ml` (one PR enables Phase 3 counter rollout)
- Shared `error_response` helper to collapse C3 from 3 shapes to 1
- Body size-limit middleware for upload-heavy routes (legendary_bash, multimodal, artifacts)

Tier P2 — once shared middleware lands:
- Add request_total / latency / errors counters to 14 silent modules (one PR each, or batched 2-3 per PR)

Tier P3 (drop):
- C4 ratchet — gap collapsed, no work needed

## 5. Pattern observations

This Phase 2 produced **two new pattern data points**:

1. **C4 over-count (auth coverage)** — Phase 1 estimate exceeded reality by ~5×. The 4-phase pattern doc currently emphasizes Phase 1 over-classification as the dominant failure mode. This case is a routine over-count, not new behavior, but the *direction* (gap doesn't exist at all) is more dramatic than typical narrowing.
2. **C1 confirmed gap (no platform fallback)** — Phase 2 narrowing assumed platform might enforce body limits; it doesn't. The conservative-bias rule still works in this direction: Phase 1 flagged the gap, Phase 2 confirmed it cannot be safely dropped.

These two observations are worth folding back into the pattern doc (PR #12193) under "Phase 2 outcome categories": narrow-confirm, narrow-collapse, narrow-discover.

## 6. Audit chain context

Sixth audit chain Phase 2; third under the codified pattern (after Dashboard #12208, Auth #12209→Phase 2 sibling PR). Continued reuse confirms portability and produces incremental signals about the pattern itself.

## 7. References

- PR #12213 — Server HTTP routes audit Phase 1 (parent)
- PR #12193 — 4-phase audit pattern (codification)
- PR #12208 — Dashboard Phase 2 (sibling)
- `lib/server/server_routes_http_routes_channel_gate.ml`, `*_frontend.ml` — C5 anchors
- `lib/server/server_routes_http_common.ml` — telemetry middleware target
