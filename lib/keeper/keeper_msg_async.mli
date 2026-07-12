(** Keeper_msg_async — Fire-and-forget keeper message execution.

    Background fibers run [keeper_msg] turns. MCP tool returns
    immediately with a [request_id]; clients poll via
    [masc_keeper_msg_result] for completion. Completed entries auto-expire
    from memory after [max_age_sec] (1h), while accepted request records are
    persisted under the active [.masc] root for recovery diagnostics. Terminal
    disk records follow the same age-based cleanup policy. *)

(** {1 Types} *)

type request_status =
  | Queued
  | Running
  | Lost of { reason : string }
  | Cancelled of
      { reason : string
      ; cancelled_by : string
      }
  | Persistence_failed of
      { attempted_status : string
      ; reason : string
      }
  | Done of
      { ok : bool
      ; body : string
      }

type entry =
  { request_id : string
  ; keeper_name : string
  ; base_path : string
  ; submitted_by : string
  ; status : request_status
  ; submitted_at : float
  ; completed_at : float option
  }

(** A request exists, but the supplied access identity does not own it (or
    cannot be constructed). [Caller_mismatch] intentionally does not expose
    the persisted owner value. A different base path is a different store and
    therefore yields [Absent], not an ownership oracle. *)
type access_rejection =
  | Invalid_base_path of { reason : string }
  | Invalid_caller
  | Invalid_request_id
  | Caller_mismatch

(** Outcome of looking up a request record.

    - [Found entry] — the request is known (in memory or recovered from disk).
    - [Absent] — no record exists: the id was never accepted, or its terminal
      record already aged out. Pollers can stop polling or resubmit.
    - [Unreadable reason] — a record file exists but cannot be decoded
      (corrupt JSON, missing required fields, or unknown status). The request
      WAS accepted, but its result cannot be recovered. *)
type load_result =
  | Found of entry
  | Absent
  | Unreadable of string
  | Rejected of access_rejection

type submit_error =
  | Submit_rejected of access_rejection
  | Invalid_timeout of { reason : string }
  | Initial_persistence_failed of { reason : string }
  | Acceptance_persistence_failed of
      { request_id : string
      ; reason : string
      }
  | Background_switch_unavailable of { reason : string }
  | Background_fork_failed of
      { request_id : string
      ; reason : string
      }

type cancel_result =
  | Cancelled_request
  | Cancel_not_found
  | Cancel_unreadable of string
  | Cancel_rejected of access_rejection
  | Cancel_already_terminal of request_status
  | Cancel_persistence_failed of { reason : string }
  | Cancel_worker_signal_failed of { reason : string }

(** Reason [f] was cut off before it could reach its own completion. [f] is
    the sole owner of any terminal signal it emits on its own side channels
    (e.g. an SSE event stream) while it runs — those channels see nothing if
    [f] never returns. [worker_abort_reason] is what [on_worker_aborted]
    receives so such callers can push their own terminal signal instead of
    waiting forever on a channel [f] never got to finish. *)
type worker_cancel_source =
  | Operator_request
  | Runtime_cancellation

val worker_cancel_source_to_string : worker_cancel_source -> string
(** Stable wire label for cancellation provenance. *)

type worker_abort_reason =
  | Timeout of { timeout_sec : float }
  | Worker_cancelled of
      { cancelled_by : worker_cancel_source
      ; reason : string
      }

(** {1 Submit and poll} *)

val server_background_switch : unit -> (Eio.Switch.t, submit_error) result
(** Resolve the server-lifetime root switch without consulting the current
    turn-local switch. Failure is typed and suitable for the same error envelope
    as [submit]. *)

