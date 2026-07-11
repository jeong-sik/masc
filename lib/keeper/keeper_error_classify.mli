(** {1 Static ADT Classification}
    RFC-0314 / task-1854: Replace heuristic string-matching predicates with
    a static ADT that the compiler can exhaustively match. *)
type error_classification =
  | Transient_network
  | Transient_internal_runner
  | Transient_oas_timeout
  | Transient_rate_limit
  | Transient_capacity
  | Non_transient
  | Unclassified

val classify_error : Agent_sdk.Error.sdk_error -> error_classification

(** Keeper_error_classify — Error classification, side-effect safety,
    and retry constants for the unified keeper cycle.

    Extracted from keeper_unified_turn.ml.

    @since 0.122.0 *)

(** Detect transient network errors eligible for retry.
    Uses structured [Agent_sdk.Error.sdk_error] pattern matching. *)
val is_transient_network_error : Agent_sdk.Error.sdk_error -> bool

(** [true] when a typed internal runner exception preserves a transient
    transport failure raised inside {!Keeper_turn_driver.runtime_runner_execute_site}.
    Legacy internal exception envelopes without [transport_error_kind] are
    diagnostic-only and are not parsed heuristically. *)
val is_transient_internal_runner_error : Agent_sdk.Error.sdk_error -> bool

(** [true] when an OAS timeout message describes an execution budget expiry,
    not a transport-level timeout. *)
val is_structural_oas_timeout_message : string -> bool

(** Detect request body parse errors from either the provider or the API
    (e.g. Ollama yyjson rejecting a malformed request body or the API
    rejecting invalid JSON).  The LLM never processed the request, so
    committed tool results are not at risk of duplication.  Used to
    auto-recover reconcile-safe tools instead of requiring manual reconcile. *)
val is_server_rejected_parse_error : Agent_sdk.Error.sdk_error -> bool

(** [true] for provider-side request-body parse rejections. *)
val is_provider_rejected_parse_error : Agent_sdk.Error.sdk_error -> bool

(** [true] for model/API-side request-body parse rejections reported as
    [InvalidRequest]. *)
val is_model_rejected_parse_error : Agent_sdk.Error.sdk_error -> bool

(** [true] when the keeper should preserve liveness and skip consecutive
    failure counting, even if same-turn retry is still disabled. *)
val is_auto_recoverable_turn_error : Agent_sdk.Error.sdk_error -> bool

(** [true] for accept-rejected responses tagged by the built-in keeper
    progress contract as no usable text/tool/non-terminal progress. *)
val is_accept_no_usable_progress_error : Agent_sdk.Error.sdk_error -> bool

(** [true] when the turn runner should record the immediate
    ["keeper cycle FAILED"] line as WARN instead of ERROR because the
    heartbeat policy layer will handle the failure as a provider/OAS budget
    strike with cooldown or work-level pause. *)
val should_warn_keeper_cycle_failed : Agent_sdk.Error.sdk_error -> bool

(** Reclassify any post-commit turn error as a persistent integrity error when
    mutating tool calls already committed in the same turn. *)
val reclassify_error_after_side_effect :
  tool_names:string list ->
  Agent_sdk.Error.sdk_error ->
  Agent_sdk.Error.sdk_error

val post_commit_failure_kind_of_error :
  Agent_sdk.Error.sdk_error -> Keeper_registry.ambiguous_partial_commit_kind

(** [true] when an error represents an ambiguous partial commit after a
    mutating tool call succeeded but the turn failed before a clean result. *)
val is_ambiguous_side_effect_error : Agent_sdk.Error.sdk_error -> bool

val ambiguous_side_effect_commit_tools :
  tool_names:string list ->
  Agent_sdk.Error.sdk_error -> string list

val has_ambiguous_side_effect_commit :
  tool_names:string list ->
  Agent_sdk.Error.sdk_error -> bool

(** [true] when a structured error indicates context overflow. *)
val is_context_overflow : Agent_sdk.Error.sdk_error -> bool

