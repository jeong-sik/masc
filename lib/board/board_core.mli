(** Board post/thread queries and the existing public operation surface.

    The implementation composes persistence, classification and payload
    helpers with private comment, reaction and sub-board owners. This explicit
    interface retains canonical Board_types identities through the existing
    Board_votes and Board includes. Owner-specific state and helper functions
    remain private; the declarations below define the public surface. *)

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
    swallowed during a JSONL append; consumed by the
    operator dashboard for at-a-glance health. *)
val persist_error_count : unit -> int

(** Record and log a board persistence failure. *)
val record_persist_error : where:string -> string -> unit

val require_persisted_snapshot_readable :
  (unit, string) result -> (unit, board_error) result
(** Reject a mutation whose full-snapshot source did not load completely.
    The stored result carries the source path and load failure. *)

(** {1 Configuration} *)

(** Re-export of [Env_config.Board.flush_interval_sec].  How
    often the board flusher actor consumes a [Flush] message
    from {!store.flusher_inbox}. *)
val flush_interval_sec : float

(** {1 Store lifecycle} *)

(** Builds a fresh empty store with default Hashtbl capacities
    (1024 posts / 4096 comments / 2048 vote-log entries),
    fresh [Eio.Mutex], cold caches, and an [Eio.Stream]
    [flusher_inbox] capped by the persistence-layer flusher inbox capacity.
    Captures the explicit existing BasePath and its no-follow state boundary,
    anchoring relative input; empty input raises [Invalid_argument]. No directory
    or payload is created. A failed capture remains refused on this store;
    prepare the root before construction, then explicitly load sources. *)
val create_store : base_path:string -> unit -> store

val create_store_bound : Board_workspace_binding.t -> store
(** Same store on a BasePath the caller already captured. The store keeps that
    capture as its binding and resolves no path of its own. *)

val create_store_with_source_io_for_testing :
  base_path:string -> io:posts_source_io -> unit -> store
(** Same production store with an immutable posts transaction IO seam.
    A None slot uses production IO; the constructor creates/adopts nothing and
    leaves posts unobserved until explicit load. *)

val create_store_with_comments_io_for_testing :
  base_path:string -> io:Fs_compat.private_jsonl_transaction_io_for_testing ->
  unit -> store
(** One immutable comments transaction IO seam; creates/adopts nothing. *)
val create_store_with_sub_boards_io_for_testing :
  base_path:string -> io:Fs_compat.private_jsonl_transaction_io_for_testing ->
  unit -> store
(** One immutable sub-board transaction IO seam; creates/adopts nothing. *)
val create_store_with_votes_io_for_testing :
  base_path:string -> io:Fs_compat.private_jsonl_transaction_io_for_testing ->
  unit -> store
(** One immutable vote-file transaction IO seam; creates/adopts nothing. *)

val create_store_with_reactions_io_for_testing :
  base_path:string -> io:Fs_compat.private_jsonl_transaction_io_for_testing ->
  unit -> store
(** One immutable reaction-file transaction IO seam; creates/adopts nothing. *)

val create_store_with_deletion_io_for_testing :
  base_path:string -> io:Fs_compat.private_jsonl_transaction_io_for_testing ->
  unit -> store
(** One immutable decision-marker transaction IO seam; creates/adopts nothing. *)

(** {1 Locking + cache invalidation} *)

(** [with_lock store f] runs [f ()] under
    [Eio.Mutex.use_rw ~protect:true store.mutex].  Callers
    should keep the critical section short and avoid I/O —
    {!create_post} for instance emits its side-effect hook
    {b outside} the lock so the ledger write does not block
    every other reader / writer. *)
