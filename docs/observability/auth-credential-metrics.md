---
status: reference
last_verified: 2026-05-14
code_refs:
  - lib/auth.ml
  - lib/auth.mli
  - lib/server/server_runtime_bootstrap.ml
  - lib/server/server_bootstrap_loops.ml
  - lib/prometheus.ml
  - lib/prometheus.mli
  - infrastructure/monitoring/auth-credential-alerts.yml
---

# Auth Credential Surface Metrics

How to read the boot-time and runtime credential state exposed by `/metrics` and the alerting rules that turn them into pages. The surface was introduced by PR #15112 to close the bare-form keeper credential ping-pong between PR-#10440 (`Auth.ensure_credential_alias` writes a short-form alias at every boot) and PR-3b2 #11155 (`Auth.archive_bare_for_canonical` archives any bare-form file unconditionally), which had been accumulating about 20 archive epoch directories per day for 17 days before discovery.

## Background

The credential subsystem exposes its state on **seven surfaces** (six original + flow/heartbeat counters added by the 2026-05-14 audit pass):

| Surface | Location | Information shape | Use case |
|---------|----------|-------------------|----------|
| 1. API (mli)            | `lib/auth.mli`                                            | typed contract              | Compile-time |
| 2. Tests                | `test/test_auth.ml` (credentials group 22-32)             | assertions                  | CI guards |
| 3. Boot log             | `[Server] startup bare alias audit: ...`                  | text (operator-readable)    | One-shot boot |
| 4. Prom gauge (snapshot)| `masc_auth_bare_alias{state=...}`                          | numeric end-state           | Time-series + alert |
| 5. Periodic fiber       | `start_bare_alias_audit_fiber` (60s default)              | gauge refresh + heartbeat   | Mid-run regression |
| 6. Prom counter (flow)  | `masc_auth_bare_alias_outcome_total{outcome=...}`         | per-call dispatch events    | Transient regression catch |
| 7. AlertManager rule    | `infrastructure/monitoring/auth-credential-alerts.yml`    | derived alarm               | Operator page |

Surfaces 3 and 4 carry the *same data* — by design — but for different consumers (log grep vs Prometheus scrape). Surfaces 4 and 6 are complementary: the gauge gives end-state visible per scrape, the counter gives per-call events visible via `rate(...)`. The audit pass (2026-05-14) confirmed no genuine duplication; the only addition needed was flow + heartbeat surfaces to catch what the snapshot gauges cannot show.

## γ Classifier (lib/auth.ml)

`classify_bare_for_canonical` is the pure read-only predicate that decides whether a bare-form file is alive or dead. It returns one of three variants:

