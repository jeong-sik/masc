(** Board_core — in-memory board store, persistence, and
    canonical post / comment operations.

    The .ml is a 687-line module that splits into four
    layers:

    - {b Type / classification} re-exported via
      [include Board_core_classify] (which itself does
      [include Board_types]) — every {!Board_types} surface
      entry, every visibility / post-kind variant, and the
      [reclassify_report] record reach callers via this
      facade.
    - {b Payload normalisation} re-exported via
      [include Board_core_payload] — state-block extraction,
      post-title derivation, and the canonical
      [normalize_post_payload].
    - {b Local store + persistence} (this .mli's locally
      pinned surface) — sweeper / lock / cache /
      JSONL-rotate / append helpers.
    - {b Public board operations} — create / get / list /
      search / reclassify post + comment APIs.

    Runtime-include preserves type identity end-to-end with
    [include module type of struct include M end] (cycle
    187 rationale).  {!Board_votes} does its own
    [include Board_core], which transitively reaches the
    top-level {!Board} facade — every helper consumed by
    that chain (the 13 unqualified usages from
    [board_votes.ml] plus the 15 [Board.X] dotted callers
    that resolve into Board_core defs) is pinned below.

    Internal helpers stay private at this boundary
    ([persist_errors] atomic counter, [record_persist_error],
    [remove_from_list_index], [maybe_sweep],
    [board_masc_dir], [ensure_dir], [max_jsonl_bytes],
    [append_post], [append_comment]). *)

include module type of struct
  include Board_core_classify
end

include module type of struct
  include Board_core_payload
end

(** {1 Persist-error counter} *)

(** Returns the cumulative count of persist failures since
    process start.  The counter is bumped by the internal
    [record_persist_error] path whenever a [Sys_error] is
    swallowed during JSONL append / rotate; consumed by the
    operator dashboard for at-a-glance health. *)
val persist_error_count : unit -> int

(** Record and log a board persistence failure. *)
val record_persist_error : where:string -> string -> unit

(** {1 Configuration} *)

(** Re-export of [Env_config.Board.flush_interval_sec].  How
    often the board flusher actor consumes a [Flush] message
    from {!store.flusher_inbox}. *)
val flush_interval_sec : float

(** {1 Store lifecycle} *)

(** Builds a fresh empty store with default Hashtbl capacities
    (1024 posts / 4096 comments / 2048 vote-log entries),
    fresh [Eio.Mutex], cold caches, and an [Eio.Stream]
    [flusher_inbox] capped by the persistence-layer flusher inbox capacity. *)
val create_store : unit -> store

(** Reset the per-author comment rate-limit tracker.  Test-only. *)
val reset_comment_rate_tracker : unit -> unit

(** Check whether [author] is currently rate-limited at time [now].
    Returns [Some retry_after] if the author has reached the limit,
    [None] otherwise. *)
val check_comment_rate_limit : author:string -> now:float -> float option

(** Record a comment timestamp for [author] at time [now].
    Used internally by [add_comment_with_status]; exposed for test
    manipulation of the sliding window. *)
val record_comment_timestamp : author:string -> now:float -> unit

(** {1 Locking + cache invalidation} *)

(** [with_lock store f] runs [f ()] under
    [Eio.Mutex.use_rw ~protect:true store.mutex].  Callers
    should keep the critical section short and avoid I/O —
    {!create_post} for instance emits its side-effect hook
    {b outside} the lock so the ledger write does not block
    every other reader / writer. *)
