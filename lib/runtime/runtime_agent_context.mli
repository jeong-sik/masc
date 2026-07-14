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
  | TurnLimitObserved of { turns_used : int; limit : int }
  | ExecutionTimeoutObserved of {
      elapsed_sec : float;
      timeout_sec : float;
      turn_count : int;
      max_turns : int;
    }
  | ExecutionIdleTimeoutObserved of {
      idle_sec : float;
      idle_timeout_sec : float;
      turn_count : int;
      max_turns : int;
    }
  | Yielded_to_chat_waiting of { turns_used : int }
  | Yielded_to_durable_stimulus of { turns_used : int }
  | InputRequired of {
      turns_used : int;
      request : Agent_sdk.Error.input_required;
    }

(** {1 Per-worker config} *)

type config = {
  name : string;
  provider_cfg : Llm_provider.Provider_config.t;
  model_id : string;
  system_prompt : string;
  tools : Agent_sdk.Tool.t list;
  max_turns : int;
  max_idle_turns : int;
  stream_idle_timeout_s : float option;
  max_execution_time_s : float option;
      (** Wall-clock ceiling for one [Agent.run] / [run_stream] call.
          When [Some] AND a clock is available, agent_sdk returns
          [Retry.Timeout] after [s] seconds. Default [None] preserves
          historical block-on-hang behaviour. *)
  body_timeout_s : float option;
      (** Total HTTP body-consumption ceiling forwarded to OAS
          [Builder.with_body_timeout] for non-streaming completion paths.
          Streaming paths deliberately ignore this knob so active long
          streams are not killed by total duration; streaming liveness is
          owned by [stream_idle_timeout_s] and the attempt liveness
          observer. Non-HTTP transports ignore it. *)
  max_tokens : int option;
      (** Request-time output token budget. [None] means no [max_tokens]
          field goes on the request at all — the keeper lane's default
          (masc#24067 / oas#2517): the OAS capability catalog ceiling is a
          validation bound, never a synthesized request value. [Some n] is
          an explicit operator/profile override or a non-keeper caller's
          deliberate request budget. *)
  temperature : float option;
      (** Exact caller/model sampling declaration. [None] omits temperature and
          leaves the selected provider's default intact. *)
  hooks : Agent_sdk.Hooks.hooks option;
  event_bus : Agent_sdk.Event_bus.t option;
  session_id : string option;
  description : string option;
  initial_messages : Agent_sdk.Types.message list;
  model_input_projection
      : (Agent_sdk.Types.message list -> Agent_sdk.Types.message list) option;
  raw_trace : Agent_sdk.Raw_trace.t option;
  trace_link : (string * string) option;
  enable_thinking : bool option;
  preserve_thinking : bool option;
  transport : Masc_grpc_transport.t;
  allowed_paths : string list;
  checkpoint_sidecar : Yojson.Safe.t option;
  cache_system_prompt : bool;
  yield_on_tool : bool;
  context_injector : Agent_sdk.Hooks.context_injector option;
  context : Agent_sdk.Context.t option;
  approval : Agent_sdk.Hooks.approval_callback option;
  exit_condition : (int -> bool) option;
  exit_condition_result : (int -> stop_reason * string option) option;
  thinking_budget : int option;
      (** Token budget for extended thinking, forwarded to OAS
          [Builder.with_thinking_budget]. Only meaningful when
          [enable_thinking = Some true]. *)
  top_p : float option;
      (** Nucleus sampling probability forwarded to OAS [Builder.with_top_p].
          [None] leaves the provider/model default intact. *)
  top_k : int option;
      (** Top-k sampling limit forwarded to OAS [Builder.with_top_k].
          [None] leaves the provider/model default intact. *)
  min_p : float option;
      (** Minimum probability threshold for nucleus sampling, forwarded
          to OAS [Builder.with_min_p]. [None] leaves the provider default
          intact; [Some 0.0] is a no-op and some providers (Groq, GLM)
          reject the field, so leave [None] unless explicitly needed. *)
  on_run_complete : (bool -> unit) option;
  checkpoint_sink : Agent_sdk.Agent.checkpoint_sink option;
}
(** Per-worker configuration.  60 fields — concrete record because
    callers ({!Runtime_agent}, keeper workers) construct + tweak
    fields field-by-field at the dispatch site. *)

(** {1 Default config builder} *)

val unbounded_max_turns : int
(** The pinned SDK's documented "no turn-count limit" sentinel ([0],
    agent_sdk lib/base/types.mli); the value
    {!Agent_sdk.Types.has_finite_max_turns} tests against. The SDK
    exports the predicate but no named constant, so masc names it here
    (masc#24391 layer 2). *)

val default_config :
  name:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  config
(** [default_config ~name ~provider_cfg ~system_prompt ~tools]
    returns a {!config} populated with sensible defaults for every
    field except the four required ones.  Caller mutates fields
    in place via record copy ([{ cfg with ... }]) before passing
    to {!builder_without_approval} or {!prepare_resume}. *)

(** {1 Builder (no approval)} *)

val builder_without_approval :
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  ?transport:Llm_provider.Llm_transport.t ->
  unit ->
  Agent_sdk.Builder.t
(** [builder_without_approval ~net ~config ?transport ()] builds an
    {!Agent_sdk.Builder.t} from [config] without wiring approval
    callbacks.  Approval wiring is the responsibility of the
    public facade ({!Runtime_agent}) which adds the approval
    callback before calling [Builder.build_safe]. *)

(** {1 Resume preparation} *)

type prepared_resume = {
  patched_checkpoint : Agent_sdk.Checkpoint.t;
  agent_config : Agent_sdk.Types.agent_config;
  options : Agent_sdk.Agent.options;
}
(** Output of {!prepare_resume}.  [patched_checkpoint] has
    runtime identity fields adjusted, and [agent_config.max_turns]
    preserves [0] as unbounded; otherwise it is extended past the checkpoint
    [turn_count] so resume picks up where the previous run left off without
    re-counting consumed turns. *)

val set_oas_tracer : Agent_sdk.Tracing.t -> unit
(** Set the OAS tracer used by {!builder_without_approval}.  Called once
    at server bootstrap so OAS spans flow to the same OTLP collector as
    MASC-native telemetry.  Defaults to [Tracing.null] until set. *)

val prepare_resume :
  config:config -> checkpoint:Agent_sdk.Checkpoint.t -> prepared_resume
(** [prepare_resume ~config ~checkpoint] computes the patched
    checkpoint + agent_config + options for an
    [Agent.resume] call.  Pure — no side effects.  The patched
    agent config preserves {!unbounded_max_turns}; otherwise it
    extends [config.max_turns] beyond the consumed [checkpoint.turn_count] for
    generic finite OAS clients. Keeper callers use the unbounded sentinel. *)