(** [true] when the error is a completion contract violation.
    Contract violations should cap rotation because retrying the same
    or different runtime will not satisfy the contract. Narrow no-progress
    accept rejections that carry an explicit empty/read-only recovery hint are
    handled by the degraded retry path instead. *)
val is_completion_contract_violation : Agent_sdk.Error.sdk_error -> bool

(** [true] when the error is an OAS [InputRequired] — the agent paused
    to request human input.  Not a failure; a special stop condition. *)
val is_input_required_error : Agent_sdk.Error.sdk_error -> bool

(** Extract the [InputRequired] payload from an [sdk_error], if any.
    Typed companion to {!is_input_required_error} — callers that need
    the [input_required] record (request_id, question, …) avoid a
    separate pattern match plus [assert false] when the predicate
    has already filtered for the constructor. *)
val extract_input_required
  :  Agent_sdk.Error.sdk_error
  -> Agent_sdk.Error.input_required option

(** [true] when an error represents terminal runtime exhaustion. *)
val is_runtime_exhausted_error : Agent_sdk.Error.sdk_error -> bool

(** Classification of why a degraded retry is being attempted. Closed
    set; producer-side is [keeper_error_classify]. Wire form is the
    lowercase string via [degraded_retry_reason_to_string]. *)
type degraded_retry_reason =
  | Hard_quota
  | Resumable_cli_session
  | Admission_queue_timeout
  | Provider_timeout
  | Turn_timeout
  | Runtime_candidates_filtered
  | Runtime_exhausted
  | Capacity_backpressure
  | Model_unavailable
  | Rate_limit
  | Server_error
  | Auth_error
  | Read_only_no_progress
  | Empty_no_progress
  | Thinking_only_no_progress

val degraded_retry_reason_to_string : degraded_retry_reason -> string

val is_read_only_no_progress_accept_rejection : Agent_sdk.Error.sdk_error -> bool
(** [true] for typed accept rejections whose only progress was read-only tool
    observation. These can remain terminal for direct retry while still using a
    bounded auto-resume pause policy after repeated failures. *)

val normalized_runtime_id : catalog_names:string list -> string -> string
(** Normalize a runtime name for rotation matching.
    All runtime names are plain provider:model strings. *)

type degraded_retry =
  { next_runtime : string
  ; fallback_reason : degraded_retry_reason
  }

(** Opportunistically fail open to a broader runtime when the current
    effective runtime is temporarily unavailable (for example cooldown /
    phase-buffer bootstrap fallback). *)
val fallback_runtime_for_unavailable_profile :
  base_runtime:string ->
  effective_runtime:string ->
  string option

(** Classifies an SDK error into a fallback reason label when the runtime
    failure is recoverable via [fallback_runtime] or [degraded_rotation].
    Returns [None] for terminal errors (e.g. generic accept-rejected,
    ambiguous post-commit) that should not trigger same-turn escalation. A
    narrow built-in progress-contract rejection is recoverable only when the
    response was thinking-only after a read-only tool.

    Status-code-aware rotation: raw API errors that are not wrapped in a MASC
    internal error are also classified when a different runtime may succeed:
    - [RateLimited] hard-quota messages → ["hard_quota"]
    - [RateLimited] soft provider throttles → ["rate_limit"] (rotation filters
      candidates sharing the same credential pool)
    - [Overloaded] and Cloudflare 524 → ["capacity_backpressure"]
    - [NotFound] → ["model_unavailable"]
    - [ServerError] with status >= 500 → ["server_error"]
    - [AuthError] → ["auth_error"]

    Exposed for unit tests; production callers go through
    [degraded_retry_after_recoverable_error] or
    [degraded_rotation_after_recoverable_error]. *)
val recoverable_runtime_failure_reason :
  Agent_sdk.Error.sdk_error -> degraded_retry_reason option

(** Returns the one-shot degraded retry lane for recoverable whole-runtime
    failures. Already-degraded lanes do not broaden further. *)
