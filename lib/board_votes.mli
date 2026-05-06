(** Board_votes — voting + karma + flair on top of the
    Board_core store.

    Cascade-include extends {!Board_core} (which itself
    includes {!Board_core_classify} and {!Board_core_payload})
    via [include module type of struct include Board_core end].
    Type identity propagates end-to-end across the chain
    (cycle 187 rationale).

    The {!Board} top-level facade ([lib/board.ml]) is the
    final hop in the cascade — it does
    [include Board_votes] and re-exports every entry below
    plus the entire Board_core surface to the wider codebase.

    External callers reach 5 dotted [Board_votes.X] symbols
    plus 17 [Board.X] entries that resolve into Board_votes
    defs.  All are pinned below.

    Internal helpers stay private at this boundary:
    - {b Vote-direction normaliser}: [all_vote_directions],
      [vote_direction_of_string_opt].
    - {b Vote log persistence}: [append_vote_log],
      [rewrite_vote_log].
    - {b Internal vote outcome}: the [vote_outcome] record
      carries the score delta, optional fresh peer-upvote economy
      credit, and post-lock vote log / feedback side effects.
    - {b Persistence loaders}: [load_persisted_posts],
      [load_persisted_comments], [load_persisted_votes],
      [recalculate_reply_counts].
    - {b Quarantine helpers}: [is_fixture_voter_target],
      [quarantine_enabled].
    - {b Global store}: [global_lazy] ref.
    - {b Flair extractor internals}: [flair_tag_re],
      [extract_flair]. *)

include module type of struct
  include Board_core
end

(** {1 Vote direction wire format} *)

val vote_direction_to_string : vote_direction -> string
(** Lower-cased canonical encoding ([Up] → ["up"], [Down] →
    ["down"]).  Consumed by the JSONL persister and the
    operator dashboard. *)

val valid_vote_direction_strings : string list
(** SSOT mirror of the encoded forms that
    [vote_direction_of_string_opt] accepts.  Used by the
    JSON Schema generator for the [direction] enum field
    in the vote MCP tool. *)

val all_vote_directions : vote_direction list
(** Witness list — one entry per {!vote_direction}
    constructor, in declaration order. *)

val vote_direction_of_string_opt : string -> vote_direction option
(** Sound partial parser: case-insensitive, trims whitespace.
    [""] is accepted as [Some Up] for back-compat with
    [tool_board.ml] which defaults to ["up"] when the field
    is missing.  Unknown input returns [None] (no silent
    permissive fallback).  Pinned for behaviour-tests under
    {!test/test_types}. *)

(** {1 Vote log path} *)

val vote_log_path : unit -> string
(** Path to the append-only vote log JSONL under
    [<base>/.masc/board-votes.jsonl].  The internal append
    + rotate path mirrors the post / comment writers in
    {!Board_core}. *)

(** {1 Voting} *)

val current_vote_for_post :
  store ->
  voter:string ->
  post_id:string ->
  (vote_direction option, board_error) Result.t
(** Returns the persisted vote direction for [voter] on [post_id],
    if any. *)

val vote :
  store ->
  voter:string ->
  post_id:string ->
  direction:vote_direction ->
  (int, board_error) Result.t
(** Casts a vote on the post identified by [post_id].
    Returns [Ok delta] where [delta] is the new
    [(votes_up - votes_down)] score.  Validates [voter] +
    [post_id] before taking the lock; rejects duplicate
    votes in the same direction with [Already_voted].

    Vote flips swap up↔down without re-counting (and
    {b without} earning credits, to prevent down/up
    alternation abuse).  Fresh peer upvotes earn the post
    author a credit via [Agent_economy.earn] {b outside}
    the lock so the ledger write does not block other
    readers.  Every vote is broadcast to
    {!Thompson_sampling.record_vote} outside the state lock
    for posterior feedback. *)

val current_vote_for_comment :
  store ->
  voter:string ->
  comment_id:string ->
  (vote_direction option, board_error) Result.t
(** Returns the persisted vote direction for [voter] on [comment_id],
    if any. *)

val vote_comment :
  store ->
  voter:string ->
  comment_id:string ->
  direction:vote_direction ->
  (int, board_error) Result.t
(** Same shape as {!vote} but targets a comment via its
    [comment_id]. *)

(** {1 Stats} *)

val stats : store -> Yojson.Safe.t
(** Returns an [`Assoc] with [post_count],
    [comment_count], [expired_pending], [last_sweep], and
    [backend = "jsonl"].  Consumed by the operator
    dashboard's at-a-glance health card. *)

(** {1 JSONL row decoders} *)

val visibility_of_string : string -> visibility option
(** Re-export of {!Board_core_classify.visibility_of_string}.
    Pinned at this layer so callers reach it via the
    {!Board} facade unchanged. *)

val post_of_yojson : Yojson.Safe.t -> post option
(** Decodes a single persisted-post JSON row.  Returns
    [None] when any required field is missing or any id /
    visibility / post-kind parser rejects the value;
    legacy rows missing [updated_at] / [post_kind] /
    [hearth] are accepted with the canonical defaults
    derived via {!legacy_migrate_post_kind}. *)

val comment_of_yojson : Yojson.Safe.t -> comment option
(** Decodes a single persisted-comment JSON row.  Same
    fail-soft contract as {!post_of_yojson}. *)

(** {1 Hearth aggregation} *)

val list_hearths : store -> (string * int) list
(** Returns [(hearth, post_count)] pairs sorted by count
    descending.  Posts with no [hearth] are skipped. *)

(** {1 Mutation helpers} *)

val set_thread_id :
  store ->
  post_id:string ->
  thread_id:string ->
  (unit, board_error) Result.t
(** Pins [thread_id] onto the post.  Used by the
    Conversation linker to bridge a Board post to a
    persisted Conversation thread. *)

val delete_post :
  store -> post_id:string -> (unit, board_error) Result.t
(** Removes the post and every comment under it from the
    in-memory store.  The JSONL log keeps the original
    rows; the rewriter on next flush overwrites the file
    without them. *)

(** {1 Global store + lifecycle} *)

val global : unit -> store
(** Lazy singleton.  First call constructs the store via
    {!create_store}, then runs the four loaders
    ([load_persisted_posts] / [_comments] / [_votes] +
    [recalculate_reply_counts]) under
    [Eio.Lazy.from_fun ~cancel:`Protect] so a cancelled
    fiber cannot leave the singleton half-initialised. *)

