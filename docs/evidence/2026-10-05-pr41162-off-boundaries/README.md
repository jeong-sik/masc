# PR #41162 optional-off boundaries — 2026-10-05

Response against published head `758d8d672e90056c61ad07db996c2cf70b692797`; newer parent integration remains pending.

Disabled Exact HTTP slots now pass through the existing `Exact_output.admit_target_ref` grammar authority. Malformed references produce the existing typed rejection; well-formed targets absent from the catalog remain dormant. No grammar copy, interface change, enabled admission change or deadline/thinking policy change was introduced.

Account removal refuses to empty an Exact lane only when that lane is enabled. Both HTTP-slot and CLI-slot cases remove the sole account from optional `librarian_exact`, verify the provider is removed, and parse the retained explicitly off lane with empty candidates. Existing enabled-lane refusal remains covered. HITL is Required according to `Standalone_lane.obligation`: the initial off-HITL fixture was rejected by the parser and is retained in `excluded-required-fixture.log`, not claimed as the account-removal RED.

The existing real `Runtime.load_list` dormant-candidate assertions remain. This API intentionally skips registry admission, and raw saves before registry bootstrap also omit that gate, so exploratory expectations at those layers were unsuitable and are not RED proof for this change. The malformed-reference regression parses real Runtime TOML and calls public `Runtime_exact_output_registry.check_publication`, the admission contract shared by publish. It accepts well-formed unavailable dormant candidates and requires the exact `Invalid_lane_slot` / `Invalid_target_ref` rejection for `../target`.

Actual old-branch admission RED: handle 42565 exit 1, after temporarily rebuilding the original registry production file with the new test; the fixed file was restored before the final build. Actual optional-account RED: handle 95406 exit 1. Final resource-limited two-target build passed (80167), then **147 config tests + 8 account-removal tests passed**, each exit 0. Commands, source/binary hashes and exact raw log hashes are in `checks.json`. The full config run includes Required, enabled, dormant, deadline and thinking checks.

These are focused native tests, not the full suite, Web/browser/PTY execution, hosted CI, deployment or release proof. No source changes occurred during active checks; raw output bytes are unchanged.
