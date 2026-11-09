(** Observability tests.

    The turn pipeline publishes an {!Event_bus.InferenceTelemetry} event for
    each completed turn onto the agent's {!Event_bus.t}, carrying the provider,
    turn, model, token counts, and decode timings reported for the call. A
    tool-using run surfaces the tool and turn events in causal order. *)

open Agent_core

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
  ; unreadable_tool_uses = []
  ; stop_reason = Types.EndTurn
  ; content = [ Llm_provider.Types.Text "ok" ]
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

let make_agent ?tools ~net ~name ~event_bus ~transport () =
  let options =
    { Agent.default_options with
      provider_config = Some mock_provider
    ; transport = Some transport
    ; event_bus = Some event_bus
    }
  in
  Agent.create
    ~net
    ~media_store:(Agent_core.History.Memory_store.create ())
    ~config:{ (Types.default_config ~model:"mock-model") with name }
    ?tools
    ~options
    ()
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

(* Turn 1: the model interleaves a Thinking block before a ToolUse block. AGENT_CORE
   must preserve that order in the assembled assistant message so a downstream
   renderer (MASC) can show Thinking → Tool in sequence. *)
let thinking_then_tool_response : Types.api_response =
  { id = "obs-tool-1"
  ; model = "mock-model"
  ; unreadable_tool_uses = []
  ; stop_reason = Types.StopToolUse
  ; content =
      [ Llm_provider.Types.Thinking { signature = None; content = "I should check the time" }
      ; Llm_provider.Types.ToolUse
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
  ; unreadable_tool_uses = []
  ; stop_reason = Types.EndTurn
  ; content = [ Llm_provider.Types.Text "it is 12:00 UTC" ]
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
    (fun _input -> Ok { Types.content = "12:00 UTC"; content_blocks = None; _meta = None })
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
  Llm_provider.Llm_transport.custom ({ complete_sync =
      (fun _req ->
        { Llm_provider.Llm_transport.response = Ok (next ()); latency_ms = Some 0 })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _req -> Ok (next ()))
  })
;;

let first_index pred xs =
  let rec loop i = function
    | [] -> None
    | x :: rest -> if pred x then Some i else loop (i + 1) rest
  in
  loop 0 xs
;;

let test_pipeline_emits_inference_telemetry () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let transport = sequence_transport [ response_with_telemetry ] in
  let event_bus = Event_bus.create () in
  let agent = make_agent ~net ~name:"obs-emit" ~event_bus ~transport () in
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

(* The adversarial core of the observability pillar: a tool-using multi-turn
   run must surface Tools and Turns on the agent's bus in causal order, and
   AGENT_CORE must preserve the Thinking → Tool interleaving order in the
   assembled assistant message. *)
let test_tools_turns_and_interleaving_are_observed () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let transport =
    sequence_transport [ thinking_then_tool_response; final_text_response ]
  in
  let event_bus = Event_bus.create () in
  let agent =
    make_agent ~tools:[ get_time_tool ] ~net ~name:"obs-tools" ~event_bus ~transport ()
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
  (* Tools observed, in causal order (call before completion). *)
  let idx k = first_index (String.equal k) kinds in
  (match idx "tool_called", idx "tool_completed" with
   | Some called, Some completed ->
     Alcotest.(check bool) "tool_called precedes tool_completed" true (called < completed)
   | _ ->
     Alcotest.failf
       "expected tool_called and tool_completed on the bus; saw [%s]"
       (String.concat "; " kinds));
  (* Turn and per-call telemetry observed. *)
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
    "Observability"
    [ ( "pipeline"
      , [ Alcotest.test_case
            "emits InferenceTelemetry on the bus"
            `Quick
            test_pipeline_emits_inference_telemetry
        ; Alcotest.test_case
            "tools, turns, and interleaving are observed"
            `Quick
            test_tools_turns_and_interleaving_are_observed
        ] )
    ]
;;
