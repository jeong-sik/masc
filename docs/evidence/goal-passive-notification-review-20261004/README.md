# Passive Goal notification review response

Review findings on #41053:
- P1 `4176362396`: a Goal title/evidence containing @beta was parsed again by the
  recipient transcript writer, turning passive informational content into mention
  metadata that the observation lane classifies as pending Mention.
- P2 `4176362392`: a nonempty malformed notification ID was accepted by Goal_store
  but permanently refused by Broadcast delivery, allowing continued mutation of a
  corrupted outbox.

The shared workspace request identity owner now mints and validates the canonical
wmsg- plus 32 lowercase hex shape. Broadcast filenames/delivery and Goal outbox
use that same parser. Invalid notification identities make the authoritative Goal
source unavailable and prevent mutation.

The transcript append-once API has an explicit Parse_mentions / Passive_context
policy. The passive fleet projection selects Passive_context, preserves literal
content and persists an explicit empty mentions array. Normal inbound callers
keep parsing mentions. Append-once still preserves an already accepted mention row;
a later fleet pass cannot erase its metadata or duplicate it.

## Native evidence

The same nine registered cases fail seven times against parent sources and pass
9/9 against the candidate. They cover external and Keeper passive projection with
literal mentions, duplicate delivery, preserving a prior active mention, canonical
ID acceptance and five malformed ID forms refusing the Goal store and mutation.

The complete candidate workspace ID, Workspace_broadcast, Goal_store and
Keeper_chat_store modules were natively compiled. Execution uses the exact server
append_workspace_message_to_recipient function extracted unchanged, its real
filesystem writes and the registered suite with module aliases. Lower dependencies
are cached. The complete server module and reactive Keeper turn scheduler have not
been built/executed; empty persisted mention IDs are verified at the storage boundary.

Additional existing suites exercise append failures, approval identity and raw
Broadcast content. Their full outputs and manifests are retained here.

Runner: `python3 check-notifications.py CHECKOUT CACHE_CHECKOUT`.
Add `--source-ref 2bd58f3cc4d3ef5c0e102d1c5eb50bd41fe3d62e` for the failing parent.
The script creates its own temporary directory, prints it and propagates failures.
Use `--suite` for the explicitly listed existing suites. For the baseline, only the
new workspace identity module (not called by the parent) comes from the candidate.

No full product build, CI, production restart, provider execution, independent
approval, merge or deployment is claimed. Parent #41053 was merged by another
session while this follow-up was in progress; its findings remain addressed by
this child until the child itself is integrated. D3/D4 remain separate work.
