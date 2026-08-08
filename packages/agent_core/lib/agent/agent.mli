(** Agent: structured concurrency agent with hooks, tools, and handoffs.

    {b type t is abstract.}  Use accessor functions below to inspect
    agent state.  Direct record field access is restricted to
    library-internal code via [Agent_types.t].

    @stability Stable
    @since 0.93.1 *)

(** {1 Types (re-exported from Agent_types)} *)

type periodic_callback = Agent_types.periodic_callback =
  { interval_sec : float
  ; callback : unit -> unit
  }

type checkpoint_stage = Agent_types.checkpoint_stage =
  | After_assistant_collected
  | After_tool_results_appended
  | After_context_injection

val checkpoint_stage_to_string : checkpoint_stage -> string

type checkpoint_snapshot = Agent_types.checkpoint_snapshot =
  { stage : checkpoint_stage
  ; turn : int
  ; checkpoint : Checkpoint.t
  ; timestamp : float
  }

type checkpoint_sink = Agent_types.checkpoint_sink

(** Agent-level provider-fit policy. [Disabled] preserves the historical
    single-call path. [Enforce_when_supported] uses provider-native request
    measurement for protocols that OAS supports and otherwise preserves that
    protocol's historical path; it never estimates token counts. *)
type context_fit_admission = Agent_types.context_fit_admission =
  | Disabled
  | Enforce_when_supported

type model_input_projection = Agent_types.model_input_projection
type pre_dispatch_serialization_observer = Agent_types.pre_dispatch_serialization_observer

type options = Agent_types.options =
  { provider_config : Llm_provider.Provider_config.t option
  ; stream_idle_timeout_s : float option
  ; first_event_timeout_s : float option
  ; body_timeout_s : float option
  ; hooks : Hooks.hooks
  ; guardrails_async : Guardrails_async.t
  ; tracer : Tracing.t
  ; trace_link : (string * string) option
  ; raw_trace : Raw_trace.t option
  ; context_injector : Hooks.context_injector option
  ; mcp_clients : Mcp.managed list
  ; event_bus : Event_bus.t option
  ; skill_registry : Skill_registry.t option
    (** Discovery/metadata path only.  Surfaced via {!Agent.card} for
          A2A negotiation.  Does not affect runtime prompt composition. *)
  ; elicitation : Hooks.elicitation_callback option
  ; tool_approval : Hooks.tool_approval_callback option
    (** Closed synchronous exact-tool approval callback. *)
  ; description : string option
  ; periodic_callbacks : periodic_callback list
  ; slot_id : int option
  ; on_run_complete : (bool -> unit) option
  ; journal : Durable_event.journal option
  ; transport : Llm_provider.Llm_transport.t option
  }

type lifecycle_status = Agent_lifecycle.lifecycle_status =
  | Accepted
  | Ready
  | Running
  | Completed
  | Failed

type lifecycle_snapshot = Agent_lifecycle.lifecycle_snapshot

(** Abstract agent type. *)
type t

(** {1 Accessors} *)

val state : t -> Types.agent_state
val lifecycle : t -> lifecycle_snapshot option
val tools : t -> Tool_set.t
val context : t -> Context.t
val options : t -> options
val provider_config : t -> Llm_provider.Provider_config.t option
val net : t -> [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
val description : t -> string option

(** {1 Defaults} *)

val default_options : options
val sdk_version : string

(** {1 Construction} *)

(** [checkpoint_sink] attaches an optional caller-owned mutation-boundary
    checkpoint sink. The pipeline updates live state first, then emits a typed
    snapshot after assistant collection, after base tool-result append, and
    after successful context injection. A sink failure is returned before the
    pipeline advances to the next mutation stage. The sink is passed here
    rather than through {!options} so callers that construct options records
    remain source-compatible.

    [options.provider_config] is the exact typed provider carrier. Endpoint,
    credential, request path, headers, and capability overrides are preserved.

    [context_fit_admission], [model_input_projection], and
    [pre_dispatch_serialization_observer] are separate from [options] so callers
    that construct options records remain source-compatible.
    The optional projection is applied once during turn preparation; native
    request measurement and provider dispatch consume the same projected
    messages. A returned [Error detail] or non-reserved callback exception
    fails the turn as {!Error.HookExecutionFailed}.

    [pre_dispatch_serialization_observer] receives metadata-only evidence for
    the admitted provider body before built-in HTTP dispatch is attempted. It
    does not prove that transport dispatch started or completed. *)
val create
  :  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> config:Types.agent_config
  -> ?tools:Tool.t list
  -> ?context:Context.t
  -> ?options:options
  -> ?context_fit_admission:context_fit_admission
  -> ?model_input_projection:model_input_projection
  -> ?pre_dispatch_serialization_observer:pre_dispatch_serialization_observer
  -> ?checkpoint_sink:checkpoint_sink
  -> unit
  -> t

val clone : ?copy_context:bool -> t -> t

(** {1 Agent Card} *)

(** Build a discovery card with the exact caller-owned interface authority.
    The authority is mandatory and non-empty; OAS never invents an endpoint,
    protocol binding, or protocol version. *)
val card
  :  supported_interfaces:Agent_card.supported_interfaces
  -> t
  -> Agent_card.agent_card

(** {1 Execution} *)

type api_strategy =
  | Sync
  | Stream of
      { on_event : Types.sse_event -> unit
      ; on_telemetry : (Llm_provider.Telemetry_event.t -> unit) option
      }

(** Additive provider-failure carrier.  Existing execution entry points are
    exact projections of this record's [error] field. *)
type detailed_error = Provider_failure_attribution.detailed_error =
  { error : Error.sdk_error
  ; provider_failure : Provider_failure_attribution.t option
  }

(** Application-lifetime CPU capability shared by execution journals. *)
type execution_runtime

(** One caller-owned directory for one fresh Agent API-call execution scope. *)
type execution_store

(** Opaque durable identity for one Agent API-call execution scope. *)
type execution_locator

type execution_terminal_outcome =
  | Terminal_succeeded
  | Terminal_failed
  | Terminal_cancelled

type execution_operator_repair_reason = Effect_outcome_unknown

type execution_recovery_action =
  | Retire
  | Operator_repair_required of execution_operator_repair_reason

type execution_terminal_disposition =
  { outcome : execution_terminal_outcome
  ; recovery : execution_recovery_action
  }

val execution_locator_to_yojson : execution_locator -> Yojson.Safe.t

(** Decode the exact versioned locator emitted by
    {!execution_locator_to_yojson}. Unknown versions or fields are rejected. *)
val execution_locator_of_yojson : Yojson.Safe.t -> (execution_locator, string) result

val create_execution_runtime
  :  sw:Eio.Switch.t
  -> domain_mgr:_ Eio.Domain_manager.t
  -> domain_count:int
  -> (execution_runtime, Error.sdk_error) result

(** Lossless read-only projection of OAS's canonical recursive execution
    journal. These values are observations only: they cannot append, admit,
    pause, cancel, or terminate execution. *)
module Execution_projection : Agent_execution_projection_intf.S

(** Open the same read-only projection for a currently running scope or after
    process restart. [locator] must identify the top-level run in exactly this
    directory. The call takes no writer lock and performs no recovery writes.
    The returned value is safe to share between fibers; sharing also preserves
    its incremental validated-prefix cache across consumers. *)
val open_execution_projection
  :  runtime:execution_runtime
  -> dir:Eio.Fs.dir_ty Eio.Path.t
  -> execution_locator
  -> (Execution_projection.t, Execution_projection.error) result

(** Configure one durable execution scope. Without [resume], the directory must
    be new and the call starts a fresh scope. With [resume], the same Agent API
    reopens that scope in the same directory, validates Agent identity and the
    restored user input, and replays settled ToolResults without rerunning tool
    gates, handlers, or completion observers. An admitted Tool attempt without
    a settled result fails closed because its external outcome is unknown.

    The same optional value is accepted by regular, streaming, handoff,
    single-turn, and [Advanced] run entry points; no parallel durable run
    surface is introduced. One store and directory must be used for exactly one
    API call. A cooperative [Yielded] return is a successful terminal boundary
    for that call.

    [on_scope_ready], when supplied, must persist the opaque locator before
    provider or Tool effects begin. It is invoked for both fresh and resumed
    scopes, so the sink should be idempotent. Failure aborts the scope and the
    Agent call. The same locator and directory can be passed to
    {!open_execution_projection} immediately for live reads or later after a
    restart; the callback is not a separate event or catch-up authority.

    [on_terminal_disposition] is invoked after the terminal journal commit and
    successful writer drain, before this Agent call returns. [Retire] means the
    caller-owned recovery locator may be removed.
    [Operator_repair_required Effect_outcome_unknown] means an admitted Tool
    attempt has no settled result, so automatic retry could duplicate an
    external effect. The sink should persist the decision idempotently. A
    returned error or non-reserved exception fails the Agent call with
    [Error.Internal] after the terminal commit; the recovery locator must
    remain. If writer drain fails, the sink is not invoked and the locator must
    likewise remain. Caller cancellation is protected through terminal
    settlement, writer drain, and callback, then re-raised. If callback cleanup
    also fails, cancellation remains the primary exception and the cleanup
    failure is logged. *)
val execution_store
  :  runtime:execution_runtime
  -> dir:Eio.Fs.dir_ty Eio.Path.t
  -> ?on_scope_ready:(execution_locator -> (unit, string) result)
  -> ?on_terminal_disposition:(execution_terminal_disposition -> (unit, string) result)
  -> ?resume:execution_locator
  -> unit
  -> execution_store

(** Advanced host-driven execution.  The regular {!run}, {!run_blocks}, and
    streaming entry points remain the simple run-to-completion API. *)
module Advanced : sig
  type tool_boundary =
    { turn : int
    ; checkpoint_stage : checkpoint_stage
    }

  type boundary_decision =
    | Continue
    | Yield

  type yielded =
    { turn : int
    ; checkpoint_stage : checkpoint_stage
    ; checkpoint : Checkpoint.t
    }

  type terminal_tool_completed =
    { turn : int
    ; receipt : Terminal_tool_receipt.t
    ; checkpoint : Checkpoint.t
    }

  type run_outcome =
    | Completed of Types.api_response
    | Yielded of yielded
    | Terminal_tool_completed of terminal_tool_completed

  (** Run from one caller-authored input until terminal completion or until
      [on_tool_boundary] requests a cooperative yield.

      The callback is evaluated only after all tool executions for the turn,
      optional context injection, and the final configured checkpoint-sink
      call have succeeded.  [checkpoint_stage] identifies that typed boundary.
      When no checkpoint sink is configured, crossing the stage is an in-memory
      boundary and does not claim durable persistence.

      The callback runs synchronously on the agent fiber and should only inspect
      host state and return a decision; blocking work belongs after a [Yielded]
      return.

      [on_yield] and [on_resume] preserve the regular run API's provider-lease
      callbacks and must be supplied together or both omitted.  When
      [agent_config.yield_on_tool] is enabled, [on_yield] runs after assistant
      collection and its checkpoint have succeeded but before tool execution.
      [on_tool_boundary] remains after tool execution, optional context
      injection, and the final checkpoint sink. [Continue] invokes [on_resume]
      before the next provider turn; [Yield] returns with the lease released
      and does not invoke [on_resume] in this call.

      [Yielded] is a successful host outcome: it is not an SDK error, does not
      consume or enforce a turn/time/cost budget, and leaves the agent lifecycle
      [Ready].  Its [checkpoint] is captured only after the callback chooses
      [Yield], avoiding checkpoint-copy overhead on [Continue]. *)
  val run_blocks_detailed
    :  sw:Eio.Switch.t
    -> ?clock:_ Eio.Time.clock
    -> ?on_yield:(unit -> unit)
    -> ?on_resume:(unit -> unit)
    -> ?execution_store:execution_store
    -> api_strategy:api_strategy
    -> on_tool_boundary:(tool_boundary -> boundary_decision)
    -> t
    -> Types.content_block list
    -> (run_outcome, detailed_error) result

  (** Exact error projection of {!run_blocks_detailed}. *)
  val run_blocks
    :  sw:Eio.Switch.t
    -> ?clock:_ Eio.Time.clock
    -> ?on_yield:(unit -> unit)
    -> ?on_resume:(unit -> unit)
    -> ?execution_store:execution_store
    -> api_strategy:api_strategy
    -> on_tool_boundary:(tool_boundary -> boundary_decision)
    -> t
    -> Types.content_block list
    -> (run_outcome, Error.sdk_error) result
end

(** Detailed counterpart of {!run}. *)
val run_detailed
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?on_yield:(unit -> unit)
  -> ?on_resume:(unit -> unit)
  -> ?execution_store:execution_store
  -> t
  -> string
  -> (Types.api_response, detailed_error) result

(** Run the agent until a provider returns a terminal response or a typed error.
    The tool loop is unbounded: OAS does not stop it because of turn count,
    idle-turn count, tool-round count, accumulated cost, or token usage. Those
    values are observations only.

    The caller owns the lifetime of the run through Eio structured
    concurrency. Use a caller-owned child switch or cancellation scope to stop
    one run without cancelling unrelated lanes, and wrap that scope in an
    objective deadline when a whole-run timeout is required. Supplying [clock]
    does not create such a deadline; it supplies time to periodic callbacks and
    to explicitly configured provider body or stream-idle timeouts.
    Caller-initiated [Eio.Cancel.Cancelled] propagates and is not converted into
    an agent result.

    [on_yield] is called after a non-empty tool batch and the collected
    assistant checkpoint have been validated, immediately before the first
    tool hook or implementation starts. [on_resume] is called before the next
    LLM turn, allowing callers to release/re-acquire provider capacity. They
    must be supplied together or both omitted and are invoked only when
    [agent_config.yield_on_tool = true].
    @since 0.100.0 *)
val run
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?on_yield:(unit -> unit)
  -> ?on_resume:(unit -> unit)
  -> ?execution_store:execution_store
  -> t
  -> string
  -> (Types.api_response, Error.sdk_error) result

(** Run agent to completion with a user-authored content block list.
    This is the multimodal entrypoint for callers that need to pass text
    together with images, documents, or audio. Text blocks are UTF-8 sanitized;
    non-text media payloads are preserved. *)
val run_blocks
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?on_yield:(unit -> unit)
  -> ?on_resume:(unit -> unit)
  -> ?execution_store:execution_store
  -> t
  -> Types.content_block list
  -> (Types.api_response, Error.sdk_error) result

(** Detailed counterpart of {!run_blocks}. *)
val run_blocks_detailed
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?on_yield:(unit -> unit)
  -> ?on_resume:(unit -> unit)
  -> ?execution_store:execution_store
  -> t
  -> Types.content_block list
  -> (Types.api_response, detailed_error) result

(** Stream a full agent run. Non-fatal exceptions raised by [on_event] are
    logged and do not abort the run. *)
val run_stream
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> on_event:(Types.sse_event -> unit)
  -> ?on_yield:(unit -> unit)
  -> ?on_resume:(unit -> unit)
  -> ?execution_store:execution_store
  -> t
  -> string
  -> (Types.api_response, Error.sdk_error) result

(** Detailed counterpart of {!run_stream}. *)
val run_stream_detailed
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> on_event:(Types.sse_event -> unit)
  -> ?on_yield:(unit -> unit)
  -> ?on_resume:(unit -> unit)
  -> ?execution_store:execution_store
  -> t
  -> string
  -> (Types.api_response, detailed_error) result

(** Stream a full agent run with a user-authored content block list.
    See {!run_blocks}. *)
val run_stream_blocks
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> on_event:(Types.sse_event -> unit)
  -> ?on_yield:(unit -> unit)
  -> ?on_resume:(unit -> unit)
  -> ?execution_store:execution_store
  -> t
  -> Types.content_block list
  -> (Types.api_response, Error.sdk_error) result

(** Detailed counterpart of {!run_stream_blocks}. *)
val run_stream_blocks_detailed
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> on_event:(Types.sse_event -> unit)
  -> ?on_yield:(unit -> unit)
  -> ?on_resume:(unit -> unit)
  -> ?execution_store:execution_store
  -> t
  -> Types.content_block list
  -> (Types.api_response, detailed_error) result

(** Stream one agent turn. Non-fatal exceptions raised by [on_event] are
    logged and do not abort the turn. *)
val run_turn_stream
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> on_event:(Types.sse_event -> unit)
  -> ?on_telemetry:(Llm_provider.Telemetry_event.t -> unit)
  -> ?execution_store:execution_store
  -> t
  -> ( [ `Complete of Types.api_response
       | `TerminalToolCompleted of Terminal_tool_receipt.t
       | `ToolsExecuted
       ]
       , Error.sdk_error )
       result

(** Detailed counterpart of {!run_turn_stream}. *)
val run_turn_stream_detailed
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> on_event:(Types.sse_event -> unit)
  -> ?on_telemetry:(Llm_provider.Telemetry_event.t -> unit)
  -> ?execution_store:execution_store
  -> t
  -> ( [ `Complete of Types.api_response
       | `TerminalToolCompleted of Terminal_tool_receipt.t
       | `ToolsExecuted
       ]
       , detailed_error )
       result

(** Append an elicitation response to the agent conversation so callers that
    received {!Error.InputRequired} can resume with {!run_turn_stream} or an
    equivalent turn driver. [Declined] and [Timeout] preserve the legacy
    callback behavior and do not append a synthetic user message. *)
val provide_input : t -> Error.input_required -> Hooks.elicitation_response -> unit

(** {1 Handoff} *)

val run_with_handoffs
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?execution_store:execution_store
  -> t
  -> targets:Handoff.handoff_target list
  -> string
  -> (Types.api_response, Error.sdk_error) result

(** Detailed counterpart of {!run_with_handoffs}. *)
val run_with_handoffs_detailed
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?execution_store:execution_store
  -> t
  -> targets:Handoff.handoff_target list
  -> string
  -> (Types.api_response, detailed_error) result

val run_with_handoffs_blocks
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?execution_store:execution_store
  -> t
  -> targets:Handoff.handoff_target list
  -> Types.content_block list
  -> (Types.api_response, Error.sdk_error) result

(** Detailed counterpart of {!run_with_handoffs_blocks}. *)
val run_with_handoffs_blocks_detailed
  :  sw:Eio.Switch.t
  -> ?clock:_ Eio.Time.clock
  -> ?execution_store:execution_store
  -> t
  -> targets:Handoff.handoff_target list
  -> Types.content_block list
  -> (Types.api_response, detailed_error) result

(** {1 Checkpoint / Resume} *)

(** [resume ... ?checkpoint_sink ()] restores messages, usage, turn count, and
    the default context from a checkpoint. If [config] is supplied, it is the
    complete caller-owned runtime configuration. Otherwise, configuration fields
    represented by the checkpoint are restored over current defaults, and
    non-persisted runtime fields use those defaults. The optional sink is the same caller-owned
    turn-boundary checkpoint sink used by {!create}. It is not stored in
    {!options}; pass it explicitly when resumed turns should continue emitting
    crash-recovery checkpoints. [options.provider_config] uses the same
    exact-carrier contract as {!create}.
    [context_fit_admission], [model_input_projection], and
    [pre_dispatch_serialization_observer] must be supplied again when a resumed
    Agent should retain opt-in provider-fit enforcement, caller-owned
    provider-message projection, and pre-dispatch serialization evidence. *)
val resume
  :  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> checkpoint:Checkpoint.t
  -> ?tools:Tool.t list
  -> ?context:Context.t
  -> ?options:options
  -> ?context_fit_admission:context_fit_admission
  -> ?model_input_projection:model_input_projection
  -> ?pre_dispatch_serialization_observer:pre_dispatch_serialization_observer
  -> ?checkpoint_sink:checkpoint_sink
  -> ?config:Types.agent_config
  -> unit
  -> t

val checkpoint : ?session_id:string -> ?working_context:Yojson.Safe.t -> t -> Checkpoint.t

(** {1 Lifecycle} *)

val last_raw_trace_run : t -> Raw_trace.run_ref option
val close : t -> unit
val lifecycle_snapshot : t -> lifecycle_snapshot option

(** {1 Internal (testing only -- do not use in production code)} *)

val set_state : t -> Types.agent_state -> unit
val update_state : t -> (Types.agent_state -> Types.agent_state) -> unit

val set_lifecycle
  :  t
  -> ?current_run_id:string
  -> ?worker_id:string
  -> ?runtime_actor:string
  -> ?last_error:string
  -> ?accepted_at:float
  -> ?ready_at:float
  -> ?first_progress_at:float
  -> ?started_at:float
  -> ?last_progress_at:float
  -> ?finished_at:float
  -> Agent_lifecycle.lifecycle_status
  -> unit

val base_messages : t -> Types.message list

(** Dump the agent's Durable_event journal to [path] as JSONL.
    Returns [Error "no journal"] when the agent was built without
    {!Builder.with_journal}.  Thin wrapper over
    {!Durable_event.save_to_file}.
    @since 0.135.0 *)
val save_journal : t -> string -> (unit, string) result
