(** Shared turn logic for sync and streaming paths.

    Contains helper functions shared by the sync and streaming Agent drivers.

    These functions take explicit parameters (not [Agent.t]) to avoid
    circular module dependency: [Agent -> Agent_turn] is fine,
    [Agent_turn -> Agent] is not.

    @stability Internal
    @since 0.93.1 *)

(** {1 Turn preparation} *)

(** One request the turn may send. *)
type turn_request =
  { effective_messages : Llm_provider.Types.message list
    (** The request messages: the caller projection's output, or the
        history converted with {!History.to_wire_message}. *)
  ; tools : Tool_set.t
    (** Callable tools admitted by this exact request window. *)
  ; tools_json : Yojson.Safe.t list option
    (** Stable wire catalog paired with [effective_messages]. *)
  ; visible_tool_names : string list
    (** Callable names admitted by this exact request window. *)
  ; context_message : (Types.message option, Error.t) result
    (** The fresh carrier as actually transmitted after projection, or [None]
        if no carrier was generated or the projection removed it. An ambiguous
        selection is data, not a preparation failure: only a signed Anthropic
        response needs this result. Projected history never replaces the
        canonical transcript. *)
  }

(** A caller's narrower request ({!Agent_types.narrower_model_input}) with
    its carrier selected as for [request]. An exception it raises is its
    [Error]. *)
type narrower_turn_request = Error.t -> (turn_request option, Error.t) result

(** Pre-processed inputs for an LLM turn. *)
type turn_preparation =
  { tools_json : Yojson.Safe.t list option
  ; request : turn_request
    (** The request the turn sends first. *)
  ; narrower : narrower_turn_request list
    (** The narrower requests, in the order the route may ask them
        ({!Agent_types.model_input_candidates}). Empty without a caller
        projection. *)
  ; visible_tool_names : string list
    (** Names of the callable tools admitted for dispatch. With native deferred
        loading, [tools_json] also contains deferred schemas that are not in this
        list. Useful for [Event_bus.TurnReady] subscribers and deterministic
        substrate observability. Empty list when no callable tools are presented.

        Order matches the callable set in [Tool_set.to_list].

        @since 0.162.0 *)
  }

(** Serialize callable tools and, when native deferred loading is enabled, the
    full deferred catalog without admitting those deferred tools for dispatch. *)
val prepare_tools
  :  tools:Tool_set.t
  -> ?deferred_tools:Tool.t list
  -> ?defer_loading:bool
  -> unit
  -> Yojson.Safe.t list option * string list
(** Returns [(tools_json, visible_tool_names)].
    [visible_tool_names] contains only callable names; deferred schemas remain
    in [tools_json] when native deferred loading is enabled. It is empty when no
    callable tools were supplied.

    @since 0.162.0 third tuple element added (visible_tool_names) *)

(** Preserve the complete transcript and inject optional turn context. *)

val prepare_messages
  :  messages:Types.message list
  -> turn_params:Hooks.turn_params
  -> unit
  -> Types.message list

(** Full turn preparation: exact caller-supplied tools plus messages. A failed
    caller projection is returned before provider measurement or dispatch.
    Retention selection cannot reject another provider's request. Collection
    consumes that selection only for an Anthropic response with signed reasoning.

    @since 0.185.0 added optional [config] parameter for provider-facing
      thinking preservation. *)
val prepare_turn
  :  media_store:History.media_store
  -> tools:Tool_set.t
  -> messages:Types.message list
  -> turn_params:Hooks.turn_params
  -> ?eager_tools:Tool_set.t
  -> ?deferred_tools:Tool.t list
  -> ?defer_loading:bool
  -> ?model_input_projection:Agent_types.model_input_projection
  -> unit
  -> (turn_preparation, Error.t) result

(** Project caller-owned turn controls onto the exact provider carrier.
    Provider identity and transport fields remain unchanged; model-specific
    capability overrides are retained only when the selected model is
    unchanged. *)
val provider_config_with_agent_config
  :  config:Types.agent_config
  -> Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t

(** {1 Provider turn identity} *)

(** The zero-based identity of the fresh provider turn that runs next on
    [state].

    [Pipeline.resolve_turn_frontier] reads it for a fresh turn; a turn resumed
    from the durable journal takes its persisted ordinal instead. The resolved
    identity is what the pipeline stages, the [BeforeTurn]/[AfterTurn] hooks,
    the event bus, tracing spans, tool invocations and the agent loop's
    "turn completed" log line all carry. No reader derives a number from
    [turn_count] on its own, so no site can drift by one from the others. *)
val provider_turn_ordinal : Types.agent_state -> int

(** {1 Usage accumulation} *)

(** Accumulate observed response usage and already-annotated cost. [Some 0.0]
    is a known charge; [None] stays a pricing gap even when a catalog has rates.
    [response_model] only names that gap and grants no pricing authority.
    Missing pricing never blocks the turn. A missing payload advances both the processed
    response count and its independent missing-payload count, preserving known
    subtotals. Payload coverage does not establish per-field reporting. *)
val accumulate_usage
  :  current_usage:Types.usage_stats
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
val last_tool_results_from : Types.message list -> Hooks.history_tool_result list

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

type context_injection_outcome =
  | No_injection
  | Injected of Types.message list
(** [No_injection] means every injector reported no context updates or extra
    messages. [Injected messages] includes context-only updates; its message
    list may therefore be the original list. *)

(** Apply context injector after tool execution, updating context and messages.
    No updates are applied until every injector has succeeded. *)
val apply_context_injection
  :  context:Context.t
  -> messages:Types.message list
  -> injector:Hooks.context_injector
  -> tool_uses:Llm_provider.Types.content_block list
  -> results:Agent_tools.tool_execution_result list
  -> (context_injection_outcome, context_injection_error) result

(** {1 Tool result construction} *)

(** Convert tool execution results into history [ToolResult] blocks. Text
    content is kept; result media is put in [media_store] and
    held by reference. A result whose media payload is not padded standard
    base64 becomes a [Non_retryable_tool_error] result that appends a media
    diagnostic to the original text and holds no media. Any other media error
    fails the conversion. *)
val make_tool_results
  :  media_store:History.media_store
  -> Agent_tools.tool_execution_result list
  -> (Types.content_block list, Error.t) result
