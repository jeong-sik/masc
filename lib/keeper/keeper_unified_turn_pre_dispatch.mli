(** Pre-dispatch validation stage extracted from
    [Keeper_unified_turn.run_keeper_cycle] per RFC-0136 PR-3.

    Owns the runtime-execution builder: runtime-id validation,
    context-window resolution, and temperature inference. Returns a
    [Keeper_turn_runtime_budget.runtime_execution] record on success,
    or a typed [Agent_core.Error.t] on the first failed check.

    Keeper output is not bounded by a MASC request-token budget. *)

val load_profile_defaults :
     base_path:string
  -> keeper_name:string
  -> ( Keeper_types_profile.keeper_profile_defaults
     , Agent_core.Error.t )
     result
(** Load one immutable profile snapshot at the pre-dispatch boundary. Invalid
    child or inherited base TOML returns [Config InvalidConfig]; prompt-only
    and genuinely absent profiles remain valid empty/default snapshots. *)

val build_runtime_execution
  :  meta:Keeper_meta_contract.keeper_meta
  -> runtime_id:string
  -> ( Keeper_turn_runtime_budget.runtime_execution
     , Agent_core.Error.t )
     result
(** Build a [runtime_execution] for the given [runtime_id] under
    [meta]'s context.

    Failure modes (returned as [Error]):
    - The exact [runtime_id] has no configured context window.
    - [meta.max_context_override] is not positive.

    AGENT_CORE alone owns provider/model ceiling validation and envelope-specific
    clamping. No context-window default or ordered-label fallback is applied at
    this turn-admission boundary. *)