(** [submit ?clock ?timeout_sec ?on_accepted ?on_worker_aborted ~background_sw ~f
    ~keeper_name ~base_path ~caller] forks a background daemon fiber on the
    explicitly supplied server-lifetime [background_sw].  The per-request
    worker switch passed to [f] is distinct: cancellation fails that switch,
    never the server root.  Returns the fresh [request_id] synchronously only
    after the owner-bearing v2 request record is durably accepted. The async
    transport has no implicit outer deadline: Keeper/OAS turn policy owns
    execution deadlines and finalization. When [timeout_sec] is explicitly
    supplied together with [clock], the caller-owned deadline is enforced and
    recorded as a terminal timeout. A timeout must be finite and positive, and
    an explicit timeout without [clock] is rejected before persistence.
    Cancellation of the
    per-request worker switch interrupts the worker and records a terminal
    [Cancelled] state before stopping, so
    pollers do not observe an indefinite [Running] request. [Lost] is
    reserved for persisted non-terminal requests recovered without a live
    worker.

    [on_accepted] runs after the request record is durable and before a worker
    can start. It owns any producer-specific durable acceptance side effect;
    failure returns [Acceptance_persistence_failed] and no worker is forked.

    [on_worker_aborted], when supplied, is invoked exactly once whenever [f]
    is cut off by a timeout or cancellation before it completes on its own —
    never when [f] returns or raises normally, since [f] is expected to have
    already signaled its own completion on those paths. It runs from a fiber
    that is not itself under cancellation at the moment of the call (wrapped
    internally in {!Eio.Cancel.protect}), so it may safely perform blocking
    Eio operations such as pushing to a caller-owned stream. Callback
    errors and exceptions are converted to [Persistence_failed]; the requested
    timeout/cancel status cannot become terminal polling truth until this
    delivery callback succeeds. Callback failures never escape to the server
    root switch. *)
val submit
  :  ?clock:_ Eio.Time.clock
  -> ?timeout_sec:float
  -> ?on_accepted:(string -> (unit, string) result)
  -> ?on_worker_aborted:(worker_abort_reason -> (unit, string) result)
  -> background_sw:Eio.Switch.t
  -> base_path:string
  -> caller:string
  -> f:(Eio.Switch.t -> Keeper_types_profile.tool_result)
  -> keeper_name:string
  -> unit
  -> (string, submit_error) result

(** [poll ~base_path ~caller request_id] returns [Found entry] for a known request,
    [Absent] when no record exists, and [Unreadable reason] when a persisted
    record exists but cannot be decoded. [Rejected reason] means the request
    exists outside the exact canonical base-path/caller lane. If a
    persisted non-terminal request exists without an in-memory worker, it is
    returned as [Lost] and the terminal lost state is persisted. *)
val poll : base_path:string -> caller:string -> string -> load_result

(** Mark persisted non-terminal request records that have no live in-memory
    worker as [Lost], returning the number of records transitioned. This is
    intended for server startup/recovery sweeps: current-process workers remain
    protected by the in-memory pending table, while disk-only [Queued]/[Running]
    records from a previous process stop looking indefinitely active. *)
val recover_lost_disk_records : base_path:string -> int

(** [cancel ~base_path ~caller request_id] validates exact request ownership,
    atomically installs the terminal cancelled state, and only then fails the
    per-request worker switch. *)
val cancel : base_path:string -> caller:string -> string -> cancel_result

(** [list_for_keeper ~base_path ~caller ?keeper_name ()] returns only entries
    owned by the exact caller lane, optionally filtered by target keeper, sorted
    most-recent-first. Cross-lane entries are omitted. *)
val list_for_keeper
  :  base_path:string
  -> caller:string
  -> ?keeper_name:string
  -> unit
  -> (entry list, access_rejection) result

(** {1 JSON output} *)

val status_to_string : request_status -> string
val access_rejection_to_json : access_rejection -> Yojson.Safe.t
val submit_error_to_json : submit_error -> Yojson.Safe.t
val cancel_result_to_json : request_id:string -> cancel_result -> Yojson.Safe.t

(** JSON encoding with [request_id], [keeper_name], [status],
    [submitted_at], and — depending on state — [completed_at] /
    [elapsed_sec] / [ok] + [result]. *)
val entry_to_json : entry -> Yojson.Safe.t

module For_testing : sig
  val record_schema_version : int
  val is_safe_request_id : string -> bool
  val forget : base_path:string -> caller:string -> request_id:string -> unit
  val clear : unit -> unit
  val record_path : base_path:string -> request_id:string -> string option
  val load_record : base_path:string -> request_id:string -> load_result
  val gc_stale_disk : base_path:string -> int
  val recover_lost_disk_records : base_path:string -> int
  val active_switch_count : unit -> int
  val effective_timeout_sec : ?timeout_sec:float -> unit -> float option
end
