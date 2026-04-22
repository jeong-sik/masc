(** Keeper_extend_turns — Self-extending turn budget tool for keeper Agent.run.

    Creates an [extend_turns] {!Oas.Tool.t} that lets the keeper request
    more turns at runtime.  The tool enforces a per-session extension limit
    (10 extensions) and an absolute ceiling on total turns. *)

(** Create the extend_turns tool.

    @param agent_ref  Mutable ref set to [Some agent] after [Agent.create].
                      The tool mutates the agent's [max_turns] on grant.
    @param max_turns  Initial turn budget.
    @param ceiling    Absolute upper bound on turns (default: [max max_turns 200]). *)
val make :
  agent_ref:Oas.Agent.t option ref ->
  max_turns:int ->
  ?ceiling:int ->
  unit ->
  Oas.Tool.t
