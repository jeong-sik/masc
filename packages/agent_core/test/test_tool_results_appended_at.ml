(** RFC replayed-tool-results-carry-their-time, L2. A live turn stamps when
    its tool results entered the conversation, with the pipeline clock. The
    stamp survives a checkpoint and never reaches a provider request. The
    journal replay leaves it out; [test_pipeline] checks that case on its
    durable resume fixture. *)

open Agent_core

(* 2026-11-14T08:06:49.25Z. A quarter second keeps the value non-integral, so
   a checkpoint that turned it into an integer would fail the check. *)
let appended_at = 1_794_643_609.25

let classification =
  Alcotest.testable
    (fun fmt -> function
       | Types.Tool_results_appended_at.Absent -> Format.pp_print_string fmt "Absent"
       | Types.Tool_results_appended_at.Present at -> Format.fprintf fmt "Present %.17g" at
       | Types.Tool_results_appended_at.Invalid -> Format.pp_print_string fmt "Invalid"
       | Types.Tool_results_appended_at.Duplicate -> Format.pp_print_string fmt "Duplicate")
    Stdlib.( = )
;;

let classify (message : Types.message) =
  Types.Tool_results_appended_at.classify message.metadata
;;

(* ── Key module ──────────────────────────────────────── *)

let test_classify () =
  let open Types.Tool_results_appended_at in
  let stamped = entry ~appended_at in
  let check label expected metadata =
    Alcotest.check classification label expected (classify metadata)
  in
  check "no key" Absent [];
  check "other keys only" Absent [ "other", `Bool true ];
  check "one stamp among other keys" (Present appended_at) [ "other", `Bool true; stamped ];
  check "integer seconds are not the shape entry writes" Invalid [ key, `Int 1_794_643_609 ];
  check "a date string" Invalid [ key, `String "2026-11-14T08:06:49Z" ];
  check "a non-finite float" Invalid [ key, `Float Float.infinity ];
  check "two stamps" Duplicate [ stamped; stamped ];
  check
    "an integral second survives JSON text"
    (Present 1_794_643_609.)
    (match
       Yojson.Safe.from_string
         (Yojson.Safe.to_string (`Assoc [ entry ~appended_at:1_794_643_609. ]))
     with
     | `Assoc fields -> fields
     | _ -> Alcotest.fail "not an object");
  Alcotest.(check bool)
    "without drops every stamp and keeps the rest"
    true
    (without [ stamped; "other", `Bool true; stamped ] = [ "other", `Bool true ])
;;

(* ── Live turn ───────────────────────────────────────── *)

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

let response ~id ~stop_reason content : Types.api_response =
  { id
  ; model = "mock-model"
  ; unreadable_tool_uses = []
  ; stop_reason
  ; content
  ; usage = None
  ; telemetry = None
  }
;;

let tool_use_response =
  response
    ~id:"appended-at-tool"
    ~stop_reason:Types.StopToolUse
    [ Types.ToolUse { id = "call_1"; name = "get_time"; input = `Assoc [] } ]
;;

let text_response =
  response ~id:"appended-at-text" ~stop_reason:Types.EndTurn [ Types.Text "12:00 UTC" ]
;;

