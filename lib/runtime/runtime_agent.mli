(** Runtime_agent — config, build, and run entry points
    for Agent Core execution.

    Coordinates {!Runtime_agent_context}, {!Runtime_transport}, and
    {!Runtime_agent_checkpoint}. External callers reach
    the run/config entry points via [Runtime_agent.X];
    provider transport internals and transport-local diagnostics are owned by
    {!Runtime_transport}.

    All model-selection and runtime logic lives in
    {!Runtime_observation} and {!Keeper_turn_driver}.

    Internal helpers stay private at this boundary
    ([invalid_runtime_config],
    [provider_supports_inline_tools],
    [build_checkpoint],
    [partial_response_of_stop]). *)

(** {1 Stop reason} *)

type stop_reason = Runtime_agent_context.stop_reason =
  | Completed
  | Yielded_to_operation_queued of { turns_used : int }
  | Yielded_to_durable_stimulus of { turns_used : int }
  | Awaiting_external_effect of { turns_used : int }
  | Yielded_after_repeated_tool_call of {
      turns_used : int;
      tool_name : string;
      repeated_count : int;
    }
  | Yielded_after_repeated_assistant_text of {
      turns_used : int;
      repeated_count : int;
    }
  | InputRequired of {
      turns_used : int;
      request : Agent_core.Error.input_required;
    }

type cooperative_yield_reason =
  | Operation_queued
  | Durable_stimulus_waiting
  | External_effect_deferred
  | Repeated_tool_call of {
      tool_name : string;
      repeated_count : int;
    }
  | Repeated_assistant_text of { repeated_count : int }
  | Terminal_tool_completed

type cooperative_yield_decision =
  | Continue
  | Yield of cooperative_yield_reason

type cooperative_yield_probe =
  Agent_core.Agent.Advanced.tool_boundary ->
  (cooperative_yield_decision, Agent_core.Error.t) result
(** Why this single Agent Core call yielded control. [Completed] is the
    model's success path. [Yielded_to_operation_queued] fires when an
    autonomous-lane run stopped at a turn boundary to let the Owner start its
    queued Dashboard/connector operation.
    [Yielded_to_durable_stimulus] fires after at least one provider turn when
    another durable event is waiting behind the event currently leased by the
    cycle. [Awaiting_external_effect] fires when a typed external-effect
    handler durably defers through Gate; it is distinct because the originating
    chat must receive an acknowledgement rather than a transport failure.
    [Yielded_after_repeated_tool_call] fires only after repeated exact tool
    input and output prove that the provider loop is not advancing.
    [Yielded_after_repeated_assistant_text] fires when the trailing provider
    turns each emitted the same non-blank assistant text — the loop signal
    that appears before tool fingerprints repeat.
    [InputRequired] means Agent Core returned a typed elicitation request whose
    question and checkpoint must be surfaced without provider fallback. These
    typed non-completion stops persist checkpoints rather than claiming a
    completed deliverable: [InputRequired] resumes from later host input, while
    yield variants resume through later host-owned activity boundaries. *)

type classified_advanced_outcome =
  | Advanced_completed of Agent_core.Types.api_response
  | Advanced_yielded of
      cooperative_yield_reason
      * Agent_core.Agent.Advanced.yielded
      * Agent_core.Types.api_response

val classify_advanced_outcome :
  yield_reason:cooperative_yield_reason option ->
  boundary_response:Agent_core.Types.api_response option ->
  Agent_core.Agent.Advanced.run_outcome ->
  (classified_advanced_outcome, Agent_core.Error.t) result
(** Pure projection of one Advanced run outcome. [Terminal_tool_completed]
    completes with its receipt's provider response: the run ended because a
    terminal-contract tool finished its effect (for example a connector
    post), which is a success, not an unsupported state. A cooperative yield
    must carry both its typed decision and the provider response captured at
    the boundary; a missing half is a typed internal error. *)

(** {1 Config} *)

type config = Runtime_agent_context.config = {
  name : string;
  provider_cfg : Llm_provider.Provider_config.t;
  model_id : string;
  system_prompt : string;
  tools : Agent_core.Tool.t list;
  stream_idle_timeout_s : float option;
  first_event_timeout_s : float option;
  body_timeout_s : float option;
  max_tokens : int option;
  temperature : float option;
  hooks : Agent_core.Hooks.hooks option;
  tool_approval : Agent_core.Hooks.tool_approval_callback option;
  event_bus : Agent_core.Event_bus.t option;
  session_id : string option;
  description : string option;
      (** Human-facing display text only. Runtime logic must not parse identity
          or capability policy out of this field. *)
  runtime_id : string option;
      (** Typed catalog identity used by runtime logic. [None] means the caller
          did not supply a catalog identity, so [name] is used. *)
  initial_messages : Agent_core.Types.message list;
  model_input_projection : Agent_core.Agent.model_input_projection option;
  pre_dispatch_serialization_observer :
    Agent_core.Agent.pre_dispatch_serialization_observer option;
  raw_trace : Agent_core.Raw_trace.t option;
  trace_link : (string * string) option;
  enable_thinking : bool option;
  preserve_thinking : bool option;
  transport : Masc_grpc_transport.t;
  checkpoint_sidecar : Yojson.Safe.t option;
  cache_system_prompt : bool;
  yield_on_tool : bool;
  max_tool_rounds : int option;
  context_injector : Agent_core.Hooks.context_injector option;
  context : Agent_core.Context.t option;
  thinking_budget : int option;
  top_p : float option;
  top_k : int option;
  min_p : float option;
  on_run_complete : (bool -> unit) option;
  checkpoint_sink : Agent_core.Agent.checkpoint_sink option;
}

