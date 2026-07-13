(** Runtime_agent — config, build, and run entry points
    for OAS agent execution.

    Thin facade over {!Runtime_agent_context},
    {!Runtime_transport}, and
    {!Runtime_oas_checkpoint}.  External callers reach
    the run/config entry points via [Runtime_agent.X];
    provider transport internals (CLI / MCP wire formats,
    runtime policy projections, and transport-local
    diagnostics) are owned by {!Runtime_transport}.

    All model-selection and runtime logic lives in
    {!Runtime_observation} and {!Keeper_turn_driver}.

    Internal helpers stay private at this boundary
    ([invalid_runtime_config],
    [provider_supports_inline_tools],
    [provider_supports_runtime_mcp_lane],
    [persist_checkpoint], [build_checkpoint],
    [partial_response_of_stop]). *)

(** {1 Stop reason} *)

type stop_reason = Runtime_agent_context.stop_reason =
  | Completed
  | TurnBudgetExhausted of { turns_used : int; limit : int }
  | MutationBoundaryReached of {
      turns_used : int;
      tool_name : string option;
    }
  | Yielded_to_chat_waiting of { turns_used : int }
  | Yielded_to_durable_stimulus of { turns_used : int }
  | InputRequired of {
      turns_used : int;
      request : Agent_sdk.Error.input_required;
    }
  | ToolFailureRecoveryDeferred of {
      turns_used : int;
      reason : string;
      tool_names : string list;
    }
(** Why this single OAS call yielded control. [Completed] is the
    model's success path; [TurnBudgetExhausted] means the per-call
    turn budget checkpoint was reached. It is not a completed
    deliverable; callers must classify it from typed stop reason plus
    durable-progress evidence before deciding whether to continue from
    the persisted checkpoint. [MutationBoundaryReached] fires when the
    keeper hit a mutation tool while in read-only mode (the [tool_name]
    surfaces which tool triggered the gate). [Yielded_to_chat_waiting]
    fires when an autonomous-lane run stopped at a turn boundary to hand
    the keeper's turn slot to a parked dashboard/connector chat request.
    [Yielded_to_durable_stimulus] fires after at least one provider turn when
    another durable event is waiting behind the event currently leased by the
    cycle. [InputRequired] means OAS returned a typed elicitation request whose
    question and checkpoint must be surfaced without provider fallback.
    [ToolFailureRecoveryDeferred] means the typed OAS recovery judge
    returned control to the host without another main-provider call; its
    [reason] is observation-only and must never drive scheduling. These typed
    non-completion stops persist checkpoints rather than claiming a completed
    deliverable: [InputRequired] resumes from later host input, while the yield
    and defer variants resume through later host-owned activity boundaries. *)

(** {1 Config} *)

type config = Runtime_agent_context.config = {
  name : string;
  provider_cfg : Llm_provider.Provider_config.t;
  provider : Agent_sdk.Provider.config;
  model_id : string;
  priority : Llm_provider.Request_priority.t option;
  system_prompt : string;
  tools : Agent_sdk.Tool.t list;
  runtime_mcp_policy :
    Llm_provider.Llm_transport.runtime_mcp_policy option;
  max_turns : int;
  max_idle_turns : int;
  stream_idle_timeout_s : float option;
  max_execution_time_s : float option;
  body_timeout_s : float option;
  max_tokens : int option;
  temperature : float;
  hooks : Agent_sdk.Hooks.hooks option;
  context_reducer : Agent_sdk.Context_reducer.t option;
  guardrails : Agent_sdk.Guardrails.t option;
  event_bus : Agent_sdk.Event_bus.t option;
  checkpoint_dir : string option;
  session_id : string option;
  description : string option;
  initial_messages : Agent_sdk.Types.message list;
  raw_trace : Agent_sdk.Raw_trace.t option;
  trace_link : (string * string) option;
  enable_thinking : bool option;
  preserve_thinking : bool option;
  transport : Masc_grpc_transport.t;
  allowed_paths : string list;
  checkpoint_sidecar : Yojson.Safe.t option;
  cache_system_prompt : bool;
  yield_on_tool : bool;
  tool_failure_judge : Agent_sdk.Tool_failure_recovery.judge option;
  compact_ratio : float option;
  context_window_tokens : int option;
  oas_auto_context_overflow_retry : bool;
  context_injector : Agent_sdk.Hooks.context_injector option;
  context : Agent_sdk.Context.t option;
  approval : Agent_sdk.Hooks.approval_callback option;
  exit_condition : (int -> bool) option;
  exit_condition_result : (int -> stop_reason * string option) option;
  summarizer : (Agent_sdk.Types.message list -> string) option;
  execution_idle_timeout_s : float option;
  thinking_budget : int option;
  top_p : float option;
  top_k : int option;
  min_p : float option;
  on_run_complete : (bool -> unit) option;
  disclosure_level : Agent_sdk.Tool.disclosure_level option;
  disclosure_resolver
      : (Agent_sdk.Types.tool_result list -> Agent_sdk.Tool.disclosure_level option) option;
  tool_selector : Agent_sdk.Tool_selector.strategy option;
  checkpoint_sink : Agent_sdk.Agent.checkpoint_sink option;
}

