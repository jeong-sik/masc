(** Typed projection from a Keeper tool bundle's terminal-effect state to the
    Agent Core cooperative-yield boundary. *)

val decision
  :  Keeper_tools_agent_core.terminal_effect_state
  -> (Runtime_agent.cooperative_yield_decision, Agent_core.Error.t) result
