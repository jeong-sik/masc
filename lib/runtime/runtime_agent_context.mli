(** Runtime_agent_context — shared {!config} surface and agent
    assembly helpers.

    Owns the shared per-worker {!config} record + pure / defaulted
    preparation logic shared by both
    {!Runtime_agent.build} and
    {!Runtime_agent.resume_from_checkpoint}.
    {!Runtime_agent} remains the public facade and still
    performs the approval wiring and final
    [build_safe] / [Agent.resume] calls. *)

(** {1 Stop reason} *)

(** Why a worker run terminated. *)
type stop_reason =
  | Completed
  | Yielded_to_operation_queued of { turns_used : int }
  | Yielded_to_durable_stimulus of { turns_used : int }
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

(** {1 Per-worker config} *)

type config = {
  name : string;
  provider_cfg : Llm_provider.Provider_config.t;
  model_id : string;
  system_prompt : string;
  tools : Agent_core.Tool.t list;
  stream_idle_timeout_s : float option;
  first_event_timeout_s : float option;
      (** Bound on the silent wait for the FIRST streaming provider event
          (TTFT/prefill), forwarded to AGENT_CORE
          [Builder.with_first_event_timeout]. [stream_idle_timeout_s] arms
          only after that event; when [None], AGENT_CORE's resolver falls
          back to [body_timeout_s], then to [stream_idle_timeout_s]
          (RFC-AC-037). *)
  body_timeout_s : float option;
      (** Total HTTP body-consumption ceiling forwarded to AGENT_CORE
          [Builder.with_body_timeout] for non-streaming completion paths.
          Streaming paths deliberately ignore this knob so active long
          streams are not killed by total duration; streaming liveness is
          owned by [stream_idle_timeout_s] and the attempt liveness
          observer. Non-HTTP transports ignore it. *)
  max_tokens : int option;
      (** Caller-level output-token override. [None] adds no override, so an
          explicit [provider_cfg.max_tokens] remains authoritative; when both
          are absent no request field is synthesized from a capability
          ceiling. [Some n] is an operator/profile override or a non-keeper
          caller's deliberate request budget. *)
  temperature : float option;
      (** Exact caller/model sampling declaration. [None] omits temperature and
          leaves the selected provider's default intact. *)
  hooks : Agent_core.Hooks.hooks option;
  (* Settles a [pre_tool_use] hook that answers [ElicitToolApproval]. Absent
     means such a decision is rejected rather than admitted, so a turn with
     nobody watching does not run the call on its own. *)
  tool_approval : Agent_core.Hooks.tool_approval_callback option;
  event_bus : Agent_core.Event_bus.t option;
  session_id : string option;
  description : string option;
  runtime_id : string option;
  initial_messages : Agent_core.Types.message list;
  model_input_projection : Agent_core.Agent.model_input_projection option;
  pre_dispatch_serialization_observer :
    Agent_core.Agent.pre_dispatch_serialization_observer option;
      (** Observer for the exact serialized request body, invoked by AGENT_CORE after
          stream-field injection and after the serialized-body admission check.
          This is the only reading of the byte quantity admitted against
          [max_request_body_bytes]:
          [Keeper_context_core_accessors.serialize_context] covers
          [{system_prompt, messages}] and excludes tool schemas, and only a
          refused request reports its size today. Diagnostic and
          non-authoritative — a rejection or raised callback becomes typed
          failure evidence and does not rewrite the provider result. *)
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
      (** Token budget for extended thinking, forwarded to AGENT_CORE
          [Builder.with_thinking_budget]. Only meaningful when
          [enable_thinking = Some true]. *)
  top_p : float option;
      (** Nucleus sampling probability forwarded to AGENT_CORE [Builder.with_top_p].
          [None] leaves the provider/model default intact. *)
  top_k : int option;
      (** Top-k sampling limit forwarded to AGENT_CORE [Builder.with_top_k].
          [None] leaves the provider/model default intact. *)
  min_p : float option;
      (** Minimum probability threshold for nucleus sampling, forwarded
          to AGENT_CORE [Builder.with_min_p]. [None] leaves the provider default
          intact; [Some 0.0] is a no-op and some providers (Groq, GLM)
          reject the field, so leave [None] unless explicitly needed. *)
  on_run_complete : (bool -> unit) option;
  checkpoint_sink : Agent_core.Agent.checkpoint_sink option;
}
(** Per-worker configuration.  60 fields — concrete record because
    callers ({!Runtime_agent}, keeper workers) construct + tweak
    fields field-by-field at the dispatch site. *)

(** {1 Default config builder} *)

val default_config :
  name:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  config
(** [default_config ~name ~provider_cfg ~system_prompt ~tools]
    returns a {!config} populated with sensible defaults for every
    field except the four required ones.  Caller mutates fields
    in place via record copy ([{ cfg with ... }]) before passing
    to {!builder} or {!prepare_resume}. *)

(** {1 Builder} *)

val builder :
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  ?transport:Llm_provider.Llm_transport.t ->
  unit ->
  Agent_core.Builder.t
(** [builder ~net ~config ?transport ()] builds an {!Agent_core.Builder.t}
    from [config]. *)

val context_fit_admission
  :  Llm_provider.Provider_config.t
  -> Agent_core.Agent.context_fit_admission
(** Exact provider-fit policy shared by fresh and resumed agents. The AGENT_CORE
    provider capability SSOT decides whether native request measurement exists;
    unsupported providers retain compatibility dispatch. *)

(** {1 Resume preparation} *)

type prepared_resume = {
  patched_checkpoint : Agent_core.Checkpoint.t;
  agent_config : Agent_core.Types.agent_config;
  options : Agent_core.Agent.options;
  context_fit_admission : Agent_core.Agent.context_fit_admission;
}
(** Output of {!prepare_resume}. [patched_checkpoint] and [agent_config] use
    the same provider-base-plus-explicit-override resolution as a fresh
    builder. *)

val set_agent_core_tracer : Agent_core.Tracing.t -> unit
(** Set the AGENT_CORE tracer used by {!builder}.  Called once
    at server bootstrap so AGENT_CORE spans flow to the same OTLP collector as
    MASC-native telemetry.  Defaults to [Tracing.null] until set. *)

val prepare_resume :
  config:config -> checkpoint:Agent_core.Checkpoint.t -> prepared_resume
(** [prepare_resume ~config ~checkpoint] computes the patched checkpoint,
    agent config, and options for an [Agent.resume] call. Pure — no side
    effects. *)
