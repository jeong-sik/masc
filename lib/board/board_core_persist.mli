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

(** Canonical cadence for deferred flush scheduling and failed flusher
    obligation retry. *)
val flush_interval_sec : float
val flusher_inbox_capacity : int
(** Capacity of {!store.flusher_inbox}. The scheduler reserves room for a whole
    sweep/flush batch before enqueueing. *)

val flusher_schedule_dropped_count : unit -> int
(** Count of sweep/flush schedule messages skipped because the flusher inbox was
    full. *)

val persist_error_count : unit -> int
val record_persist_error : where:string -> string -> unit
val persist_io_error : where:string -> string -> ('a, board_error) result
val persist_transaction_error :
  where:string -> Fs_compat.private_jsonl_transaction_error -> ('a, board_error) result

val create_store : unit -> store

val invalidate_post_caches : store -> unit
val invalidate_comment_caches : store -> unit
val mark_dirty_post : store -> string -> unit
val mark_dirty_comment : store -> string -> unit
val with_lock : store -> (unit -> 'a) -> 'a
val with_persist_lock : store -> (unit -> 'a) -> 'a
(** Serializes durable state transitions and their writes. Acquire this before
    briefly taking [with_lock]; never acquire it while holding [with_lock]. *)
val sweep :
  ?protected_post_ids:string list ->
  ?protected_comment_ids:string list ->
  store ->
  int * int
val maybe_sweep : store -> unit

val request_flush : store -> (unit, string) result
(** Enqueue an explicit dirty-state flush without blocking on a full inbox.
    Capacity observation and admission are serialized across all producers. *)
val settle_unknown_durable_snapshot :
  store ->
  initial_detail:string ->
  retry:(unit -> (unit, board_error) result) ->
  on_settled:(unit -> unit) ->
  (unit, board_error) result
(** Retry an idempotent full snapshot after a commit-unknown result. A failed
    retry preserves the original failure class and explicitly queues the dirty
    state for the flusher. *)
val reset_sweep_schedule_for_test : store -> unit
(** Reset sweep/flush schedule timestamps. Test-only. *)

val sweep_schedule_timestamps_for_test : store -> float * float
(** Snapshot sweep/flush schedule timestamps under the store mutex. Test-only. *)

val board_base_path : unit -> string
val board_masc_dir : unit -> string
val persist_path : unit -> string
val comments_path : unit -> string
val reactions_path : unit -> string
val sub_boards_path : unit -> string
val ensure_dir : string -> unit
val ensure_masc_dir : unit -> unit
val posts_jsonl_unlocked : store -> string
val comments_jsonl_unlocked : store -> string
val rewrite_jsonl_durable_result :
  where:string -> string -> string -> (unit, board_error) result
val save_posts_jsonl_result : string -> (unit, board_error) result
val save_comments_jsonl_result : string -> (unit, board_error) result
val reactions_jsonl_unlocked : store -> string
val save_reactions_jsonl_result : string -> (unit, board_error) result
val append_post : post -> (unit, board_error) result
val append_comment : comment -> (unit, board_error) result

val sub_board_access_to_string : sub_board_access -> string
val sub_board_access_of_string_opt : string -> sub_board_access option
val sub_board_post_counts_unlocked : store -> (string, int) Hashtbl.t
val sub_board_post_count_from_counts : (string, int) Hashtbl.t -> string -> int
val sub_board_with_post_count_unlocked : store -> sub_board -> sub_board
val sub_board_with_post_count : (string, int) Hashtbl.t -> sub_board -> sub_board
val sub_board_author_allowed : sub_board -> author_id:Agent_id.t -> bool
val validate_sub_board_post_policy_unlocked :
  store -> author_id:Agent_id.t -> hearth:string option -> (unit, board_error) result

val prepare_post :
  store ->
  ?post_id:Post_id.t ->
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
  (post, board_error) result
(** Validate and normalize a post command without mutating the store. The
    returned record is immutable recovery evidence with one canonical time. *)

val apply_prepared_post :
  store -> post -> (post mutation_application, board_error) result
(** Idempotently apply an immutable prepared post. Exact creation-identity
    replay returns [Already_applied]; an unrelated id collision is explicit. *)

(** [post_id] is preassigned by the durable routing outbox; duplicate ids fail
    with [Already_exists] rather than returning or replacing an existing post. *)
val create_post :
  store ->
  ?post_id:Post_id.t ->
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
  (post, board_error) result

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
  post_id:string ->
  editor:string ->
  content:string ->
  ?title:string ->
  ?body:string ->
  ?new_author:string ->
  unit ->
  (post, board_error) result

(** RFC-0233 §7: maintain the [posts_by_turn_ref] / [posts_by_run_id]
    secondary indexes from a post's [origin].  Idempotent; a [None] origin is
    a no-op.  Called on create and on load so the two paths stay in lockstep. *)
val index_post_origin : store -> post -> unit

val unindex_post_origin : store -> post -> unit
(** Remove the secondary-index entries owned by one post. *)
