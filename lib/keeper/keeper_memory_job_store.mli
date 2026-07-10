(** Durable per-keeper post-turn memory jobs.

    The store is rooted exclusively from [base_path]. A job moves through
    [awaiting-turn-commit -> pending -> inflight -> terminal receipt]. The
    execution receipt gates the first transition; the terminal memory receipt
    gates acknowledgement. Recovery requeues only inflight jobs that have no
    terminal memory receipt.
    Callers serialize access for one keeper; files are still written atomically
    so process crashes cannot expose partial JSON. *)

type job = private
  { id : string
  ; keeper_name : string
  ; trace_id : string
  ; generation : int
  ; turn : int
  ; oas_turn_count : int
  ; enqueued_at : float
  ; payload : Yojson.Safe.t
  }

type lease =
  { job : job
  ; started_at : float
  }

type admission =
  | Staged_awaiting_turn_commit
  | Already_awaiting
  | Already_pending
  | Already_inflight
  | Already_completed

type activation =
  | Activated
  | Activation_already_pending
  | Activation_already_inflight
  | Activation_already_completed

type terminal_outcome =
  | Succeeded
  | Failed

type receipt_identity =
  { id : string
  ; keeper_name : string
  ; trace_id : string
  ; generation : int
  ; turn : int
  ; oas_turn_count : int
  ; enqueued_at : float
  ; payload_sha256 : string
  }

type terminal_receipt =
  { identity : receipt_identity
  ; started_at : float
  ; ended_at : float
  ; outcome : terminal_outcome
  ; detail : Yojson.Safe.t
  }

type io_operation =
  | Ensure_directory
  | Set_permissions
  | Inspect
  | List_directory
  | Read
  | Write
  | Rename
  | Remove

type error =
  | Invalid_keeper_name of string
  | Invalid_trace_id of string
  | Invalid_turn_identity of
      { generation : int
      ; turn : int
      ; oas_turn_count : int
      }
  | Invalid_enqueue_time of float
  | Invalid_job_id of string
  | Unexpected_queue_entry of string
  | Decode_error of
      { path : string
      ; detail : string
      }
  | Identity_conflict of
      { job_id : string
      ; path : string
      }
  | Turn_receipt_error of
      { keeper_name : string
      ; detail : string
      }
  | Io_error of
      { operation : io_operation
      ; path : string
      ; detail : string
      }

type cleanup_report =
  { cleanup_errors : error list
  }

type recovery_report =
  { replayed : int
  ; cleanup_errors : error list
  }

type claim_report =
  { leases : lease list
  ; cleanup_errors : error list
  }

val error_to_string : error -> string
val is_valid_job_id : string -> bool

val make_job :
  keeper_name:string ->
  trace_id:string ->
  generation:int ->
  turn:int ->
  oas_turn_count:int ->
  enqueued_at:float ->
  payload:Yojson.Safe.t ->
  (job, error) result
(** Construct a job with a deterministic full SHA-256 id over its typed turn
    identity. Re-admitting the same turn is therefore idempotent. *)

val job_to_json : job -> Yojson.Safe.t
val job_of_json : Yojson.Safe.t -> (job, string) result
val receipt_identity_of_job : job -> receipt_identity
val receipt_to_json : terminal_receipt -> Yojson.Safe.t
val receipt_of_json : Yojson.Safe.t -> (terminal_receipt, string) result

val stage_awaiting_turn_commit :
  base_path:string -> job -> (admission, error) result
(** Persist the job in a non-runnable outbox before returning. It cannot be
    claimed until {!activate} runs after the owning execution receipt commits. *)

val list_awaiting :
  base_path:string -> keeper_name:string -> (job list, error) result

val activate :
  base_path:string -> job -> (activation * cleanup_report, error) result
(** Durably move an awaiting job into [pending]. Writing [pending] is the
    activation commit; failure to remove the old awaiting envelope is reported
    as cleanup debt and cannot block the runnable lane. *)

val abort_awaiting : base_path:string -> job -> (unit, error) result
(** Remove a non-runnable job when its owning execution receipt failed. *)

val recover_inflight :
  base_path:string -> keeper_name:string -> (recovery_report, error) result
(** Move every receipt-less inflight job back to pending. Inflight jobs with a
    terminal receipt are acknowledged without replay. Cleanup failures are
    returned as debt and never stop recovery of later jobs. *)

val claim_all :
  base_path:string -> keeper_name:string -> now:float -> (claim_report, error) result
(** Claim the current pending batch with one validated scan and one sort. The
    returned leases preserve the keeper's linear turn order. *)

val finish :
  base_path:string -> terminal_receipt -> (cleanup_report, error) result
(** Atomically persist the terminal receipt before acknowledging queue/stage
    files. Repeating [finish] for the same receipt is idempotent. Post-commit
    cleanup errors are returned as debt, not as commit failure. *)

val backlog_count :
  base_path:string -> keeper_name:string -> (int, error) result

val discover_keeper_names :
  base_path:string -> (string list * error list, error) result
(** Discover keeper directories with awaiting, pending, or inflight memory jobs. A
    keeper-local malformed queue is returned in the error list without
    suppressing healthy keepers; an outer [Error] means the keepers root itself
    could not be inspected. *)

val operation_stage_path_for_keepers_dir :
  keepers_dir:string -> keeper_name:string -> operation_id:string -> string
(** SSOT path for a provider result staged until its memory-job terminal receipt
    is durable. *)

module For_testing : sig
  val awaiting_dir : base_path:string -> keeper_name:string -> string
  val pending_dir : base_path:string -> keeper_name:string -> string
  val inflight_dir : base_path:string -> keeper_name:string -> string
  val receipts_dir : base_path:string -> keeper_name:string -> string
  val receipt_path : base_path:string -> job -> string
end
