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
  | Done of
      { ok : bool
      ; body : string
      }

type entry =
  { request_id : string
  ; keeper_name : string
  ; base_path : string
  ; status : request_status
  ; submitted_at : float
  ; completed_at : float option
  }

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

(** [submit ?clock ?timeout_sec ?on_worker_aborted ~sw ~f ~keeper_name] forks
    a background daemon fiber on [sw] that runs [f] and stores the result.
    Returns the fresh [request_id] synchronously. The async request has no
    implicit outer deadline: keeper/OAS turn policy owns execution deadlines
    and finalization, so this wrapper must not cancel a live multi-turn run a
    second time. When [timeout_sec] is explicitly supplied together with
    [clock], the caller-requested deadline is enforced and recorded as a
    terminal timeout. Supplying [timeout_sec] without [clock], or a non-
    positive/non-finite value, raises [Invalid_argument] before the request is
    accepted. Cancellation of [sw] interrupts the worker and records a
    terminal [Cancelled] state before stopping, so pollers do not observe an
    indefinite [Running] request. [Lost] is reserved for persisted non-
    terminal requests recovered without a live worker.

    [on_worker_aborted], when supplied, is invoked exactly once whenever [f]
    is cut off by a timeout or cancellation before it completes on its own —
    never when [f] returns or raises normally, since [f] is expected to have
    already signaled its own completion on those paths. It runs from a fiber
    that is not itself under cancellation at the moment of the call (wrapped
    internally in {!Eio.Cancel.protect}), so it may safely perform blocking
    Eio operations such as pushing to a caller-owned stream. Callback
    exceptions are logged and re-raised; they are never treated as successful
    notification. *)
val submit
  :  ?clock:_ Eio.Time.clock
  -> ?timeout_sec:float
  -> ?on_worker_aborted:(worker_abort_reason -> unit)
  -> sw:Eio.Switch.t
  -> base_path:string
  -> f:(unit -> Keeper_types_profile.tool_result)
  -> keeper_name:string
  -> unit
  -> string

(** [poll ?base_path request_id] returns [Found entry] for a known request,
    [Absent] when no record exists, and [Unreadable reason] when a persisted
    record exists but cannot be decoded. If [base_path] is supplied and a
    persisted non-terminal request exists without an in-memory worker, it is
    returned as [Lost] and the terminal lost state is persisted. *)
val poll : ?base_path:string -> string -> load_result

(** Mark persisted non-terminal request records that have no live in-memory
    worker as [Lost], returning the number of records transitioned. This is
    intended for server startup/recovery sweeps: current-process workers remain
    protected by the in-memory pending table, while disk-only [Queued]/[Running]
    records from a previous process stop looking indefinitely active. *)
val recover_lost_disk_records : base_path:string -> int

(** [cancel ?base_path request_id] aborts a running async keeper_msg request.
    Returns [true] if it was successfully cancelled, [false] if not found
    or already finished. *)
val cancel : ?base_path:string -> string -> bool

(** [list_for_keeper ?keeper_name ()] returns all entries for a keeper (or all keepers if omitted)
    sorted most-recent-first. *)
val list_for_keeper : ?keeper_name:string -> unit -> entry list

(** {1 JSON output} *)

val status_to_string : request_status -> string

(** JSON encoding with [request_id], [keeper_name], [status],
    [submitted_at], and — depending on state — [completed_at] /
    [elapsed_sec] / [ok] + [result]. *)
val entry_to_json : entry -> Yojson.Safe.t

module For_testing : sig
  val is_safe_request_id : string -> bool
  val forget : string -> unit
  val clear : unit -> unit
  val record_path : base_path:string -> request_id:string -> string option
  val load_record : base_path:string -> request_id:string -> load_result
  val gc_stale_disk : base_path:string -> int
  val recover_lost_disk_records : base_path:string -> int
  val active_switch_count : unit -> int
  val effective_timeout_sec : ?timeout_sec:float -> unit -> float option
end
