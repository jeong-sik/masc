(** Voting, statistics, post mutations, snapshot settlement, karma and flair.

    Extends {!Board_core} with canonical Board types. The {!Board} facade in
    [lib/board/board.ml] includes this module and re-exports its public API.

    Private [Board_voting] owns vote queries, casts and vote-log writes.
    Its constructor witness, append helper, renderer and snapshot saver stay
    hidden at this public boundary. [Board_store_load] owns persistence
    loading and count rebuilding; [Board_store_lifecycle] owns the global
    lazy cell. Snapshot selection and retry settlement remain here. *)

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
    [vote_direction_of_string_opt] accepts.  Used by the JSON Schema
    generator for the [direction] enum field in the vote MCP tool. *)

val vote_direction_of_string_opt : string -> vote_direction option
(** Sound partial parser: case-insensitive, trims whitespace, and
    accepts only ["up"] / ["down"].  Empty or unknown input returns
    [None] (no silent permissive fallback). *)

(** {1 Vote log path} *)

val vote_log_path : store -> string
(** Path to the append-only vote log JSONL under the board directory
    captured by the store — the same workspace used by
    [persist_path] / [comments_path] / [reactions_path] / [sub_boards_path],
    so this is [<base>/.masc/board_votes.jsonl].  Each accepted row
    has exactly [target], [voter], [direction], and positive finite [ts]
    fields; [target] carries canonical typed target/voter identities and the
    derived [voter] field must match it. *)

val reload_votes : store -> (int, board_error) result
(** Explicit source/model reload under persistence then state. A complete load
    replaces the ledger, retains valid orphan votes and rebuilds counts. The
    result counts accepted physical rows. Reload refuses while a deletion is
    pending. Unknown writes and interrupted model publication remain fail-stop
    and require a fresh store. *)

(** {1 Voting} *)

val current_vote_for_post :
  store ->
  voter:string ->
  post_id:string ->
  (vote_direction option, board_error) Result.t
(** Known vote direction in this store's readable source model. An incomplete
    or unavailable vote source returns [Io_error], not a claim of no vote. *)

val vote :
  store ->
  voter:string ->
  post_id:string ->
  direction:vote_direction ->
  (int, board_error) Result.t
(** Casts a vote on the post identified by [post_id].
    Returns [Ok total_score] — the post's [(votes_up - votes_down)]
    score {b after} this vote, not the amount this vote changed it.
    Validates [voter] + [post_id] before taking the lock; rejects
    duplicate votes in the same direction with [Already_voted].

    Vote flips swap up↔down without re-counting (and
    {b without} earning credits, to prevent down/up
    alternation abuse).

    Staging, exact-source append and fresh model publication share one
    persistence interval. The model changes only after known file success;
    acknowledgement follows a normally successful model callback. A proven
    nonwrite leaves the model unchanged. Unknown file effects and interrupted
    model publication retain their exact source evidence and require a fresh
    store; a normal error does not authorize replay. *)

val current_vote_for_comment :
  store ->
  voter:string ->
  comment_id:string ->
  (vote_direction option, board_error) Result.t
(** Same readable-source rule as {!current_vote_for_post}. *)

val vote_comment :
  store ->
  voter:string ->
  comment_id:string ->
  direction:vote_direction ->
  (int, board_error) Result.t
