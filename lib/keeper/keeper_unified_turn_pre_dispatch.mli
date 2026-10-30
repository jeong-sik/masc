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
(** Load one immutable profile snapshot at the pre-dispatch boundary. Every
    load error returns [Config InvalidConfig] on field [keeper.profile]: a
    keeper with no declaration, invalid child or inherited base TOML, and a
    [tools.deny] entry that names no model-visible tool. *)

val turn_profile_and_meta :
     base_path:string
  -> entry_meta:Keeper_meta_contract.keeper_meta
  -> ( Keeper_types_profile.keeper_profile_defaults
       * Keeper_meta_contract.keeper_meta
     , Agent_core.Error.t )
     result
(** The profile snapshot plus the meta a turn runs with: the registry entry's
    meta with that snapshot overlaid.

    Durable keeper JSON carries no config fields, so [entry_meta] always holds
    the decoder's placeholder [sandbox_profile] and the keeper TOML is the only
    source that states one. Loading the defaults without applying them ran
    every heartbeat turn's [Execute] against the placeholder rather than the
    declaration (#30982) -- on the host, back when a host arm existed
    (#32078). Returning the pair keeps the two halves from drifting apart
    again. *)

val build_runtime_execution
  :  meta:Keeper_meta_contract.keeper_meta
  -> runtime_id:string
  -> deferred_runtime_lane:Keeper_turn_driver.deferred_runtime_lane option
  -> ( Keeper_turn_runtime_budget.runtime_execution
     , Agent_core.Error.t )
     result
(** Build a [runtime_execution] for the given [runtime_id] under
    [meta]'s context.

    The context window is the smallest window among every candidate that can
    serve the turn's prompt. For a lane that is the lane's candidates. When
    [deferred_runtime_lane] is the hint the turn resumes from (its
    [next_runtime_id] is [runtime_id]), it is [Keeper_turn_driver.deferred_runtime_ids]
    of that hint, the candidates the walk still rotates through.

    Failure modes (returned as [Error]):
    - [deferred_runtime_lane] resumes at a runtime other than [runtime_id].
    - The exact [runtime_id] has no configured context window.
    - [meta.max_context_override] is not positive.

    AGENT_CORE alone owns provider/model ceiling validation and envelope-specific
    clamping. No context-window default or ordered-label fallback is applied at
    this turn-admission boundary. *)
