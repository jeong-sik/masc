(** Subsystem — shared contract for OAS-integrated subsystems.

    Each subsystem (Guardian, Sentinel, Gardener) exports:
    - Agent Card identity (A2A v0.3)
    - JSON status snapshot
    - Event publication capability

    Note: [start] / [shutdown] signatures differ per subsystem
    (Guardian needs [~net], Gardener needs [~room_config]) so they
    are NOT part of this shared contract.

    @since 2.95.1 *)

(** Minimal module type shared across Guardian, Sentinel, Gardener. *)
module type S = sig
  (** Subsystem name (e.g. "guardian", "sentinel", "gardener"). *)
  val name : string

  (** A2A v0.3 Agent Card for this subsystem. *)
  val agent_card : Agent_card.agent_card

  (** Current runtime status as JSON. *)
  val status_json : unit -> Yojson.Safe.t
end