val default_config :
  name:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  config
(** Builds a {!config} populated with sensible defaults
    for every field except the four required ones.
    Caller mutates fields in place via record copy
    ([\{ cfg with ... \}]) before passing to {!build} or
    {!resume_from_checkpoint}. *)

(** {1 Run result} *)

type run_result = {
  response : Agent_sdk.Types.api_response;
  checkpoint : Agent_sdk.Checkpoint.t option;
  session_id : string;
  turns : int;
  trace_ref : Agent_sdk.Raw_trace.run_ref option;
  run_validation : Agent_sdk.Raw_trace.run_validation option;
  runtime_observation : Runtime_observation.runtime_observation option;
  stop_reason : stop_reason;
}

type worker_lifecycle_classification =
  { event : string
  ; status : string
  ; error : string option
  }

val worker_lifecycle_classification_of_result :
  (run_result, Agent_sdk.Error.sdk_error) result -> worker_lifecycle_classification


(** {1 Label resolution} *)

val label_resolution_error_to_string :
  Runtime_transport.label_resolution_error -> string
val label_resolution_error_to_sdk_error :
  Runtime_transport.label_resolution_error ->
  Agent_sdk.Error.sdk_error

val resolve_provider_config_of_label :
  string -> (Llm_provider.Provider_config.t,
             Runtime_transport.label_resolution_error) result

(** {1 Provider helpers} *)

val provider_caps_of_config :
  Llm_provider.Provider_config.t ->
  Llm_provider.Capabilities.capabilities
val provider_label : Llm_provider.Provider_config.t -> string
val resolve_tool_lane_for_oas_tools :
  base_path:string ->
  ?agent_name:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  tools:Agent_sdk.Tool.t list ->
  unit ->
  ( Agent_sdk.Tool.t list
    * Llm_provider.Llm_transport.runtime_mcp_policy option,
    Agent_sdk.Error.sdk_error )
  result

val runtime_observation_for_terminal_config :
  total_duration_ms:float ->
  ?error:string ->
  config ->
  Runtime_observation.runtime_observation

(** {1 RFC-0265 — capability-driven proactive runtime reroute} *)

type reroute_decision =
  | No_reroute_needed
  | Reroute of { to_runtime_id : string; reason : string }
  | No_capable_runtime of { required : string list }

val decide_modality_reroute :
  assigned_caps:Llm_provider.Capabilities.capabilities ->
  required_modalities:string list ->
  candidates:(string * Llm_provider.Capabilities.capabilities) list ->
  reroute_decision
(** Pure pre-dispatch reroute decision. [No_reroute_needed] when [assigned_caps]
    already admit [required_modalities]; [Reroute] to the first [candidates] entry
    whose capabilities admit them (declaration/[media_failover] order is the
    caller's responsibility); [No_capable_runtime] when none qualify (caller keeps
    the loud capability rejection as the floor). Deterministic: no I/O, no provider
    liveness (deferred to RFC-0260). *)

val content_blocks_for_run :
  initial_messages:Agent_sdk.Types.message list ->
  goal_blocks:Agent_sdk.Types.content_block list ->
  Agent_sdk.Types.content_block list
(** Active content blocks for a single OAS run: prior [initial_messages] plus
    the current goal blocks. Keeper reroute and the runtime capability floor use
    this same view so media retained in history cannot bypass pre-dispatch
    gating on a later text-only follow-up. *)

val input_capabilities_of_runtime :
  Runtime.t -> Llm_provider.Capabilities.capabilities
(** Effective input capabilities of a materialized runtime: provider caps overlaid
    with the model's declared media capabilities (the MASC SSOT). Used to score the
    assigned runtime and reroute candidates. *)

val media_reroute_candidates :
  exclude:string -> (string * Llm_provider.Capabilities.capabilities) list
(** Ordered [(runtime_id, input_caps)] reroute candidates: [\[runtime\].media_failover]
    order first, then remaining configured runtimes in declaration order, excluding
    [exclude]. Reads the runtime cache; deterministic (no provider liveness). *)

val caps_admit_required_modalities :
  Llm_provider.Capabilities.capabilities -> string list -> bool
(** Shared RFC-0265 modality-admission predicate. Callers that need to preselect
    media-capable runtimes must use this instead of re-deriving checks from
    individual capability booleans. *)

