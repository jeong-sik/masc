(** Pre-dispatch validation stage extracted from
    [Keeper_unified_turn.run_keeper_cycle] per RFC-0136 PR-3.

    Owns the runtime-execution builder: runtime-name → keeper-meta
    projection, model-label resolution, API-key + local-discovery
    readiness checks, context budget resolution, and temperature/max-tokens
    inference. Returns a
    [Keeper_turn_runtime_budget.runtime_execution] record on success,
    or a typed [Agent_sdk.Error.sdk_error] on the first failed check.

    The unified-max-tokens fallback is internal to this module — its
    behavior depends only on [meta_name] + [profile_defaults], so the
    caller does not need to thread a callback through. *)

val build_runtime_execution
  :  meta:Keeper_meta_contract.keeper_meta
  -> profile_defaults:Keeper_types_profile.keeper_profile_defaults
  -> runtime_id:string
  -> ( Keeper_turn_runtime_budget.runtime_execution
     , Agent_sdk.Error.sdk_error )
     result
(** Build a [runtime_execution] for the given [runtime_id] under
    [meta]'s context.

    Failure modes (returned as [Error]):
    - [Keeper_types_support.ensure_api_keys_for_labels] missing required keys.
    - [ensure_local_discovery_ready] local-runtime discovery fail.

    The function is total over its three failure modes plus the [Ok]
    case; no exceptions cross the boundary. *)
