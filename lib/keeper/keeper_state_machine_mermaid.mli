(** Keeper state-machine -> Mermaid [stateDiagram-v2] rendering. *)

val phase_to_mermaid_id : Keeper_state_machine.phase -> string
val phase_to_mermaid : current:Keeper_state_machine.phase -> string
