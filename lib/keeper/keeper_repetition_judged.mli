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
    kept in the agent context's Session scope under {!context_key}. It
    moves at the yield itself: when the guard's decision is a
    [Repeated_tool_call], the run records the pairs it was set up over plus
    its own fingerprinted calls -- the pairs that yield judged -- into the
    keeper's loop-lived context. A turn that stops for any other reason
    moves nothing, so the 2+2 case #26057 measured still seeds; pairs a
    direct turn appends afterwards sit past the boundary and seed too.

    Where it lasts. An AGENT_CORE lane takes its Yielded checkpoint after
    the boundary probe, so the record rides to disk with it, and setup on
    both lanes restores it from there -- a direct turn runs on a context of
    its own that its checkpoints persist whole, so the key has to be on it
    too. An official-client lane (claude_code, codex, antigravity) persists
    no AGENT_CORE checkpoint: there the boundary lives in the loop-lived
    context, restore keeps the larger of the durable and the live count,
    and the next AGENT_CORE turn of the same keeper writes it to disk. A
    restart forgets what only the live context held; the next repetition
    yield sets it again.

    The count is the post-tool hook's: a call the hook never saw -- a
    validation failure, an unknown tool -- still leaves a pair the seeder
    counts, so a boundary can fall short by that many and re-seed as many
    of the judged run's newest pairs. Pairs are only ever appended, so the
    oldest [judged] pairs are the ones the yield saw; a history since cut
    shorter seeds nothing rather than something it cannot name. *)

type error = Invalid_record of string

val error_to_string : error -> string

val context_key : string

(** [restore ~source ~target] is the larger of the boundary the durable
    context holds and the one the run's context already holds, written into
    the run's context when that raises it; [0] when neither holds one. A
    present record that does not decode is the error, not [0]. *)
val restore
  :  source:Agent_core.Context.t
  -> target:Agent_core.Context.t
  -> (int, error) result

(** [record context pairs] writes the boundary into [context]'s Session
    scope; the checkpoint taken after it commits it. *)
val record : Agent_core.Context.t -> int -> unit

(** [pairs_judged_by ~history_pairs_at_setup tool_calls] is the boundary a
    repetition yield records: the history pairs the run was set up over,
    plus the run's own calls that carry both fingerprints -- the calls the
    seeder will count once their ToolUse/ToolResult pairs are in the
    history. *)
val pairs_judged_by
  :  history_pairs_at_setup:int
  -> Keeper_agent_result.tool_call_detail list
  -> int

(** [seed_beyond ~judged pairs] keeps the newest [length pairs - judged] of
    [pairs] (newest first): everything a previous yield has not judged.
    [judged] at or past the length keeps nothing. *)
val seed_beyond
  :  judged:int
  -> Keeper_agent_result.tool_call_detail list
  -> Keeper_agent_result.tool_call_detail list
