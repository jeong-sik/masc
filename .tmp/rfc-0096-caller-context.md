# RFC-0096 caller context

## Goal

Capture the minimum caller context for the Keeper turn-contract RFC after
renumbering away from the RFC-0091 collision.

## Code coordinates

- `lib/keeper/keeper_tool_disclosure.ml:466` is the required-tool satisfaction entrypoint.
- `lib/keeper/keeper_tool_disclosure.ml:483` treats read-only calls as insufficient for required tool use.
- `lib/keeper/keeper_execution_receipt.ml:475` derives alert disposition from cascade exhaustion.
- `config/cascade.toml:57` starts the checked-in GLM provider surface used by cascade profiles.

## Gotchas

- This RFC is a design document only.
- RFC-0094 and RFC-0095 are already used by open RFC PRs, so this repair uses RFC-0096 and advances the ledger to 0097.
