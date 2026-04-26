(** Progress Notifications — MCP 2025-11-25 MAY requirement.

    Send real-time progress updates for long-running tasks.
    Uses JSON-RPC 2.0 notifications/progress method. *)

(** {1 Types} *)

type progress =
  { task_id : string
  ; progress : float
  ; message : string option
  ; estimated_remaining : float option
  }

type validation_error =
  | TaskIdEmpty
  | TaskIdTooLong of int
  | TaskIdInvalidChars
  | ProgressOutOfRange of float

(** {1 Validation} *)

val validate_task_id : string -> (string, validation_error) result
val validate_progress : float -> (float, validation_error) result
val validation_error_to_string : validation_error -> string

(** {1 JSON serialization} *)

val progress_to_jsonrpc : progress -> Yojson.Safe.t

(** {1 Tracker}

    Step-based progress tracking with automatic rate estimation. *)
module Tracker : sig
  type t =
    { task_id : string
    ; mutable current : float
    ; total_steps : int
    ; mutable completed_steps : int
    ; start_time : float
    }

  val notify_ref
    : (task_id:string
       -> progress:float
       -> ?message:string
       -> ?estimated_remaining:float
       -> unit
       -> unit)
        ref

  val assert_wired : unit -> unit
  val create : task_id:string -> ?total_steps:int -> unit -> t
  val update : t -> progress:float -> ?message:string -> unit -> unit
  val step : t -> ?message:string -> unit -> unit
  val complete : t -> ?message:string -> unit -> unit
end

(** {1 State management} *)

val set_sse_callback : (Yojson.Safe.t -> unit) -> unit

val notify
  :  task_id:string
  -> progress:float
  -> ?message:string
  -> ?estimated_remaining:float
  -> unit
  -> unit

val start_tracking : task_id:string -> ?total_steps:int -> unit -> Tracker.t
val get_tracker : string -> Tracker.t option
val stop_tracking : string -> unit

(** {1 Tool handler} *)

val handle_progress_tool : Yojson.Safe.t -> bool * string

(** {1 Testing} *)

val reset_for_testing : unit -> unit
