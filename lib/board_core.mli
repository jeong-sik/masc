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

    Cascade-include preserves type identity end-to-end with
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

val persist_error_count : unit -> int
(** Returns the cumulative count of persist failures since
    process start.  The counter is bumped by the internal
    [record_persist_error] path whenever a [Sys_error] is
    swallowed during JSONL append / rotate; consumed by the
    operator dashboard for at-a-glance health. *)

(** {1 Configuration} *)

val flush_interval_sec : float
(** Re-export of [Env_config.Board.flush_interval_sec].  How
    often the board flusher actor consumes a [Flush] message
    from {!store.flusher_inbox}. *)

(** {1 Store lifecycle} *)

val create_store : unit -> store
(** Builds a fresh empty store with default Hashtbl capacities
    (1024 posts / 4096 comments / 2048 vote-log entries),
    fresh [Eio.Mutex], cold caches, and an [Eio.Stream]
    [flusher_inbox] capped at 1000 messages. *)

(** {1 Locking + cache invalidation} *)

val with_lock : store -> (unit -> 'a) -> 'a
(** [with_lock store f] runs [f ()] under
    [Eio.Mutex.use_rw ~protect:true store.mutex].  Callers
    should keep the critical section short and avoid I/O —
    {!create_post} for instance does its [Agent_economy.earn]
    {b outside} the lock so the ledger write does not block
    every other reader / writer. *)

val invalidate_post_caches : store -> unit
(** Clears [karma_cache] and [sorted_posts_cache].  Called
    after every post mutation. *)

val invalidate_comment_caches : store -> unit
(** Clears [karma_cache].  Called after every comment
    mutation (comments contribute to the karma rollup but
    not to the sorted-posts cache). *)

(** {1 Sweeper} *)

val sweep : store -> int * int
(** Drops expired posts / comments from the in-memory store
    in batches up to {!Limits.sweeper_batch_size}.  Permanent
    posts ([expires_at = 0.0]) are skipped.  Returns
    [(removed_posts, removed_comments)]. *)

(** {1 Persistence paths + rotation} *)

val board_base_path : unit -> string
(** Resolves the board base path from {!Env_config}.  Used by
    {!persist_path}, {!comments_path}, and the
    [Agent_economy.earn] integration in {!create_post}. *)

val persist_path : unit -> string
(** Path to the board posts JSONL log under
    [<base>/.masc/board-posts.jsonl]. *)

val comments_path : unit -> string
(** Path to the board comments JSONL log under
    [<base>/.masc/board-comments.jsonl]. *)

val ensure_masc_dir : unit -> unit
(** Idempotent [.masc] directory creation; called before
    every JSONL append. *)

val rotate_if_needed : string -> unit
(** Rotates the JSONL file at [path] when it exceeds
    [max_jsonl_bytes] (10 MiB).  The previous file is
    renamed with a timestamp suffix; rotation failures are
    routed through the persist-error counter so the runtime
    keeps appending to the live file rather than aborting. *)

(** {1 Whole-state JSONL rewrite} *)

val rewrite_posts : store -> unit
(** Atomically rewrites {!persist_path} from
    [store.posts].  Used by {!Board_votes} after batch vote
    application to flush the in-memory state to disk. *)

val rewrite_comments : store -> unit
(** Atomically rewrites {!comments_path} from
    [store.comments].  Same usage pattern as
    {!rewrite_posts}. *)

(** {1 Wire encoders} *)

val post_to_yojson : post -> Yojson.Safe.t
val comment_to_yojson : comment -> Yojson.Safe.t

(** {1 Post operations} *)

val create_post :
  store ->
  author:string ->
  content:string ->
  ?title:string ->
  ?body:string ->
  post_kind:post_kind ->
  ?meta_json:Yojson.Safe.t ->
  ?visibility:visibility ->
  ?ttl_hours:int ->
  ?hearth:string ->
  ?thread_id:string ->
  unit ->
  (post, board_error) result
(** Creates a new post.  Validates [author] via
    {!Agent_id.of_string}, normalises [hearth] (lowercased +
    trimmed), folds the canonical [title / body / kind /
    meta] via {!normalize_post_payload}, then writes under
    {!with_lock}.  [ttl_hours = 0] persists indefinitely
    (clamped to 0 for human posts; automation / system
    posts are forced to {!Limits.automation_ttl_hours}).
    Errors on validation failure, capacity exhaustion
    ([Capacity_exceeded]), or content length overflow.  The
    [Agent_economy.earn] credit is intentionally awarded
    {b outside} the lock to avoid blocking concurrent
    readers on the ledger write. *)

val get_post :
  store -> post_id:string -> (post, board_error) result

val get_post_and_comments :
  store ->
  post_id:string ->
  (post * comment list, board_error) result
(** Coalesces [get_post] + [get_comments] under a single
    {!with_lock} block to avoid the two-call lock churn
    that previously surfaced as
    [Mutex.lock: Resource deadlock avoided] under contended
    keeper polling. *)

val reclassify_posts :
  store ->
  ?limit:int ->
  ?dry_run:bool ->
  unit ->
  reclassify_report
(** Re-runs {!legacy_migrate_post_kind} against persisted
    posts to detect classification drift.  [limit]
    (default 5200) is clamped to [0..5200].  [dry_run]
    (default [true]) reports drift without mutating the
    store; setting it to [false] applies the new kind +
    rewrites the JSONL.  The returned
    {!reclassify_report.changed_post_ids} list caps at 20
    entries for log-friendly summarisation. *)

val list_posts :
  store ->
  ?visibility_filter:visibility option ->
  ?hearth:string ->
  ?limit:int ->
  unit ->
  post list
(** Returns posts sorted by [(score desc, created_at desc)]
    with optional visibility / hearth filters and a hard
    cap of {!Limits.max_posts} (10000) regardless of the
    requested [limit].  Uses [store.sorted_posts_cache] when
    warm to skip the sort. *)

val search_posts :
  store -> predicate:(post -> bool) -> limit:int -> post list
(** Full-scan search over every post (no cap on the scan,
    only on the result size).  Returns matches sorted by
    [created_at desc]. *)

(** {1 Comment operations} *)

val add_comment :
  store ->
  post_id:string ->
  author:string ->
  content:string ->
  ?parent_id:string ->
  ?ttl_hours:int ->
  unit ->
  (comment, board_error) result
(** Validates [post_id] / [author] / optional [parent_id]
    via {!Post_id.of_string} / {!Agent_id.of_string} /
    {!Comment_id.of_string} before taking the lock.
    Capacity guarded against {!Limits.max_comments_per_post}
    and the global [Limits.max_comments] ceiling.  Awards
    [Agent_economy.earn] credits outside the lock (same
    rationale as {!create_post}). *)

val get_comments :
  store ->
  post_id:string ->
  (comment list, board_error) result
(** Returns the comments for [post_id] sorted by
    [created_at] ascending. *)

val list_comments :
  store -> ?limit:int -> unit -> comment list
(** Returns up to [limit] (default 1000) most recent
    comments across every post.  Used by the profile
    aggregator. *)
