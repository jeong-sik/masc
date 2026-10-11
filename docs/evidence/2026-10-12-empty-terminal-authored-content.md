# Empty terminal content and authored-text boundary

Base: `c28c379e1bc1804bec3f48b2437e90e111262ff9` (#42411).

## Direct failure evidence

Four actual send-action scenarios failed before the repair: empty terminal, exposed thinking only, tool only, and whitespace-only saying. The first two fabricated thinking/error prose into text and rawText; whitespace overwrote actual text and changed a confirmed terminal to error; tool-only fabricated text. Each scenario used accepted operation events and an actual RUN_FINISHED event through the shared reducer. These are mocked transport behavior checks, not live provider proof.

A separate renderer DOM scenario failed because an empty terminal assistant was rendered as markdown fallback rather than a separate content-absence status.

## Repair and checks

The send action preserves observed terminal completion and actual authored content without inferring failure or thinking from blank text. Existing no_reply is retained. The shared bubble renders content absence as role=status; no copy action or fabricated markdown exists for the empty terminal row. Thinking/tool/structured/status blocks keep their existing rendering paths.

Focused Vitest: keeper-actions, chat/primitives, copilot-dock; 323 tests passed. TypeScript noEmit and git diff --check passed. Whole suite, OCaml build, CI, formal approval, merge, installation, named-provider runtime and screenshot evidence are not established.

The full chat goal remains active: account-scoped cache authority, pre-header fetch cancellation, actual provider/async/broadcast continuity and installed UI measurements remain separate work.
