(** Keeper_error_classify — Error classification, side-effect safety,
    and retry constants for the unified keeper cycle.

    Extracted from keeper_unified_turn.ml.

    @since 0.122.0 *)

(** Detect transient network errors eligible for retry.
    Uses structured [Oas.Error.sdk_error] pattern matching. *)
val is_transient_network_error : Oas.Error.sdk_error -> bool

(** [true] when an OAS timeout message describes an execution budget expiry,
    not a transport-level timeout. *)
val is_structural_oas_timeout_message : string -> bool

type timeout_failure_class =
  | Provider_timeout
  | Oas_timeout_budget
  | Turn_wall_clock_timeout

(** Classify timeout-like SDK errors.
    Structured MASC internal errors take precedence.  Legacy
    [Api (Timeout { message })] payloads are inspected only via their
    timeout message field; the classifier does not stringify whole SDK
    errors.  Provider timeouts stay distinct from structural OAS/keeper
    budget expiry so heartbeat strike logic only counts the latter. *)
val timeout_failure_class_of_error :
  Oas.Error.sdk_error -> timeout_failure_class option

(** Detect server-side request body parse errors (e.g. Ollama yyjson
    rejecting a malformed request body).  The LLM never
    processed the request, so committed tool results are not at risk
    of duplication.  Used to auto-recover reconcile-safe tools instead
    of requiring manual reconcile. *)
val is_server_rejected_parse_error : Oas.Error.sdk_error -> bool

(** [true] when the provider/tooling violated a required tool-use contract
    by returning text/no-op where a ToolUse block was required. *)
val is_required_tool_contract_violation : Oas.Error.sdk_error -> bool

(** [true] when the keeper should preserve liveness and skip consecutive
    failure counting, even if same-turn retry is still disabled. *)
val is_auto_recoverable_turn_error : Oas.Error.sdk_error -> bool

(** Reclassify any post-commit turn error as a persistent integrity error when
    mutating tool calls already committed in the same turn. *)
val reclassify_error_after_side_effect :
  tool_names:string list ->
  Oas.Error.sdk_error ->
  Oas.Error.sdk_error

val post_commit_failure_kind_of_error :
  Oas.Error.sdk_error -> Keeper_registry.ambiguous_partial_commit_kind

(** [true] when an error represents an ambiguous partial commit after a
    mutating tool call succeeded but the turn failed before a clean result. *)
val is_ambiguous_side_effect_error : Oas.Error.sdk_error -> bool

(** [true] when a structured error indicates context overflow. *)
val is_context_overflow : Oas.Error.sdk_error -> bool

(** [true] when an error represents terminal cascade exhaustion or a
    final accept-rejected result from the MASC OAS boundary. *)
val is_cascade_exhausted_error : Oas.Error.sdk_error -> bool

type degraded_retry =
  { next_cascade : string
  ; fallback_reason : string
  }

(** Opportunistically fail open to a broader cascade when the current
    effective cascade is temporarily unavailable (for example cooldown /
    local-only bootstrap fallback). *)
val fallback_cascade_for_unavailable_profile :
  base_cascade:string ->
  effective_cascade:string ->
  string option

(** Classifies an SDK error into a fallback reason label when the cascade
    failure is recoverable via [fallback_cascade] or [degraded_rotation].
    Returns [None] for terminal errors (e.g. accept-rejected, ambiguous
    post-commit) that should not trigger same-turn escalation.
    Exposed for unit tests; production callers go through
    [degraded_retry_after_recoverable_error] or
    [degraded_rotation_after_recoverable_error]. *)
val recoverable_cascade_failure_reason :
  Oas.Error.sdk_error -> string option

(** Returns the one-shot degraded retry lane for recoverable whole-cascade
    failures. Required-tool turns stay terminal, and already-degraded lanes
    do not broaden further. *)
val degraded_retry_after_recoverable_error :
  effective_cascade:string ->
  tool_requirement:string ->
  Oas.Error.sdk_error ->
  degraded_retry option

(** Returns the next untried cascade in the same-turn recovery group for a
    whole-cascade failure. [rotation_cascades], when provided, is the
    runtime/catalog-owned candidate order and is used as-is; otherwise the
    legacy base/default/local_recovery group is used. Required-tool turns keep
    the tool requirement and leave concrete provider filtering to the cascade
    resolver.

    [fallback_hint], when provided, is prepended to the candidate list so
    that single-provider profiles can declare an immediate escalation
    target via [cascade.toml]. The hint is normalized and deduplicated like
    any other candidate; if it duplicates the effective cascade or has
    already been attempted, the next legal candidate is returned.
    @since 0.174.0 *)
val degraded_rotation_after_recoverable_error :
  ?rotation_cascades:string list ->
  ?fallback_hint:string ->
  base_cascade:string ->
  effective_cascade:string ->
  tool_requirement:string ->
  attempted_cascades:string list ->
  Oas.Error.sdk_error ->
  degraded_retry option

val max_transient_retries : unit -> int

val transient_backoff_sec : int -> float

(** Filter and deduplicate tool names to those with mutating side effects. *)
val committed_mutating_tools : string list -> string list

val classify_post_commit_failure :
  tool_names:string list ->
  ?kind:Keeper_registry.ambiguous_partial_commit_kind ->
  Oas.Error.sdk_error ->
  (Oas.Error.sdk_error * Keeper_registry.failure_reason) option

val summarize_post_commit_failure :
  tool_names:string list ->
  kind:Keeper_registry.ambiguous_partial_commit_kind ->
  Oas.Error.sdk_error ->
  string
