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

(** {1 Submit and poll} *)

(** [submit ?clock ?timeout_sec ~sw ~f ~keeper_name] forks a background daemon fiber on
    [sw] that runs [f] and stores the result. Returns the fresh
    [request_id] synchronously. When [clock] is provided, the worker records a
    terminal timeout error if [f] does not return before the deadline:
    [timeout_sec] when explicitly supplied, otherwise the runtime-resolved
    keeper turn timeout. Cancellation of [sw] interrupts the worker and records
    a terminal [Cancelled] state before stopping, so pollers do not observe an
    indefinite [Running] request. [Lost] is reserved for persisted non-terminal
    requests recovered without a live worker. *)
val submit
  :  ?clock:_ Eio.Time.clock
  -> ?timeout_sec:float
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
  val active_switch_count : unit -> int
  val effective_timeout_sec : ?timeout_sec:float -> unit -> float
end
