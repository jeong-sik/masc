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
  ; provider : Agent_sdk.Provider.config
  ; model_id : string
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
  ; stream_idle_timeout_s : float option
  ; body_timeout_s : float option
  ; max_tokens : int option
  ; temperature : float
  ; hooks : Agent_sdk.Hooks.hooks option
  ; event_bus : Agent_sdk.Event_bus.t option
  ; checkpoint_dir : string option
  ; session_id : string option
  ; description : string option
  ; initial_messages : Agent_sdk.Types.message list
  ; raw_trace : Agent_sdk.Raw_trace.t option
  ; trace_link : (string * string) option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; transport : Masc_grpc_transport.t
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; context_injector : Agent_sdk.Hooks.context_injector option
  ; context : Agent_sdk.Context.t option
  ; thinking_budget : int option
  ; top_p : float option
  ; top_k : int option
  ; min_p : float option
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
  { patched_checkpoint : Agent_sdk.Checkpoint.t
  ; agent_config : Agent_sdk.Types.agent_config
  ; options : Agent_sdk.Agent.options
  }

val set_oas_tracer : Agent_sdk.Tracing.t -> unit

val prepare_resume :
  config:config -> checkpoint:Agent_sdk.Checkpoint.t -> prepared_resume
