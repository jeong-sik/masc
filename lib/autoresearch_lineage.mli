(** Autoresearch_lineage — shared actor names and tag contract
    for autoresearch feedback artifacts.

    Lesson and finding records produced across the autoresearch
    loop need to describe the same lineage consistently: which
    internal actor generated the record, which loop actor
    participated, and which baseline tags make the record
    discoverable from search.

    Internal helpers (the [actor] variant, the [actor_name]
    derivation, and the [normalize_tag] string trimmer) are
    hidden — callers consume only the materialised string
    constants and the {!finding_tags} composer. *)

val lesson_reviewer_actor_name : string
(** ["autoresearch-reviewer"] — the agent name attributed to
    lesson-review writes. Pinned at the contract seam because
    the dashboard / search index depend on the exact spelling. *)

val cycle_runner_actor_name : string
(** ["autoresearch_cycle"] — the agent name attributed to
    cycle-runner writes. Different shape (underscore, no
    "reviewer" suffix) is intentional and historic; do not
    "harmonise" without an explicit migration. *)

val cycle_failure_participants : string list
(** [[lesson_reviewer_actor_name; cycle_runner_actor_name]] —
    the canonical participant list embedded in
    cycle-failure lessons so retrospective queries can match
    either actor. *)

val domain_tag : string
(** ["autoresearch"] — the always-present root tag in
    {!finding_tags} output. *)

val finding_tags :
  target_file:string ->
  extra:string list ->
  string list
(** Compose a deduplicated tag list for a finding record.

    Order: {!domain_tag} first, then [target_file] (when
    non-empty after trim), then each member of [extra] in input
    order. Empty / whitespace-only entries are dropped via the
    internal [normalize_tag]; duplicates are filtered with
    first-occurrence wins so the result is stable across
    re-renders of the same finding. *)
