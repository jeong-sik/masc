(** Observability-as-default tests.

    Covers the three guarantees added with the default-on event bus:
    1. [Builder.build] installs a per-agent {!Event_bus.t} without the caller
       opting in (default-on).
    2. [Builder.without_event_bus] clears it (opt-out).
    3. The turn pipeline publishes an {!Event_bus.InferenceTelemetry} event for
       each completed turn onto that default bus, carrying the provider, turn,
       model, token counts, and decode timings reported for the call. *)

open Agent_sdk

(* The agent's exact provider config selects [OpenAI_compat], so
   [Complete_common.patch_telemetry] stamps the response telemetry with that kind.
   The producer therefore emits [provider = "openai_compat"] regardless of the
   value the mock transport sets, which is what the emit test asserts. *)
let mock_provider =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~provider_id:"test"
    ~api_key:""
    ~headers:[ "Content-Type", "application/json" ]
    ~request_path:"/v1/chat/completions"
    ~base_url:"http://mock.local"
    ~model_id:"mock-model"
    ()
;;

(* A completed-turn response carrying usage and llama-server-style timings.
   [patch_telemetry] preserves [usage] and [timings] while overwriting
   [provider_kind], so these token/timing values survive to the producer and
   are the non-vacuous core of the emit assertion. *)
let response_with_telemetry : Types.api_response =
  { id = "obs-1"
  ; model = "mock-model"
  ; stop_reason = Types.EndTurn
  ; content = [ Types.Text "ok" ]
  ; usage =
      Some
        { Types.input_tokens = 11
        ; output_tokens = 22
        ; cache_creation_input_tokens = 0
        ; cache_read_input_tokens = 0
        ; cost_usd = None
        }
  ; telemetry =
      Some
        { Types.default_inference_telemetry with
          timings =
            Some
              { Types.prompt_n = Some 11
              ; prompt_ms = Some 12.0
              ; prompt_per_second = None
              ; predicted_n = Some 22
              ; predicted_ms = Some 34.0
              ; predicted_per_second = Some 81.5
              ; cache_n = None
              }
        ; provider_kind = Some Llm_provider.Provider_kind.OpenAI_compat
        }
  }
;;

let build_or_fail b =
  match Builder.build_safe b with
  | Ok agent -> agent
  | Error err -> Alcotest.fail ("build_safe failed: " ^ Error.to_string err)
;;

let sample_telemetry : Types.inference_telemetry =
  { Types.default_inference_telemetry with
    timings =
      Some
        { Types.prompt_n = Some 11
        ; prompt_ms = Some 12.0
        ; prompt_per_second = None
        ; predicted_n = Some 22
        ; predicted_ms = Some 34.0
        ; predicted_per_second = Some 81.5
        ; cache_n = None
        }
  ; provider_kind = Some Llm_provider.Provider_kind.OpenAI_compat
  }
;;

let sample_usage : Types.api_usage =
  { input_tokens = 11
  ; output_tokens = 22
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 0
  ; cost_usd = None
  }
;;

(* Turn 1: the model interleaves a Thinking block before a ToolUse block. OAS
   must preserve that order in the assembled assistant message so a downstream
   renderer (MASC) can show Thinking → Tool in sequence. *)
let thinking_then_tool_response : Types.api_response =
  { id = "obs-tool-1"
  ; model = "mock-model"
  ; stop_reason = Types.StopToolUse
  ; content =
      [ Types.Thinking { signature = None; content = "I should check the time" }
      ; Types.ToolUse
          { id = "call_1"
          ; name = "get_time"
          ; input = `Assoc [ "timezone", `String "UTC" ]
          }
      ]
  ; usage = Some sample_usage
  ; telemetry = Some sample_telemetry
  }
;;

let final_text_response : Types.api_response =
  { id = "obs-tool-2"
  ; model = "mock-model"
  ; stop_reason = Types.EndTurn
  ; content = [ Types.Text "it is 12:00 UTC" ]
  ; usage = Some sample_usage
  ; telemetry = Some sample_telemetry
  }
