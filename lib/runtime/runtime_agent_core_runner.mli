(** Runtime_agent_core_runner — Eio context, runtime resolution, runtime MCP policy.

    Resolves MASC runtime intent into an Agent Core runtime.
    Provides runtime profile defaults, Eio context validation,
    provider resolution, and tool-support filtering.

    This module is [include]d by {!Keeper_turn_driver}; all bindings are
    re-exported by the facade.  @since God file decomposition *)

(** {1 Runtime profile defaults} *)

(** {1 Eio context validation} *)

val require_eio :
  ?sw:Eio.Switch.t -> ?net:Eio_context.eio_net -> unit ->
  (Eio.Switch.t * Eio_context.eio_net, string) result
(** Validate that an Eio switch and network are available in the current
    context.  Returns [Ok (sw, net)] when both are present, or [Error msg]
    when running outside a server context. *)

val eio_context_error_to_core_error : string -> Agent_core.Error.t
(** Lift a context-missing diagnostic string into an [Agent_core.Error.Config]
    error with field ["eio_context"]. *)

val is_eio_context_error : Agent_core.Error.t -> bool
(** [true] iff the error is the "Eio context unavailable" config error
    produced by {!eio_context_error_to_core_error} (running outside a server
    context).  Classifies on the typed [Config (InvalidConfig { field })] tag
    rather than on the rendered message, so an Eio wording change cannot
    silently break the heartbeat loop's fatal-environment promotion. *)

val runtime_catalog_error_to_core_error : string -> Agent_core.Error.t
(** Lift a runtime-catalog diagnostic into an [Agent_core.Error.Config]
    error with field ["runtime_id"]. *)

(** {1 Provider resolution} *)

val resolve_runtime_providers :
  runtime_id:string -> unit ->
  (Llm_provider.Provider_config.t list, string) result
(** Resolve the requested runtime's provider config via the RFC-0207 runtime
    catalog. An empty [runtime_id] resolves the default runtime; a non-empty
    id that is not a configured runtime returns [Error] — never the default
    runtime (no Unknown→Permissive substitution, RFC-0206 §2.1; audit F8).

    This is the provider {i binding} only. A turn additionally carries the
    runtime's inference seed — use {!resolve_runtime_providers_for_turn} when
    the caller is about to dispatch. *)

val apply_inference_seed
  :  seed:Runtime_inference.seed
  -> Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** Overlay a runtime's thinking seed onto a resolved provider config. Declared
    seed values win; absent ones leave the binding untouched. *)

val resolve_runtime_providers_for_turn :
  runtime_id:string -> unit ->
  (Llm_provider.Provider_config.t list, string) result
(** {!resolve_runtime_providers} with the runtime's inference seed applied, i.e.
    the config a keeper turn would dispatch with.

    Resolving without the seed is not merely a lost hint. An absent
    [enable_thinking] makes {!Llm_provider.Backend_ollama} omit the wire [think]
    field entirely, handing the decision to the model's chat template — whose
    default is thinking-on for reasoning models. [ollama.agentworld-35b-a3b]
    declares [thinking-support = false]; probed without the seed it spent ~900
    output tokens reasoning and emitted its tool call as bare JSON, which Ollama
    could not parse into [tool_calls], so it scored 0/12 as though it could not
    call tools at all. It called them every time (masc#28473). *)
