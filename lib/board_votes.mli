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
      ({delta; earn_upvote_for}) is consumed only inside the
      vote / vote_comment paths to gate the
      [Agent_economy.earn] credit on the fresh-upvote path.
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

(** {1 Vote log path} *)

val vote_log_path : unit -> string
(** Path to the append-only vote log JSONL under
    [<base>/.masc/board-votes.jsonl].  The internal append
    + rotate path mirrors the post / comment writers in
    {!Board_core}. *)

(** {1 Voting} *)

val vote :
  store ->
  voter:string ->
  post_id:string ->
  direction:vote_direction ->
  (int, board_error) result
(** Casts a vote on the post identified by [post_id].
    Returns [Ok delta] where [delta] is the new
    [(votes_up - votes_down)] score.  Validates [voter] +
    [post_id] before taking the lock; rejects duplicate
    votes in the same direction with [Already_voted].

    Vote flips swap up↔down without re-counting (and
    {b without} earning credits, to prevent down/up
    alternation abuse).  Fresh upvotes earn the post
    author a credit via [Agent_economy.earn] {b outside}
    the lock so the ledger write does not block other
    readers.  Every vote is broadcast to
    {!Thompson_sampling.record_vote} for posterior
    feedback. *)

val vote_comment :
  store ->
  voter:string ->
  comment_id:string ->
  direction:vote_direction ->
  (int, board_error) result
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
  (unit, board_error) result
(** Pins [thread_id] onto the post.  Used by the
    Conversation linker to bridge a Board post to a
    persisted Conversation thread. *)

val delete_post :
  store -> post_id:string -> (unit, board_error) result
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
(** Flushes [dirty_posts] / [dirty_comments] back to the
    JSONL files via {!rewrite_posts} / {!rewrite_comments},
    then atomically rewrites the vote-log.  Stamps
    [last_flush] with the wall clock.  Call on shutdown to
    prevent data loss from the deferred-flush write path. *)

(** {1 Karma} *)

val get_agent_karma : store -> agent_name:string -> int
(** Sums [votes_up] across every post + comment authored
    by [agent_name].  Lock-free read of the in-memory
    [posts] / [comments] tables. *)

val get_all_karma : store -> (string * int) list
(** Returns [(agent_name, total_upvotes)] for every author
    in the store.  Memoised in [store.karma_cache] —
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