;;

let get_time_tool =
  Tool.create
    ~name:"get_time"
    ~description:"Get current time"
    ~parameters:
      [ { name = "timezone"
        ; param_type = Types.String
        ; description = "tz"
        ; required = true
        }
      ]
    (fun _input -> Ok { Types.content = "12:00 UTC"; _meta = None })
;;

let sequence_transport responses : Llm_provider.Llm_transport.t =
  let remaining = ref responses in
  let next () =
    match !remaining with
    | r :: rest ->
      remaining := rest;
      r
    | [] -> Alcotest.fail "mock transport exhausted"
  in
  { complete_sync =
      (fun _req ->
        { Llm_provider.Llm_transport.response = Ok (next ()); latency_ms = Some 0 })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _req -> Ok (next ()))
  }
;;

let first_index pred xs =
  let rec loop i = function
    | [] -> None
    | x :: rest -> if pred x then Some i else loop (i + 1) rest
  in
  loop 0 xs
;;

let test_builder_default_on_event_bus () =
  Eio_main.run
  @@ fun env ->
  let agent =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> build_or_fail
  in
  Alcotest.(check bool)
    "Builder installs a default event bus"
    true
    (Option.is_some (Agent.options agent).event_bus)
;;

let test_builder_without_event_bus_opts_out () =
  Eio_main.run
  @@ fun env ->
  let agent =
    Builder.create ~net:env#net ~model:(Types.default_config ~model:"test-model").model
    |> Builder.without_event_bus
    |> build_or_fail
  in
  Alcotest.(check bool)
    "without_event_bus clears the default bus"
    true
    (Option.is_none (Agent.options agent).event_bus)
;;

let test_pipeline_emits_inference_telemetry_on_default_bus () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let transport = sequence_transport [ response_with_telemetry ] in
  (* Build through the default-on path and pull the bus the Builder created, so
     this also proves the producer publishes onto the *default* bus. *)
  let agent =
    Builder.create ~net ~model:"mock-model"
    |> Builder.with_name "obs-emit"
    |> Builder.with_provider_config mock_provider
    |> Builder.with_transport transport
    |> build_or_fail
  in
  let event_bus =
    match (Agent.options agent).event_bus with
    | Some bus -> bus
    | None -> Alcotest.fail "expected default-on event bus on the built agent"
  in
  let config =
    Event_bus.subscription_config ~capacity:32 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let sub = Event_bus.subscribe ~config event_bus in
  (match Agent.run ~sw agent "trigger a turn" with
   | Ok _ -> ()
   | Error err -> Alcotest.fail ("expected run success: " ^ Error.to_string err));
  (* [InferenceTelemetry] is an inline-record constructor, so its value cannot
     escape the match arm; project the fields into a plain tuple instead. *)
  let telemetry =
    Event_bus.drain sub
    |> List.map (fun event -> event.Event_bus.payload)
    |> List.find_map (function
      | Event_bus.InferenceTelemetry r ->
        Some
          ( r.provider
          , r.turn
          , r.model
          , r.prompt_tokens
          , r.completion_tokens
          , r.prompt_ms
          , r.decode_ms
          , r.decode_tok_s )
      | _ -> None)
  in
  match telemetry with
  | None -> Alcotest.fail "expected an InferenceTelemetry event"
  | Some
      ( provider
      , turn
      , model
      , prompt_tokens
      , completion_tokens
      , prompt_ms
      , decode_ms
      , decode_tok_s ) ->
    Alcotest.(check string) "provider" "openai_compat" provider;
    Alcotest.(check int) "turn" 0 turn;
    Alcotest.(check string) "model" "mock-model" model;
    Alcotest.(check (option int)) "prompt_tokens" (Some 11) prompt_tokens;
    Alcotest.(check (option int)) "completion_tokens" (Some 22) completion_tokens;
    Alcotest.(check (option (float 0.001))) "prompt_ms" (Some 12.0) prompt_ms;
    Alcotest.(check (option (float 0.001))) "decode_ms" (Some 34.0) decode_ms;
    Alcotest.(check (option (float 0.001))) "decode_tok_s" (Some 81.5) decode_tok_s