val default_config :
  name:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  config
(** Builds a {!config} populated with sensible defaults
    for every field except the four required ones.
    Caller mutates fields in place via record copy
    ([\{ cfg with ... \}]) before passing to {!build} or
    {!resume_from_checkpoint}. *)

(** {1 Run result} *)

type run_result = {
  response : Agent_core.Types.api_response;
  checkpoint : Agent_core.Checkpoint.t option;
  session_id : string;
  session_resumed : bool option;
  turns : int;
  trace_ref : Agent_core.Raw_trace.run_ref option;
  run_validation : Agent_core.Raw_trace.run_validation option;
  runtime_observation : Runtime_observation.runtime_observation option;
  stop_reason : stop_reason;
}

(** {1 Label resolution} *)

val label_resolution_error_to_string :
  Runtime_transport.label_resolution_error -> string
val label_resolution_error_to_core_error :
  Runtime_transport.label_resolution_error ->
  Agent_core.Error.t

val resolve_provider_config_of_label :
  string -> (Llm_provider.Provider_config.t,
             Runtime_transport.label_resolution_error) result

(** {1 Provider helpers} *)

val provider_caps_of_config :
  Llm_provider.Provider_config.t ->
  Llm_provider.Capabilities.capabilities
val provider_label : Llm_provider.Provider_config.t -> string

val runtime_observation_for_terminal_config :
  total_duration_ms:float ->
  ?error:string ->
  ?usage_scope:Runtime_usage_scope.t ->
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
  initial_messages:Agent_core.Types.message list ->
  goal_blocks:Agent_core.Types.content_block list ->
  Agent_core.Types.content_block list
(** Active content blocks for a single Agent Core run: prior [initial_messages] plus
    the current goal blocks. Keeper reroute and the runtime capability floor use
    this same view so media retained in history cannot bypass pre-dispatch
    gating on a later text-only follow-up. *)

val input_capabilities_of_runtime :
  Runtime.t -> Llm_provider.Capabilities.capabilities
(** Effective input capabilities of a materialized runtime: provider caps overlaid
    with the model's declared media capabilities (the MASC SSOT). Used to score the
    assigned runtime and reroute candidates. *)

val caps_admit_required_modalities :
  Llm_provider.Capabilities.capabilities -> string list -> bool
(** Shared RFC-0265 modality-admission predicate. Callers that need to preselect
    media-capable runtimes must use this instead of re-deriving checks from
    individual capability booleans. *)

val decide_modality_reroute_for_runtime_candidates :
  assigned:Runtime.t ->
  candidates:Runtime.t list ->
  ?checkpoint_messages:Agent_core.Types.message list ->
  ?initial_messages:Agent_core.Types.message list ->
  Agent_core.Types.content_block list ->
  reroute_decision
(** Keeper-dispatch variant for scoped candidate sets such as explicit runtime
    lanes. It preserves the caller-provided candidate order and does not consult
    global [runtime.media_failover]. *)

val strip_unsupported_modality_blocks :
  Llm_provider.Capabilities.capabilities ->
  Agent_core.Types.content_block list ->
  Agent_core.Types.content_block list * (string * int) list
(** RFC-0265 follow-up media degrade. Drop the top-level [Image]/[Document]/[Audio]
    blocks whose modality [caps] does not admit; keep text/thinking/tool blocks.
    Returns the kept blocks and a per-modality drop count. ToolResult-nested media
    is left intact (the capability gate floor still applies to it). *)

