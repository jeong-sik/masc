(** Cascade_attempt_fsm — SDK error to FSM outcome, session/resumption analysis.

    Extracted from oas_worker_named.ml (God file decomposition).
    Converts OAS SDK errors into Cascade_fsm provider outcomes,
    classifies CLI-wrapped error patterns (hard quota, max turns,
    resumable sessions), and enriches errors with provider-specific hints.

    This module is [include]d by {!Oas_worker_named}; all bindings are
    re-exported by the facade.  @since God file decomposition *)

(** {1 Cascade outcome classification} *)

val sdk_error_to_cascade_outcome :
  Agent_sdk.Error.sdk_error -> Cascade_fsm.provider_outcome option
(** Convert an SDK error into a cascade FSM provider outcome.
    API-level errors and model-capability-dependent agent errors are
    cascadeable.  Structural agent errors (budget, idle, exit) are not. *)

(** {1 Error enrichment} *)

val enrich_sdk_error :
  cascade_name:Cascade_error_classify.cascade_name ->
  provider_cfg:Llm_provider.Provider_config.t ->
  Agent_sdk.Error.sdk_error -> Agent_sdk.Error.sdk_error
(** Enrich an SDK error with provider-specific diagnostic hints
    (e.g. Moonshot auth, OpenAI-compat 404). *)

(** {1 CLI-wrapped error pattern classification} *)

val message_looks_like_cli_wrapped_hard_quota : string -> bool
(** Detect hard-quota indicators in CLI-wrapped error messages. *)

val message_looks_like_cli_wrapped_max_turns : string -> bool
(** Detect max-turns indicators in CLI-wrapped error messages. *)

val message_looks_like_resumable_cli_session : string -> bool
(** Detect resumable-session indicators in CLI-wrapped error messages. *)

val cli_wrapped_hard_quota_indicators : string list
(** List of substring indicators for CLI-wrapped hard quota. *)

val cli_wrapped_max_turns_indicators : string list
(** List of substring indicators for CLI-wrapped max turns. *)

(** {1 Resumable CLI session helpers} *)

val resumable_cli_session_detail : string -> string

val resumable_cli_session_exit_code : string -> int option

val exit_code_of_message : string -> int option
(** Extract an exit code from a CLI error message string. *)

val retry_message_looks_like_not_found : string -> bool
(** Detect "not found" / 404 patterns in retry error messages. *)

(** {1 SDK error predicates} *)

val sdk_error_to_resumable_cli_session :
  cascade_name:Cascade_error_classify.cascade_name ->
  Agent_sdk.Error.sdk_error ->
  Agent_sdk.Error.sdk_error option
(** If the error looks like a resumable CLI session, convert it into the
    structured [Resumable_cli_session] form. *)

val sdk_error_is_resumable_cli_session : Agent_sdk.Error.sdk_error -> bool

val sdk_error_is_terminal_provider_runtime_failure :
  Agent_sdk.Error.sdk_error -> bool
(** [true] for deterministic provider/adapter crashes that should enter the
    immediate long cooldown lane instead of waiting for generic failure
    thresholding. *)

val sdk_error_is_model_access_denied : Agent_sdk.Error.sdk_error -> bool
(** [true] for deterministic model-access denials that should cool down the
    concrete provider/model pair without poisoning sibling models. *)

val sdk_error_is_hard_quota : Agent_sdk.Error.sdk_error -> bool
(** [true] when the error represents a hard usage quota that will not
    recover within the cascade turn budget. *)

val retry_api_error_to_provider_error :
  provider:string ->
  capacity_exhausted:bool ->
  Llm_provider.Retry.api_error ->
  Provider_error.t option
(** Convert an SDK retry error into the additive provider-error contract.
    [capacity_exhausted] is explicit so the production body classifier
    stays at this OAS boundary instead of moving into [Provider_error]. *)

val sdk_error_to_provider_error :
  provider:string -> Agent_sdk.Error.sdk_error -> Provider_error.t option
(** Convert API-level SDK errors into provider errors. Non-API structural
    errors return [None]. *)

val provider_error_total_metric : string
(** Prometheus counter for additive provider-error variant emission. *)

val emit_provider_error_metric :
  cascade_name:Cascade_error_classify.cascade_name ->
  provider:string ->
  Provider_error.t ->
  unit
(** Emit one provider-error variant event while preserving existing
    string-based health tracker labels. *)

val emit_sdk_provider_error_metric :
  cascade_name:Cascade_error_classify.cascade_name ->
  provider:string ->
  Agent_sdk.Error.sdk_error ->
  Provider_error.t option
(** Convert and emit an SDK provider error. Returns the converted variant
    so callers/tests can assert the same decision without reparsing metrics. *)

val sdk_error_soft_rate_limited :
  Agent_sdk.Error.sdk_error -> float option option
(** [Some (Some retry_after)] for non-quota 429 responses with a parsed
    [retry_after].  [Some None] when [retry_after] is absent.
    [None] for non-429 or hard-quota-429 errors. *)

val sdk_error_is_max_turns_exceeded : Agent_sdk.Error.sdk_error -> bool

val sdk_error_cascade_fallback_class :
  Agent_sdk.Error.sdk_error -> string option
(** Stable class label for cascade fallback logs/audit reasons.  This keeps
    operator-facing [top_level_reason] aggregation on typed causes instead of
    generic SDK/Internal wrapper strings. *)

(** {1 Moonshot / Kimi helpers} *)

val is_moonshot_provider : Llm_provider.Provider_config.t -> bool

val resolve_kimi_api_key_env_name :
  cascade_name:Cascade_error_classify.cascade_name -> string

val moonshot_auth_hint_marker : string
val openai_compat_not_found_hint_marker : string
