val machine_of_request_target : string -> (Machine_lane.t option, string) result
(** Read the optional ["machine"] query. An unknown value is an error; absence
    leaves the observer stream without a machine ticker. *)

type step_error =
  | Unavailable of string
  | Outcome_unknown of string
  | Host_refusal of string

val start :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> stop_promise:unit Eio.Promise.t ->
  machine:Machine_lane.t -> config:Workspace.config -> unit
(** Run the selected machine's time only while its observer stream is open.
    Retry [Unavailable], but never replay [Outcome_unknown] or [Host_refusal]. *)

module For_testing : sig
  val with_step :
    (config:Workspace.config -> machine:Machine_lane.t -> (unit, step_error) result) ->
    (unit -> 'a) -> 'a
end
