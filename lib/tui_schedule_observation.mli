(** Read-only evidence for the latest occurrence of a scheduled Keeper wake.
    Dispatch acceptance, a turn boundary and durable completion are distinct.
    No timer, wake, acknowledgement or other mutation is performed here. *)
type stage =
  | No_occurrence
  | Dispatching
  | Dispatch_failed of string option
  | Queued
  | Queued_at of string
  | Missing
  | Turn_started
  | Turn_ended
  | Consumed
  | Completed
  | Failed of string option
  | Cancelled of string option
  | Settling
  | Transferring
  | Unknown of string

type t =
  { stage : stage
  ; due_at_iso : string option
  }

val decode : Yojson.Safe.t -> (t, string) result
(** Decode a dashboard schedule row. Queue/reaction evidence must agree with
    the row's instance, schedule and exact dispatch stimulus. Queue evidence
    also binds the wake's due time and payload digest. Unknown vocabulary
    becomes [Unknown]. A supported receipt without an exact stimulus stays
    [Unknown] after checking the schedule and Keeper target; malformed or
    contradictory identities still return [Error].
    [due_at_iso] belongs to the last wake, never the next scheduled firing. *)

val needs_attention : stage -> bool
(** Pending execution or uncertain/failed delivery, rather than a finished
    historical occurrence. This never implies operator action is required. *)
