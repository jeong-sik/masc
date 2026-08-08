(** Shared turn logic for sync and streaming paths.

    Contains helper functions shared by the sync and streaming Agent drivers.

    These functions take explicit parameters (not [Agent.t]) to avoid
    circular module dependency: [Agent -> Agent_turn] is fine,
    [Agent_turn -> Agent] is not.

    @stability Internal
    @since 0.93.1 *)

(** {1 Turn preparation} *)

(** Pre-processed inputs for an LLM turn. *)
type turn_preparation =
  { tools_json : Yojson.Safe.t list option
  ; effective_messages : Types.message list
  ; visible_tool_names : string list
    (** Names of the caller-supplied tools. This is exactly the list the LLM
        sees this turn. Useful for [Event_bus.TurnReady] subscribers and
        deterministic substrate observability. Empty list when no
        tools are presented to the LLM.

        Order matches [tools_json] and [Tool_set.to_list].

        @since 0.162.0 *)
  }

(** Serialize every caller-supplied tool with its complete input schema. *)
val prepare_tools : tools:Tool_set.t -> unit -> Yojson.Safe.t list option * string list
(** Returns [(tools_json, visible_tool_names)].
    [visible_tool_names] mirrors the order of [tools_json] and is empty
    when no tools were supplied.

    @since 0.162.0 third tuple element added (visible_tool_names) *)

(** Preserve the complete transcript and inject optional turn context. *)

val prepare_messages
  :  messages:Types.message list
  -> turn_params:Hooks.turn_params
  -> unit
  -> Types.message list

(** Full turn preparation: exact caller-supplied tools plus messages. A failed
    caller projection is returned before provider measurement or dispatch.

    @since 0.185.0 added optional [config] parameter for provider-facing
      thinking preservation. *)
val prepare_turn
  :  tools:Tool_set.t
  -> messages:Types.message list
  -> turn_params:Hooks.turn_params
  -> ?model_input_projection:Agent_types.model_input_projection
  -> unit
  -> (turn_preparation, string) result

(** Project caller-owned turn controls onto the exact provider carrier.
    Provider identity and transport fields remain unchanged; model-specific
    capability overrides are retained only when the selected model is
    unchanged. *)
val provider_config_with_agent_config
  :  config:Types.agent_config
  -> Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t

(** {1 Usage accumulation} *)

(** Accumulate response usage into running totals, including observational cost
    estimation. The exact non-empty [response_model] takes precedence over the
    configured request model. Missing or incomplete pricing records a gap and
    never blocks the turn. *)
val accumulate_usage
  :  current_usage:Types.usage_stats
  -> provider_config:Llm_provider.Provider_config.t option
  -> response_model:string option
  -> response_usage:Types.api_usage option
  -> Types.usage_stats

(** {1 Turn params resolution} *)

type turn_params_resolution_error =
  | Illegal_decision of Hooks.hook_decision
  | Hook_failed of
      { stage : Hooks.hook_stage
      ; detail : string
      }

(** Extract the most recent non-empty canonical [Tool]-role result batch.
    ToolResult blocks carried by any other role, or mixed with other blocks,
    are not consumed. *)
val last_tool_results_from : Types.message list -> Types.tool_result list

(** Resolve the single canonical [BeforeTurnParams] contract. Illegal hook
    decisions remain explicit instead of falling back to defaults. *)
val resolve_turn_params
  :  hooks:Hooks.hooks
  -> messages:Types.message list
  -> turn:int
  -> invoke_hook:
       (hook_name:string
        -> (Hooks.hook_event -> Hooks.hook_decision) option
        -> Hooks.hook_event
        -> Hooks.hook_decision)
  -> (Hooks.turn_params, turn_params_resolution_error) result

(** {1 Context injection} *)

(** Explicit context injection failure. No partial context/message update is
    committed when an injector fails. *)
type context_injection_error =
  { tool_name : string option
  ; detail : string
  }

(** Apply context injector after tool execution, updating context and messages. *)
val apply_context_injection
  :  context:Context.t
  -> messages:Types.message list
  -> injector:Hooks.context_injector
  -> tool_uses:Types.content_block list
  -> results:Agent_tools.tool_execution_result list
  -> (Types.message list, context_injection_error) result

(** {1 Tool result construction} *)

(** Convert tool execution results into [ToolResult] content blocks.
    Content is preserved exactly in canonical agent messages. Any
    provider-specific transport adaptation belongs at provider projection. *)
val make_tool_results : Agent_tools.tool_execution_result list -> Types.content_block list
