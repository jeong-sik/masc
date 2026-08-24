(** Explicit turn-local causal evidence for contextual Gate judgment.

    The cell is created once by the outer Keeper turn and threaded through the
    AGENT_CORE tool bundle. Each completed Tool appends its exact typed input.
    [snapshot] renders the newest of those calls that fit a declared evidence
    budget, as immutable JSON for one later Gate request. No global,
    string-keyed, or fiber-local carrier is used. *)

type t

val evidence_budget_bytes : int
(** Byte ceiling applied to the rendered ["completed_tool_calls"] of one
    {!snapshot}. Shared with {!Keeper_run_tools_setup.gate_history_budget_bytes}
    so the two evidence axes of the judge bundle stay one declared number
    instead of two independently tuned ones. *)

val create : turn_id:int option -> initial:Yojson.Safe.t -> t

val record_tool_result :
  t -> operation:string -> input:Yojson.Safe.t -> Tool_result.result -> unit

val snapshot : t -> Keeper_gate.causal_context
(** Renders ["completed_tool_calls"] newest-first within
    {!For_testing.evidence_budget_bytes} and reports how many calls that left
    out as ["completed_tool_calls_omitted"]. The cell keeps every recorded call;
    only this rendering is bounded, so the judge is told its view is partial
    rather than handed an unbounded prompt. See the implementation comment for
    the #26081 measurement this restores. *)