val first_media_capable_runtime : modality:string -> string option
(** Runtime id of the first configured runtime that admits [modality] (e.g.
    ["image"]) as input, in [media_reroute_candidates] order (media_failover then
    declaration). [None] when none qualifies. Uses the same admit predicate as the
    RFC-0265 reroute, so the pick matches the dispatch capability gate. *)

val decide_modality_reroute_for_runtime :
  assigned:Runtime.t ->
  ?checkpoint_messages:Agent_sdk.Types.message list ->
  ?initial_messages:Agent_sdk.Types.message list ->
  Agent_sdk.Types.content_block list ->
  reroute_decision
(** Keeper-dispatch convenience: gather candidates from the runtime cache and
    decide a reroute for [assigned] given the active run view: prior
    [initial_messages], checkpoint resume messages, plus the current turn's
    content blocks. Composes [input_capabilities_of_runtime] /
    [media_reroute_candidates] / [decide_modality_reroute]. *)

val decide_modality_reroute_for_runtime_candidates :
  assigned:Runtime.t ->
  candidates:Runtime.t list ->
  ?checkpoint_messages:Agent_sdk.Types.message list ->
  ?initial_messages:Agent_sdk.Types.message list ->
  Agent_sdk.Types.content_block list ->
  reroute_decision
(** Keeper-dispatch variant for scoped candidate sets such as explicit runtime
    lanes. It preserves the caller-provided candidate order and does not consult
    global [runtime.media_failover]. *)

val strip_unsupported_modality_blocks :
  Llm_provider.Capabilities.capabilities ->
  Agent_sdk.Types.content_block list ->
  Agent_sdk.Types.content_block list * (string * int) list
(** RFC-0265 follow-up media degrade. Drop the top-level [Image]/[Document]/[Audio]
    blocks whose modality [caps] does not admit; keep text/thinking/tool blocks.
    Returns the kept blocks and a per-modality drop count. ToolResult-nested media
    is left intact (the capability gate floor still applies to it). *)

val strip_unsupported_modality_messages :
  Llm_provider.Capabilities.capabilities ->
  Agent_sdk.Types.message list ->
  Agent_sdk.Types.message list * (string * int) list
(** [strip_unsupported_modality_blocks] mapped over each message's content,
    accumulating the per-modality drop count across the message list. *)

val merge_modality_counts :
  (string * int) list -> (string * int) list -> (string * int) list
(** Sum two per-modality drop-count assoc lists. *)

val media_degrade_note :
  runtime_id:string -> (string * int) list -> string option
(** Notice text injected into a degraded turn so model input records that media
    was dropped rather than vanishing. [None] when nothing was dropped. *)

module For_testing : sig
  val request_runtime_fields_on_base_config :
    base:Llm_provider.Provider_config.t ->
    Llm_provider.Provider_config.t ->
    Llm_provider.Provider_config.t

  val provider_http_observation_transport :
    Llm_provider.Llm_transport.t -> Llm_provider.Llm_transport.t

  val runtime_id_of_config : config -> string

  (* RFC-OAS-026 §4.6 fail-fast (pure decision; raises [Failure] when an idle
     deadline is configured but no clock resolves). *)
  val decide_clock_for_idle :
    stream_idle_timeout_s:float option ->
    process_clock:(float Eio.Time.clock_ty Eio.Resource.t, string) result ->
    ctx_clock:float Eio.Time.clock_ty Eio.Resource.t option ->
    (float Eio.Time.clock_ty Eio.Resource.t option, Agent_sdk.Error.sdk_error) result

  val required_modalities_of_content_blocks :
    Agent_sdk.Types.content_block list -> string list

  val content_blocks_of_messages :
    Agent_sdk.Types.message list -> Agent_sdk.Types.content_block list

  val messages_for_run_with_checkpoint :
    checkpoint_messages:Agent_sdk.Types.message list ->
    initial_messages:Agent_sdk.Types.message list ->
    Agent_sdk.Types.message list

  val content_blocks_for_run :
    initial_messages:Agent_sdk.Types.message list ->
    goal_blocks:Agent_sdk.Types.content_block list ->
    Agent_sdk.Types.content_block list

  val content_blocks_for_run_with_checkpoint :
    checkpoint_messages:Agent_sdk.Types.message list ->
    initial_messages:Agent_sdk.Types.message list ->
    goal_blocks:Agent_sdk.Types.content_block list ->
    Agent_sdk.Types.content_block list

  val required_modalities_of_messages :
    Agent_sdk.Types.message list -> string list

  val required_modalities_for_run :
    initial_messages:Agent_sdk.Types.message list ->
    goal_blocks:Agent_sdk.Types.content_block list ->
    string list

  val required_modalities_for_run_with_checkpoint :
    checkpoint_messages:Agent_sdk.Types.message list ->
    initial_messages:Agent_sdk.Types.message list ->
    goal_blocks:Agent_sdk.Types.content_block list ->
    string list

  val caps_admit_required_modalities :
    Llm_provider.Capabilities.capabilities -> string list -> bool

  val validate_content_blocks_for_run_against_capabilities :
    provider_label:string ->
    Llm_provider.Capabilities.capabilities ->
    initial_messages:Agent_sdk.Types.message list ->
    goal_blocks:Agent_sdk.Types.content_block list ->
    (unit, Agent_sdk.Error.sdk_error) result

  val validate_content_blocks_for_run_against_capabilities_with_checkpoint :
    provider_label:string ->
    Llm_provider.Capabilities.capabilities ->
    checkpoint_messages:Agent_sdk.Types.message list ->
    initial_messages:Agent_sdk.Types.message list ->
    goal_blocks:Agent_sdk.Types.content_block list ->
    (unit, Agent_sdk.Error.sdk_error) result

  val validate_content_blocks_against_capabilities :
    provider_label:string ->
    Llm_provider.Capabilities.capabilities ->
    Agent_sdk.Types.content_block list ->
    (unit, Agent_sdk.Error.sdk_error) result

  val apply_runtime_model_input_capabilities :
    Llm_provider.Capabilities.capabilities ->
    Runtime_schema.model_capabilities ->
    Llm_provider.Capabilities.capabilities

  val runtime_observation_for_completed_config :
    total_duration_ms:float -> config -> Runtime_observation.runtime_observation

  val runtime_observation_for_terminal_config :
    total_duration_ms:float ->
    ?error:string ->
    config ->
    Runtime_observation.runtime_observation
