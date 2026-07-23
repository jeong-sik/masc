## Summary

<!-- What changed? Keep this short and factual. -->

## Product impact

- User-visible change:

## Evidence

<!-- Tests, harness runs, screenshots, logs, or other proof. -->
- If tool-call behavior or provider tool support changed: include replay-harness or typed Gate-boundary evidence.

## Direct evidence

<!--
Agent PR evidence schema. Classify each proof stage by provenance:
direct = keeper/agent performed it through its own tool surface;
operator_proxy = a human/operator ran it for the agent;
mixed = direct and operator_proxy stages both exist;
n/a = not applicable for this PR.
-->

```yaml
schema_version: 1
direct_ratio: 0/0
provenance: n/a
stages: []
```

## GOAL LOOP ACT checklist

<!-- Complete this section for operational/runtime fixes. Leave unchecked items with a brief N/A reason. -->

- [ ] Observe — metric/log/trace evidence for the failure or drift is linked or pasted above
- [ ] Orient — mapped to a finding, live-log pattern, audit item, or explicit new finding
- [ ] Decide — priority/risk rationale is stated, including why this scope is the next action
- [ ] Act — code/config/docs changed in the smallest bounded scope; rollback path is clear
- [ ] Verify — regression test, focused local command, CI job, or production-log check proves PASS/FAIL
- [ ] Loop — remaining follow-up is linked as an issue/PR/handoff, or explicitly marked none

## Review evidence

<!-- Cross-model review result, reviewer model, and fallback reason if any. -->

## Linked issue

- Closes #
- Relates #

## Variant addition checklist

<!-- Complete this section if you added, removed, or renamed any OCaml variant,
     TypeScript union member, TLA+ domain literal, or JSON schema enum value.
     Leave unchecked boxes with a brief justification comment if not applicable. -->

- [ ] **OCaml** — variant added/removed in `.ml`/`.mli` and exhaustive `match` updated (no silent `_` wildcard without justification comment)
- [ ] **TypeScript** — corresponding union type in `dashboard/src/types/core.ts` updated (e.g. `KeeperPhase`, `KeeperHealth`, etc.)
- [ ] **TLA+ spec** — matching domain literal or `DOMAIN` set in the relevant `.tla` file updated
- [ ] **Event / JSON schema** — event type string, JSON schema enum, or `canonical_keeper_toml_key_names` updated if applicable
- [ ] **`make check-variants` passes** — run `bash scripts/check-variants.sh` locally and confirm PASS
