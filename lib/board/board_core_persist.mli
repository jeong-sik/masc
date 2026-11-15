(** Board core persistence and mutation helpers.

    This is the persistence split consumed by [Board_core]. It intentionally
    exposes the helper surface that [Board_core] includes and builds on. *)

include module type of struct
  include Board_core_classify
end

include module type of struct
  include Board_core_payload
end

include module type of struct
  include Board_core_json
end

val flush_interval_sec : float
val flusher_inbox_capacity : int
(** Capacity of {!store.flusher_inbox}. The scheduler reserves room for a whole
    sweep/flush batch before enqueueing. *)

val flusher_schedule_dropped_count : unit -> int
(** Count of sweep/flush schedule messages skipped because the flusher inbox was
    full. *)

val persist_error_count : unit -> int
val record_persist_error : where:string -> string -> unit

(** [persist_io_error ~where msg] records the failure via
    {!record_persist_error} and returns the typed
    [Error (Io_error "<where>: <msg>")] the append paths surface to
    their callers. *)
val persist_io_error : where:string -> string -> ('a, board_error) result

val create_store : base_path:string -> unit -> store
(** Capture one explicit BasePath, including its original anchored spelling and
    physical-root result. Exactly empty input raises [Invalid_argument]. No
    directory or payload is created; a failed capture grants no write authority.
    Prepare the root before construction, then explicitly load sources. *)

val create_store_bound : Board_workspace_binding.t -> store
(** Same store on a BasePath the caller already captured. The store keeps that
    capture as its binding and resolves no path of its own. *)

val create_store_with_source_io_for_testing :
  base_path:string -> io:posts_source_io -> unit -> store
(** Same production store with an immutable posts transaction IO seam.
    A None slot uses production IO. Faults must be armed after an explicit
    load; the constructor itself creates and admits nothing. *)

val create_store_with_comments_io_for_testing :
  base_path:string -> io:Fs_compat.private_jsonl_transaction_io_for_testing ->
  unit -> store
(** Same store with one immutable comments transaction IO seam. *)
val create_store_with_sub_boards_io_for_testing :
  base_path:string -> io:Fs_compat.private_jsonl_transaction_io_for_testing ->
  unit -> store
(** Immutable IO seam using the real sub-board file transaction. *)
val create_store_with_votes_io_for_testing :
  base_path:string -> io:Fs_compat.private_jsonl_transaction_io_for_testing ->
  unit -> store
(** Immutable IO seam using the real vote-file transaction. The constructor
    leaves the vote source unobserved until an explicit load. *)

val create_store_with_reactions_io_for_testing :
  base_path:string -> io:Fs_compat.private_jsonl_transaction_io_for_testing ->
  unit -> store
(** One immutable reaction-file transaction IO seam; creates/adopts nothing. *)

val create_store_with_deletion_io_for_testing :
  base_path:string -> io:Fs_compat.private_jsonl_transaction_io_for_testing ->
  unit -> store
(** Immutable decision-marker IO seam; constructor performs no IO. *)

val require_persisted_snapshot_readable :
  (unit, string) result -> (unit, board_error) result
(** Reject a mutation whose full-snapshot source did not load completely.
    The stored detail includes the authoritative path and malformed row. *)

val require_model_reload_allowed : store -> path:string -> (unit, string * exn) result
(** Pure loader precondition under persistence or quiescent startup. A pending,
    observed, refused or uncertain decision cannot be cleared by model reload. *)

val invalidate_post_caches : store -> unit
val invalidate_comment_caches : store -> unit
val mark_dirty_post : store -> string -> unit
val mark_dirty_comment : store -> string -> unit
val with_lock : store -> (unit -> 'a) -> 'a
val with_persist_lock : store -> (unit -> 'a) -> 'a
(** Observer exceptions propagate only after unlocking, so an instrumentation
    failure cannot poison this mutex. Exceptions from the mutation itself
    retain the write lock's normal poisoning behavior, except the private
    known-primary settlement carrier, which leaves all Board locks normally. *)
val sweep : store -> int * int
val maybe_sweep : store -> unit
val reset_sweep_schedule_for_test : store -> unit
(** Reset sweep/flush schedule timestamps. Test-only. *)

val sweep_schedule_timestamps_for_test : store -> float * float
(** Snapshot sweep/flush schedule timestamps under the store mutex. Test-only. *)

val board_base_path : unit -> string
val board_masc_dir : unit -> string
val workspace_masc_dir : store -> string
val persist_path : store -> string
val comments_path : store -> string
val reactions_path : store -> string
val sub_boards_path : store -> string
val ensure_dir : string -> unit
val ensure_masc_dir : where:string -> store -> (unit, board_error) result
(** Workspace precondition inside a persistence-protected writer: check the
    store's workspace binding, create the workspace directory and observe it
    present. This does not load posts, clear a posts refusal or bootstrap
    missing data.
    [where] retains the requested operation in its one error/log diagnostic.
    Reserved precondition failures use the existing deferred settlement carrier. *)

type posts_snapshot
(** Frozen candidate rows and their exact expected source observation. *)
val capture_posts_snapshot : ?replacement:post -> store -> posts_snapshot
val save_posts_snapshot : store -> posts_snapshot -> posts_write_outcome
(** Capture under persist then state; save retains persist and acquires no
    recursive Board lock. A stale or unreadable source cannot authorize save.
    Binding uses the physical workspace and exact source observation, not a store-owner token. *)
val require_posts_source_readable : store -> (unit, board_error) result
(** Pure source gate; caller holds the persistence mutex. Refused and unsettled
    sources never grant a write. Definite transient nonwrites retain the expected
    observation, while observed stale identity/bytes/tail revoke it. *)
val posts_source_failure_to_board_error : posts_source_failure -> board_error
val finish_posts_write : posts_write_outcome -> (unit, board_error) result
(** Caller holds persistence. Observe settlement diagnostics only after known
    successful memory publication, or a proven nonwrite after rollback/refusal.
    Known-primary reserved cleanup exceptions leave enclosing Board mutexes normally and are
    reraised after unlocking with their original backtrace. Before propagation,
    a successful write counts each observed diagnostic; a nonwrite or unknown
    outcome counts its one failure, without invoking logging after a reserved
    cause. *)
val publish_posts_read : store -> posts_source_read -> unit
(** Loader publication under persistence then state locks. *)
val read_posts_source : store -> posts_source_read
(** Caller holds persistence; general reads never recover tails or settle an
    unknown write. Complete and partial reads retain the actual Fs snapshot. *)
val finish_posts_read : posts_source_read -> unit
(** Count each observed read diagnostic before reserved propagation, without
    logging or further IO after an observed reserved cause. *)
type posts_inspection_framing =
  | Complete_rows
  | Torn_tail of { rows_end : int; end_offset : int }

type posts_inspection_observation =
  | Observed_missing
  | Observed_present of {
      accepted_rows : int;
      errors : posts_row_error list;
      framing : posts_inspection_framing;
    }

type posts_inspection =
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

type comments_snapshot
val capture_comments_snapshot : store -> comments_snapshot
val save_comments_snapshot : store -> comments_snapshot -> (unit, board_error) result
val require_comments_source_readable : store -> (unit, board_error) result
val settle_comments_source : store -> (comments_recovery_receipt option, board_error) result
val acknowledge_comments_recovery : store -> comments_recovery_receipt -> (unit, board_error) result
(** Explicit storage recovery retains its completed receipt through cleanup
    exceptions. Receive and acknowledge it under persistence, then fully reload
    comments before model authority. Does not replay the interrupted operation. *)
type comment_append_receipt
val append_comment : store -> reader:Board_access.reader -> comment -> (comment_append_receipt, board_error) result
val publish_comment_append : store -> comment_append_receipt -> (unit, board_error) result
(** Caller retains persistence through append and normal model publication.
    On a typed publication rejection, record the owned row's cleanup as dirty
    before acknowledging the receipt. Finish reserved cleanup after the state
    callback, before any further IO. Exceptions retain unfinished publication. *)
val rewrite_comments : store -> unit
val rewrite_comments_under_persistence : store -> unit
(** Same capture, write and dirty retry, for a caller already holding
    persistence through an append's typed publication rejection. *)
val reactions_jsonl_unlocked : store -> string
val save_reactions_jsonl_result : store -> string -> (unit, board_error) result
(** Caller owns persistence; these bytes capture an already-installed deletion
    or flush model. Known file success acknowledges its exact source receipt.
    Unknown effects remain owned and cannot be retried as a new ordinary write.
    Normal toggles publish their staged model before acknowledging instead. *)
val append_post : store -> post -> posts_write_outcome

val sub_board_access_to_string : sub_board_access -> string
val sub_board_access_of_string_opt : string -> sub_board_access option
val sub_board_access_field_of_yojson
  :  Yojson.Safe.t
  -> (sub_board_access option, board_error) result
val sub_board_post_counts_unlocked : store -> (string, int) Hashtbl.t
(* [sub_board_post_count_from_counts] is the lookup both
   [sub_board_with_post_count] and its _unlocked twin perform on the table
   [sub_board_post_counts_unlocked] returns; callers take the sub_board, not
   the count. *)
val sub_board_with_post_count_unlocked : store -> sub_board -> sub_board
val sub_board_with_post_count : (string, int) Hashtbl.t -> sub_board -> sub_board
(* [sub_board_author_allowed] is the predicate
   [validate_sub_board_post_policy_unlocked] applies. A caller outside asks the
   validator, which answers with the typed board_error, rather than reading the
   bool and inventing its own refusal. *)
val validate_sub_board_post_policy_unlocked :
  store -> author_id:Agent_id.t -> hearth:string option -> (unit, board_error) result
(** Call while holding the state lock. A specified hearth requires a fully
    readable sub-board source; an unscoped post needs no sub-board policy.
    Staging uses this cached precheck. Final post/comment admission separately
    decodes the exact canonical Policy snapshot under persistence and retains
    it as an actual read dependency through append. This precheck alone does
    not establish durable authority. *)

module Post_publication_failure = Board_post_publication_failure

val create_post :
  store ->
  lookup:Recipient_lookup.t ->
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
  ?origin:post_origin ->
  unit ->
  (post, Post_publication_failure.t) result

type create_post_once_result =
  | Post_created of post_creation
  | Post_already_present of post

val create_post_once_by_fusion_run_id :
  store ->
  lookup:Recipient_lookup.t ->
  fusion_run_id:string ->
  author:string ->
  content:string ->
  post_kind:post_kind ->
  ?meta_json:Yojson.Safe.t ->
  visibility:visibility ->
  ttl_hours:int ->
  origin:post_origin ->
  unit ->
  (create_post_once_result, Post_publication_failure.t) result
(** Serialize exact-origin create attempts with a fiber-aware store mutex.
    An exact normalized payload replay for the same typed Fusion run returns
    the matching observed post instead of appending another row. This positive
    recognition can use rows a partial read kept in memory. Matching
    the row neither directly accesses source files nor publishes a new row, and
    grants no posts write authority, operation receipt or durability guarantee.
    The call still runs ordinary maintenance scheduling before lookup; a
    separate flusher may process the queued sweep or flush work.
    A conflicting replay returns [Already_exists]; a new run still requires
    ordinary source admission before creation. *)

val create_post_with_audience :
  store ->
  lookup:Recipient_lookup.t ->
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
  ?origin:post_origin ->
  unit ->
  (post_creation, Post_publication_failure.t) result
(** Validate and freeze the post audience before mutating or persisting the
    Board, returning that same authority with the committed post. The final
    policy check precedes append under the store's persistence lock; successful
    append is followed by memory publication without a policy-refusal branch.
    This is same-store serialization, not a cross-process or crash-durable
    operation receipt contract. Failures retain publication evidence and expose
    a receipt only after the state commit.
    Cancellation, [Eio.Time.Timeout], [Out_of_memory], [Stack_overflow] and
    [Sys.Break] propagate rather than becoming ordinary failures. *)

(** What an edit stored: the post as saved, the audience recorded with the saved
    text, the names in that text no Keeper declares (for the response only,
    never stored), and whether the normalized title, body or author changed,
    compared under the store lock. *)
type post_edit =
  { edited : post
  ; recorded_audience : audience
  ; unresolved : string list
  ; content_changed : bool
  }

(** Owner-gated in-place edit of an existing post's title/body.  Returns
    [Unauthorized] when [editor] does not own the post, [Post_not_found] for a
    missing id, and [Validation_error] for empty/oversized content or invalid
    [new_author].  When provided, [new_author] transfers persisted ownership and
    must parse through [Agent_id.of_string]. The body is normalized exactly as on
    create and the existing [meta_json] is preserved independently, so editing
    cannot silently drop metadata.
    [post_kind]/[visibility]/[hearth] are preserved. *)
val update_post_with_outcome :
  store ->
  lookup:Recipient_lookup.t ->
  post_id:string ->
  editor:string ->
  content:string ->
  ?title:string ->
  ?body:string ->
  ?new_author:string ->
  unit ->
  (post_edit, board_error) result

(** RFC-0233 §7: maintain the [posts_by_turn_ref] / [posts_by_run_id]
    secondary indexes from a post's [origin].  Idempotent; a [None] origin is
    a no-op.  Called on create and on load so the two paths stay in lockstep. *)
val index_post_origin : store -> post -> unit
val unindex_post_origin : store -> post -> unit

(** Incremental immutable Hot-post index maintenance under [store.mutex]. *)
val index_hot_post : store -> post -> unit
val unindex_hot_post : store -> post -> unit
val reindex_hot_post : store -> previous:post -> updated:post -> unit
val put_post : store -> post -> unit
val rebuild_hot_post_index : store -> unit
