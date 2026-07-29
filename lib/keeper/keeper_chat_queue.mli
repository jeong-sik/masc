(** Durable per-Keeper chat receipt queue.

    Every accepted message receives a stable receipt before the first durable
    write.  The receipt then follows exactly one closed lifecycle:
    [Pending -> Inflight -> Delivered | Failed]. On restart, [Inflight] becomes
    terminal [Failed { kind = Interrupted }]. The external effect is unknown,
    so the receipt is never automatically re-dispatched. No external journal or
    operator recovery gate participates in this lifecycle.

    Each claim contains exactly one receipt, so message, multimodal block,
    attachment, timestamp, provenance, and connector identity boundaries are
    preserved without delimiter-based coalescing. A crashed claim is never
    automatically redispatched because its external effect is unproven.

    @since 2.145.0 *)

type message_source =
  | Dashboard of { thread_id : string }
  | Discord of { channel_id : string; user_id : string }
  | Slack of {
      channel_id : string;
      user_id : string;
      user_name : string;
      team_id : string option;
      thread_ts : string option;
    }

type queued_message = {
  content : string;
  user_blocks : Keeper_multimodal_input.user_input_block list;
  attachments : Keeper_chat_store.attachment list;
  timestamp : float;
  source : message_source;
  user_row_origin : Keeper_chat_store.user_row_origin;
}

module Receipt_id = Keeper_chat_delivery_identity.Receipt_id

type completion = {
  completed_at : float;
  outcome_ref : string option;
}

type failure_kind =
  | Turn_failed
  | No_visible_reply
  | Transcript_persist_failed
  | Connector_unavailable
  | Delivery_failed
  | Cancelled
  | Interrupted
  | Internal_error

val failure_kind_to_string : failure_kind -> string

type failure = {
  completed_at : float;
  kind : failure_kind;
  detail : string;
  outcome_ref : string option;
}

type receipt_state =
  | Pending
  | Inflight of { started_at : float }
  | Delivered of completion
  | Failed of failure

type claim = {
  receipt_id : Receipt_id.t;
  message : queued_message;
}

type finalization =
  | Mark_delivered of completion
  | Mark_failed of failure

type snapshot_load_error_kind =
  | Invalid_path
  | Read_failed
  | Parse_failed
  | Startup_transition_failed
  | Durability_uncertain
  | Reconciliation_failed
  | Configuration_conflict

type snapshot_load_error = {
  kind : snapshot_load_error_kind;
  path : string option;
  message : string;
}

type persistence_publication =
  | Not_published
  | Enqueue_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      }
  | Pending_cancel_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      }
  | Claim_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      }
  | Complete_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      }
  | Claim_compensation_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      }
  | Startup_interrupted_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      }

type persistence_failure =
  { publication : persistence_publication
  ; detail : string
  }

type mutation_error =
  | Persistence_not_configured
  | Snapshot_unavailable of snapshot_load_error
  | Invalid_input of string
  | Receipt_already_terminal of
      { receipt_id : Receipt_id.t
      ; state : receipt_state
      }
  | Receipt_not_pending of
      { receipt_id : Receipt_id.t
      ; observed_state : receipt_state option
      }
  | Receipt_not_inflight of
      { receipt_id : Receipt_id.t
      ; observed_state : receipt_state option
      }
  | Revision_exhausted
  | Persist_failed of persistence_failure

val snapshot_load_error_kind_to_string : snapshot_load_error_kind -> string
val mutation_error_to_string : mutation_error -> string
val mutation_error_to_json : mutation_error -> Yojson.Safe.t

type active_receipt = {
  receipt_id : Receipt_id.t;
  message : queued_message;
  state : receipt_state;
}

type receipt_view = {
  receipt_id : Receipt_id.t;
  state : receipt_state;
}

type receipt_lookup = {
  revision : int64;
  receipt : receipt_view option;
}

type diagnostic_snapshot = {
  revision : int64;
  pending : active_receipt list;
  inflight : active_receipt list;
  terminal_count : int64;
  load_errors : snapshot_load_error list;
}

type enqueue_receipt = {
  receipt_id : Receipt_id.t;
  revision : int64;
  pending_count : int;
  inflight_count : int;
}

type configure_report = {
  restored_keeper_count : int;
  interrupted_receipt_count : int;
  load_errors : (string option * snapshot_load_error) list;
}

type transition_observer = keeper_name:string -> revision:int64 -> unit

(** Install the single post-commit invalidation observer.  It is invoked after
    every successful queue mutation and always outside queue mutexes.  Observer
    failures are logged and never roll back or disguise a committed mutation. *)
val set_transition_observer : transition_observer option -> unit

val continuation_channel_of_message_source :
  message_source -> Keeper_continuation_channel.t

