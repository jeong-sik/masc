# Auth / Credential Surface Audit — Phase 2 (per-file refinement)

**Date**: 2026-04-30
**Scope**: same as Phase 1 — 17 ml+mli pairs across core auth (9), identity (4), credential (4), role (1)
**Pattern**: 4-phase audit (`docs/process/AUDIT-CHAIN-4-PHASE-PATTERN.md`)
**Phase 1**: PR #12209

## 1. Phase 1 → Phase 2 deltas

| Class | Phase 1 estimate | Phase 2 actual | Δ | Direction |
|---|---|---|---|---|
| C1 token refresh w/o tests | 3 | TBD (Phase 3) | — | deferred |
| C2 identity telemetry | 4 candidates | **0/4 have telemetry** | confirmed | gap real |
| C3 allowlist/role tests | 2 candidates | **2/2 covered** (Alcotest) | confirmed | gap closed |
| C4 credential redaction | 2 candidates | **0 log calls found** | gap collapse | not yet a leak vector |
| C5 anchors (Phase 1 assumed 3) | 3 | **1/3** has telemetry | gap revealed | bigger gap than thought |

Two gaps narrowed/collapsed (C3, C4), one anchor assumption falsified (C5). Pattern doc claim that "Phase 1 over-classifies, Phase 2 narrows" partially holds — C5 anchor count was over-assumed in the *opposite* direction (Phase 1 thought 3 anchors existed; only 1 does).

## 2. Per-class structural findings

### 2.1 C2 — Identity telemetry (4/4 silent)

Searched for `Prometheus.|metric_*|register_counter|inc_counter`:

| File | Telemetry | Notes |
|---|---|---|
| `lib/agent_identity.ml` | NO | 338 lines, zero counters; false positives only (`@since`, `register`, `registered_at`) |
| `lib/build_identity.ml` | NO | Pure data structures |
| `lib/keeper/keeper_identity.ml` | NO | Has comment at L201 referencing "Prometheus metric" but no instrumentation |
| `lib/coord/coord_identity.ml` | NO | Zero matches |

Phase 1 estimate: 4 modules without telemetry. Confirmed: **all 4** silent.

### 2.2 C3 — Allowlist / role property tests (covered)

| Subject | Test file | Style | LOC |
|---|---|---|---|
| `keeper_routine_allowlist` | `test/test_keeper_routine_allowlist.ml` | Alcotest unit | 338 |
| `tool_access_role` | `test/test_tool_access_policy.ml` | Alcotest unit | 844 |

Both files exist; coverage is comprehensive (claim/start/done/heartbeat actions covered). Style is unit-based, not Quickcheck — Phase 3 may add property generators if drift is observed, but the gap as originally framed (no tests) is closed.

### 2.3 C4 — Credential redaction (gap collapsed)

`lib/keeper/credential_provider.ml` and `lib/auth_doctor.ml` examined for `Log.error|Log.info|Log.warn|sprintf.*path|to_string.*ro_mount`:

- `credential_provider.ml`: sprintf at L24, L26, L28, L30 — error display only, **not logged**
- `auth_doctor.ml`: sprintf at L710-731 — diagnostic report builder, **not logged**

Neither file has a `Log.*` call. Path strings flow into return values, not into log frameworks. The Phase 1-flagged "host path leak risk" is not currently a leak vector because there is no logging instrumentation that could carry the paths off-process.

This does **not** mean the C4 risk is dismissed — if Phase 3 work adds logging (e.g., for telemetry of credential resolution failures), redaction must be designed in from the start. Phase 4 ratchet should pin this state: `credential_paths_with_unredacted_log_call` (DEC, floor 0).

### 2.4 C5 — Anchor verification (Phase 1 over-assumed)

Phase 1 listed `server_auth.ml`, `auth_strict_mode.ml`, `auth_resolve.ml` as "well-covered anchors". Phase 2 grep for `Prometheus.`:

| File | Prometheus calls |
|---|---|
| `lib/server/server_auth.ml` | **4** |
| `lib/auth_strict_mode.ml` | **0** |
| `lib/auth_resolve.ml` | **0** |

Only 1/3 actually qualifies as an anchor. `auth_strict_mode` and `auth_resolve` are bare. Phase 1 assumed them anchors based on their domain centrality, not measured telemetry. This is a Phase 1 assumption error worth recording — the codified pattern (PR #12193) advises taxonomy by structural evidence, not naming intuition; Phase 1 author here partially relied on the latter.

### 2.5 Telemetry baseline — `metric_auth_*` Prometheus families

6 unique metrics, all defined in single registry, all mutated through `server_auth.ml`:

1. `metric_auth_bearer_token_mismatch`
2. `metric_auth_credential_ambiguous_lookup`
3. `metric_auth_credential_token_duplicate`
4. `metric_auth_credential_token_rotated`
5. `metric_auth_strict_unknown_tool_denials`
6. `metric_auth_strict_would_reject`

Centralization is a strength (single point of reasoning) but also a single-point-of-failure risk if the surrounding modules silently bypass `server_auth`.

## 3. Refined ratchet floors

Phase 1 left floors as TBD. Phase 2 pins:

```
auth_modules_with_prometheus_guards          (INC, floor 1)
  Current state: only server_auth.ml. Phase 3 should add at least
  auth_strict_mode + auth_resolve telemetry to reach floor 3.

auth_identity_modules_with_telemetry         (INC, floor 0)
  Current state: 0/4. Phase 3 first PR adds one identity counter
  (e.g., agent_identity_resolution_total) to break the floor.

credential_paths_with_unredacted_log_call    (DEC, floor 0)
  Current state: 0 Log.* calls in credential surface (collapsed gap).
  Pin floor at 0 to prevent regression when Phase 3 adds logging.
```

C1 (token refresh tests) remains TBD — Phase 3 must locate refresh implementation before measuring test coverage.

## 4. Phase 3 priorities (proposal — fixes deferred to follow-up PRs)

Tier P1 (high-leverage gap closures):
- Add Prometheus counter to `auth_resolve.ml` (cascade dispatch failure modes)
- Add Prometheus counter to `auth_strict_mode.ml` (would-reject vs actual reject divergence)
- Add at least one identity-resolution counter to `agent_identity.ml`

Tier P2 (defensive):
- Design redaction helper for credential-surface logging *before* any Phase 3 telemetry adds Log.* calls
- Document the "all auth telemetry flows through server_auth.ml" invariant; add a structural test if drift is feared

Tier P3 (deferred):
- Quickcheck property generators on top of the existing allowlist/role unit tests (style upgrade, not gap closure)

## 5. Audit chain context

This is the second auth-domain Phase 2 produced under the codified 4-phase pattern (PR #12193). Comparable to the Dashboard Phase 2 (PR #12208) in narrowing direction, but with the additional finding that *Phase 1 anchor assumptions* can also be wrong — not only candidate over-classification.

## 6. References

- PR #12209 — Auth/credential audit Phase 1 (parent)
- PR #12193 — 4-phase audit pattern (codification)
- PR #12208 — Dashboard observability Phase 2 (sibling pattern instance)
- `lib/server/server_auth.ml` — only confirmed C5 anchor
- `test/test_keeper_routine_allowlist.ml`, `test/test_tool_access_policy.ml` — C3 evidence
