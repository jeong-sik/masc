# RFC-0009 — Cascade Trust Phase 2: Operator Recommendations + Opt-in Persist

**Status**: Draft (2026-04-26)
**Depends on**: #10292 (Phase 0a), #10331 (Phase 0b), #10365 (Phase 1)
**Author**: vincent (jeong-sik)

## Motivation

Phase 1 (#10365) gave the cascade an in-memory `trust_score` that auto-rotates away from rate-limited / persistently failing providers. Replay validation against 4044 live decisions confirmed the algorithm matches operator intent: dead cascades (ollama_only at 1% success → trust 0.000 on 99.5% of decisions), healthy cascades (primary at 41% success → trust 2.000 ceiling).

Two gaps remain:

1. **Restart resets reputation.** Trust lives only in memory. After every server restart the cascade re-learns each provider's persistence pattern from scratch — tens of additional failed turns per restart for the dominant fingerprints.
2. **Trust is invisible to operators.** A keeper might be quietly running on a `trust=0.05` provider for hours; the only signal is `same_fingerprint_count` in the dashboard JSON. There is no nudge that says "stop sending traffic here, fix the config."

Phase 2 closes both gaps without giving the trust loop authority to silently rewrite repo config.

## Design principles

| Principle | Application |
|---|---|
| Live-only persist | Only `~/.masc/config/cascade.toml` is touched; `config/cascade.toml` (repo seed) is never written to by the trust loop. |
| Opt-in by default | `MASC_CASCADE_TRUST_PERSIST=1` (or `=dry`) gates everything in this RFC. Default-off for the first release. |
| Observation over action | Phase 2a (operator recommendation) is observation-only. Phase 2b (persist) is a separate feature flag and a separate PR. |
| No self-reload loops | Hot-reload must skip files the trust loop just wrote; otherwise each persist triggers a reload triggers a re-emit. |
| Audit everything | Every persist write goes to `~/.masc/cascade_trust/applied/YYYY-MM/DD.jsonl` with before/after values and reason. |

## Phase 2a — Operator recommendation (observation only)

### `lib/coord/coord_hooks.ml`

Add a Hebbian-style observation callback (mirrors `hebbian_on_task_done_fn`, `activity_emit_fn`):

```ocaml
val cascade_adjust_fn :
  (provider_key:string -> trust_before:float -> trust_after:float ->
   reason:[`Success | `Transient | `Persistent | `Hard_quota] -> unit)
  Atomic.t

val install_cascade_adjust_observer :
  (provider_key:string -> trust_before:float -> trust_after:float ->
   reason:[ `Success | `Transient | `Persistent | `Hard_quota ] -> unit) ->
  unit
```

Default implementation: no-op. Dashboard / persist module register an observer at boot.

`Cascade_health_tracker.record` invokes the hook after every trust update (under the same mutex).

### `lib/dashboard/dashboard_operator_judge.ml`

Extend with a recommendation builder:

```ocaml
val low_trust_recommendations :
  Cascade_health_tracker.t -> recommendation list

(* recommendation = { provider_key; trust; recent_fingerprint;
   recurrence_count; suggested_action } *)
```

`suggested_action` is one of:

- `Reduce_weight` — trust ∈ [0.1, 0.3): degrade in cascade.toml
- `Disable` — trust < 0.1 or `same_fingerprint_count >= 5`: remove from cascade
- `Investigate` — trust < 0.3 with very high `events_in_window`: probably a config bug

Rendered on the dashboard as a card with a copy-friendly JSON snippet showing the suggested cascade.toml diff. **No auto-apply.**

### Acceptance for 2a

- [ ] Recommendation card renders for `ollama_only` (live data already shows trust=0.000) within 60s of dashboard load.
- [ ] Repo seed never modified.
- [ ] Tests: 4 alcotest cases over the recommendation classifier (reduce/disable/investigate/healthy).

## Phase 2b — Opt-in persist (separate feature flag + separate PR)

### Activation modes

| `MASC_CASCADE_TRUST_PERSIST` | Behaviour |
|---|---|
| unset (default) | No persist. Trust is in-memory only, reset on restart. |
| `dry` | Compute the would-be diff every hour, append to `cascade_trust/applied/<date>.jsonl` with `mode=dry`, no file write. |
| `1` | Same diff, plus atomic write to `~/.masc/config/cascade.toml`. |

### Persist algorithm

Every `MASC_CASCADE_TRUST_PERSIST_INTERVAL_SEC` (default 3600s):

1. Snapshot `Cascade_health_tracker.global` providers with `events_in_window > 0` AND age of `last_failure_at` < 24h (skip stale).
2. For each provider, compute target weight: `round(trust_score * 2) / 2` (0.5-step granularity, range [0.5, ceiling × current_weight]).
3. Diff against current `~/.masc/config/cascade.toml` weights.
4. If diff is empty → emit `mode=skip_no_change` audit event; return.
5. Atomic write via `lib/atomic_write.ml`:
   - `cascade.toml.tmp` → fsync → rename
   - Backup previous: `~/.masc/config/.backup/cascade.toml.YYYYMMDD-HHMMSS`
   - Top-of-file marker comment: `# auto-tuned by trust_persist at <timestamp>; do not edit by hand within 5s`

### Hot-reload loop guard

`lib/cascade/cascade_config_loader.ml` mtime-based reloader must ignore reloads triggered ≤5s after a self-write. Implementation choices:

| Option | Pros | Cons |
|---|---|---|
| **mtime threshold** | No state, simple. | False positive if operator edits within 5s. |
| **written_by marker file** | Explicit. | Extra file to clean up. |
| **inotify-style content hash** | Most precise. | Overkill for a 1h-cadence loop. |

Recommendation: mtime threshold + a process-local flag (`Atomic.t` with timestamp), invalidated after 5s. Simpler than a marker file.

### Repo seed pre-write guard

`Cascade_trust_persist.persist_now` must hard-fail if the resolved write target equals `<repo_root>/config/cascade.toml`. Path comparison via `Unix.realpath` on both sides (per `feedback_security-gate-realpath-invariants.md`).

### Acceptance for 2b

- [ ] `MASC_CASCADE_TRUST_PERSIST=dry` runs for 24h locally; audit log shows expected diffs without file writes.
- [ ] `MASC_CASCADE_TRUST_PERSIST=1` writes happen exactly once per interval; backup file is created.
- [ ] Hot-reloader does not loop (verify by checking `[CascadeConfig] loaded` log frequency stays ≤ 1/hr after persist).
- [ ] Repo seed write attempt is blocked by realpath guard (test injects a fake repo path, expects exception).
- [ ] Tests: 6 alcotest cases — atomic write, backup creation, dry mode no-op, repo guard, hot-reload skip, audit log shape.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Self-reload loop | Hot-reload skips ≤5s self-writes; persist interval ≥ 1h. |
| Operator config overwrite | Live-only path; explicit feature flag; backup before every write. |
| Trust score thrash → weight thrash | 0.5-step quantization filters small fluctuations. Plus a hysteresis gate: skip writes where `|trust_now - last_persisted_trust| < 0.25`. |
| Repo seed pollution | Realpath equality check + tests. |
| Dashboard/persist disagreement | Persist module is the writer; dashboard is the reader. Use the same `Cascade_health_tracker.global` snapshot. No second source of truth. |

## Out of scope

- **Phase 3** (cost-aware boost via OAS `cost_tracker` token usage) — separate RFC.
- **Cross-host trust sync** — every host has its own `~/.masc`; no fleet-level reputation in this RFC.
- **Auto-disable of dead cascade** — operator decides; the recommendation only suggests.

## Verification plan

| Phase | Trigger | Pass criteria |
|---|---|---|
| 2a | Phase 1 has been live ≥ 24h | Recommendation card renders ≥ 1 entry corresponding to a known-bad cascade in replay data |
| 2b dry | Phase 2a merged | 1 week of `dry` mode audit log with no file writes |
| 2b live | 2b dry green | First write produces correct diff; hot-reload count unchanged |

## Implementation order

```
RFC-0009 review  →  Phase 2a PR (recommendation, observation only)
                    →  1 week soak
                                →  Phase 2b dry PR
                                    →  1 week dry soak
                                            →  Phase 2b live (flip default)
```

Total estimated calendar time before any automatic write: 2-3 weeks.
