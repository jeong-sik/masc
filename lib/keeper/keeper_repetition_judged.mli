(** Where the loop guard's seed from checkpoint history stops: the history
    tool-call pairs a repetition yield has already judged.

    [Keeper_run_tools_setup.initial_tool_calls] seeds the guard with every
    matched ToolUse/ToolResult pair in the checkpoint history, so a loop split
    across a checkpoint restart is still caught (#26057). Read on its own,
    that seed also re-counts the pairs a previous yield was already the
    verdict on. The exact axis counts identical calls anywhere in the list,
    so once three identical reads sat in the history every later identical
    read yielded on its first call: msx-retro-mania's
    [masc_msx_screen count=41] on 2026-09-14, three times, each after one
    turn (#36276). A yield is the judgment; the calls behind it are not
    evidence again.

    The boundary is a count of history pairs, as the seeder counts them,
    kept in the agent context's Session scope under {!context_key} so it
    rides with the checkpoint the way the tool load receipts do. It moves
    only at the setup of the turn after a [Repeated_tool_call] checkpoint,
    to the whole history as it stands then; a turn that stopped for any
    other reason leaves it, so the 2+2 case #26057 measured still seeds.
    Pairs are only ever appended, so the oldest [judged] pairs are exactly
    the ones the yield saw; a history that has since been cut shorter
    seeds nothing rather than something it cannot name. *)

type error = Invalid_record of string

val error_to_string : error -> string

val context_key : string

(** [restore ~source ~target] is the boundary the durable context holds,
    copied into the run's context so it rides with the next checkpoint; [0]
    when the context holds none, which clears any stale copy on [target]. A
    present record that does not decode is the error, not [0]. *)
val restore
  :  source:Agent_core.Context.t
  -> target:Agent_core.Context.t
  -> (int, error) result

(** [record context pairs] writes the boundary into [context]'s Session
    scope; the caller's checkpoint commits it. *)
val record : Agent_core.Context.t -> int -> unit

(** [seed_beyond ~judged pairs] keeps the newest [length pairs - judged] of
    [pairs] (newest first): everything a previous yield has not judged.
    [judged] at or past the length keeps nothing. *)
val seed_beyond
  :  judged:int
  -> Keeper_agent_result.tool_call_detail list
  -> Keeper_agent_result.tool_call_detail list