let sequence_transport responses =
  let remaining = ref responses in
  let next () =
    match !remaining with
    | response :: rest ->
      remaining := rest;
      response
    | [] -> Alcotest.fail "mock transport exhausted"
  in
  Llm_provider.Llm_transport.custom
    { complete_sync =
        (fun _request ->
          { Llm_provider.Llm_transport.response = Ok (next ()); latency_ms = Some 0 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok (next ()))
    }
;;

let time_tool =
  Tool.create ~name:"get_time" ~description:"Get current time" ~parameters:[] (fun _input ->
    Ok { Types.content = "12:00 UTC"; content_blocks = None; _meta = None })
;;

(* A mock clock set to [appended_at]: the stamp must be the pipeline clock's
   reading, not the process wall clock. The checkpoint the turn persisted after
   appending the results must carry the same value through its byte encoding. *)
let test_live_turn_stamps_results_with_pipeline_clock () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock appended_at;
  let after_results = ref [] in
  let checkpoint_sink (snapshot : Agent.checkpoint_snapshot) =
    (match snapshot.stage with
     | Agent.After_tool_results_appended ->
       after_results := snapshot.checkpoint :: !after_results
     | Agent.After_assistant_collected
     | Agent.After_context_injection
     | Agent.After_input_wait_changed
     | Agent.After_rejected_response_dropped -> ());
    Ok ()
  in
  let options =
    { Agent.default_options with
      provider_config = Some mock_provider
    ; transport = Some (sequence_transport [ tool_use_response; text_response ])
    }
  in
  let config =
    { (Types.default_config ~model:"mock-model") with name = "tool-results-appended-at" }
  in
  let agent =
    Agent.create
      ~media_store:(History.Memory_store.create ())
      ~net:env#net
      ~config
      ~tools:[ time_tool ]
      ~options
      ~checkpoint_sink
      ()
  in
  (match Agent.run_blocks ~sw ~clock agent [ Types.Text "what time is it?" ] with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Error.to_string error));
  let by_role messages =
    List.partition (fun (message : Types.message) -> message.role = Types.Tool) messages
  in
  let tool_messages, others = by_role (Agent.state agent).messages in
  Alcotest.(check (list classification))
    "the one Tool message carries the pipeline clock's reading"
    [ Types.Tool_results_appended_at.Present appended_at ]
    (List.map classify tool_messages);
  Alcotest.(check bool)
    "no other message is stamped"
    true
    (List.for_all
       (fun message -> classify message = Types.Tool_results_appended_at.Absent)
       others);
  match !after_results with
  | [ checkpoint ] ->
    (match Checkpoint.of_string (Checkpoint.to_string checkpoint) with
     | Error error -> Alcotest.fail (Error.to_string error)
     | Ok reloaded ->
       let tool_messages, _ = by_role reloaded.messages in
       Alcotest.(check (list classification))
         "the checkpoint keeps the stamp through its bytes"
         [ Types.Tool_results_appended_at.Present appended_at ]
         (List.map classify tool_messages))
  | checkpoints ->
    Alcotest.failf
      "expected one checkpoint after the results were appended, got %d"
      (List.length checkpoints)
;;

(* ── Provider requests ───────────────────────────────── *)

(* The Tool message is followed by a tool-result follow-up, so the backends
   that fold the follow-up into the Tool message run that merge with the stamp
   on it. *)
let conversation ~stamp =
  let tool_metadata =
    if stamp then [ Types.Tool_results_appended_at.entry ~appended_at ] else []
  in
  [ Types.make_message ~role:User [ Text "what time is it?" ]
  ; Types.make_message
      ~role:Assistant
      [ ToolUse { id = "call_1"; name = "get_time"; input = `Assoc [] } ]
  ; Types.make_message
      ~metadata:tool_metadata
      ~role:Tool
      [ ToolResult
          { tool_use_id = "call_1"
          ; content = "12:00 UTC"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ]
  ; Types.make_message ~origin:Tool_result_followup ~role:User [ Text "continue" ]
  ]
;;

let test_stamp_does_not_reach_provider_bytes () =
  let open Llm_provider in
  Alcotest.(check bool)
    "the two conversations differ only by the stamp"
    false
    (conversation ~stamp:true = conversation ~stamp:false);
  let check name kind request_path build =
    let config =
      Provider_config.make
        ~kind
        ~model_id:"test-model"
        ~base_url:"http://127.0.0.1:8085"
        ~request_path
        ~max_tokens:1024
        ()
    in
    Alcotest.(check string)
      (name ^ " request bytes")
      (build ~config ~messages:(conversation ~stamp:false))
      (build ~config ~messages:(conversation ~stamp:true))
  in
  check "anthropic" Provider_config.Anthropic "/v1/messages" (fun ~config ~messages ->
    Backend_anthropic.build_request ~config ~messages ());
  check "openai chat" Provider_config.OpenAI_compat "/v1/chat/completions"
    (fun ~config ~messages -> Backend_openai.build_request ~config ~messages ());
  check "openai responses" Provider_config.OpenAI_compat "/v1/responses"
    (fun ~config ~messages -> Backend_openai_responses.build_request ~config ~messages ());
  check "gemini" Provider_config.Gemini "/v1beta/models" (fun ~config ~messages ->
    Backend_gemini.build_request ~config ~messages ());
  check "glm" Provider_config.Glm "/api/paas/v4/chat/completions" (fun ~config ~messages ->
    Backend_glm.build_request ~config ~messages ());
  check "ollama" Provider_config.Ollama "/api/chat" (fun ~config ~messages ->
    Backend_ollama.build_request ~config ~messages ())
;;

let () =
  Alcotest.run
    "tool_results_appended_at"
    [ "key", [ Alcotest.test_case "classify and without" `Quick test_classify ]
    ; ( "live turn"
      , [ Alcotest.test_case
            "stamps results with the pipeline clock"
            `Quick
            test_live_turn_stamps_results_with_pipeline_clock
        ] )
    ; ( "provider"
      , [ Alcotest.test_case
            "stamp does not reach request bytes"
            `Quick
            test_stamp_does_not_reach_provider_bytes
        ] )
    ]
;;
