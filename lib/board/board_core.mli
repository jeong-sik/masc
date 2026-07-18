(** Board_core — in-memory board store, persistence, and
    canonical post / comment operations.

    The .ml is a 687-line module that splits into four
    layers:

    - {b Type / classification} re-exported via
      [include Board_core_classify] (which itself does
      [include Board_types]) — every {!Board_types} surface
      entry and every visibility / post-kind variant reach callers via this facade.
    - {b Payload normalisation} re-exported via
      [include Board_core_payload] — metadata validation, post-title
      derivation, and the canonical [normalize_post_payload].
    - {b Local store + persistence} (this .mli's locally
      pinned surface) — sweeper / lock / cache /
      durable JSONL append / rewrite helpers.
    - {b Public board operations} — create / get / list /
      search post + comment APIs.

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
    [board_masc_dir], [ensure_dir], [append_post], [append_comment]). *)

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
    observed during durable JSONL persistence; consumed by the
    operator dashboard for at-a-glance health. *)
val persist_error_count : unit -> int

(** Record and log a board persistence failure. *)
val record_persist_error : where:string -> string -> unit

(** Record a persistence failure and return its explicit typed error. *)
val persist_io_error : where:string -> string -> ('a, board_error) result

(** Preserve commit-unknown as a distinct typed error; all pre-commit failures
    map to [Io_error]. *)
val persist_transaction_error :
  where:string -> Fs_compat.private_jsonl_transaction_error -> ('a, board_error) result

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

(** {1 Locking + cache invalidation} *)

(** [with_lock store f] runs [f ()] under
    [Eio.Mutex.use_rw ~protect:true store.mutex].  Callers
    should keep the critical section short and avoid I/O —
    {!create_post} for instance emits its side-effect hook
    {b outside} the lock so the ledger write does not block
    every other reader / writer. *)
val with_lock : store -> (unit -> 'a) -> 'a

(** [with_persist_lock store f] serializes durable state transitions and JSONL
    writes. Mutation paths acquire it before briefly taking [with_lock], release
    the state lock before filesystem I/O, and retain the persistence lock until
    the write result is known. Callers must not acquire it while already holding
    [with_lock]. *)
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
val sweep :
  ?protected_post_ids:string list ->
  ?protected_comment_ids:string list ->
  store ->
  int * int

(** {1 Persistence paths} *)

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

(** {1 Append-only persistence} *)

(** Appends one post snapshot to {!persist_path}. *)
val append_post : post -> (unit, board_error) result

(** RFC-0233 §7: maintain the origin secondary indexes ([posts_by_turn_ref] /
    [posts_by_run_id]) from a post's [origin].  Used by the load path to
    rebuild the indexes that {!find_post_by_turn_ref} / {!find_post_by_run_id}
    read.  A [None] origin is a no-op. *)
val index_post_origin : store -> post -> unit

(** Remove the origin-index entries owned by one post. *)
val unindex_post_origin : store -> post -> unit

(** Appends one comment snapshot to {!comments_path}. *)
val append_comment : comment -> (unit, board_error) result

(** {1 Whole-state JSONL rewrite} *)

val rewrite_jsonl_durable_result :
  where:string -> string -> string -> (unit, board_error) result
(** Stable-lock, cursor-checked, payload-and-directory-fsynced JSONL rewrite
    shared by Board projections. *)

val posts_jsonl_unlocked : store -> string
(** Serialize the current post projection. The caller must hold [with_lock]. *)

val save_posts_jsonl_result : string -> (unit, board_error) result
(** Durably rewrite the complete post projection. *)

val comments_jsonl_unlocked : store -> string
(** Serialize the current comment projection. The caller must hold [with_lock]. *)

val save_comments_jsonl_result : string -> (unit, board_error) result
(** Durably rewrite the complete comment projection. *)

val sub_boards_jsonl_unlocked : store -> string
(** Serialize the current sub-board projection. The caller must hold [with_lock]. *)

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

val prepare_post
  :  store
  -> ?post_id:Post_id.t
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
  -> (post, board_error) result

val apply_prepared_post
  :  store
  -> post
  -> (post mutation_application, board_error) result

(** Owner-gated in-place edit of an existing post's title/body.  Validates
    [editor] via {!Agent_id.of_string}, folds the canonical [title / body] via
    {!normalize_post_payload} (seeded with the existing [meta_json] so metadata
    is preserved independently from body text), then
    replaces the stored post under {!with_lock} and persists a full JSONL
    snapshot.  Returns [Unauthorized] when [editor] does not own the post,
    [Post_not_found] for a missing id, and [Validation_error] for
    empty/oversized content or invalid [new_author].  When provided by the
    current owner, [new_author] transfers persisted ownership.
    [post_kind]/[visibility]/[hearth] are preserved. *)
val update_post_with_outcome
  :  store
  -> post_id:string
  -> editor:string
  -> content:string
  -> ?title:string
  -> ?body:string
  -> ?new_author:string
  -> unit
  -> (post, board_error) Result.t

(** Creates a new post.  Validates [author] via
    {!Agent_id.of_string}, normalises [hearth] (lowercased +
    trimmed), folds the canonical [title / body / kind /
    meta] via {!normalize_post_payload}, then writes under
    {!with_lock}.  [ttl_hours = 0] persists indefinitely;
    positive values are preserved exactly and negative values are rejected.
    Errors on validation or persistence failure.  The
    JSONL append and side-effect hooks are intentionally
    performed {b outside} the state lock to avoid blocking concurrent
    readers on filesystem writes. *)
(** [post_id] lets the dispatch outbox persist mutation identity before the
    Board write. Supplying an existing id returns [Already_exists]. *)
val create_post
  :  store
  -> ?post_id:Post_id.t
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
    repeated agent polling.  Omitted pagination arguments preserve
    the full-thread read; supplied pagination arguments are clamped
    to the board comment page limits. *)
val get_post_and_comments
  :  store
  -> post_id:string
  -> ?comment_offset:int
  -> ?comment_limit:int
  -> unit
  -> (post * comment list, board_error) Result.t

(** Returns posts sorted by [(score desc, created_at desc)]
    with optional visibility / hearth filters. Uses [store.sorted_posts_cache] when
    warm to skip the sort. *)
val list_posts
  :  store
  -> ?visibility_filter:visibility option
  -> ?hearth:string
  -> ?limit:int
  -> unit
  -> post list

(** Returns the post with the greatest [(updated_at, post_id)] cursor token,
    or [None] when the board is empty. The fold runs under the board lock and
    does not allocate or sort the complete post history. *)
val current_post_cursor : store -> float * string option
(** Atomic high-water mark for Board observation.

    When the Board is empty, the timestamp is captured while holding the same
    lock used by post creation, so a concurrently admitted first post is
    strictly newer than the returned cursor. *)

(** Full-scan search over every post (no cap on the scan,
    only on the result size).  Returns matches sorted by
    [created_at desc]. *)
val search_posts : store -> predicate:(post -> bool) -> limit:int -> post list

(** {1 Comment operations} *)

val prepare_comment
  :  store
  -> ?comment_id:Comment_id.t
  -> post_id:string
  -> author:string
  -> content:string
  -> ?parent_id:string
  -> ?ttl_hours:int
  -> unit
  -> (comment * post, board_error) result

val apply_prepared_comment
  :  store
  -> parent_reply_count_before:int
  -> comment
  -> (comment mutation_application, board_error) result

(** [comment_id] serves the same prepare-before-write recovery boundary for
    comments. Supplying an existing id returns [Already_exists]. *)
val add_comment
  :  store
  -> ?comment_id:Comment_id.t
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

(** Returns one comment by id. *)
val get_comment : store -> comment_id:string -> (comment, board_error) Result.t

(** Returns up to [limit] (default 1000) most recent
    comments across every post.  Used by the profile
    aggregator. *)
val list_comments : store -> ?limit:int -> unit -> comment list

(** {1 Reaction operations} *)

val normalize_reaction_emoji : string -> (string, board_error) result
(** Canonical reaction emoji validation shared by live preparation and durable
    command decoding. *)

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

val prepare_reaction_toggle
  :  store
  -> target_type:reaction_target_type
  -> target_id:string
  -> user_id:string
  -> emoji:string
  -> (prepared_reaction, board_error) result

val set_reaction
  :  store
  -> target_type:reaction_target_type
  -> target_id:string
  -> user_id:string
  -> emoji:string
  -> reacted:bool
  -> created_at:float
  -> (reaction_toggle_result, board_error) result
(** Idempotent reaction state command. Persistence failure is returned and the
    in-memory mutation is rolled back when it is still current. *)

(** {1 SubBoard operations} *)

(** Path to the sub-boards JSONL snapshot under
    [<base>/.masc/board_sub_boards.jsonl]. *)
val sub_boards_path : unit -> string

val sub_board_access_to_string : sub_board_access -> string
val sub_board_access_of_string_opt : string -> sub_board_access option
val sub_board_to_yojson : sub_board -> Yojson.Safe.t
val sub_board_of_yojson : Yojson.Safe.t -> sub_board option

(** Creates a new sub-board with the given slug (unique, lowercase).
    [members] are canonicalised agent ids; the owner is always included.
    Returns [Validation_error] when the slug is invalid or already taken. The
    state transition and durable JSONL append share the persistence lock; an
    append failure rolls back the in-memory insertion. *)
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
