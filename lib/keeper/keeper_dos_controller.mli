(** Host lifecycle policy; controller state belongs to the attached worker. *)
val release_retired : config:Workspace.config -> keeper_name:string -> by:string -> (unit, string) result
(** Conditionally release [keeper_name] when its Keeper is removed permanently.
    Worker Board events are published after the call completes. No shared DOS
    installation or an unheld controller is a successful no-op; unreadable or
    unconfirmed worker state returns an error. *)

type participation_error = Credential_changed | Not_a_seat | Participation_unavailable of string
val set_participation : config:Workspace.config -> who:string -> token:string ->
  Play_participation.t -> (unit, participation_error) result
(** Revalidate the exact current credential and expiry under Auth admission.
    Departure persists ineligibility and asks the attached worker to release
    this holder while retaining the same admission used by incoming handoffs.
    Reconnection restores eligibility without taking control. Board publication
    occurs after release of Auth. The bearer remains valid for explicit
    reconnect. A [Worker] credential is not a seat and is refused with
    [Not_a_seat] before any record is written or controller released. *)
