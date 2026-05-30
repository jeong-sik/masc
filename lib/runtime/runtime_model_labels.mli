(** Runtime_model_labels — execution model-label resolution for the default Runtime.

    RFC-0206 cascade->Runtime replacement for the deleted [Cascade_runtime].
    All resolution is default-always (no cascade_name selection): the configured
    execution labels and the single default Runtime are the only sources. No
    discovered-context override, no multi-candidate catalog, no telemetry. *)

val provider_name_of_label : string -> string option
(** Provider scheme of a ["provider:model"] label, lowercased. [None] when the
    label has no scheme prefix. *)

val local_model_label : string -> string
(** ["<local-runtime-provider>:<model_id>"], or ["auto"] when no loopback
    no-auth runtime is registered. *)

val default_local_model_label_and_id : unit -> string * string
(** (label, model_id) for the first available configured/preferred label;
    [("auto", "auto")] fallback. *)

val has_execution_model_config : unit -> bool

val default_model_strings : unit -> string list
(** Configured execution labels; falls back to the local fallback label when
    none are configured. *)

val models : unit -> string list
(** Alias of {!default_model_strings} (collapse of the deleted
    [models_of_cascade_name] — no per-name catalog). *)

val models_result : unit -> (string list, string) result
(** [Ok] of {!models} (collapse of the deleted [models_of_cascade_name_result];
    the catalog resolution that could fail is annihilated). *)

val max_output_tokens_ceiling : unit -> int option
(** Max output-token ceiling from the default Runtime's model spec, or [None].
    Collapse of the deleted [max_output_tokens_ceiling_of_cascade_name]. *)

val max_context_of_label : string -> int
val resolve_primary_max_context : string list -> int
val resolve_max_context : string list -> int
val resolve_primary_model_id : string list -> string

val ensure_api_keys_for_labels : string list -> (unit, string) result
(** [Ok ()] when at least one label resolves to an available provider (or a
    typed declarative provider). [Error] lists the missing api-key env vars. *)

val resolve_execution_providers_strict :
  ?provider_filter:string list ->
  ?require_tool_choice_support:bool ->
  ?require_tool_support:bool ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  unit ->
  (Llm_provider.Provider_config.t list, string) result
(** The default Runtime's provider config as a singleton list, after the
    tool-use gate. [Error] when no default Runtime is configured. The
    [provider_filter] argument is accepted for call-site compatibility but
    ignored — a single Runtime has nothing to filter. *)
