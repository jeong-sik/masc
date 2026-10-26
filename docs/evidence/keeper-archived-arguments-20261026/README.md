# Archived tool arguments and fresh calls

The Keeper hour audit observed nine actual calls whose top-level input was a
`_blob` reference instead of required fields. These were invocation validation
failures, not merely shortened log display. Follow-up work is tracked in #46210.

The [sanitized provenance receipt](provenance.json) verifies one earlier
provider input against its canonical checkpoint and immutable artifact bytes.
The original private conversations, tool arguments and filesystem paths are
not included. The receipt therefore preserves verification identifiers and
results, not a publicly replayable copy of that private corpus.

The captured request contains 467 historical `ToolUse` argument references:
285 Execute, 150 Write, 16 Board posts, 4 Edit and 12 Board comments. One Write
argument artifact has 929 bytes; its content hash and size match, and its parsed
JSON equals the canonical checkpoint's original `file_path`/`content` input.
The provider-bound representation at that occurrence contains only `_blob`.
The same request's Write schema still requires `file_path` and `content`.

This is the intended source path in `Keeper_model_input_demotion.with_reference`:
only verified completed arguments can become references in the provider-bound
copy, while canonical state retains the original JSON. The artifact reader
already describes restoring such arguments and accepts an exact `sha256`.
The shared prompt now explains this distinction before a Keeper loads any
particular deferred tool: a historical reference is not a new invocation's
argument object, a preview is not the complete JSON, and only schema-declared
artifact fields accept a reference directly.

This change adds no automatic unwrapping, invented-hash recovery, schema
relaxation, mandatory reading of all historical arguments, retry loop or runtime
budget. Existing `test_keeper_model_input_demotion` completed-arguments scenarios
remain the relevant source-level contract; no prompt-text matching test was
added. `git diff --check` and the existing prompt-path validation passed.

No fresh model calls were executed. The receipt proves the historical
reference/original/schema relationship; it does not establish causation for a
particular later bad call or prove that this guidance reduces model errors.
Actual model replay and installed prompt adoption remain separate verification.
