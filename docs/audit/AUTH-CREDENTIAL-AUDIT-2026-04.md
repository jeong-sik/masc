# Auth / Credential Surface Audit — Phase 1

**Date**: 2026-04-30
**Scope**: auth + identity + credential modules in `lib/`
**Pattern**: 4-phase audit (`docs/process/AUDIT-CHAIN-4-PHASE-PATTERN.md`, PR #12193)

## 1. Surface

17 ml + mli pairs (~34 files) across 5 sub-domains:

**Core auth (9 pairs)**:
- `lib/auth.{ml,mli}` — orchestrator
- `lib/auth_resolve.{ml,mli}` — token resolution (cascade dispatch)
- `lib/auth_login.{ml,mli}` — bearer token lifecycle
- `lib/auth_doctor.{ml,mli}` — validation + health check
- `lib/auth_error_kind.{ml,mli}` — error taxonomy
- `lib/auth_strict_mode.{ml,mli}` — strict mode flag + policy
- `lib/types/types_auth.{ml,mli}` — shared type definitions
- `lib/tool_token.{ml,mli}` — "Parse, don't validate" proof token
- `lib/server/server_auth.{ml,mli}` — HTTP auth dispatch

**Identity (4 pairs)**:
- `lib/agent_identity.{ml,mli}`
- `lib/build_identity.{ml,mli}`
- `lib/keeper/keeper_identity.{ml,mli}`
- `lib/coord/coord_identity.{ml,mli}`

**Credential + allowlist (4 pairs)**:
- `lib/keeper/credential_provider.{ml,mli}` — credential trait (RFC-0008)
- `lib/keeper/keeper_persona_authoring.{ml,mli}`
- `lib/keeper/keeper_persona_authoring_contract.{ml,mli}`
- `lib/keeper/keeper_routine_allowlist.{ml,mli}`

**Role (1 pair)**:
- `lib/tool_access_role.{ml,mli}`

**Telemetry baseline**: ~8 `metric_auth_*` Prometheus families found (pending Phase 2 enumeration).

**Test coverage baseline**: 28 test files matching `auth|credential|identity|allowlist|token` (pending Phase 2 structural breakdown).

## 2. Gap taxonomy (Phase 1 candidates — conservative bias)

Phase 1 marks these as **candidates**, not certainties. Phase 2 will narrow per-file with structural evidence (per `AUDIT-CHAIN-4-PHASE-PATTERN.md` §3).

| Class | Scope | Candidate count | Severity |
|---|---|---|---|
| C1: Token refresh / rotation without dedicated tests | `auth_login.ml`, `tool_token.ml`, `credential_provider.ml` lifecycle methods | 3 | Medium |
| C2: Identity resolution without telemetry | `agent_identity`, `keeper_identity`, `coord_identity`, `build_identity` | 4 | Medium |
| C3: Allowlist / role semantics without property tests | `keeper_routine_allowlist.ml`, `tool_access_role.ml` | 2 | Medium-High |
| C4: Credential storage paths without redaction audit | `credential_provider.ml`, `auth_doctor.ml` | 2 | High |
| C5: Already well-covered (telemetry + guard) | `server_auth.ml`, `auth_strict_mode.ml`, `auth_resolve.ml` | 3 | Low (anchor) |

Conservative candidates flagged for Phase 2 verification:
- `auth_login.ml:refresh_bearer_token` — possibly inline rotation logic; Phase 2 will check whether a dedicated rotation module is needed
- `keeper_persona_authoring_contract.ml` — "contract" suggests validation; Phase 2 will check property-test coverage
- `auth_doctor.ml` — health check vs. live validation responsibilities may be conflated

## 3. Severity rationale

- **C4 = High**: host-path leak risk. `credential_provider.ml` exposes `live_admin_token_file_source` and `ro_mount.host` fields. If these flow into structured logs or error messages without redaction, host topology is disclosed. Past `feedback_b1_host_path_leak_keeper_status_detail` precedent shows this is a real recurring class — leak in `keeper_status_detail` was caught and fixed at PR #11080.
- **C3 = Medium-High**: governance gate. Allowlist-composition bugs can silently bypass auto-approval rules. Past `feedback_a1_allowlist_empty_semantics_split` precedent (#11096) shows allowlist precedence is a known footgun.
- **C2 = Medium**: silent identity failures hide cascade-resolution bugs. Past `feedback_silent-auth-token-internal-vs-per-keeper` precedent shows untracked drift between per-keeper and internal credentials.
- **C1 = Medium**: lifecycle is foundational; gaps silently age credentials. Lower urgency than C3/C4 because the symptom is observable (auth failure → re-login) rather than silent.

## 4. Recommended ratchets (Phase 1 — descriptive, not enforced)

Three families, all monotonic-direction:

```
auth_modules_with_prometheus_guards (INC, floor TBD)
  Purpose: ensure auth telemetry coverage stays ≥ baseline.
  Phase 2 will count actual emitters and pin floor.

auth_identity_modules_with_telemetry (INC, floor 0)
  Purpose: drive identity-module telemetry from 0 → ≥3.
  Goal: one Prometheus counter per identity module
        (agent_identity, keeper_identity, coord_identity).

credential_paths_without_redaction_audit (DEC, floor TBD)
  Purpose: cap regression on host-path-leak surface area.
  Phase 2 will enumerate the actual count and pin floor.
```

Wire-up deferred to Phase 4 per the 4-phase pattern. Floor values are intentionally TBD until Phase 2 measurement.

## 5. Out-of-scope for Phase 1

- Property-test audit for `keeper_routine_allowlist` (Phase 2 — structural)
- Token-refresh module location (Phase 2 — structural)
- Identity-module telemetry implementation (Phase 3 — fixes)
- Redaction enforcement (Phase 3 — fixes)

## 6. Audit chain context

This is the **fourth audit chain** to apply the 4-phase pattern, and the **second** to explicitly invoke the codified pattern doc (PR #12193) as a starting point:

1. OAS↔MASC boundary audit (Q-P0-3) — original pattern source
2. TLA+ specs gap audit (Q-P0-2) — second instance, validated
3. Dashboard observability audit — first to invoke codified pattern (PR #12202)
4. **Auth/credential audit (this doc)** — second to invoke codified pattern

Continued reuse confirms the pattern doc's portability claim across heterogeneous domains (boundary, spec, runtime observability, security).

## 7. References

- PR #12193 — 4-phase audit pattern (codification)
- PR #12202 — Dashboard observability audit Phase 1 (sibling)
- PR #11080 — host path leak in `keeper_status_detail` (C4 precedent)
- PR #11096 — allowlist empty-semantics split (C3 precedent)
- `lib/auth*.{ml,mli}`, `lib/keeper/credential_provider.{ml,mli}` — surface
- `MEMORY.md`: `feedback_silent-auth-token-internal-vs-per-keeper`, `feedback_a1_allowlist_empty_semantics_split`, `feedback_b1_host_path_leak_keeper_status_detail`
