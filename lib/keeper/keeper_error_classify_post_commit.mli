val ambiguous_side_effect_error_prefix : string

val committed_mutating_tools : string list -> string list

val is_ambiguous_side_effect_error : Agent_sdk.Error.sdk_error -> bool

val ambiguous_side_effect_commit_tools :
  tool_names:string list ->
  Agent_sdk.Error.sdk_error -> string list

val has_ambiguous_side_effect_commit :
  tool_names:string list ->
  Agent_sdk.Error.sdk_error -> bool

val reclassify_error_after_side_effect :
  tool_names:string list ->
  Agent_sdk.Error.sdk_error -> Agent_sdk.Error.sdk_error

val post_commit_failure_kind_of_error :
  Agent_sdk.Error.sdk_error -> Keeper_registry.ambiguous_partial_commit_kind

val summarize_post_commit_failure :
  tool_names:string list ->
  kind:Keeper_registry.ambiguous_partial_commit_kind ->
  Agent_sdk.Error.sdk_error -> string

val classify_post_commit_failure :
  tool_names:string list ->
  ?kind:Keeper_registry.ambiguous_partial_commit_kind ->
  Agent_sdk.Error.sdk_error ->
  (Agent_sdk.Error.sdk_error * Keeper_registry.failure_reason) option
