(** Keeper state-machine -> Mermaid [stateDiagram-v2] rendering. *)

val phase_to_mermaid_id : Keeper_state_machine.phase -> string
(** Mermaid node identifier for a phase (PascalCase: "Running", "Offline", etc.). *)

val phase_to_mermaid : current:Keeper_state_machine.phase -> string
(** Full stateDiagram-v2 output with [current] phase highlighted. *)