val strip_unsupported_modality_messages :
  Llm_provider.Capabilities.capabilities ->
  Agent_core.Types.message list ->
  Agent_core.Types.message list * (string * int) list
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
  val stop_reason_of_cooperative_yield :
    turns_used:int -> cooperative_yield_reason -> stop_reason

  (** Fail closed when a streaming deadline (inter-line idle or first-event,
      RFC-AC-037) is configured but no clock resolves. *)
  val decide_clock_for_idle :
    stream_idle_timeout_s:float option ->
    first_event_timeout_s:float option ->
    process_clock:(float Eio.Time.clock_ty Eio.Resource.t, string) result ->
    ctx_clock:float Eio.Time.clock_ty Eio.Resource.t option ->
    (float Eio.Time.clock_ty Eio.Resource.t option, Agent_core.Error.t) result

  val required_modalities_of_content_blocks :
    Agent_core.Types.content_block list -> string list


  val messages_for_run_with_checkpoint :
    checkpoint_messages:Agent_core.Types.message list ->
    initial_messages:Agent_core.Types.message list ->
    Agent_core.Types.message list

  val content_blocks_for_run :
    initial_messages:Agent_core.Types.message list ->
    goal_blocks:Agent_core.Types.content_block list ->
    Agent_core.Types.content_block list


  val required_modalities_of_messages :
    Agent_core.Types.message list -> string list

  val required_modalities_for_run :
    initial_messages:Agent_core.Types.message list ->
    goal_blocks:Agent_core.Types.content_block list ->
    string list

  val required_modalities_for_run_with_checkpoint :
    checkpoint_messages:Agent_core.Types.message list ->
    initial_messages:Agent_core.Types.message list ->
    goal_blocks:Agent_core.Types.content_block list ->
    string list

  val caps_admit_required_modalities :
    Llm_provider.Capabilities.capabilities -> string list -> bool

  val validate_content_blocks_for_run_against_capabilities :
    provider_label:string ->
    Llm_provider.Capabilities.capabilities ->
    initial_messages:Agent_core.Types.message list ->
    goal_blocks:Agent_core.Types.content_block list ->
    (unit, Agent_core.Error.t) result

  val validate_content_blocks_for_run_against_capabilities_with_checkpoint :
    provider_label:string ->
    Llm_provider.Capabilities.capabilities ->
    checkpoint_messages:Agent_core.Types.message list ->
    initial_messages:Agent_core.Types.message list ->
    goal_blocks:Agent_core.Types.content_block list ->
    (unit, Agent_core.Error.t) result

  val validate_content_blocks_against_capabilities :
    provider_label:string ->
    Llm_provider.Capabilities.capabilities ->
    Agent_core.Types.content_block list ->
    (unit, Agent_core.Error.t) result

  val apply_runtime_model_input_capabilities :
    Llm_provider.Capabilities.capabilities ->
    Runtime_schema.model_capabilities ->
    Llm_provider.Capabilities.capabilities

  val select_agent_result :
    checkpoint:'checkpoint option ->
    resume:('checkpoint -> 'result) ->
    build:(unit -> 'result) ->
    'result

  val runtime_observation_for_completed_config :
    total_duration_ms:float ->
    usage_scope:Runtime_usage_scope.t ->
    config ->
    Runtime_observation.runtime_observation

  val runtime_observation_for_terminal_config :
    total_duration_ms:float ->
    ?error:string ->
    ?usage_scope:Runtime_usage_scope.t ->
    config ->
    Runtime_observation.runtime_observation
end

(** {1 Build / resume / run} *)

val build :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  (Agent_core.Agent.t, Agent_core.Error.t) result
(** Builds an [Agent_core.Agent.t] from a {!config} ready for a
    fresh run over the HTTP provider transport. *)

val resume_from_checkpoint :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  checkpoint:Agent_core.Checkpoint.t ->
  (Agent_core.Agent.t, Agent_core.Error.t) result
(** Resumes from a persisted checkpoint.  Uses
    [Runtime_agent_context.prepare_resume] to reconcile
    [checkpoint.turn_count] with the current config. *)

val run :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  ?agent_core_checkpoint:Agent_core.Checkpoint.t ->
  ?on_event:(Agent_core.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?agent_ref:Agent_core.Agent.t option ref ->
  ?cooperative_yield_probe:cooperative_yield_probe ->
  string ->
  (run_result, Agent_core.Error.t) result
(** Runs an Agent Core agent against [goal]. When
    [agent_core_checkpoint] is present, {!resume_from_checkpoint}
    is used; otherwise {!build} produces a fresh agent.
    Returns the wrapped {!run_result}; errors propagate
    as [Agent_core.Error.t]. *)

val run_blocks :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  ?agent_core_checkpoint:Agent_core.Checkpoint.t ->
  ?on_event:(Agent_core.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?agent_ref:Agent_core.Agent.t option ref ->
  ?cooperative_yield_probe:cooperative_yield_probe ->
  Agent_core.Types.content_block list ->
  (run_result, Agent_core.Error.t) result
(** Runs an Agent Core agent against structured user-authored content blocks. *)

type agent_core_tool_projector =
  name:string ->
  description:string ->
  input_schema:Yojson.Safe.t ->
  (Yojson.Safe.t -> Tool_result.result) ->
  Agent_core.Tool.t
(** Turns one MASC tool schema into the inline [Agent_core.Tool.t] a provider
    call carries. [Tool_bridge] owns the projection and this library must not
    depend on it, so the direction is inverted by passing the function in.

    It used to be inverted by a process-global [Atomic.t] that [Tool_bridge]
    filled from a module initializer, which made "was the bridge linked and did
    its initializer run" a runtime question — answered by an [Internal] error
    at the point of use, and undone in tests by a [For_testing] helper that
    emptied the global. As an argument the question is the compiler's. *)

val run_with_masc_tools :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  masc_tools:Masc_domain.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.result) ->
  agent_core_tool_of_masc:agent_core_tool_projector ->
  ?on_event:(Agent_core.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  string ->
  (run_result, Agent_core.Error.t) result
(** Variant of {!run} that projects the supplied MASC schemas into exact inline
    [Agent_core.Tool.t] values through [dispatch]. *)
