# Chat edit evidence

The chat previously joined execution outputs but displayed only raw input and
result strings on expansion. The change renders recorded search/replacement input
snippets directly beside a successful edit call, on both flat tool bubbles and
grouped tool trace rows. It labels the path and occurrence count from the
filesystem success result. The visible note explains that redaction, per-leaf
length limits, and trimming can omit content or whitespace. These are logged
input snippets, not exact applied bytes or a reconstructed file/git diff.
Empty recorded search text remains visible when the successful patch receipt
proves an edit, because whitespace-only input can be trimmed empty.

Evidence boundary: requires a joined ToolCallEntry with successful status,
`route_evidence.descriptor_id=agent.edit_file`, structured old/new input, and
a parseable `ok=true, mode=patch` result with positive integer occurrences.
No inferred display-name match is used. Missing/blob/truncated results,
approval-pending records and failures do not render an applied change.

Backend source inspected: `keeper_tool_filesystem_runtime.ml`, successful
Replace operation output. The operation records mode, path, occurrences after
write completion. This view consumes that existing record without another
filesystem request or a new source of modification authority.

Validation commands:

```sh
cd dashboard
pnpm test src/components/chat/primitives.test.ts src/components/chat/edit-evidence.test.ts
```

Tests exercise literal text, empty logged fields, whitespace-only search logs,
redacted/shortened snippets with visible disclosure, focus access, failed/unproven results,
and execution-ID isolation through the actual ChatTranscript. Existing chat
scenarios are retained. CI and a built browser scenario remain required.
No new code was deployed or live Keeper instructions modified in this worktree.

Still outside this slice: full-file/git diffs, write/insert tool variants,
blob hydration, LSP status, persisted workspace comments, and live autonomous
edit proof. Requirement 15 and the complete 18-item objective remain open.
