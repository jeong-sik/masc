(** Materialized runtime values and their dispatch-local properties. *)

open Runtime_schema
open Runtime_config_error

type t =
  { id : string
  ; provider : provider
  ; model : model_spec
  ; binding : binding
  ; execution : Runtime_execution.t
  ; candidate_backpressure : Runtime_candidate_backpressure.candidate
    (** Candidate-only backpressure tied to the frozen dispatch binding. *)
  ; quota_scope : Runtime_quota_window.scope
    (** Quota ownership key frozen at materialization, from the same
        credential-alias selection that resolved the dispatched API key. A
        later environment change must not re-select the alias at
        window-recording time, or the window is charged to an account the
        dispatch never used (PR #28219 review). *)
  }

type dispatch_credential_error =
  | Required_env_credential_missing of
      { provider_id : string
      ; env_key : string
      }
  | Declared_credential_unavailable of
      { provider_id : string
      ; carrier : Agent_core.Error.credential_carrier
      }

val dispatch_credential_error_to_string : dispatch_credential_error -> string

val dispatch_credential_error_to_core_error :
  dispatch_credential_error -> Agent_core.Error.t
(** Preserve a missing environment credential as the existing typed
    [MissingEnvVar] configuration error. Other unavailable credential carriers
    use the closed [CredentialUnavailable] variant, so consumers never infer
    terminal configuration state from broad [InvalidConfig] text. *)

val validate_dispatch_credential :
  provider_config:Llm_provider.Provider_config.t ->
  t ->
  (unit, dispatch_credential_error) result
(** Fail closed immediately before an Agent Core dispatch when the runtime
    declares a credential but the final provider config has no secret. A
    credential-free provider remains valid. This check intentionally happens
    after materialization so dashboard missing-auth projection stays intact. *)

type max_context_source =
  | Override (** runtime.toml [model.max-context] override applies as-is. *)
  | Capability (** no override configured; the AGENT_CORE capability catalog cap applies. *)
  | Override_clamped_by_capability
      (** an override is configured but exceeds the AGENT_CORE capability catalog
          cap, so the cap wins. *)
  | Provider_override
  | Binding_override
  | Provider_override_clamped_by_capability
  | Binding_override_clamped_by_capability

val max_context_of_runtime : t -> int
(** Effective input context window for a materialized runtime.  This applies the
    same provider-cap clamp as {!Runtime.max_context_of_runtime_id} without re-resolving
    the runtime id. Derived from {!resolve_max_context_of_runtime}.
    @raise Failure if that resolves to [None] — unreachable for any [t]
    loaded by {!Runtime.load_list}, which rejects a runtime whose max
    context cannot be resolved at load time (no silent default —
    RFC-0206 §2.1). *)

val id_of_binding : binding -> string

val of_binding : config -> binding -> (t, drop_reason) result
(** Materialize one binding while preserving failure information. [Error reason]
    when the binding is disabled, its provider/model id is unresolved, or the
    provider transport/protocol cannot be materialized into a
    {!Llm_provider.Provider_config.t} (e.g. a [messages-http]
    provider the runtime adapter has no provider_config path for). The binding is
    still excluded from the runtime list (fail-closed, RFC-0206 §2.1); this
    surfaces *why*, so [\[runtime\].default] / [\[runtime.assignments\]] / lane
    validation can report a dropped target's materialize failure instead of a
    bare "not found among N runtimes" that points at a non-existent typo. *)


val is_local_runtime : t -> bool
(** [is_local_runtime rt] classifies runtime locality from the materialized
    provider schema: CLI transports are local; HTTP transports are local only
    when their endpoint is loopback and the provider declares no credential. *)

val max_context_source_to_string : max_context_source -> string
(** Wire label for the [/api/v1/runtime/resolved] document, preserving the
    declaration scope and any genuine capability clamping. *)

val resolve_max_context_of_runtime : t -> (int * max_context_source) option
(** Effective input context window and the source that produced it. [None]
    when no binding, provider or model declaration and no AGENT_CORE capability
    catalog declares a positive context window for this binding;
    {!Runtime.load_list} rejects such a runtime at load (fail-closed), so a
    materialized [t] obtained from {!Runtime.get_runtimes}/{!Runtime.get_runtime_by_id} never
    observes [None] here in practice. *)

val muse_prompt_capacity : t -> (int, Runtime_muse_prompt_capacity.error) result
(** The start-prompt ceiling of a Muse runtime: derived from its resolved
    window ({!resolve_max_context_of_runtime})
    ({!Runtime_muse_prompt_capacity.start_prompt_bytes}).
    A Muse turn applies this and refuses with the error's cause. *)

val prompt_capacity_bytes : t -> int option
(** The start-prompt ceiling a turn on this runtime applies, from
    {!Runtime_client_prompt_ceiling}: the window-derived ceiling for
    Antigravity and {!muse_prompt_capacity} for Muse, the two hosts that cut
    an oversized input without saying so. [None] when no ceiling applies:
    Claude Code, Codex and every HTTP format send the whole range and rely on
    the provider's typed overflow, and for Muse or Antigravity it means the window cannot be resolved, so the
    turn itself refuses. *)

val capabilities_for_runtime : t -> Llm_provider.Capabilities.capabilities option
val is_local_provider : provider -> bool
val partition_bindings : config -> binding list -> t list * (string * drop_reason) list

val quota_scope_of_runtime : t -> Runtime_quota_window.scope
(** Non-secret quota-scope identity derived from this resolved runtime
    snapshot.  Use this form across a provider call so a concurrent catalog
    reload cannot rebind the response to a different credential account. *)

val max_output_tokens_of_runtime : t -> int option
(** Declared max output tokens (AGENT_CORE capability catalog) for the model bound to
    [rt]. [None] for an official-client runtime (Codex app-server, Claude Code,
    Antigravity CLI, Muse serve), which the catalog does not describe, for a
    model with no catalog row, and for a row that leaves it unset. This is an
    observable capability ceiling only; AGENT_CORE owns request validation and
    clamp policy, and MASC never turns it into a request default. *)