| Variant | Meaning | Policy |
|---------|---------|--------|
| `Bare_absent`     | No file at `agents/<bare>.json`                                                              | No-op |
| `Bare_alive_alias` | Redirect stub aimed at the *same* UUID file as the canonical credential                     | Keep (PR-#10440 alias) |
| `Bare_dead`       | Direct credential, orphan redirect, or stub whose canonical is itself a direct credential    | Archive (PR-3b2 policy) |

`archive_bare_for_canonical` dispatches on the variant. `bare_alias_audit` aggregates the variant counts across the entire keeper roster and mirrors them into the Prometheus gauges.

## Gauges

### `masc_auth_bare_alias`

| Label | Values |
|-------|--------|
| `state` | `alive`, `dead`, `no_bare` |

Set by `Auth.bare_alias_audit` itself — boot-time via `sync_bootable_keeper_credentials`, then refreshed every `MASC_AUTH_BARE_ALIAS_AUDIT_INTERVAL_S` seconds (default 60) by `start_bare_alias_audit_fiber`. The fiber re-queries the keeper roster on every tick so runtime add/remove is picked up without a fiber restart.

Label cardinality: `3 series`.

#### Steady state (γ fix deployed)

```
masc_auth_bare_alias{state="alive"}   18    # one per fleet keeper
masc_auth_bare_alias{state="dead"}     0
masc_auth_bare_alias{state="no_bare"}  0
```

#### Regression state (pre-γ ping-pong)

```
masc_auth_bare_alias{state="alive"}    0
masc_auth_bare_alias{state="dead"}    18    # every keeper bare flagged for archive
masc_auth_bare_alias{state="no_bare"}  0
```

`state="dead" > 0` is the canary alert hook (`AuthBareAliasPingPongRegression`).

### `masc_auth_archive_epochs`

Unlabeled gauge. Set by `startup_prune_auth_archive` to the count of `.archive/<epoch>/` subdirectories remaining after the boot-time retention sweep. Tracks disk inventory.

Retention defaults: `MASC_AUTH_ARCHIVE_RETENTION_DAYS=30`, `MASC_AUTH_ARCHIVE_MIN_KEEP=20`. Operators can tune both via environment variables.

## Counter

### `masc_auth_archive_pruned_total`

Unlabeled counter. Incremented by `Auth.prune_archive` with the count of epoch directories removed in one sweep. A surge (`increase(... [1d]) > 100`) is the secondary regression signal — either a one-time drain after PR #15112 deployment against an already-bloated `.archive/`, or a new regression producing archive events at the historical rate.

### `masc_auth_bare_alias_outcome_total`

Flow counter — increments on every `archive_bare_for_canonical` dispatch. Labels: `outcome ∈ {alive_skip, dead_archive, absent}`.

| Outcome | Steady state | Meaning |
|---------|--------------|---------|
| `alive_skip` | ↑ on every boot per keeper with PR-#10440 alias | γ guard preserved the alias |
| `absent` | ↑ on first boot of a clean keeper | No bare file existed |
| `dead_archive` | **0 after PR #15112 deploy + initial drain** | Non-zero ongoing = regression |

The snapshot gauge `masc_auth_bare_alias` shows *end-state* after a boot; this counter shows the *transition events* that produced it. After the regression is fixed the cumulative `dead_archive` counter remains at its historical value but the *rate* must be 0.

### `masc_auth_bare_alias_audit_ticks_total`

Heartbeat counter — increments on every successful tick of `start_bare_alias_audit_fiber`. Unlabeled. Default tick rate is 1/60s ≈ 0.0166 ticks/s.

A `rate(...[5m]) < 0.01` for 2m means the fiber stopped publishing heartbeats — the gauges may retain their last set value indefinitely while no longer reflecting reality. This is a *narrower* signal than `absent(masc_auth_bare_alias)`: gauges stay present (last value held by Prometheus), only the heartbeat stops.

## Alert rules

`infrastructure/monitoring/auth-credential-alerts.yml` carries five rules:

| Group | Alert | Severity | Trigger |
|-------|-------|----------|---------|
| `masc_auth_credential_contract` | `AuthCredentialSurfaceMetricAbsent` | critical | Any of the three metrics absent for 5m -- fiber crash or binary predates fix |
| `masc_auth_bare_alias`          | `AuthBareAliasPingPongRegression`  | critical | `state="dead" > 0` for 1m -- the γ guard regression alert |
| `masc_auth_bare_alias`          | `AuthBareAliasNoBareElevated`      | warning  | `state="no_bare" > 0` for 10m -- alias writer failing |
| `masc_auth_archive`             | `AuthArchiveEpochsExcessive`       | warning  | `archive_epochs > 100` for 10m -- retention not keeping up |
| `masc_auth_archive`             | `AuthArchivePruneSurge`            | warning  | `> 100 epochs pruned in 24h` -- one-time drain or regression |
| `masc_auth_bare_alias_flow`     | `AuthBareAliasDeadArchiveOngoing`  | critical | `rate(outcome="dead_archive") > 0` for 5m -- transient regression caught before snapshot |
| `masc_auth_bare_alias_flow`     | `AuthBareAliasAuditFiberStalled`   | warning  | `rate(audit_ticks) < 0.01` for 2m -- fiber stalled, gauges stale-but-present |

Evaluation interval 30s matches `masc_goal_loop_observe_contract` so the operator cadence stays consistent across surfaces.

## Operator playbook

### Alert: `AuthBareAliasPingPongRegression`

1. Check `masc_auth_archive_pruned_total` rate -- if it is also climbing, the ping-pong is actively producing archive events.
2. `cat <base_path>/.masc/auth/.archive/` -- recent epoch dirs (sort by mtime) name the regression cycle.
3. Inspect a representative bare file: `cat <base_path>/.masc/auth/agents/<bare>.json`. A `{"redirect_to": "...json"}` stub whose target differs from the canonical's redirect target is the `Bare_dead` shape.
4. Confirm the running binary actually has commit `5d9ac2a7` (Prometheus metric definitions) and `2be6f22f` (periodic fiber) -- if `masc_auth_bare_alias` is absent from the scrape, the binary is older than PR #15112.

### Alert: `AuthArchiveEpochsExcessive`

1. Either retention is too generous for this deployment's churn (tune `MASC_AUTH_ARCHIVE_RETENTION_DAYS` down), or `AuthBareAliasPingPongRegression` is also firing -- check the cross-correlation.
2. Manual sweep: stop the server, `rm -rf` aged epoch dirs, restart -- but only after capturing one representative epoch dir for forensics.

### Verifying the fix locally

```bash
cd <repo>
dune build --root . test/test_auth.exe
_build/default/test/test_auth.exe test credentials '25,26,27,28,29,30'
# Expected: Test Successful in <50ms. 6 tests run.
```

Stress reproduction of the original ping-pong:

```bash
for i in $(seq 1 50); do
  _build/default/test/test_auth.exe test credentials 26 >/dev/null || echo "fail run $i"
done
# Expected: no output (zero failures across 50 outer iterations
# = 250 internal archive_bare_for_canonical invocations).
```

## History

- PR-#10440 (2026 earlier) introduced `Auth.ensure_credential_alias` to fix `auth_doctor` and other short-form `load_credential` callers (8/14 keepers failing).
- PR-3a #11146 archived bare files only when their token differed from the canonical (dual-identity guard).
- PR-3b1 #11152 starved the runtime caller (`tool_coord.canonicalize_if_keeper`) so all short-form runtime requests resolve through canonical.
- PR-3b2 #11155 generalised the archive helper to remove any bare-form file regardless of shape -- under the assumption that PR-3b1 had killed every short-form caller. It missed the PR-#10440 alias writer running in the same boot, producing the ping-pong.
- PR #15112 (2026-05-14) introduced the γ classifier, the retention sweep, the periodic audit fiber, the Prometheus surface, and these alert rules.

## Related

- `docs/observability/cascade-metrics.md` -- same observability pattern for cascade routing decisions.
- `docs/observability/goal-loop-observe-metrics.md` -- the boot-time exporter contract that this surface plugs into (`metric_config_credential_archived_starvation_total` is part of the GoalLoop contract presence check).
- `RFC-0019 Keeper Credential Unification` -- the narrower split-brain reconciliation in PR #15112 sits inside the architecture sketched in RFC-0019 §4.
