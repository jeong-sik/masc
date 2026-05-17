# Cascade Partial-Boot Mode — Operator Runbook

| | |
|---|---|
| RFC | RFC-0058 Phase 8.3 |
| Env var | `MASC_CASCADE_PARTIAL_BOOT` |
| Default | `false` |
| Audience | Operator on-call, infra |

## 1. What this mode does

Normally, masc-mcp's boot-time cascade-catalog gate (`Cascade_catalog_runtime.validate_path_result`) refuses to start the server when `cascade.toml` contains *any* adapter-level error — e.g. a binding referencing a removed provider (`(Cascade_declarative_adapter.Provider_not_found "claude")`). The intent is fail-loud: a broken config is visible on boot rather than silently routing traffic through a degraded catalog.

When `MASC_CASCADE_PARTIAL_BOOT=1`, that gate relaxes for the **adapter-error class only**:

- **Parser-level errors** (toml unparseable, schema-shape violations): **still fatal**. Server refuses to boot. The Phase 8 partial-parse adapter cannot produce a snapshot from an unparseable file.
- **Adapter-level errors** (resolvable on a per-binding basis, e.g. dangling `[<p>.<m>]` references): **tolerated** when a non-empty `decl_snapshot` is available. Server boots with the resolvable subset of profiles. A structured `Log.Misc.warn` (will migrate to `Log.Cascade.warn` once Phase 8.1.5 PR #15751 lands) emits per error.

## 2. When to use it

Use this mode when **all** of the following hold:

1. Server is failing to boot with an `active cascade source could not be loaded` or `declarative cascade adapter error` rejection.
2. Production keepers are blocked from running.
3. The operator has confirmed that the resolvable subset of profiles is sufficient for the workload that must continue (e.g. a degraded cascade with one or two missing providers, where the remaining providers cover the active routes).
4. A fix for the underlying `cascade.toml` is in progress but not yet ready to deploy.

This is **emergency-only**. Not a steady-state mode.

## 3. How to enable

```bash
# One-shot, single boot:
MASC_CASCADE_PARTIAL_BOOT=1 ./bin/masc_server

# Or in launchd / systemd:
Environment="MASC_CASCADE_PARTIAL_BOOT=1"

# Verify on next reload (after the fix lands, unset):
unset MASC_CASCADE_PARTIAL_BOOT
```

Accepted truthy values: `"1"`, `"true"`, `"yes"` (case-insensitive, per `Env_config_core.get_bool`). Anything else is treated as `false`.

## 4. What you'll see in the log

Per adapter-level error, on every catalog reload (including initial boot):

```
[WARN] [Misc] partial-boot mode: declarative adapter error in /path/to/cascade.toml (continuing): (Cascade_declarative_adapter.Provider_not_found "claude")
```

The boot proceeds. Profile discovery returns the resolvable subset.

If `MASC_CASCADE_PARTIAL_BOOT` is **not** set and adapter errors exist, the gate still rejects with the same error string surfaced in the rejection result. Logs in that case use `Log.Misc.warn` per error followed by `[CascadeProfileDiscovery] declarative parse error: ...`.

## 5. Footguns

| Risk | Mitigation |
|---|---|
| Operator leaves the flag on indefinitely → silent drift between intended and actual cascade routes | Periodic `Log.Misc.warn` on every reload while flag is active; check log volume on a daily cadence. |
| Resolvable subset is empty (no profile resolves) but flag is set | Snapshot is `None`; boot still fails (gate falls through to the standard rejection path). The flag only tolerates partial, not total, failure. |
| Routes reference a profile that *was* in the catalog but is *not* in the resolvable subset | `validate_path_result` still flags this via `cascade route targets missing profile %S`. The rejection path is unchanged for route-key / route-target errors. |
| Dispatch hits a route whose binding was removed | Phase 8.4 (pending) will verify that the dispatch path either uses the resolvable subset only or fails-loud (no silent fallback to reserved). Until 8.4 lands, *expect dispatch failures* for any route whose binding was in the dropped errors set. |

## 6. Rollback

Unset the env var and restart:

```bash
unset MASC_CASCADE_PARTIAL_BOOT
# launchd: edit plist, then `launchctl bootstrap ...` cycle
# systemd: edit unit, then `systemctl daemon-reload && systemctl restart masc-mcp`
```

If the underlying `cascade.toml` is still broken, the server will refuse to boot again. That's the intended behavior.

## 7. References

- `docs/rfc/RFC-0058-phase-8-cascade-catalog-partial-parse.md` §4 Phase 8.3
- `lib/cascade/cascade_catalog_runtime.ml:allow_partial_boot`
- `lib/cascade/cascade_catalog_runtime.ml:validate_path_result`
- `lib/cascade/cascade_catalog_runtime.ml:discover_profile_names`

## 8. Follow-ups (not yet shipped)

- **Phase 8.3.1** — dashboard banner showing partial-boot active + count of dropped entries.
- **Phase 8.4** — dispatch-path tests against partial snapshot to verify no silent fallback.
- **Phase 8.1.5** (PR #15751) — once merged, `Log.Misc.warn` calls in this runbook's example log lines migrate to `Log.Cascade.warn` for cleaner alerting routing.