(** Same write-ahead shape as {!vote} but targets a comment via its
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
(** Decodes one row emitted by the current {!post_to_yojson} writer.  Returns
    [None] unless the field set, JSON types, identifiers, derived values, and
    optional typed objects match that current wire shape exactly. *)

val comment_of_yojson : Yojson.Safe.t -> comment option
(** Decodes one row emitted by the current {!comment_to_yojson} writer, with
    the same exact current-wire contract as {!post_of_yojson}. *)

(** {1 Hearth aggregation} *)

val list_hearths
  :  store
  -> ?exclude_system:bool
  -> ?exclude_automation:bool
  -> unit
  -> (string * int) list
(** Returns [(hearth, post_count)] pairs sorted by count
    descending. Posts with no [hearth] are skipped. Optional post-kind filters
    use the same classification contract as Board post listing. *)

(** {1 Mutation helpers} *)

val set_thread_id :
  store ->
  post_id:string ->
  thread_id:string ->
  (unit, board_error) Result.t
(** Pins [thread_id] onto the post.  Used by the
    Conversation linker to bridge a Board post to a
    persisted Conversation thread. *)

val set_pinned :
  store ->
  post_id:string ->
  pinned:bool ->
  (unit, board_error) Result.t
(** Sets the post's [pinned] flag (operator-curated pin).
    Marks the post dirty so the change persists to
    posts.jsonl and survives restart. *)

type close_successor =
  | No_successor
  | Successor of string
(** A close must state its successor decision explicitly: [Successor id]
    continues the thread, [No_successor] says there is none. There is no
    default -- a caller that names neither is refused, so a missing
    successor is never silently read as "none". *)

val set_closed :
  store ->
  post_id:string ->
  closed_by:string ->
  successor:close_successor ->
  summary:string ->
  unit ->
  (unit, board_error) Result.t
(** Records a typed close (task-1758/#39356): who closed it, the successor
    decision, and why. Permission (author/operator/configured moderator) is
    checked by the caller before this runs, the same boundary as
    [set_pinned]. Persists immediately via [append_post], durable before the
    call returns. [summary] must be non-empty after trimming and [successor]
    must name a decision; a whitespace-only summary or a missing decision is
    refused as [Validation_error] with no write. A [Successor] id must
    resolve to an existing post and cannot equal [post_id]; either violation
    is refused as [Validation_error] with no write. *)

val reopen :
  store -> post_id:string -> (unit, board_error) Result.t
(** Clears a post's [closed] state back to open. Idempotent: reopening an
    already-open post is [Ok ()]. Same permission boundary as [set_closed]. *)

type deletion_outcome =
  | Durable_deletion
  | Deletion_persistence_pending of string
      (** The deletion is applied in memory. Failed and unattempted rewrites
          remain ordered work for [flush_dirty]. The detail names actual write failures. *)

val delete_post :
  store -> post_id:string -> (deletion_outcome, board_error) Result.t
(** Removes the post and every comment under it from the
    in-memory store, then rewrites the posts, comments, vote
    and reaction snapshots without them.  Refused with
    [Io_error], before anything changes, while any of those
    four stores did not load fully: the rewrite would delete
    the rows memory never held (#38595). [Error] always means no deletion
    was applied. Once applied, [Ok Durable_deletion] means all four rewrites
    succeeded; [Ok (Deletion_persistence_pending detail)] keeps the applied
    transition distinct from a refused write. Retrying deletion is not a
    persistence retry: the post is already absent; [flush_dirty] retries the
    failed and unattempted snapshots in deletion order, stopping on the first
    error again. A temporary nonwrite that retains source authority can retry
    after repair. A conflicting/refused source requires a fresh store: partial
    reload cannot safely reconstruct the pending deletion's models. The fresh
    store keeps completed file writes but does not replay the memory-only
    intent, so an unwritten parent deletion can reappear. Pending is not durable
    completion. #26378 retains deletion-decision and multi-source recovery work. *)

(** {1 Global store + lifecycle} *)

val global : unit -> store
(** Lazy singleton.  First call constructs the store via
    {!create_store}, then runs the five loaders
    ([load_persisted_posts] / [_comments] / [_votes] / reactions / sub-boards +
    [recalculate_reply_counts]) under
    [Eio.Lazy.from_fun ~cancel:`Protect] so a cancelled
    fiber cannot leave the singleton half-initialised. *)

val reset_global_for_test : unit -> unit
(** Reinstalls a fresh lazy singleton.  Safe to call only
    from test setup before concurrent fibers exist. *)

val flush_dirty : store -> unit
(** Atomically replaces each dirty post/comment snapshot independently, or
    retries all sources in deletion order while deletion work remains pending.
    Captures data under the state lock and serializes snapshot writers with
    the persistence lock. Independent flushes compact readable vote/reaction
    ledgers when either table is dirty. Deletion retries retain all four
    obligations, leaving later compaction pending after a failed prerequisite.
    This does not pause every other writer. Source refusals remain refused;
    retrying does not refresh their authority. Posts write failures, including
    retained refusals, are recorded by the source writer's persist-error path.
    Stamps [last_flush] with the wall clock. *)

(** {1 Karma} *)

(** A single attributed karma event.  One event is generated per upvote
    received by an agent.  Downvotes do not generate karma events
    (scoring rule: [Up] = +1, [Down] = 0). *)
type karma_event = {
  recipient : string;
  (** Agent who earned the karma — author of the upvoted post or comment. *)
  voter : string;
  (** Agent who cast the upvote. *)
  target_kind : Board_vote_key.target_kind;
  (** The upvoted content's kind, read off the vote key. *)
  target_id : string;
  (** Identifier of the upvoted post or comment. *)
  delta : int;
  (** Karma delta.  Always [+1] per upvote under the current scoring
      contract.  Stored explicitly so future rule changes are backward
      compatible — older events keep their original delta value. *)
  ts : float;
  (** Unix timestamp at which the upvote was cast (seconds since epoch). *)
}

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
    [(name, emoji, label)] (e.g. [("insight", "💡",
    "Insight")]).  Consumed by the dashboard badge renderer
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
    caller-supplied [classification_reason] when present in metadata,
    extracted [flair], and a
    pre-computed [score = votes_up - votes_down] so the
    client does not have to derive it. *)

val get_karma_by_post : store -> (string * (string * int) list) list
(** Cached recipient -> parent post -> earned delta, sharing the lifetime and
    invalidation of [get_all_karma]. Comment votes resolve to their parent. *)
