(** Pre-dispatch validation stage extracted from
    [Keeper_unified_turn.run_keeper_cycle] per RFC-0136 PR-3.

    Owns the cascade-execution builder: cascade-name → keeper-meta
    projection, model-label resolution, API-key + local-discovery
    readiness checks, context budget resolution, temperature/max-tokens
    inference, and ceiling validation. Returns a
    [Keeper_turn_cascade_budget.cascade_execution] record on success,
    or a typed [Agent_sdk.Error.sdk_error] on the first failed check.

    The unified-max-tokens fallback is internal to this module — its
    behavior depends only on [meta_name] + [profile_defaults], so the
    caller does not need to thread a callback through. *)

val build_cascade_execution
  :  meta:Keeper_types.keeper_meta
  -> profile_defaults:Keeper_types_profile.keeper_profile_defaults
  -> cascade_name:Keeper_cascade_profile.runtime_name
  -> ( Keeper_turn_cascade_budget.cascade_execution
     , Agent_sdk.Error.sdk_error )
     result
(** Build a [cascade_execution] for the given cascade name under
    [meta]'s context.

    Failure modes (returned as [Error]):
    - [ensure_api_keys_for_labels] missing required keys.
    - [ensure_local_discovery_ready] local-runtime discovery fail.
    - [validate_max_tokens_within_ceiling] raw_max_tokens exceeds the
      provider's [Cascade_runtime.max_output_tokens_ceiling].

    The function is total over its three failure modes plus the [Ok]
    case; no exceptions cross the boundary. *)
