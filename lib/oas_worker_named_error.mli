(** Oas_worker_named_error — masc_internal_error type, error conversion, codex CLI preflight.

    Extracted from oas_worker_named.ml (God file decomposition).
    Defines the [masc_internal_error] variant type, JSON serialization,
    SDK error conversion, error classification, and codex CLI prompt
    preflight checks.

    This module is [include]d by {!Oas_worker_named}; all bindings are
    re-exported by the facade.  @since God file decomposition *)

(** {1 MASC internal error type} *)

type masc_internal_error =
  | Cascade_exhausted of {
      cascade_name : string;
      reason : Keeper_types.cascade_exhaustion_reason;
    }
  | Resumable_cli_session of {
      cascade_name : string;
      detail : string;
      exit_code : int option;
    }
  | No_tool_capable_provider of {
      cascade_name : string;
      configured_labels : string list;
    }
  | Accept_rejected of {
      scope : string;
      model : string option;
      reason : string;
    }
  | Admission_queue_timeout of {
      keeper_name : string;
      cascade_name : string;
      wait_sec : float;
    }
  | Admission_queue_rejected of {
      keeper_name : string;
      reason : string;
    }
  | Turn_timeout of {
      elapsed_sec : float;
    }
  | Oas_timeout_budget of {
      budget_sec : float;
      keeper_turn_timeout_sec : float;
      estimated_input_tokens : int;
      source : string;
    }
  | Ambiguous_post_commit of {
      is_timeout : bool;
      tools : string list;
      original_error : string;
    }

val masc_internal_error_to_json : masc_internal_error -> Yojson.Safe.t

val sdk_error_of_masc_internal_error : masc_internal_error -> Oas.Error.sdk_error
(** Convert a [masc_internal_error] to an SDK error, bumping the
    [masc_oas_error_total] Prometheus counter with [kind] and
    [cascade_name] labels. *)

val classify_masc_internal_error :
  Oas.Error.sdk_error -> masc_internal_error option
(** Parse an SDK error back into a [masc_internal_error] when it was
    originally produced by [sdk_error_of_masc_internal_error].  Returns
    [None] for errors that do not carry the [masc_oas_error] prefix. *)

val kind_of_masc_internal_error : masc_internal_error -> string
(** Short label for each variant, used as the [kind] Prometheus label. *)

val cascade_name_of_masc_internal_error : masc_internal_error -> string
(** Cascade name from the error payload, or ["unknown"] for variants that
    fire outside cascade context. *)

val admission_wait_timeout_error :
  keeper_name:string ->
  cascade_name:string ->
  priority:Llm_provider.Request_priority.t ->
  int ->
  (string, Oas.Error.sdk_error) result
(** Build an [Admission_queue_timeout] error from a wait duration in ms. *)

val cross_cascade_fallback_metric : string

(** {1 Config construction} *)

val config_for_label :
  name:string ->
  model_label:string ->
  system_prompt:string ->
  tools:Oas.Tool.t list ->
  max_turns:int ->
  max_tokens:int ->
  ?max_input_tokens:int ->
  ?max_cost_usd:float ->
  temperature:float ->
  ?max_idle_turns:int ->
  ?stream_idle_timeout_s:float ->
  ?guardrails:Oas.Guardrails.t ->
  ?hooks:Oas.Hooks.hooks ->
  ?context_reducer:Oas.Context_reducer.t ->
  ?memory:Oas.Memory.t ->
  ?tool_retry_policy:Oas.Tool_retry_policy.t ->
  ?enable_thinking:bool ->
  ?compact_ratio:float ->
  ?contract:Oas.Risk_contract.t ->
  ?approval:Oas.Hooks.approval_callback ->
  description:string option ->
  unit ->
  (Oas_worker_exec.config, Oas.Error.sdk_error) result
(** Build an [Oas_worker_exec.config] from a model label string.  Resolves
    the provider config and fills in defaults. *)

(** {1 Codex CLI preflight} *)

type codex_cli_prompt_preflight = {
  prompt_bytes : int;
  prompt_tokens : int;
  context_window_tokens : int;
  retry_limit_tokens : int;
  hits_argv_limit : bool;
  hits_context_window : bool;
}

val codex_cli_prompt_preflight :
  config:Oas_worker_exec.config -> goal:string -> codex_cli_prompt_preflight option
(** Check whether a codex_cli invocation would exceed the argv or context
    window limit.  Returns [Some] when limits are hit, [None] when safe
    (or when the provider is not codex_cli). *)

val with_codex_cli_preflight :
  scope:string ->
  config:Oas_worker_exec.config ->
  goal:string ->
  (unit -> ('a, Oas.Error.sdk_error) result) ->
  ('a, Oas.Error.sdk_error) result
(** Wrap an execution with a codex_cli preflight check.  If the prompt
    exceeds limits, returns [Error] immediately without calling [run].
    Otherwise delegates to [run]. *)
