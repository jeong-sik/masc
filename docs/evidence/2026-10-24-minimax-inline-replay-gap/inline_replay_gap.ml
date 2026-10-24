open Llm_provider
open Types
module Parse = Backend_openai_parse
let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)
let msg role content : message = {role;content;name=None;tool_call_id=None;metadata=[]}
let member = Yojson.Safe.Util.member
let to_list = Yojson.Safe.Util.to_list
let to_string = Yojson.Safe.Util.to_string
let require_model_capabilities model_id = match Capabilities.for_model_id model_id with
 | Some caps -> caps | None -> Alcotest.fail "missing model declaration"
let response_json ?(content = `String "ok") ?(finish_reason = "stop") ?message_fields () =
 let fields = ("content", content) :: Option.value ~default:[] message_fields in
 `Assoc ["id", `String "chatcmpl-test"; "model", `String "minimax-m3";
 "choices", `List [`Assoc ["finish_reason",`String finish_reason; "message", `Assoc fields]]]
let rows = ref []
let test_minimax_native_catalog_replay () =
  let caps = require_model_capabilities "minimax-m3" in
  let config =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~provider_id:"minimax"
      ~model_id:"minimax-m3"
      ~base_url:"https://api.minimax.io"
      ~request_path:"/v1/chat/completions"
      ~model_capabilities_override:caps
      ()
  in
  let call =
    `Assoc
      [ "id", `String "weather-call"
      ; "type", `String "function"
      ; "function", `Assoc
          [ "name", `String "weather"
          ; "arguments", `String {|{"city":"Seoul"}|}
          ]
      ]
  in
  let assistant response =
    let response = Complete_common.patch_telemetry response ~config None in
    match assistant_message_of_response response with
    | Ok message -> message
    | Error error -> Alcotest.fail (show_assistant_message_error error)
  in
  let sync content fields =
    match Parse.parse_openai_response_result_json
            ~content_inline_reasoning:caps.content_inline_reasoning
            (response_json ~content ~finish_reason:"tool_calls"
               ~message_fields:(("tool_calls", `List [call]) :: fields) ()) with
    | Ok response -> assistant response
    | Error error -> Alcotest.fail (Parse.parse_error_to_string error)
  in
  let stream content fields =
    let dialect = Reasoning_dialect.for_provider_config config in
    let inline_reasoning = match caps.content_inline_reasoning with
      | Capabilities.Think_tags -> true
      | Capabilities.No_content_inline_reasoning -> false
    in
    let state = Streaming.create_openai_stream_state ~inline_reasoning () in
    let acc = Complete_stream_acc.create_stream_acc () in
    let feed wire =
      let parsed = Streaming.parse_openai_sse_chunk
          ~streaming_reasoning:dialect.streaming wire in
      let events, _ = Streaming.openai_sse_parse_result_to_events state parsed in
      List.iter (Complete_stream_acc.accumulate_event acc) events
    in
    let chunk delta finish = Yojson.Safe.to_string
        (`Assoc ["id", `String "mini-response"; "model", `String "minimax-m3";
                 "choices", `List [`Assoc ["index", `Int 0; "delta", `Assoc delta;
                                           "finish_reason", finish]]]) in
    let indexed_call = match call with
      | `Assoc fields -> `Assoc (("index", `Int 0) :: fields)
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        Alcotest.fail "tool fixture must be an object"
    in
    feed (chunk (("content", content) :: fields) `Null);
    feed (chunk ["tool_calls", `List [indexed_call]] `Null);
    feed (chunk [] (`String "tool_calls"));
    feed "[DONE]";
    match Complete_stream_acc.finalize_stream_acc acc with
    | Ok response -> assistant response
    | Error _ -> Alcotest.fail "native MiniMax SSE fixture failed"
  in
  let cases =
    [ "inline reasoning", `String "<think>check forecast</think>", [],
        Some "check forecast"
    ]
  in
  let last = match Parse.parse_openai_response_result_json
                     (response_json ~content:(`String "Sunny") ()) with
    | Ok response -> assistant response
    | Error error -> Alcotest.fail (Parse.parse_error_to_string error)
  in
  List.iter (fun (mode, parse) -> List.iter
    (fun (label, content, fields, _expected_reasoning) ->
       let label = mode ^ ": " ^ label in
       let first = parse content fields in
       let history =
         [ msg User [Text "Weather?"]
         ; first
         ; msg Tool
             [ToolResult { tool_use_id = "weather-call"; content = "sunny"
                         ; outcome = Tool_succeeded; json = None; content_blocks = None }]
         ; last
         ; msg User [Text "And tomorrow?"]
         ]
       in
       let body = Backend_openai_request.build_request ~config ~messages:history ()
           |> Yojson.Safe.from_string in
       let wire = member "messages" body |> to_list in
       check_int (label ^ " keeps complete conversation") 5 (List.length wire);
       let replay = List.nth wire 1 in
       rows := `Assoc ["case", `String label; "returned_content", content; "replayed_message", replay] :: !rows;
       check_bool (label ^ " tool identity and arguments") true
         (member "tool_calls" replay = `List [call]);
       check_string (label ^ " answer without thinking retained") "Sunny"
         (member "content" (List.nth wire 3) |> to_string))
    cases) ["sync", sync; "stream", stream]
;;


(* This is a contract probe, not a passing regression test for the broken wire.
   Print both observations before returning failure when original content is lost. *)
let () =
  test_minimax_native_catalog_replay ();
  let rows = List.rev !rows in
  Yojson.Safe.pretty_to_channel stdout (`List rows);
  print_newline ();
  let lost = List.filter (fun row ->
    member "returned_content" row <>
    member "content" (member "replayed_message" row)) rows in
  if lost <> [] then (
    Printf.eprintf "inline original-content contract failed in %d/2 modes\n" (List.length lost);
    exit 1)
