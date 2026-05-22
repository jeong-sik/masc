# Task-497: Verify tier admission configuration for P1 tasks

## Summary

Verified the tier admission system for MASC cascade routing. The system is
well-implemented per RFC-0153 Phase B.1 with no P1-specific misconfiguration
found.

## Files Reviewed

| File | Purpose |
|------|---------|
| `lib/cascade/cascade_tier_admission.ml` | Per-tier inflight admission control (RFC-0153 Phase B.1) |
| `lib/cascade/cascade_tier_admission.mli` | Public interface contract |
| `lib/cascade/cascade_tier.ml` | Capability-tier monotonicity (RFC-0055/0058) |
| `lib/cascade/cascade_config_strategy_resolve.ml` | Priority-tier + strategy resolution |
| `lib/cascade/cascade_strategy.ml` | Strategy types including Priority_tier |
| `lib/cascade/cascade_preflight_state.ml` | Health-check fingerprinting per tier_group |
| `lib/cascade/cascade_declarative_adapter.ml` | Tier group strategy building |
| `lib/cascade/cascade_runtime.ml` | Tier group member resolution |
| `test/test_cascade_tier_admission.ml` | Unit tests for admission module |

## Key Findings

1. **Admission is tier_id-agnostic**: No hardcoded P1 priority mapping exists.
   The system uses string-based `tier_id` from `cascade.toml`
   `[tier-group.<name>]` keys. P1 tasks follow the same admission path as any
   priority.

2. **Required/Bypass policies** (RFC-0153 §6.8): `Required` enforces capacity
   limits for main keeper turns; `Bypass` skips admission for probes/side
   tasks, preventing starvation. Enforced at compile time by OCaml's type
   system (no default `admission_policy`).

3. **Default max_inflight=8**: Unconfigured tiers default to 8 concurrent
   admissions. Explicit `configure` calls can override per tier.

4. **Exception safety**: Counter is released even when the executed function
   raises. Release errors are swallowed per MASC finalizer convention.

5. **Priority-tier validation** (`normalize_priority_tier`): Validates model
   IDs against TOML-loaded catalog before constructing priority tiers. Invalid
   tiers emit one-time warnings and fall back to Failover strategy.

6. **Test coverage**: 10+ test cases covering: default/custom capacity, Bypass
   policy at saturation, Required capacity-full rejection, exception safety,
   lazy tier creation, concurrent admission.

## Conclusion

No P1-specific tier admission misconfiguration exists. The
`strict_tool_candidates` cascade failures observed in episodic memory (turns
626-631, 956-958) are cascade routing failures (`no_tool_capable_provider`),
not admission configuration issues. All 12 configured candidates reject the
required tool set, causing the cascade to exhaust before admission is reached.