val with_lock : store -> (unit -> 'a) -> 'a

(** [with_persist_lock store f] serializes JSONL writes. Callers must not hold
    [with_lock] while acquiring it. Acquire this lock before capturing a
    snapshot under [with_lock], and retain it through the corresponding write. *)
val with_persist_lock : store -> (unit -> 'a) -> 'a

(** Clears [karma_cache].  Called after post mutations that
    affect karma / persisted state. *)
val invalidate_post_caches : store -> unit

(** Clears [karma_cache].  Called after every comment
    mutation (comments contribute to the karma rollup but
    not to the sorted-posts cache). *)
val invalidate_comment_caches : store -> unit

(** {1 Sweeper} *)

(** Drops expired posts / comments from the in-memory store
    in batches up to {!Limits.sweeper_batch_size}.  Permanent
    posts ([expires_at = 0.0]) are skipped.  A swept post takes its
    comments with it, the way {!Board_votes.delete_post} removes them;
    larger cascades remove a batch of comments per pass and keep the post
    until its final comment is removed. Returns [(removed_posts, removed_comments)],
    cascaded comments counted in [removed_comments]. Expired rows loaded after
    restart also remain visible until this bounded cleanup removes them.
    Incomplete post, comment, vote or reaction sources defer all deletions
    until a healthy reload; their typed load failures remain on the store. *)
val sweep : store -> int * int

(** {1 Persistence paths} *)

(** Resolves the configured base path. Store persistence uses its captured
    directory instead of consulting this configuration helper. *)
val board_base_path : unit -> string
val workspace_masc_dir : store -> string

(** Path to the posts JSONL log in the store's captured workspace. *)
val persist_path : store -> string

(** Path to the comments JSONL log in the store's captured workspace. *)
val comments_path : store -> string

(** Path to the reactions snapshot in the store's captured workspace. *)
val reactions_path : store -> string

(** Checked directory preparation inside a persistence-protected writer. *)
val ensure_masc_dir : where:string -> store -> (unit, board_error) result

(** {1 Append-only persistence} *)

(** Appends one post snapshot only against its loaded exact source observation.
    The stable-lock precondition rereads all prior bytes on each append. *)
val append_post : store -> post -> posts_write_outcome

(** RFC-0233 §7: maintain the origin secondary indexes ([posts_by_turn_ref] /
    [posts_by_run_id]) from a post's [origin].  Used by the load path to
    rebuild the indexes that {!find_post_by_turn_ref} / {!find_post_by_run_id}
    read.  A [None] origin is a no-op. *)
val index_post_origin : store -> post -> unit
val unindex_post_origin : store -> post -> unit

(** Incremental immutable Hot-post index maintenance under [store.mutex]. *)
val index_hot_post : store -> post -> unit
val unindex_hot_post : store -> post -> unit
val reindex_hot_post : store -> previous:post -> updated:post -> unit
val put_post : store -> post -> unit
val rebuild_hot_post_index : store -> unit

type comment_append_receipt = Board_core_persist.comment_append_receipt
val append_comment : store -> reader:Board_access.reader -> comment -> (comment_append_receipt, board_error) result
val publish_comment_append : store -> comment_append_receipt -> (unit, board_error) result
(** Append against the exact loaded comments observation while holding
    persistence. Retain the receipt through a normal model publication; typed
    rejection must record its owned row's dirty cleanup before acknowledgement.
    A projection exception retains unfinished publication and denies rewrites. *)

(** {1 Whole-state JSONL rewrite} *)

(** A captured whole-posts replacement uses the exact prior source bytes and
    cursor. It cannot discard rejected source rows or adopt unrelated disk state. *)
type posts_snapshot = Board_core_persist.posts_snapshot
(** Frozen candidate rows and their exact expected source observation. *)
val capture_posts_snapshot : ?replacement:post -> store -> posts_snapshot
val save_posts_snapshot : store -> posts_snapshot -> posts_write_outcome
(** Capture under persist then state; save retains persist and acquires no
    recursive Board lock. A stale or unreadable source cannot authorize save.
    Snapshots bind the physical workspace and exact source observation, not a store-owner
    token; trusted callers sharing both may pass a captured snapshot. *)
val require_posts_source_readable : store -> (unit, board_error) result
(** Pure source gate; caller holds the persistence mutex. Refused and unsettled
    sources never grant a write. Definite transient nonwrites retain the expected
    observation, while observed stale identity/bytes/tail revoke it. *)
val posts_source_failure_to_board_error : posts_source_failure -> board_error
val finish_posts_write : posts_write_outcome -> (unit, board_error) result
(** Caller holds persistence. Observe settlement diagnostics only after known
    successful memory publication, or a proven nonwrite after rollback/refusal.
    Reserved cleanup exceptions leave enclosing Board mutexes normally and are
    reraised after unlocking with their original backtrace. *)
val publish_posts_read : store -> posts_source_read -> unit
(** Loader publication under persistence then state locks. *)
val read_posts_source : store -> posts_source_read
(** Caller holds persistence; general reads never recover tails or settle an
    unknown write. Complete and partial reads retain the actual Fs snapshot. *)
val finish_posts_read : posts_source_read -> unit
type posts_inspection_framing = Board_core_persist.posts_inspection_framing =
  | Complete_rows
  | Torn_tail of { rows_end : int; end_offset : int }

type posts_inspection_observation = Board_core_persist.posts_inspection_observation =
  | Observed_missing
  | Observed_present of {
      accepted_rows : int;
      errors : posts_row_error list;
      framing : posts_inspection_framing;
    }

type posts_inspection = Board_core_persist.posts_inspection =
  | Inspected of {
      observation : posts_inspection_observation;
      settlement_diagnostic : Fs_compat.private_jsonl_operation_failure option;
    }
  | Inspection_failed of {
      error : Fs_compat.Private_jsonl_unique_fold.error;
      settlement_diagnostic : Fs_compat.private_jsonl_operation_failure option;
    }

val inspect_posts_source : workspace_masc_dir:string -> posts_inspection
(** Noncreating unique-regular read observation. This uses the data reader's
    shared lock and before/after snapshot checks, not stable-sibling exclusion.
    Missing is an observation, not initialized absence, a durability receipt or
    authority to mutate any store. Reserved failures retain their backtrace. *)
val inspect_posts_source_with_io_for_testing :
  workspace_masc_dir:string ->
  io:Fs_compat.private_jsonl_transaction_io_for_testing -> posts_inspection


type comments_snapshot = Board_core_persist.comments_snapshot
val capture_comments_snapshot : store -> comments_snapshot
val save_comments_snapshot : store -> comments_snapshot -> (unit, board_error) result
(** Capture under persist then state, retain persistence through the write.
    The candidate is bound to its captured source bytes, cursor and workspace.
    Failed/unknown loads and stale source changes grant no write authority. *)
val require_comments_source_readable : store -> (unit, board_error) result
val settle_comments_source : store -> (comments_recovery_receipt option, board_error) result
val acknowledge_comments_recovery : store -> comments_recovery_receipt -> (unit, board_error) result
(** Explicitly fence a fresh source without replay. Completed receipts survive
    cleanup exceptions and can be retrieved again. Receive and acknowledge the
    exact receipt under persistence, then reload the complete model. *)

(** Atomically rewrites {!comments_path} from
    [store.comments]. The snapshot is captured under the state lock and written
    outside it while retaining the persistence lock. Failure re-marks comments
    dirty for the flusher to retry; callers must not invoke this while already
    holding the state lock. *)
val rewrite_comments : store -> unit

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

(** task-1758/#39356: encode the typed close state. Re-exported here for the
    same reason as {!post_origin_to_yojson} above. *)
val post_close_state_to_yojson : post_close_state -> Yojson.Safe.t
val comment_to_yojson : comment -> Yojson.Safe.t
val reaction_to_yojson : reaction -> Yojson.Safe.t
val reaction_of_yojson : Yojson.Safe.t -> reaction option
val reaction_summary_to_yojson : reaction_summary -> Yojson.Safe.t
val reaction_toggle_result_to_yojson : reaction_toggle_result -> Yojson.Safe.t
val reaction_target_type_to_string : reaction_target_type -> string
val reaction_target_type_of_string_opt : string -> reaction_target_type option
val compare_reaction_target_type : reaction_target_type -> reaction_target_type -> int
val valid_reaction_target_type_strings : string list
val board_reaction_emojis : string list

val reaction_key
  :  target_type:reaction_target_type
  -> target_id:string
  -> user_id:string
  -> emoji:string
  -> string

(** {1 Post operations} *)

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
(** What an edit stored: the post as saved, the audience recorded with the saved
    text, and whether the normalized title, body or author changed, compared
    under the store lock. *)
type post_edit =
  { edited : post
  ; recorded_audience : audience
  ; unresolved : string list
  ; content_changed : bool
  }

val update_post_with_outcome
  :  store
  -> lookup:Recipient_lookup.t
  -> post_id:string
  -> editor:string
  -> content:string
  -> ?title:string
  -> ?body:string
  -> ?new_author:string
  -> unit
  -> (post_edit, board_error) Result.t

(** Creates a new post.  Validates [author] via
    {!Agent_id.of_string}, normalises [hearth] (lowercased +
    trimmed), folds the canonical [title / body / kind /
    meta] via {!normalize_post_payload}, then writes under
    {!with_lock}.  [ttl_hours = 0] persists indefinitely;
    positive values are preserved exactly and negative values are rejected.
    Errors on validation or persistence failure.
    Final sub-board policy admission precedes append while holding this
    store's persistence lock, shared with runtime sub-board mutations.
    A specified hearth requires a fully readable sub-board policy source;
    an unscoped post is independent of that source. This boundary does not
    serialize other stores/processes or supply durable operation receipts.
    JSONL append and side-effect hooks are intentionally
    performed {b outside} the state lock to avoid blocking concurrent
    readers on filesystem writes. *)
module Post_publication_failure = Board_core_persist.Post_publication_failure

val create_post
  :  store
  -> lookup:Recipient_lookup.t
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
  -> (post, Post_publication_failure.t) Result.t

type create_post_once_result =
  | Post_created of post_creation
  | Post_already_present of post

val create_post_once_by_fusion_run_id
  :  store
  -> lookup:Recipient_lookup.t
  -> fusion_run_id:string
  -> author:string
  -> content:string
  -> post_kind:post_kind
  -> ?meta_json:Yojson.Safe.t
  -> visibility:visibility
  -> ttl_hours:int
  -> origin:post_origin
  -> unit
  -> (create_post_once_result, Post_publication_failure.t) Result.t
(** Exact typed-origin create. Requires [origin.fusion_producer] to match
    [author] at creation; replays match the immutable [origin] and return the
    existing normalized post even after mutable [post.author] is transferred via
    [update_post]. Conflicting payloads return [Already_exists]. *)

val create_post_with_audience
  :  store
  -> lookup:Recipient_lookup.t
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
  -> (post_creation, Post_publication_failure.t) Result.t
(** Create a post only after its routing audience has been validated, and
    return the exact audience admitted with the write. Failures retain publication
    evidence and expose a receipt only after the state commit. Cancellation,
    [Eio.Time.Timeout], [Out_of_memory], [Stack_overflow] and [Sys.Break] propagate. *)

val read_post : store -> post_id:string -> (post, board_read_error) Result.t
(** The post with [post_id], read from the in-memory store. *)

val read_post_for_evidence : store -> post_id:string -> (post, board_read_error) Result.t
(** Read from an admitted, complete posts source. A source failure cannot
    establish either visibility or the absence of the post. *)


(** RFC-0233 §7: look up a post by the originating turn's join key
    ([Ids.Turn_ref.to_string], i.e. ["<trace_id>#<absolute_turn>"]).  Exact
    O(1) index lookup ([posts_by_turn_ref]); [None] on miss.  No meta_json scan
    and no time-window heuristic (RFC §7.6 guard #2/#3). *)
val find_post_by_turn_ref : store -> turn_ref:string -> post option

(** RFC-0233 §7: look up a post by its fusion run correlation id
    ([origin.fusion_run_id]).  Exact O(1) index lookup ([posts_by_run_id]);
    [None] on miss.  [run_id] is distinct from [turn_ref] (RFC §7.6 guard #5). *)
val find_post_by_run_id : store -> run_id:string -> post option

val list_posts_by_run_origin : store -> post list
(** Snapshot the exact run-origin index, newest publication first. Does not
    scan unrelated Board posts or inspect body text. *)

val observe_post_and_comments
  : store
  -> post_id:string
  -> (post * comments_observation, board_read_error) Result.t
(** Capture a post, indexed comments and comments-source completeness together
    under persistence then state locks. Retains comment display rows when that
    source is incomplete. Refuses an incomplete posts source before looking up
    any post, so a source failure cannot distinguish hidden from absent posts. *)

(** Complete thread in {!read_comments} order, observed in one persistence
    then state critical section. Refuses an incomplete posts or comments source
    with [Read_source_unavailable]. Paging is {!Board_types.Comment_page}'s job. *)
val read_post_and_comments
  :  store
  -> post_id:string
  -> (post * comment list, board_read_error) Result.t


(** Returns posts sorted by [(score desc, created_at desc, post_id asc)]
    with optional visibility / hearth filters, traversed lazily from
    [store.hot_post_index] up to [limit] without sorting the full store. *)
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

(** Traverse the Recent index in [created_at DESC, post_id ASC] order until
    [limit] matches are collected or the index is exhausted. A nonpositive
    limit returns no posts. *)
val search_posts : store -> predicate:(post -> bool) -> limit:int -> post list

(** {1 Comment operations} *)

val add_comment
  :  store
  -> reader:Board_access.reader
  -> lookup:Recipient_lookup.t
  -> post_id:string
  -> author:string
  -> content:string
  -> ?parent_id:string
  -> ?ttl_hours:int
  -> unit
  -> (comment, board_error) Result.t

val add_comment_with_audience
  :  store
  -> reader:Board_access.reader
  -> lookup:Recipient_lookup.t
  -> post_id:string
  -> author:string
  -> content:string
  -> ?parent_id:string
  -> ?ttl_hours:int
  -> unit
  -> (comment_creation, board_error) Result.t
(** Validate and freeze comment routing before the Board mutation, returning
    the same audience with the committed comment. *)

val observe_comments : store -> post_id:string -> (comments_observation, board_read_error) Result.t
(** Display rows with their completeness captured in the same persistence then
    state critical section. Incomplete rows cannot establish absence or totals. *)

(** Returns complete comments for [post_id] oldest first: by [created_at], and by
    comment id among comments with the same [created_at], so every read of an
    unchanged thread returns the same order. *)
val read_comments : store -> post_id:string -> (comment list, board_read_error) Result.t
(** Only a complete source may answer [Ok []]. An incomplete source answers
    [Read_source_unavailable]. This lookup does not check post existence;
    retained orphan comments remain readable by their post ID. *)


(** Returns one comment by id from a complete comments source. Source failures
    precede lookup for both cached and absent rows, so checked target readers
    cannot infer a hidden comment's existence from different source errors. *)
val get_comment : store -> comment_id:string -> (comment, board_error) Result.t

(** Returns up to [limit] (default 1000) most recent
    comments across every post, newest first in the reverse of
    {!read_comments} order.  Used by the profile aggregator. *)
val list_comments : store -> ?limit:int -> unit -> comment list

(** {1 Reaction operations} *)

(** Reaction summaries require a complete observed reaction source. Target IDs
    are canonicalized with the domain parser for lookup, rows, batch keys and
    write receipts. Unavailable source observations return [Io_error]. *)

val list_reactions
  :  store
  -> target_type:reaction_target_type
  -> target_id:string
  -> ?user_id:string
  -> unit
  -> (reaction_summary list, board_error) Result.t

(** Returns reaction summaries for all requested [targets] after one
    scan of the reaction table. Source failure is not a known empty summary.
    Target existence is not checked here; Dispatch applies reader visibility. *)
val list_reactions_batch
  :  store
  -> targets:(reaction_target_type * string) list
  -> ?user_id:string
  -> unit
  -> (((reaction_target_type * string) * reaction_summary list) list, board_error) Result.t

val toggle_reaction
  :  store
  -> reader:Board_access.reader -> target_type:reaction_target_type
  -> target_id:string
  -> user_id:string
  -> emoji:string
  -> (reaction_toggle_result, board_error) Result.t

(** {1 SubBoard operations} *)

(** Path to the sub-board snapshot in the store's captured workspace. *)
val sub_boards_path : store -> string

val sub_board_access_to_string : sub_board_access -> string
val sub_board_access_of_string_opt : string -> sub_board_access option
val sub_board_access_field_of_yojson
  :  Yojson.Safe.t
  -> (sub_board_access option, board_error) Result.t
val sub_board_to_yojson : sub_board -> Yojson.Safe.t
val sub_board_of_yojson : Yojson.Safe.t -> sub_board option

val reload_sub_boards : store -> (int, string * exn) result
(** Explicit full policy load/reload under persist then state. Partial rows
    remain display-only. Cannot clear unknown writes or interrupted publication. *)

(** Creates a new sub-board with the given slug (unique, lowercase).
    [members] are canonicalised agent ids; the owner is always included.
    Returns [Validation_error] when the slug is invalid and [Already_exists]
    when taken. The final uniqueness check precedes append under this store's
    persistence lock; append runs outside the state lock. *)
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

(** Best-effort display rows, sorted by [created_at]. This is not a complete
    policy query or permission evidence. *)
val list_sub_boards : store -> sub_board list

val read_sub_boards : store -> (sub_board list, board_error) result
(** Capture policy completeness and rows under one persistence interval. *)

(** Durably record the original board and affected post IDs, then remove policy
    and unlink only those posts. Pending outcomes retain their owned recovery. *)
val delete_sub_board : store -> authorization:sub_board_deletion_authorization ->
  sub_board_id:string -> (deletion_outcome, board_error) Result.t

(** Updates an existing sub-board by ID or slug.
    Only provided fields are changed; owner and slug are immutable.
    Persist an exact-source-checked candidate before publishing policy memory. *)
val update_sub_board
  :  store
  -> sub_board_id:string
  -> ?name:string
  -> ?description:string
  -> ?members:string list
  -> ?access:sub_board_access
  -> unit
  -> (sub_board, board_error) Result.t