;;

(* The adversarial core of the observability pillar: with only a Builder (no
   explicit bus wiring), a tool-using multi-turn run must surface Tools and
   Turns on the default bus in causal order, and OAS must preserve the
   Thinking → Tool interleaving order in the assembled assistant message. This
   is "Tools observed by default — verified, not claimed". *)
let test_tools_turns_and_interleaving_observed_by_default () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let transport =
    sequence_transport [ thinking_then_tool_response; final_text_response ]
  in
  let agent =
    Builder.create ~net ~model:"mock-model"
    |> Builder.with_name "obs-tools"
    |> Builder.with_provider_config mock_provider
    |> Builder.with_transport transport
    |> Builder.with_tool get_time_tool
    |> build_or_fail
  in
  let event_bus =
    match (Agent.options agent).event_bus with
    | Some bus -> bus
    | None -> Alcotest.fail "expected default-on event bus on the built agent"
  in
  let config =
    Event_bus.subscription_config ~capacity:32 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let sub = Event_bus.subscribe ~config event_bus in
  (match Agent.run ~sw agent "what time is it?" with
   | Ok _ -> ()
   | Error err -> Alcotest.fail ("expected run success: " ^ Error.to_string err));
  let kinds =
    Event_bus.drain sub
    |> List.map (fun event -> Event_bus.payload_kind event.Event_bus.payload)
  in
  (* Tools observed by default, in causal order (call before completion). *)
  let idx k = first_index (String.equal k) kinds in
  (match idx "tool_called", idx "tool_completed" with
   | Some called, Some completed ->
     Alcotest.(check bool) "tool_called precedes tool_completed" true (called < completed)
   | _ ->
     Alcotest.failf
       "expected tool_called and tool_completed on the default bus; saw [%s]"
       (String.concat "; " kinds));
  (* Turn and per-call telemetry observed by default. *)
  Alcotest.(check bool) "turn_completed observed" true (List.mem "turn_completed" kinds);
  Alcotest.(check bool)
    "inference_telemetry observed"
    true
    (List.mem "inference_telemetry" kinds);
  (* Interleaving exposure: the assistant message that carries the tool call
     must keep Thinking before ToolUse so a renderer can reproduce the order. *)
  let assistant_with_tool =
    List.find_opt
      (fun (m : Types.message) ->
         m.role = Types.Assistant
         && List.exists
              (function
                | Types.ToolUse _ -> true
                | _ -> false)
              m.content)
      (Agent.state agent).messages
  in
  match assistant_with_tool with
  | None -> Alcotest.fail "expected an assistant message carrying the tool call"
  | Some m ->
    let thinking_at =
      first_index
        (function
          | Types.Thinking _ -> true
          | _ -> false)
        m.content
    in
    let tool_at =
      first_index
        (function
          | Types.ToolUse _ -> true
          | _ -> false)
        m.content
    in
    (match thinking_at, tool_at with
     | Some t, Some u ->
       Alcotest.(check bool) "Thinking precedes ToolUse (interleaving order)" true (t < u)
     | _ -> Alcotest.fail "expected both Thinking and ToolUse in the assistant message")
;;

let () =
  Alcotest.run
    "Observability default"
    [ ( "builder"
      , [ Alcotest.test_case
            "default-on installs event bus"
            `Quick
            test_builder_default_on_event_bus
        ; Alcotest.test_case
            "without_event_bus opts out"
            `Quick
            test_builder_without_event_bus_opts_out
        ] )
    ; ( "pipeline"
      , [ Alcotest.test_case
            "emits InferenceTelemetry on default bus"
            `Quick
            test_pipeline_emits_inference_telemetry_on_default_bus
        ; Alcotest.test_case
            "tools, turns, and interleaving observed by default"
            `Quick
            test_tools_turns_and_interleaving_observed_by_default
        ] )
    ]
;;
