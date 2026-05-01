## Summary

<!-- What changed? Keep this short and factual. -->

## Product impact

- User-visible change:

## Evidence

<!-- Tests, harness runs, screenshots, logs, or other proof. -->
- If tool-call behavior or provider tool support changed: include replay-harness or `ToolCallContract` evidence.

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
