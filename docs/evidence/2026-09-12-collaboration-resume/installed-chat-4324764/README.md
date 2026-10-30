# Installed autonomous Edit acceptance

The isolated service on port 18951 now runs source `4324764e959a5ff8b265b292e5bab9f68e550313`. Its embedded identity, health response and independently recomputed executable SHA256 agree: `a38ff7f2e6ecbd9efe6dcfbb2469d67e56e837f3cad7eba0fa2f7eed6571643a`. Both the exact-source Test and full Release workflows succeeded; see `ci-snapshot.json`.

`receipt.json` is the successful installed-browser observation at 2026-09-12T16:52:39Z. It opened the real historical autonomous Edit `exec-1789223431021-0129` by exhibit-editor, turn 428, through the actual API and installed Dashboard assets. The output manifest, original blob bytes and displayed before/after text agree. Applying the displayed patch reconstructs the after bytes. All 83 fetched assets match the installed manifest, and the actual diff worker loaded. No page errors, HTTP failures or probe assertion failures were observed. WebSocket and write requests were blocked by the read-only probe; responses were not fixture replacements.

- Before: 12,602 bytes, SHA256 `5237a2dd6de137936ab964ace1c4057a8f9a78f77fb2d5f99e1d7a269c52cbcf`.
- After: 12,641 bytes, SHA256 `18e044a0f658da739b69c84a8a7993e9579a13c0ff4becab69071353be14659a`.
- `displayed.diff`: SHA256 `7a83bed9daf8e1aa305c6068992b5869ebdf6b0bfe91edfc321197e46cf4d5f7`.
- Desktop: `chat-edit-desktop.png` and `edit-record-desktop.png`.
- Mobile, 390 by 844: `chat-edit-mobile.png` and `edit-diff-mobile.png`. The diff is explicitly brought into view; the document has no horizontal overflow, while long code lines scroll inside the diff pane.

The first installed probe also passed. Its mobile screenshot showed the after-text pane, so the final capture above specifically scrolls to and captures the diff. Older failed attempts remain in the parent evidence directory. The probe correction is in `scripts/verify-installed-chat-edit.mjs`.

`runtime-and-goals.json` preserves a fresh health/source check and the restart comparison: 98 files in its stated scope, 96 unchanged, two memory journals appended with their original byte prefixes intact, no missing files. All three scenario Goals still await human confirmation. This establishes display of one actual historical autonomous Edit; it does not establish a new autonomous turn, installed LSP behavior, general UI acceptance, or completion of the full 18-item goal.

Scope correction from a later path audit: the 98-file restart snapshot did not include the canonical Task backlog at `.masc/tasks/backlog.json`. Its original broad "domain files" label must not be read as complete domain coverage. The comparison establishes preservation only for the listed files; it does not prove byte preservation of the Task backlog across that restart. Subsequent restart captures must explicitly include the canonical backlog.
