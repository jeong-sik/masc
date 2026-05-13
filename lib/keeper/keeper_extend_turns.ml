(** Keeper_extend_turns — Self-extending turn budget tool for keeper Agent.run.

    Delegates to {!Agent_sdk.Agent.make_extend_turns_tool} which uses the
    public [Agent.t] type and OAS-internal {!Agent_turn_budget} for
    budget tracking, idle checks, and cost guards.

    Previously this module reimplemented the budget logic and called an
    internal state-mutating API.  Using the public wrapper avoids the
    internal-API dependency and keeps budget enforcement in OAS. *)

(** Default absolute ceiling on total turns.
    Keepers typically run 50-100 turns per session. 200 is ~2x the worst-case
    observed session length, providing headroom while preventing runaway loops. *)
let default_ceiling = 200

let make ~agent_ref ~max_turns ?ceiling () : Agent_sdk.Tool.t =
  let ceiling = match ceiling with Some c -> c | None -> max max_turns default_ceiling in
  let budget =
    Agent_sdk.Agent_turn_budget.create
      ~initial:max_turns
      ~ceiling
      ()
  in
  Agent_sdk.Agent.make_extend_turns_tool ~agent_ref ~budget ()