val degraded_retry_after_recoverable_error :
  effective_runtime:string ->
  Agent_sdk.Error.sdk_error ->
  degraded_retry option

(** Returns the next untried runtime in the same-turn recovery group for a
    whole-runtime failure. Uses the default degraded rotation candidate set
    (base/default/phase-recovery). Read-only no-progress accept rejections also
    append configured tool-capable runtimes so a default-runtime
    thinking-only response can still rotate to another safe tool-capable model.

    [fallback_hint], when provided, is prepended to the candidate list so
    that single-provider profiles can declare an immediate escalation
    target via [runtime.toml]. The hint is normalized and deduplicated like
    any other candidate; if it duplicates the effective runtime or has
    already been attempted, the next legal candidate is returned.

    For ["hard_quota"] and ["rate_limit"], candidates sharing the effective
    runtime's credential pool, as reported by [credential_pool_of_runtime_id],
    are excluded before attempt filtering, preserving independent-provider
    failover while avoiding same-account fan-out. If no pool function is
    supplied, no credential-pool filtering is applied. Non-contract transient
    infrastructure errors (provider timeout, server error) allow cycling
    through candidates again when all are exhausted, because the same runtime
    may succeed on a subsequent attempt. [Capacity_backpressure] caps rotation:
    its provider retry_after is minutes-long, so cycling the same pool is
    futile and previously looped forever (2026-05-21, 2026-07-06, #23373).
    Contract violations, read-only no-progress accept rejections, and
    quota/rate-limit classes cap rotation after the candidate set is exhausted.

    RFC-0313 W3: with [pacing_enforced:true] the class-based cycle cap is
    bypassed — every recoverable class may re-cycle the (pool-filtered)
    candidate set within the turn's cycle budget, because revisit pacing now
    spaces the retries the cap used to suppress. [pacing_enforced:false]
    keeps the legacy cap (kill-switch; the cap and this parameter go away in
    W4). Contract violations never cycle in either mode.
    @since 0.174.0 *)
val degraded_rotation_after_recoverable_error :
  ?credential_pool_of_runtime_id:(string -> string option) ->
  ?fallback_hint:string ->
  pacing_enforced:bool ->
  base_runtime:string ->
  effective_runtime:string ->
  attempted_runtimes:string list ->
  Agent_sdk.Error.sdk_error ->
  degraded_retry option

(** [true] when [reason] permits re-cycling the candidate pool after every
    candidate has been attempted. [Capacity_backpressure] and
    [Model_unavailable] return [false] in shadow mode (see
    {!degraded_rotation_after_recoverable_error}). *)
val degraded_reason_allows_candidate_cycle :
  degraded_retry_reason -> bool

val max_transient_retries : unit -> int

val transient_backoff_sec : int -> float

(** Filter and deduplicate tool names to those with mutating side effects. *)
val committed_mutating_tools : string list -> string list

val classify_post_commit_failure :
  tool_names:string list ->
  ?kind:Keeper_registry.ambiguous_partial_commit_kind ->
  Agent_sdk.Error.sdk_error ->
  (Agent_sdk.Error.sdk_error * Keeper_registry.failure_reason) option

val summarize_post_commit_failure :
  tool_names:string list ->
  kind:Keeper_registry.ambiguous_partial_commit_kind ->
  Agent_sdk.Error.sdk_error ->
  string

val is_provider_timeout_error : Agent_sdk.Error.sdk_error -> bool
(** True when [err] is a provider-timeout class failure (deadline,
    runtime timeout, budget retry). Live caller:
    [keeper_unified_turn.ml] degraded-retry classification. *)

val is_receipt_lost_error : Agent_sdk.Error.sdk_error -> bool
(** True when [err] indicates a receipt-lost failure (the provider
    confirmed completion but the response payload was lost in transit).
    Live caller: [keeper_unified_turn.ml] failure-reason classification
    via the [EC] alias. *)
