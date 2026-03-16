(** Subsystem — shared contract for OAS-integrated subsystems.
    See [subsystem.mli] for the module type [S]. *)

module type S = sig
  val name : string
  val agent_card : Agent_card.agent_card
  val status_json : unit -> Yojson.Safe.t
end
