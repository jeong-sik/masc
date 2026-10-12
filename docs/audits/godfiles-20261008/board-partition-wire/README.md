# Board partition wire ownership, 2026-10-09

Parent: `1f482a08922981a9148e3a3de5f16e69e1ede1a0` (#42027).
Issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

`Keeper_board_attention_partition` combined durable ledger/cache/cursor effects
and transition policy with immutable domain declarations and strict JSON/ledger
framing. Canonical internal declarations now belong to
`Keeper_board_attention_partition_types`; pure encoding, decoding and ledger
framing belong to `Keeper_board_attention_partition_wire`. Both are Dune-private.
The storage owner retains entropy acquisition and the worker generator's mutex,
clock and runtime identity acquisition, deterministic root identity, indexed
views, transition policy, cursor-fenced writes and recovery effects.

The public partition `.mli` is byte-identical. It still seals the partition record
as private and the worker epoch as opaque. Internal records can be constructed by
the authoritative storage implementation; they cannot be passed directly as the
public nominal partition type. Existing public codec calls bind directly to their
owner. No new public raw decoder, unsafe conversion, construction wrapper,
schema, wire tag, compatibility reader or test forwarding API is introduced.

Partition storage changes from 2,123 to 1,329 lines; internal types have 137 lines
and the wire owner 684. [extraction-comparison.json](extraction-comparison.json)
confirms the complete wire/ledger body equals the extracted parent, domain
declarations and pure epoch helpers match, entropy/mutex/generation remain
byte-identical at the storage boundary, and the remaining root after its identity
framing is byte-identical. Falling below 2,000 lines does not finish this
candidate's view/cache/storage/transition audit.

## Consumer checks

| Boundary | Executed evidence | Result |
| --- | --- | --- |
| Public codec and durable partition lifecycle | Existing singleton FSM suite: identities, generations, bound/CLI/advanced progress, strict schemas, blocked causes, Ready confirmations, child-process restart, torn tail and invalid provenance | 21 cases passed |
| Public private/opaque API | Compiler probes: normal roundtrip/generator use; attempted public record update, UUID literal as epoch, and internal record into public codec | Positive compiled; all 3 invalid uses refused for their intended type reason |
| Partition types → exact-flow/worker consumer | Focused exact-flow target compilation | Compiled; adapter/provider-flow cases were not executed |

Both focused executables compiled. [checks.json](checks.json) records terminal
results and commands. Compiler sources and
diagnostics are in [api-probes/checks.json](api-probes/checks.json). Those probes
use built CMIs including internal paths: they establish public nominal/private
boundaries, not private namespace exclusion or library installation.
No tests were added to mirror the extraction or implementation layout.

## Restack

The parent branch was externally rewritten while this slice was being published.
Its tree delta is limited to TUI retained-media/input code and related fixtures;
the partition source/interface is unchanged. The two local slice commits were preserved on a checkpoint branch
and rebased onto the actual parent. Original validation receipts remain recorded
separately from focused checks on the new combined inputs.

## Scope

These are focused macOS checks against isolated real ledgers, existing recovery
fixtures and compiler interfaces. Provider execution, live Keeper continuity,
visible UI, installation, deployment, full CI and whole-stack approval remain
unverified. The other responsibilities remain pending in the original
171-candidate campaign; this is a bounded partial improvement.
