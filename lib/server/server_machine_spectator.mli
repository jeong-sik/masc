val machine_of_request_target : string -> (Machine_lane.t option, string) result
(** Read the optional ["machine"] query. An unknown value is an error; absence
    leaves the observer stream without a machine ticker. *)

val start :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> stop_promise:unit Eio.Promise.t ->
  machine:Machine_lane.t -> config:Workspace.config -> unit
(** Run the selected machine's time only while its observer stream is open. *)

module For_testing : sig
  val with_step :
    (config:Workspace.config -> machine:Machine_lane.t -> (unit, string) result) ->
    (unit -> 'a) -> 'a
end
