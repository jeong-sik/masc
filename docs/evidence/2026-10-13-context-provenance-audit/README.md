# Context provenance boundary audit

Base examined: `8b94bb037199d62655f376a8b6542fcbb4795a7f` (PR #42713).
This is a bounded source audit, not fleet or live-provider certification.

## Confirmed: finalization discarded reasoning provenance

`Types.assistant_message_of_response` attaches the producing reasoning source to
message metadata. `Keeper_replay_checkpoint.canonical_success_replay_checkpoint`
calls `Keeper_context_core.patch_checkpoint_last_assistant` when persisting a
visible reply. That function rebuilt the last assistant using `make_message`
without metadata, even if the visible text was already unchanged. The next
`Reasoning_history_projection.project` classified the source as absent and
removed its reasoning with `Missing_reasoning_source`.

This affects metadata-bearing reasoning across provider families. Keeping the
block alone was insufficient: the existing finalization test checked that a
Thinking block remained but never checked its provenance or subsequent replay.

The repair preserves all message metadata and avoids rebuilding an unchanged
message merely because metadata exists. Added cases exercise canonical
finalization, checkpoint disk save/load, and the shared replay projection for
Anthropic, Gemini and OpenAI opaque-state source contracts. They check that the
same source retains the artifact and a different endpoint is rejected for
incompatibility, not missing provenance. These are synthetic contract fixtures,
not live-provider signature tests. Visible-text normalization and replay policy
are unchanged.

## Separate finding: memory history ignored runtime context provenance

`Keeper_memory_recall.user_messages_newest_first` selects every User-role
checkpoint message. `Keeper_tool_memory_runtime.search_history` presents those
bodies through `keeper_memory_search` with `source=history` or `source=all`.
Consequently a Historical context retained by PR #42713 is searchable as a
previous user statement. The follow-up change applies the same typed filter to
checkpoint extraction and the disk-history reader. Current/historical context
is omitted; malformed or duplicate context provenance is omitted with a
diagnostic. Malformed disk rows count toward existing unreadable-row reporting.
Unrelated metadata does not exclude ordinary User-role messages.

The regression calls the actual `keeper_memory_search` tool with both `history`
and `all`: checkpoint and disk contexts containing a private sentinel must not
match, while ordinary text remains searchable. Its result also checks disk
metadata error reporting. Checkpoint provenance errors remain log-only; this
change does not widen the search result schema.

## Other boundaries inspected

- Checkpoint message JSON and Keeper history JSON preserve metadata.
- Shared reasoning replay distinguishes absent, malformed, duplicate and
  incompatible sources and performs provider/endpoint compatibility checks.
- Provider serializers derive replay from that shared projection; their
  wire-specific transformations are not written back into canonical history.
- Synthetic media follow-ups are transport projections, not saved user input.
- The previous PR distinguishes current and historical runtime context in
  prompt metrics, windowing, official-client composition and Librarian input.

No additional defect is asserted from these inspections. They do not establish
that every runtime consumer or wire-level prefix edit has been covered.

## Verification boundary

Both repairs' changed OCaml files passed parser-only validation and `git diff
--check`. The added behavioral cases require execution in CI. Local Dune builds
and tests were not run under the repository execution protocol. No runtime
checkpoint or installed binary was modified.
