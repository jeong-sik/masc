(** MASC Agent Core

    A type-safe, Eio-based execution engine embedded in MASC.

    Example usage (the same provider wiring is compiled by
    [examples/basic_agent.ml]):
    {[
      open Agent_core

      let weather_tool = Tool.create
        ~name:"get_weather"
        ~description:"Get weather for a location"
        ~parameters:[{
          Types.name = "location"; description = "City name";
          param_type = String; required = true;
        }]
        (fun input ->
           let loc = Yojson.Safe.Util.(input |> member "location" |> to_string) in
           Ok { Types.content = Printf.sprintf "Weather in %s: Sunny, 22C" loc; content_blocks = None; _meta = None })

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
          ~media_store:(History.Memory_store.create ())
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
module Version = Version

(** Wrapped namespaces for the underlying libraries. *)
module Base = Agent_core_base

module Llm_provider = Llm_provider
module Result_syntax = Agent_core_base.Result_syntax
module Types = Agent_core_base.Types
module History = Agent_core_base.History
module Util = Agent_core_base.Util
module Fs_result = Fs_result
module Context = Agent_core_base.Context
module Provider_runtime_binding = Provider_runtime_binding
module Exact_output = Llm_provider.Exact_output
module Binding_identity = Binding_identity
module Provider_failure_attribution = Provider_failure_attribution
module Retry = Llm_provider.Retry
module Error = Agent_core_base.Error
module Agent_input_request = Agent_core_base.Agent_input_request
module Error_domain = Error_domain
module Hooks = Agent_core_base.Hooks
module Tracing = Tracing
module Tool_contract = Agent_core_base.Tool_contract
module Execution_json = Execution_json
module Execution_tool_schedule = Execution_tool_schedule
module Tool = Agent_core_base.Tool
module Mcp = Mcp
module Mcp_http = Mcp_http
module Mcp_session = Mcp_session
module Telemetry_event = Llm_provider.Telemetry_event
module Response_shape = Llm_provider.Response_shape
module Canonical_tool = Llm_provider.Canonical_tool
module Tool_set = Tool_set
module Log = Log
module Caller_scope = Caller_scope
module Event_envelope = Event_envelope
module Event_bus = Event_bus
module Telemetry_bus = Telemetry_bus
module Skill_document = Skill_document
module Skill_registry = Skill_registry
module Structured = Structured
module Checkpoint = Checkpoint
module Checkpoint_snapshot = Checkpoint_snapshot
module Checkpoint_objects = Checkpoint_objects
module Session = Session
module Raw_trace = Raw_trace
module Raw_trace_query = Raw_trace_query
module Handoff = Handoff
module Agent_types = Agent_types
module Agent_lifecycle = Agent_lifecycle
module Agent_lifecycle_events = Agent_lifecycle_events
module Agent_turn = Agent_turn
module Agent_tools = Agent_tools
module Agent_tool_pre_execution_gate = Agent_tool_pre_execution_gate
module Agent_checkpoint = Agent_checkpoint
module Terminal_tool_receipt = Terminal_tool_receipt
module Agent = Agent
module Agent_card = Agent_card
module Tool_guidance_text = Tool_guidance_text
module Otel_tracer = Otel_tracer
module Otel_export = Otel_export
module Runtime = Runtime
module Sessions = Sessions
module Sessions_store = Sessions_store
module Harness = Harness
module Trajectory = Trajectory
module Metrics = Metrics
module Async_agent = Async_agent
module Consumer = Consumer
module Eval_stats = Eval_stats
module Runtime_store = Runtime_store
module Tool_input_validation = Tool_input_validation

(* runtime_query/query removed — CLI Runtime purge *)

(** Version info *)
let version = Version.version

let name = Version.name