(** Claim the startup-only persistence ownership boundary and restore every
    per-Keeper SQLite store. Unsupported or malformed databases are retained,
    registered as unavailable, and reported here; they are never replaced by an
    empty queue. A second live configuration attempt returns a typed
    [Configuration_conflict] report and cannot clear or replace the active
    registry. *)
val configure_persistence : base_path:string -> configure_report

val persistence_configured : unit -> bool

(** Enqueue only after the receipt-bearing SQLite transaction commits. *)
val enqueue :
  keeper_name:string -> queued_message -> (enqueue_receipt, mutation_error) result

val enqueue_with_receipt :
  keeper_name:string ->
  receipt_id:Receipt_id.t ->
  queued_message ->
  (enqueue_receipt, mutation_error) result
(** Idempotently accept a preallocated receipt. An existing active receipt must
    carry exactly the same canonical message and is returned without mutation.
    An existing terminal receipt returns [Receipt_already_terminal]; terminal
    rows never retain message bodies and are never overwritten or redispatched. *)

val claim_next :
  keeper_name:string ->
  [ `Claimed of claim
  | `Empty
  | `Already_claimed of Receipt_id.t
  | `Error of mutation_error
  ]

(** Atomically complete the receipt in the matching claim. Terminal records
    retain correlation metadata but discard message bodies and attachments. *)
val complete_claim :
  keeper_name:string ->
  receipt_id:Receipt_id.t ->
  outcome:finalization ->
  [ `Completed of Receipt_id.t
  | `Error of mutation_error
  ]

val has_active_receipts : keeper_name:string -> (bool, mutation_error) result

type lane_health =
  | Ready
  | Persistence_reconciliation_required
  | Unavailable of snapshot_load_error

type lane_status = {
  revision : int64;
  has_active : bool;
  health : lane_health;
}

(** O(1), memory-only hot-path projection. Consumers should use this instead
    of materializing [snapshot] before [claim_next]. *)
val lane_status : keeper_name:string -> (lane_status, mutation_error) result

val snapshot : keeper_name:string -> diagnostic_snapshot

val lookup_receipt :
  keeper_name:string ->
  receipt_id:Receipt_id.t ->
  (receipt_lookup, mutation_error) result
(** Atomically return the receipt observation with the queue revision that
    produced it. A [Durability_uncertain] lane remains observable by receipt id
    even though further mutations are rejected until reconciliation. *)

type pending_cancellation =
  { cancelled_at : float
  ; detail : string
  }

type pending_cancellation_report =
  { receipt_id : Receipt_id.t
  ; revision : int64
  ; state : receipt_state
  }

(** Cancel exactly one durable [Pending] receipt. A receipt that has already
    started delivery is rejected without mutation. *)
val cancel_pending :
  keeper_name:string ->
  receipt_id:Receipt_id.t ->
  cancellation:pending_cancellation ->
  (pending_cancellation_report, mutation_error) result

type reconciliation_outcome =
  | Already_consistent
  | Reconciled

type reconciliation_report =
  { outcome : reconciliation_outcome
  ; revision : int64
  }

val reconcile_persistence :
  keeper_name:string -> (reconciliation_report, mutation_error) result
(** Reconcile one quarantined Keeper lane without resetting the process-wide
    registry. The SQLite observation must exactly match either side of the
    retained transaction plan. A pre-publication projection is replayed; a
    published projection is verified; a pre-dispatch claim is returned to
    [Pending]. Any third state remains a typed [Reconciliation_failed] conflict
    that the consumer never replays. *)

val all_keeper_names : unit -> string list

module For_testing : sig
  type transaction_stage =
    | Transaction_begun
    | Mutation_applied
    | Before_commit
    | Commit_invoked
    | Commit_returned
    | Before_rollback
    | Before_close

  type commit_failure =
    | Commit_busy
    | Commit_io_error

  val reset : unit -> unit
  val fail_transaction_at_stages : transaction_stage list -> unit
  val fail_next_commit_with : commit_failure -> unit
  val set_transaction_stage_observer :
    (transaction_stage -> unit) option -> unit
  val set_inventory_classified_observer : (unit -> unit) option -> unit

  val finalize_statement : Sqlite3.db -> Sqlite3.stmt -> (unit, string) result
  (** Total statement finalize: folds both the rc channel and the
      SqliteError raise channel of [Sqlite3.finalize] into [result], so
      cleanup can never erase a body result or replace a pending
      [Eio.Cancel.Cancelled]. Exposed for the totality regression test. *)
  val snapshot_path : base_path:string -> keeper_name:string -> (string, string) result
  val receipt_json :
    base_path:string ->
    keeper_name:string ->
    receipt_id:Receipt_id.t ->
    (string option, string) result
end
