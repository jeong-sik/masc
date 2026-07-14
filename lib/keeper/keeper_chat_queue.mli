(** Durable per-Keeper chat receipt queue.

    Every accepted message receives a stable receipt before the first durable
    write.  The receipt then follows exactly one closed lifecycle:
    [Pending -> Inflight -> Delivered | Failed]. On restart, [Inflight] becomes
    [Recovery_required] in the same SQLite store. From there only an explicit
    operator decision can produce [Pending] or [Failed]. No external journal
    participates in this lifecycle.

    Each lease contains exactly one receipt, so message, multimodal block,
    attachment, timestamp, provenance, and connector identity boundaries are
    preserved without delimiter-based coalescing. A crashed lease is never
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
  | Internal_error
  | Recovery_interrupted

val failure_kind_to_string : failure_kind -> string

type failure = {
  completed_at : float;
  kind : failure_kind;
  detail : string;
  outcome_ref : string option;
}

type receipt_state =
  | Pending
  | Inflight of { lease_id : string; started_at : float }
  | Recovery_required of { lease_id : string; started_at : float }
  | Delivered of completion
  | Failed of failure

type leased_message = {
  receipt_id : Receipt_id.t;
  message : queued_message;
}

type lease = {
  lease_id : string;
  item : leased_message;
}

type recovery_evidence = {
  receipt_id : Receipt_id.t;
  lease_id : string;
  started_at : float;
}

type finalization =
  | Mark_delivered of completion
  | Mark_failed of failure

type snapshot_load_error_kind =
  | Invalid_path
  | Read_failed
  | Parse_failed
  | Recovery_failed
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
  | Lease_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      ; lease_id : string
      }
  | Finalize_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      ; lease_id : string
      }
  | Nack_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      ; lease_id : string
      }
  | Startup_recovery_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      ; lease_id : string
      }
  | Recovery_requeue_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      ; lease_id : string
      }
  | Recovery_cancel_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      ; lease_id : string
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
  | Receipt_not_recovery_required of
      { receipt_id : Receipt_id.t
      ; observed_state : receipt_state option
      }
  | Recovery_revision_mismatch of
      { receipt_id : Receipt_id.t
      ; expected_revision : int64
      ; observed_revision : int64
      }
  | Recovery_lease_mismatch of
      { receipt_id : Receipt_id.t
      ; expected_lease_id : string
      ; observed_lease_id : string
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
  recovery_required : active_receipt list;
  terminal_count : int64;
  load_errors : snapshot_load_error list;
}

type enqueue_receipt = {
  receipt_id : Receipt_id.t;
  revision : int64;
  pending_count : int;
  inflight_count : int;
  recovery_required_count : int;
}

type configure_report = {
  restored_keeper_count : int;
  recovery_required_receipt_count : int;
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

val lease_next :
  keeper_name:string ->
  [ `Leased of lease
  | `Empty
  | `Already_leased of string
  | `Recovery_required of recovery_evidence
  | `Error of mutation_error
  ]

(** Atomically finalize the receipt in the matching lease. Terminal records
    retain correlation metadata but discard message bodies and attachments. *)
val finalize :
  keeper_name:string ->
  lease_id:string ->
  outcome:finalization ->
  [ `Finalized of Receipt_id.t
  | `Unknown_lease
  | `Error of mutation_error
  ]

(** Return the receipt in the matching lease to [Pending], preserving its id
    and FIFO position. *)
val nack :
  keeper_name:string ->
  lease_id:string ->
  [ `Requeued of Receipt_id.t
  | `Unknown_lease
  | `Error of mutation_error
  ]

val pending_count : keeper_name:string -> (int, mutation_error) result
val inflight_count : keeper_name:string -> (int, mutation_error) result
val has_active_receipts : keeper_name:string -> (bool, mutation_error) result

type lane_health =
  | Ready
  | Persistence_reconciliation_required
  | Delivery_recovery_required of
      { receipt_id : Receipt_id.t
      ; lease_id : string
      ; started_at : float
      }
  | Unavailable of snapshot_load_error

type lane_status = {
  revision : int64;
  has_active : bool;
  health : lane_health;
}

(** O(1), memory-only hot-path projection. Consumers should use this instead
    of materializing [snapshot] before [lease_next]. *)
val lane_status : keeper_name:string -> (lane_status, mutation_error) result

val snapshot : keeper_name:string -> diagnostic_snapshot

val lookup_receipt :
  keeper_name:string ->
  receipt_id:Receipt_id.t ->
  (receipt_lookup, mutation_error) result
(** Atomically return the receipt observation with the queue revision that
    produced it. A [Durability_uncertain] lane remains observable by receipt id
    even though further mutations are rejected until reconciliation. *)

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
    published projection is verified; an uncertain lease is compensated to
    [Pending]. Any third state remains a typed [Reconciliation_failed] conflict
    for explicit operator action. *)

type recovery_cancellation =
  { cancelled_at : float
  ; detail : string
  ; outcome_ref : string option
  }

type recovery_resolution =
  | Requeue_unconfirmed
  | Cancel_unconfirmed of recovery_cancellation

type recovery_resolution_report =
  { receipt_id : Receipt_id.t
  ; revision : int64
  ; state : receipt_state
  }

(** Resolve exactly one durable [Recovery_required] receipt. The caller must
    present the revision and lease evidence it observed. A stale or mismatched
    decision is rejected without mutation. [Requeue_unconfirmed] is the only
    path back to dispatch; [Cancel_unconfirmed] makes the receipt terminal. *)
val resolve_recovery_required :
  keeper_name:string ->
  receipt_id:Receipt_id.t ->
  expected_revision:int64 ->
  lease_id:string ->
  resolution:recovery_resolution ->
  (recovery_resolution_report, mutation_error) result

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
  val set_before_entry_lock_observer : (string -> unit) option -> unit
  val failure_kind_of_string : string -> (failure_kind, string) result
  val snapshot_path : base_path:string -> keeper_name:string -> (string, string) result
  val receipt_json :
    base_path:string ->
    keeper_name:string ->
    receipt_id:Receipt_id.t ->
    (string option, string) result
end
