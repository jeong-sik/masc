Independent source review: committed projection identities

Head `16dd4aa47803259dc516a1c2acbc244d9985c0cd`, base `c63ecd3094eeda1fe5bc7d0e03a0057961a45a81`. Source `bin/masc_tui_render_chat.ml` SHA-256 `a31655fc4e45e82dcae44b828b5becfc0e72d725f6add536842b842d1ec69a0d`. Diff: one file, 21 insertions and 5 deletions. Worktree was clean when observed; `git diff --check` passed.

Verdict: no unresolved P0/P1/P2 finding in this delta.

The new single-slot memo is a pure pairing of its two complete inputs. It requires physical equality of both the immutable visible timeline and the layout list. It reads no workspace, Keeper, live log, preview or state value. A timeline change rebuilds row tags even when the layout happens to reuse entries. Shared empty lists across contexts correctly produce the same empty output.

`msg_entry` and its anchor identity fields are immutable (`masc_tui_types.ml:1153-1228`); the bin/test scan found no mutable `me_` field or field assignment. `chat_rows_for` accounts for Keeper, loaded/history/session lists, selected transcript revisions, settled logs, queue and tools (`types.ml:21517-21569`). The visible timeline and layout caches preserve their existing visibility, width, owner, palette, preview and metadata invalidation (`render_chat.ml:1369-1425`, `2181-2244`).

The search index only reads tag identity/role/request/phase/sequence/reply source (`3453-3468`, `3508-3555`), so it has no extra state dependency hidden by stable committed tags. Only immutable committed `Tagged_row` values enter the new memo. Owner diagnostic filtering, live/settled blocks, held/polled/pending/child/native projection remain downstream (`3194-3254`, `3358-3451`). No row body, mutable live log or wire/API value is newly cached.

This is a source verdict. No build, tests, CI query or product edit was performed. Native compilation and the existing search/pin semantic suites remain separate checks. No measured latency/GC/allocation improvement is claimed here. The mapping work changed timing-stage placement, so individual stage attribution does not prove total Build improvement.
