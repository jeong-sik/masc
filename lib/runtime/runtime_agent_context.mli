(** Shared MASC-owned configuration and OAS assembly. *)

type stop_reason =
  | Completed
  | Yielded_to_chat_waiting of { turns_used : int }
  | Yielded_to_durable_stimulus of { turns_used : int }
  | InputRequired of
      { turns_used : int
      ; request : Agent_sdk.Error.input_required
      }

type config =
  { name : string
  ; provider_cfg : Llm_provider.Provider_config.t
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
  ; stream_idle_timeout_s : float option
  ; body_timeout_s : float option
  ; hooks : Agent_sdk.Hooks.hooks option
  ; event_bus : Agent_sdk.Event_bus.t option
  ; session_id : string option
  ; description : string option
  ; initial_messages : Agent_sdk.Types.message list
  ; raw_trace : Agent_sdk.Raw_trace.t option
  ; trace_link : (string * string) option
  ; transport : Masc_grpc_transport.t
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; yield_on_tool : bool
  ; context_injector : Agent_sdk.Hooks.context_injector option
  ; context : Agent_sdk.Context.t option
  ; on_run_complete : (bool -> unit) option
  ; checkpoint_sink : Agent_sdk.Agent.checkpoint_sink option
  }

val default_config :
  name:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  config

val builder :
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  ?transport:Llm_provider.Llm_transport.t ->
  unit ->
  Agent_sdk.Builder.t

type prepared_resume =
  { options : Agent_sdk.Agent.options }

val set_oas_tracer : Agent_sdk.Tracing.t -> unit

val prepare_resume :
  config:config ->
  checkpoint:Agent_sdk.Checkpoint.t ->
  (prepared_resume, Agent_sdk.Error.sdk_error) result
(** Validates that the selected typed provider still names the checkpoint's
    exact model. The checkpoint itself remains the sole source of restored
    conversation and inference configuration. *)