val with_lock : store -> (unit -> 'a) -> 'a

(** [with_persist_lock store f] serializes JSONL writes. Callers must not hold
    [with_lock] while acquiring it; compute any state snapshot under
    [with_lock], release it, then acquire [with_persist_lock]. *)
val with_persist_lock : store -> (unit -> 'a) -> 'a

(** Clears [karma_cache] and [sorted_posts_cache].  Called
    after every post mutation. *)
val invalidate_post_caches : store -> unit

(** Clears [karma_cache].  Called after every comment
    mutation (comments contribute to the karma rollup but
    not to the sorted-posts cache). *)
val invalidate_comment_caches : store -> unit

(** {1 Sweeper} *)

(** Drops expired posts / comments from the in-memory store
    in batches up to {!Limits.sweeper_batch_size}.  Permanent
    posts ([expires_at = 0.0]) are skipped.  Returns
    [(removed_posts, removed_comments)]. *)
val sweep : store -> int * int

(** {1 Persistence paths + rotation} *)

(** Resolves the board base path from {!Env_config}.  Used by
    {!persist_path}, {!comments_path}, and the
    side-effect hook integration in {!create_post}. *)
val board_base_path : unit -> string

(** Path to the board posts JSONL log under
    [<base>/.masc/board-posts.jsonl]. *)
val persist_path : unit -> string

(** Path to the board comments JSONL log under
    [<base>/.masc/board-comments.jsonl]. *)
val comments_path : unit -> string

(** Path to the board reactions JSONL snapshot under
    [<base>/.masc/board_reactions.jsonl]. *)
val reactions_path : unit -> string

(** Idempotent [.masc] directory creation; called before
    every JSONL append. *)
val ensure_masc_dir : unit -> unit

(** Rotates the JSONL file at [path] when it exceeds
    [max_jsonl_bytes] (10 MiB).  The previous file is
    renamed with a timestamp suffix; rotation failures are
    routed through the persist-error counter so the runtime
    keeps appending to the live file rather than aborting. *)
val rotate_if_needed : string -> unit

(** {1 Append-only persistence} *)

(** Appends one post snapshot to {!persist_path}. *)
val append_post : post -> unit

(** RFC-0233 §7: maintain the origin secondary indexes ([posts_by_turn_ref] /
    [posts_by_run_id]) from a post's [origin].  Used by the load path to
    rebuild the indexes that {!find_post_by_turn_ref} / {!find_post_by_run_id}
    read.  A [None] origin is a no-op. *)
val index_post_origin : store -> post -> unit

(** Appends one comment snapshot to {!comments_path}. *)
val append_comment : comment -> unit

(** {1 Whole-state JSONL rewrite} *)

(** Atomically rewrites {!persist_path} from
    [store.posts].  The implementation snapshots under [store.mutex]
    and performs disk I/O under the persist lock after releasing the
    state lock; callers must not invoke it while already holding
    [store.mutex]. *)
val rewrite_posts : store -> unit

(** Atomically rewrites {!comments_path} from
    [store.comments].  Same usage pattern as
    {!rewrite_posts}. *)
val rewrite_comments : store -> unit

(** Atomically rewrites {!reactions_path} from [store.reactions]. *)
val rewrite_reactions : store -> unit

(** Rewrites reactions assuming the caller already owns [store.mutex]. *)
val rewrite_reactions_unlocked : store -> unit

(** Marks one post for append-only deferred persistence.  Call with
    [store.mutex] already held. *)
val mark_dirty_post : store -> string -> unit

(** Marks one comment for append-only deferred persistence.  Call with
    [store.mutex] already held. *)
val mark_dirty_comment : store -> string -> unit

(** {1 Wire encoders} *)

val post_to_yojson : post -> Yojson.Safe.t

(** RFC-0233 §7: encode the typed post origin. Re-exported here so the
    dashboard board serializer ({!Board_votes.post_to_yojson_with_karma}) can
    reuse the single origin encoder. *)
val post_origin_to_yojson : post_origin -> Yojson.Safe.t
val comment_to_yojson : comment -> Yojson.Safe.t
val reaction_to_yojson : reaction -> Yojson.Safe.t
val reaction_of_yojson : Yojson.Safe.t -> reaction option
val reaction_summary_to_yojson : reaction_summary -> Yojson.Safe.t
val reaction_toggle_result_to_yojson : reaction_toggle_result -> Yojson.Safe.t
val reaction_target_type_to_string : reaction_target_type -> string
val reaction_target_type_of_string_opt : string -> reaction_target_type option
val valid_reaction_target_type_strings : string list
val board_reaction_emojis : string list

val reaction_key
  :  target_type:reaction_target_type
  -> target_id:string
  -> user_id:string
  -> emoji:string
  -> string

(** {1 Post operations} *)

(** Result of a create-post attempt before the legacy API folds it
    back to just the persisted/found post.  Dispatch layers use this
    to avoid re-emitting post-created fanout for receive-side dedup
    hits. *)
type create_post_outcome =
  | Fresh_post of post
  | Dedup_hit of post
  | Rolled_up_post of post

(** Extract the post carried by {!create_post_outcome}. *)
val post_of_create_post_outcome : create_post_outcome -> post

(** Creates a post and preserves whether the operation was fresh, a receive-side
    dedup hit, or a status-only automation rollup.  Same validation and
    persistence semantics as {!create_post}; fresh posts append JSONL + earn
    credits, while dedup/rollup hits return the existing post without those
    create-side effects. *)
val create_post_with_outcome
  :  store
  -> author:string
  -> content:string
  -> ?title:string
  -> ?body:string
  -> post_kind:post_kind
  -> ?meta_json:Yojson.Safe.t
  -> ?visibility:visibility
  -> ?ttl_hours:int
  -> ?hearth:string
  -> ?thread_id:string
  -> ?origin:post_origin
  -> unit
  -> (create_post_outcome, board_error) Result.t

(** Owner-gated in-place edit of an existing post's title/body.  Validates
    [editor] via {!Agent_id.of_string}, folds the canonical [title / body] via
    {!normalize_post_payload} (seeded with the existing [meta_json] so a [STATE]
    block in the edited body lifts into meta instead of being dropped), then
    replaces the stored post under {!with_lock} and persists a full JSONL
    snapshot.  Returns [Unauthorized] when [editor] does not own the post,
    [Post_not_found] for a missing id, and [Validation_error] for
    empty/oversized content.  [post_kind]/[visibility]/[hearth] are preserved. *)
val update_post_with_outcome
  :  store
  -> post_id:string
  -> editor:string
  -> content:string
  -> ?title:string
  -> ?body:string
  -> unit
  -> (post, board_error) Result.t

(** Creates a new post.  Validates [author] via
    {!Agent_id.of_string}, normalises [hearth] (lowercased +
    trimmed), folds the canonical [title / body / kind /
    meta] via {!normalize_post_payload}, then writes under
    {!with_lock}.  [ttl_hours = 0] persists indefinitely
    (clamped to 0 for human posts; automation / system
    posts are forced to {!Limits.automation_ttl_hours}).
    Errors on validation failure, capacity exhaustion
    ([Capacity_exceeded]), or content length overflow.  The
    JSONL append and side-effect hooks are intentionally
    performed {b outside} the state lock to avoid blocking concurrent
    readers on filesystem writes. *)
val create_post
  :  store
  -> author:string
  -> content:string
  -> ?title:string
  -> ?body:string
  -> post_kind:post_kind
  -> ?meta_json:Yojson.Safe.t
  -> ?visibility:visibility
  -> ?ttl_hours:int
  -> ?hearth:string
  -> ?thread_id:string
  -> ?origin:post_origin
  -> unit
  -> (post, board_error) Result.t

val get_post : store -> post_id:string -> (post, board_error) Result.t

(** RFC-0233 §7: look up a post by the originating turn's join key
    ([Ids.Turn_ref.to_string], i.e. ["<trace_id>#<absolute_turn>"]).  Exact
    O(1) index lookup ([posts_by_turn_ref]); [None] on miss.  No meta_json scan
    and no time-window heuristic (RFC §7.6 guard #2/#3). *)
val find_post_by_turn_ref : store -> turn_ref:string -> post option

(** RFC-0233 §7: look up a post by its fusion run correlation id
    ([origin.fusion_run_id]).  Exact O(1) index lookup ([posts_by_run_id]);
    [None] on miss.  [run_id] is distinct from [turn_ref] (RFC §7.6 guard #5). *)
val find_post_by_run_id : store -> run_id:string -> post option

(** Coalesces [get_post] + [get_comments] under a single
    {!with_lock} block to avoid the two-call lock churn
    that previously surfaced as
    [Mutex.lock: Resource deadlock avoided] under contended
    repeated agent polling. *)
val get_post_and_comments
  :  store
  -> post_id:string
  -> (post * comment list, board_error) Result.t

(** Re-runs {!legacy_migrate_post_kind} against persisted
    posts to detect classification drift.  [limit]
    (default 5200) is clamped to [0..5200].  [dry_run]
    (default [true]) reports drift without mutating the
    store; setting it to [false] applies the new kind +
    rewrites the JSONL.  The returned
    {!reclassify_report.changed_post_ids} list caps at 20
    entries for log-friendly summarisation. *)
val reclassify_posts : store -> ?limit:int -> ?dry_run:bool -> unit -> reclassify_report

(** Returns posts sorted by [(score desc, created_at desc)]
    with optional visibility / hearth filters and a hard
    cap of {!Limits.max_posts} (10000) regardless of the
    requested [limit].  Uses [store.sorted_posts_cache] when
    warm to skip the sort. *)
val list_posts
  :  store
  -> ?visibility_filter:visibility option
  -> ?hearth:string
  -> ?limit:int
  -> unit
  -> post list

(** Full-scan search over every post (no cap on the scan,
    only on the result size).  Returns matches sorted by
    [created_at desc]. *)
val search_posts : store -> predicate:(post -> bool) -> limit:int -> post list

(** {1 Comment operations} *)

(** Validates [post_id] / [author] / optional [parent_id]
    via {!Post_id.of_string} / {!Agent_id.of_string} /
    {!Comment_id.of_string} before taking the lock.
    Exact duplicate [(post_id, parent_id, author, content)] writes
    return the existing comment without appending JSONL, incrementing
    [reply_count], or consuming thread capacity.
    Capacity guarded against {!Limits.max_comments_per_post}
    and the global [Limits.max_comments] ceiling.  Post-lock side effects
    follow the same rationale as {!create_post}. *)
val add_comment_with_status
  :  store
  -> post_id:string
  -> author:string
  -> content:string
  -> ?parent_id:string
  -> ?ttl_hours:int
  -> unit
  -> (comment * [ `Fresh | `Dedup ], board_error) Result.t

val add_comment
  :  store
  -> post_id:string
  -> author:string
  -> content:string
  -> ?parent_id:string
  -> ?ttl_hours:int
  -> unit
  -> (comment, board_error) Result.t

(** Returns the comments for [post_id] sorted by
    [created_at] ascending. *)
val get_comments : store -> post_id:string -> (comment list, board_error) Result.t

(** Returns up to [limit] (default 1000) most recent
    comments across every post.  Used by the profile
    aggregator. *)
val list_comments : store -> ?limit:int -> unit -> comment list

(** {1 Reaction operations} *)

val list_reactions
  :  store
  -> target_type:reaction_target_type
  -> target_id:string
  -> ?user_id:string
  -> unit
  -> (reaction_summary list, board_error) Result.t

(** Returns reaction summaries for all requested [targets] after one
    scan of the reaction table. Intended for callers that already hold
    valid post/comment ids from the board store. *)
val list_reactions_batch
  :  store
  -> targets:(reaction_target_type * string) list
  -> ?user_id:string
  -> unit
  -> ((reaction_target_type * string) * reaction_summary list) list

val toggle_reaction
  :  store
  -> target_type:reaction_target_type
  -> target_id:string
  -> user_id:string
  -> emoji:string
  -> (reaction_toggle_result, board_error) Result.t

(** {1 SubBoard operations} *)

(** Path to the sub-boards JSONL snapshot under
    [<base>/.masc/board_sub_boards.jsonl]. *)
val sub_boards_path : unit -> string

val sub_board_access_to_string : sub_board_access -> string
val sub_board_access_of_string_opt : string -> sub_board_access option
val sub_board_to_yojson : sub_board -> Yojson.Safe.t
val sub_board_of_yojson : Yojson.Safe.t -> sub_board option

(** Snapshots [store.sub_boards] under the state lock, then atomically
    rewrites {!sub_boards_path} under the persist lock. *)
val rewrite_sub_boards : store -> unit

(** Creates a new sub-board with the given slug (unique, lowercase).
    [members] are canonicalised agent ids; the owner is always included.
    Returns [Validation_error] when the slug is invalid or already taken,
    [Capacity_exceeded] when the sub-board limit is reached. JSONL append
    persistence is performed outside the state lock. *)
val create_sub_board
  :  store
  -> slug:string
  -> name:string
  -> description:string
  -> owner:string
  -> ?members:string list
  -> ?access:sub_board_access
  -> unit
  -> (sub_board, board_error) Result.t

(** Resolves a sub-board by its ID or slug. *)
val get_sub_board : store -> sub_board_id:string -> (sub_board, board_error) Result.t

(** Returns all sub-boards sorted by [created_at] ascending. *)
val list_sub_boards : store -> sub_board list

(** Removes a sub-board by ID or slug under the state lock, then persists the
    rewritten snapshot outside the state lock. *)
val delete_sub_board : store -> sub_board_id:string -> (unit, board_error) Result.t

(** Updates an existing sub-board by ID or slug.
    Only provided fields are changed; owner and slug are immutable.
    Persists the rewritten snapshot outside the state lock. *)
val update_sub_board
  :  store
  -> sub_board_id:string
  -> ?name:string
  -> ?description:string
  -> ?members:string list
  -> ?access:sub_board_access
  -> unit
  -> (sub_board, board_error) Result.t
