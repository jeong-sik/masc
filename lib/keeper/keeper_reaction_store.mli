(** Per-Keeper SQLite authority for reaction-ledger events.

    The database contains only the current v4 typed schema.  Retired file-based
    generations are outside this module's authority. *)

type stimulus_kind =
  | Board_signal
  | Bootstrap
  | Fusion_completed
  | Bg_completed
  | Schedule_due
  | Connector_attention
  | Hitl_resolved
  | Failure_judgment
  | Manual_compaction
  | Goal_assigned

type reaction_kind =
  | Turn_started
  | Event_queue_ack
  | Event_queue_requeued
  | Event_queue_escalated
  | Cursor_ack

type urgency =
  | Immediate
  | Normal
  | Low

val stimulus_kind_to_string : stimulus_kind -> string
val stimulus_kind_of_string : string -> stimulus_kind option
val reaction_kind_to_string : reaction_kind -> string
val reaction_kind_of_string : string -> reaction_kind option

type stimulus =
  { kind : stimulus_kind
  ; post_id : string
  ; urgency : urgency
  ; arrived_at : float
  ; board_updated_at : float option
  }

type reaction_source =
  { stimulus_kind : stimulus_kind
  ; post_id : string
  }

type cursor =
  { cursor_ts : float
  ; post_id : string option
  }

type event_payload =
  | Stimulus_event of stimulus
  | Turn_started_event of reaction_source
  | Cursor_ack_event of cursor

type event =
  { event_id : string
  ; stimulus_id : string
  ; recorded_at : float
  ; payload : event_payload
  }

type settlement_kind =
  | Ack
  | Requeue
  | Escalate

type transition_source =
  { event_id : string
  ; stimulus_id : string
  ; stimulus_kind : stimulus_kind
  ; post_id : string
  }

type transition =
  { transition_id : string
  ; transition_event_id : string
  ; lease_id : string
  ; lease_sequence : int64
  ; settled_at : float
  ; settlement_kind : settlement_kind
  ; settlement_identity : string
  ; external_input_requested : bool
  ; sources : transition_source list
  }

type stored_payload =
  | Stored_stimulus of stimulus
  | Stored_turn_started of reaction_source
  | Stored_transition_settlement of
      { reaction_kind : reaction_kind
      ; source : reaction_source
      ; transition_id : string
      ; source_index : int
      ; source_count : int
      ; external_input_requested : bool
      }
  | Stored_cursor_ack of cursor

type stored_event =
  { sequence : int64
  ; event_id : string
  ; stimulus_id : string
  ; recorded_at : float
  ; payload : stored_payload
  }

type stimulus_evidence =
  { matched_record_count : int
  ; stimulus_recorded_at : float option
  ; turn_started_recorded_at : float option
  ; event_queue_ack_recorded_at : float option
  ; latest_recorded_at : float option
  ; latest_reaction_event : stored_event option
  }

type write_outcome =
  | Inserted
  | Already_recorded

type transition_write_outcome =
  | Transition_inserted
  | Transition_already_recorded

type exact_summary =
  { row_count : int
  ; stimulus_count : int
  ; reaction_count : int
  ; turn_started_count : int
  ; event_queue_ack_count : int
  ; event_queue_requeue_count : int
  ; event_queue_escalation_count : int
  ; event_queue_external_input_count : int
  ; cursor_ack_count : int
  ; cursor_swept_stimulus_count : int
  ; orphan_reaction_stimulus_count : int
  ; in_progress_stimulus_count : int
  ; acked_stimulus_count : int
  ; escalated_stimulus_count : int
  ; external_input_requested_stimulus_count : int
  ; pending_stimulus_count : int
  ; pending_stimulus_ids : string list
  ; pending_ids_truncated : bool
  ; latest_recorded_at : float option
  ; latest_stimulus_id : string option
  }

type read_observation =
  { cursor : cursor option
  ; exact_summary : exact_summary
  }
(** One transactionally consistent read of the two materialized observation
    authorities. The retained read capability is not a value cache: both
    fields are selected from SQLite for every call. *)

type path_operation =
  | Inspect_parent
  | Inspect_retired_epoch
  | Prepare_parent
  | Inspect_database
  | Inspect_sidecar
  | Inspect_lock
  | Prepare_lock
  | Prepare_staging
  | Validate_identity
  | Publish_database

type sqlite_operation =
  | Open_database
  | Configure_connection
  | Initialize_schema
  | Validate_schema
  | Prepare_statement
  | Bind_parameter
  | Step_statement
  | Begin_transaction
  | Commit_transaction
  | Rollback_transaction
  | Finalize_statement
  | Close_database

type error =
  | Invalid_keeper_name of string
  | Invalid_event_identity of { field : string }
  | Invalid_timestamp of { field : string; value : float }
  | Invalid_transition of string
  | Retired_epoch_residue of { path : string }
  | Lock_failure of File_lock_eio.durable_lock_error
  | Path_failure of
      { operation : path_operation
      ; path : string
      ; detail : string
      }
  | Database_identity_changed of string
  | Orphan_database_sidecars of
      { database_path : string
      ; sidecars : string list
      }
  | Application_id_mismatch of { expected : int64; actual : int64 }
  | User_version_mismatch of { expected : int64; actual : int64 }
  | Keeper_identity_mismatch of { expected : string; actual : string }
  | Schema_mismatch of string
  | Integrity_failure of string
  | Sqlite_failure of
      { operation : sqlite_operation
      ; rc : Sqlite3.Rc.t option
      ; detail : string
      }
  | Event_identity_conflict of { event_id : string }
  | Transition_identity_conflict of { transition_id : string }
  | Transition_source_conflict of
      { transition_id : string
      ; source_index : int
      }
  | Transition_cardinality_violation of
      { transition_id : string
      ; expected : int
      ; actual : int
      }
  | Commit_outcome_indeterminate of error
  | Cleanup_failure of { primary : error; cleanup : error }

type discovery =
  { keeper_names : string list
  ; errors : error list
  }

val error_to_string : error -> string

val normalize_cursor : cursor -> (cursor, error) result
(** Canonicalize the timestamp to the SQLite microsecond representation used
    by cursor identity, storage, and ordering. *)

val compare_normalized_cursor : cursor -> cursor -> int
(** Total ordering used by the SQLite cursor projection: timestamp first, then
    [None < Some post_id], then bytewise post id. Both arguments must already
    have passed {!normalize_cursor}. This is the single comparison authority
    for Board scan and reconciliation code. *)

val cursor_identity_id : cursor -> (string, error) result
(** Collision-resistant identity of the normalized cursor token. *)

val append_event :
  base_path:string ->
  keeper_name:string ->
  event ->
  (write_outcome, error) result

val append_events :
  base_path:string ->
  keeper_name:string ->
  event list ->
  (write_outcome list, error) result
(** Atomically records one causal event block in list order. A conflict rolls
    back every new row from the block; exact replays remain idempotent. *)

val append_transition :
  base_path:string ->
  keeper_name:string ->
  transition ->
  (transition_write_outcome, error) result
(** Atomically records the transition header and every ordered source.  A
    replay is accepted only when the complete typed content is identical. *)

val append_events_and_transition :
  base_path:string ->
  keeper_name:string ->
  events:event list ->
  transition ->
  (transition_write_outcome, error) result
(** Atomically records prerequisite root events and the complete settlement
    transition. No partial causal projection is externally observable. *)

val read_observation :
  base_path:string ->
  keeper_name:string ->
  pending_id_display_limit:int ->
  (read_observation, error) result
(** Read cursor and exact summary in one SQLite read transaction. A validated
    connection capability may be retained between calls, but never a cursor,
    count, or pending identity. Every use validates exact file identity,
    application/user/store/Keeper metadata, and SQLite [schema_version]. A
    changed capability is closed and strictly reopened with full schema-object
    validation before any value is returned. *)

val current_cursor :
  base_path:string -> keeper_name:string -> (cursor option, error) result
(** Read the singleton Board cursor projection in one SQLite read
    transaction. [None] means that this Keeper has never committed a cursor;
    an absent database has the same exact empty meaning. *)

val events_for_stimuli :
  base_path:string ->
  keeper_name:string ->
  stimulus_ids:string list ->
  ((string * stored_event list) list, error) result
(** One connection and one read transaction.  The result preserves the first
    occurrence order of the requested identities. *)

val evidence_for_stimuli :
  base_path:string ->
  keeper_name:string ->
  stimulus_ids:string list ->
  ((string * stimulus_evidence) list, error) result
(** Exact bounded evidence: aggregate history plus at most one latest reaction
    row per requested stimulus. Runtime and memory do not grow with history. *)

val recent_events :
  base_path:string ->
  keeper_name:string ->
  limit:int ->
  (stored_event list, error) result
(** Newest-first typed events.  An absent v4 database is an exact empty store. *)

val exact_summary :
  base_path:string ->
  keeper_name:string ->
  pending_id_display_limit:int ->
  (exact_summary, error) result
(** Exact transactionally projected state. The immutable event insertion and
    current-state/counter projection commit together. Health reads one summary
    row plus an indexed, bounded pending identity sample; the limit never caps
    counts or status inputs. *)

val release_read_capability :
  base_path:string -> keeper_name:string -> (unit, error) result
(** Close and remove the retained read capability for one Keeper lifecycle.
    A later observation performs a fresh strict open. No timeout or arbitrary
    pool-size eviction participates in this boundary. *)

val database_path : base_path:string -> keeper_name:string -> (string, error) result
(** Exposed for operator diagnostics and focused corruption tests only. *)

val discover_keeper_names : base_path:string -> discovery
(** Discovers every valid Keeper with a current SQLite reaction authority.
    Unsafe entries are explicit errors and do not hide healthy sibling lanes. *)

module For_testing : sig
  val full_schema_validation_count : unit -> int
  (** Number of exact [sqlite_schema] object-list validations performed by
      this process. This is a typed performance seam, not production state. *)

  val close_read_capabilities : unit -> (unit, error list) result
  (** Close and remove every retained read capability. Any close failure is
      returned explicitly. Tests should call this only while no read is live. *)
end