val reset_global_for_test : unit -> unit
(** Reinstalls a fresh lazy singleton.  Safe to call only
    from test setup before concurrent fibers exist. *)

val flush_dirty : store -> unit
(** Flushes dirty post/comment snapshots to the JSONL files
    with a short in-memory snapshot lock and append-only disk
    writes.  When dirty vote targets exist, compacts the vote
    log from the same timestamp-preserving in-memory snapshot.
    Stamps [last_flush] with the wall clock. *)

(** {1 Karma} *)

val karma_score_for_direction : vote_direction -> int
(** Scoring contract: [Up] → [+1], [Down] → [0].
    This is the single source of truth for karma scoring.
    Replay and rebuild operations must use this function so that
    a scoring-rule change takes effect everywhere simultaneously. *)

val build_karma_ledger : store -> karma_event list
(** Rebuild the full karma ledger from the in-memory vote log and
    author tables.  One {!karma_event} is emitted per [Up] vote
    whose target post/comment still exists in the store and whose
    voter differs from the content author.

    The function:
    - Holds the store lock for the duration of the snapshot.
    - Returns events sorted ascending by [ts] (oldest first) so
      callers can replay them in chronological order.
    - Silently drops votes whose target has since been deleted
      (content gone, vote orphan — not an error).
    - Excludes self-upvotes from karma. The board score can still
      record a self-vote, but reputation is peer recognition only.

    Replay contract: [totals_of_karma_ledger (build_karma_ledger s)]
    must equal the output of [get_all_karma s]. *)

val totals_of_karma_ledger : karma_event list -> (string * int) list
(** Aggregate [(recipient, total_karma)] pairs from a ledger.
    Sorted descending by total (highest karma first).
    Complement to {!build_karma_ledger} for the rebuild path. *)

val karma_event_to_yojson : karma_event -> Yojson.Safe.t
(** JSON serialiser for a single karma event.  Wire format:
    [{recipient, voter, target_kind, target_id, delta, ts, ts_iso}].
    [ts_iso] is RFC-3339 UTC (["YYYY-MM-DDTHH:MM:SSZ"]). *)

val get_agent_karma : store -> agent_name:string -> int
(** Returns the karma projection for [agent_name] from the same
    ledger-backed totals used by {!get_all_karma}.  Self-upvotes are
    excluded. *)

val get_all_karma : store -> (string * int) list
(** Returns [(agent_name, total_peer_upvotes)] for every author in
    the store by replaying the karma ledger.  Memoised in
    [store.karma_cache] —
    {!invalidate_post_caches} and
    {!invalidate_comment_caches} clear the entry on every
    relevant mutation. *)

(** {1 Flair} *)

val available_flairs : (string * string * string) list
(** Curated flair catalogue.  Each entry is
    [(slug, emoji, label)] (e.g. [("insight", "💡",
    "Insight")]).  Consumed by the dashboard chip renderer
    and by {!flair_to_yojson} when serialising a
    karma-enriched post. *)

val flair_to_yojson :
  string * string * string -> Yojson.Safe.t
(** Wire encoder for a single flair entry.  Emits
    [`Assoc [("name", _); ("emoji", _); ("label", _)]]. *)

val post_to_yojson_with_karma :
  post -> author_karma:int -> Yojson.Safe.t
(** Karma-enriched serialiser used by the dashboard:
    extends {!post_to_yojson} with [author_karma],
    [classification_reason], extracted [flair], and a
    pre-computed [score = votes_up - votes_down] so the
    client does not have to derive it. *)

(** {1 Fixture-voter quarantine (#9886)} *)

val is_fixture_voter_target : string -> bool
(** Returns [true] when [target] (a [room:agent] tuple or bare
    agent name) refers to a fixture / synthetic / test voter.
    Matches the [hot-voter-] / [synthetic-voter-] /
    [test-voter-] prefixes that production traffic never uses.
    Pinned for behaviour-tests under
    {!test/test_board_fixture_detector}. *)

val quarantine_enabled : unit -> bool
(** Reads [MASC_BOARD_VOTE_QUARANTINE] (default [true] —
    production-ledger #9886 measured 100% fixture-pattern votes
    orphaning ranking).  Returns [false] only when the env is
    explicitly set to [0] / [false] / [off] / empty.  Pinned
    for behaviour-tests under
    {!test/test_board_vote_quarantine}. *)
