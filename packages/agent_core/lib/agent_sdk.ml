(** OCaml Agent SDK

    A type-safe, Eio-based single-provider agent runtime.

    Example usage (the same provider wiring is compiled by
    [examples/basic_agent.ml]):
    {[
      open Agent_sdk

      let weather_tool = Tool.create
        ~name:"get_weather"
        ~description:"Get weather for a location"
        ~parameters:[{
          Types.name = "location"; description = "City name";
          param_type = String; required = true;
        }]
        (fun input ->
           let loc = Yojson.Safe.Util.(input |> member "location" |> to_string) in
           Ok { Types.content = Printf.sprintf "Weather in %s: Sunny, 22C" loc; _meta = None })

      let () =
        Eio_main.run @@ fun env ->
        let net = Eio.Stdenv.net env in
        Eio.Switch.run @@ fun sw ->
        let provider_config =
          Llm_provider.Provider_config.make
            ~kind:Llm_provider.Provider_config.OpenAI_compat
            ~model_id:"qwen3.5"
            ~base_url:"http://127.0.0.1:8085"
            ()
        in
        let agent = Agent.create ~net
          ~config:{ (Types.default_config ~model:provider_config.model_id) with
            name = "weather-agent";
            system_prompt = Some "You are a helpful weather assistant.";
          }
          ~options:{ Agent.default_options with
            provider_config = Some provider_config;
          }
          ~tools:[weather_tool] () in
        match Agent.run ~sw agent "What's the weather in Seoul?" with
        | Ok response ->
            List.iter (function
              | Types.Text t -> print_endline t | _ -> ()) response.content
        | Error e -> prerr_endline ("Error: " ^ Error.to_string e)
    ]}
*)

(** Re-export all modules (dependency-safe order) *)
module Sdk_version = Sdk_version

(** Wrapped namespaces for the underlying libraries. *)
module Base = Agent_sdk_base

module Llm_provider = Llm_provider
module Result_syntax = Agent_sdk_base.Result_syntax
module Types = Agent_sdk_base.Types
module Util = Agent_sdk_base.Util
module Fs_result = Fs_result
module Fs_atomic_eio = Fs_atomic_eio
module Context = Agent_sdk_base.Context
module Provider_runtime_binding = Provider_runtime_binding
module Exact_output = Llm_provider.Exact_output
module Binding_identity = Binding_identity
module Provider_failure_attribution = Provider_failure_attribution
module Image_generation = Llm_provider.Image_generation
module Speech_generation = Llm_provider.Speech_generation
module Retry = Llm_provider.Retry
module Error = Agent_sdk_base.Error
module Error_domain = Error_domain
module Hooks = Agent_sdk_base.Hooks
module Tracing = Tracing
module Tool_contract = Agent_sdk_base.Tool_contract
module Tool = Agent_sdk_base.Tool
module Typed_tool = Typed_tool
module Mcp = Mcp
module Mcp_http = Mcp_http
module Mcp_session = Mcp_session
module Telemetry_event = Llm_provider.Telemetry_event
module Response_shape = Llm_provider.Response_shape
module Canonical_tool = Llm_provider.Canonical_tool
module Tool_set = Tool_set
module Log = Log
module Event_envelope = Event_envelope
module Event_bus = Event_bus
module Telemetry_bus = Telemetry_bus
module Skill = Skill
module Skill_registry = Skill_registry
module Contract = Contract
module Structured = Structured
module Checkpoint = Checkpoint
module Checkpoint_store = Checkpoint_store
module Session = Session
module Raw_trace = Raw_trace
module Raw_trace_query = Raw_trace_query
module Handoff = Handoff
module Agent_types = Agent_types
module Agent_lifecycle = Agent_lifecycle
module Agent_turn = Agent_turn
module Agent_tools = Agent_tools
module Agent_checkpoint = Agent_checkpoint
module Agent = Agent
module Builder = Builder
module Agent_card = Agent_card
module Agent_tool = Agent_tool
module Otel_tracer = Otel_tracer
module Otel_export = Otel_export
module Runtime = Runtime
module Artifact_service = Artifact_service
module Sessions = Sessions
module Sessions_store = Sessions_store
module Harness = Harness
module Eval = Eval
module Trajectory = Trajectory
module Tool_middleware = Tool_middleware
module Metrics = Metrics
module Async_agent = Async_agent
module Consumer = Consumer
module Guardrails_async = Guardrails_async
module Eval_stats = Eval_stats
module Runtime_store = Runtime_store
module Plan = Plan
module Tool_input_validation = Tool_input_validation
module Durable_event = Durable_event
module Journal_bridge = Journal_bridge

(* runtime_query/query removed — CLI Runtime purge *)

(** Version info *)
let version = Sdk_version.version

let sdk_name = Sdk_version.sdk_name
