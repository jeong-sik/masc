(** Keeper state-machine JSON wire encoders.

    No reverse alias in [Keeper_state_machine] (wrapped-library cycle).
    See PR #16880 [Keeper_state_machine_mermaid] for the same pattern. *)

open Keeper_state_machine

val phase_to_json : phase -> Yojson.Safe.t
val conditions_to_json : conditions -> Yojson.Safe.t
val event_to_json : event -> Yojson.Safe.t
val transition_result_to_json : transition_result -> Yojson.Safe.t