end

(** {1 Lifecycle / checkpoint helpers (re-exported)} *)

module Lifecycle_for_testing : sig
  val provider_attrs : config -> (string * Yojson.Safe.t) list
end

val publish_lifecycle :
  name:string ->
  event:string ->
  detail:string ->
  ?error:string ->
  ?session_id:string ->
  ?status:string ->
  ?attrs:(string * Yojson.Safe.t) list ->
  unit ->
  unit
val enrich_idle_detail :
  string -> Agent_sdk.Types.message list -> string

(** {1 Build / resume / run} *)

val build :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  (Agent_sdk.Agent.t, Agent_sdk.Error.sdk_error) result
(** Builds an [Agent_sdk.Agent.t] from a {!config} ready for a
    fresh run over the HTTP provider transport; threads
    [config.approval] into the OAS builder when present. *)

val resume_from_checkpoint :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  checkpoint:Agent_sdk.Checkpoint.t ->
  (Agent_sdk.Agent.t, Agent_sdk.Error.sdk_error) result
(** Resumes from a persisted checkpoint.  Uses
    [Runtime_agent_context.prepare_resume] to reconcile
    [checkpoint.turn_count] with the current config. *)

val run :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  ?oas_checkpoint:Agent_sdk.Checkpoint.t ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?agent_ref:Agent_sdk.Agent.t option ref ->
  string ->
  (run_result, Agent_sdk.Error.sdk_error) result
(** Runs an OAS agent against [goal].  When
    [oas_checkpoint] is present, {!resume_from_checkpoint}
    is used; otherwise {!build} produces a fresh agent.
    Returns the wrapped {!run_result}; errors propagate
    as [Agent_sdk.Error.sdk_error]. *)

val run_blocks :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  ?oas_checkpoint:Agent_sdk.Checkpoint.t ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?agent_ref:Agent_sdk.Agent.t option ref ->
  ?goal_detail:string ->
  Agent_sdk.Types.content_block list ->
  (run_result, Agent_sdk.Error.sdk_error) result
(** Runs an OAS agent against structured user-authored content blocks.  The
    optional [goal_detail] is a display/log fallback only; media payloads stay
    in typed OAS blocks and are not rendered into lifecycle strings. *)

val run_with_masc_tools :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  base_path:string ->
  config:config ->
  masc_tools:Masc_domain.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.result) ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  string ->
  (run_result, Agent_sdk.Error.sdk_error) result
(** Variant of {!run} that wires MASC public-MCP tools
    into the agent through [dispatch].  Used by the
    keeper-runtime path that needs to expose MCP-style
    tools to the model alongside OAS tools. *)

val set_oas_tool_of_masc_hook :
  (name:string ->
   description:string ->
   input_schema:Yojson.Safe.t ->
   (Yojson.Safe.t -> Tool_result.result) ->
   Agent_sdk.Tool.t) ->
  unit
(** [set_oas_tool_of_masc_hook f] registers a function to project MASC tool schemas
    into Agent_sdk.Tool.t. Used to decouple the [Tool_bridge] module. *)
