(** Chat and Responses replay conformance through the production public codecs.
    Local deterministic wire fixtures do not establish provider account behavior. *)
open Llm_provider
open Types
module Codec = Backend_openai_responses
module Stream = Streaming
module Acc = Complete_stream_acc

let config request_path = Provider_config.make
  ~kind:Provider_config.OpenAI_compat ~provider_id:"openai" ~model_id:"gpt-5.5"
  ~base_url:"https://api.openai.com" ~request_path ~max_tokens:128 ()

let replay_input_items message =
  Codec.build_request ~config:(config "/v1/responses") ~messages:[message] ()
  |> Yojson.Safe.from_string |> Yojson.Safe.Util.member "input" |> Yojson.Safe.Util.to_list

module Sync = struct
let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let rec canonical = function
 | `Assoc fields -> `Assoc(List.map(fun(k,v)->k,canonical v)fields |> List.sort(fun(a,_)(b,_)->String.compare a b))
 | `List items -> `List(List.map canonical items)
 | (`Null|`Bool _|`Int _|`Intlit _|`Float _|`String _) as value -> value
let equal_items a b = canonical(`List a)=canonical(`List b)
let item ?phase texts = `Assoc (["type",`String "message";"role",`String "assistant";"content",`List(List.map(fun text->`Assoc["type",`String"output_text";"text",`String text])texts)] @ match phase with None->[]|Some phase->["phase",phase])
let response items = Yojson.Safe.to_string (`Assoc["id",`String "response";"model",`String "fixture";"status",`String "completed";"output",`List items])
let projected wire = let response=ok(Codec.parse_response_result wire) in match assistant_message_of_response response with Ok message->message|Error error->Alcotest.fail(show_assistant_message_error error)
let parts () =
 let input=[item ~phase:(`String"commentary") ["checking"];item ~phase:(`String"final_answer") ["one";"two"]] in
 let message=projected(response input) in
 Alcotest.(check bool) "no last phase on aggregate" false (List.mem_assoc "openai.responses.phase" message.metadata);
 Alcotest.(check bool) "original per-item phases and multiText" true (equal_items (replay_input_items message) input)
let nullable () = List.iter(fun phase->let input=[item ?phase ["answer"]] in Alcotest.(check bool) "nullable exact replay" true (equal_items (replay_input_items(projected(response input))) input)) [None;Some `Null;Some (`String "commentary");Some (`String "final_answer")]
let bad_phase () = match Codec.parse_response_result (response[item ~phase:(`String "not_a_known_phase") ["answer"]]) with Error _->()|Ok _->Alcotest.fail"unknown phase accepted"
let tool_order () =
 let call=`Assoc["type",`String"function_call";"call_id",`String"call";"name",`String"test";"arguments",`String"{}"] in
 let input=[item ~phase:(`String"commentary") ["checking"];call;item ~phase:(`String"final_answer") ["answer"]] in
 Alcotest.(check bool) "tool remains between native messages" true (equal_items (replay_input_items(projected(response input))) input)
let telemetry_roundtrip () =
 let input=[item ~phase:(`String"commentary") ["checking"];item ~phase:(`String"final_answer") ["answer"]] in
 let response=ok(Codec.parse_response_result(response input)) in
 let telemetry=Option.map(fun t->ok(inference_telemetry_of_yojson(inference_telemetry_to_yojson t)))response.telemetry in
 let restored={response with telemetry} in
 let message=match assistant_message_of_response restored with Ok m->m|Error e->Alcotest.fail(show_assistant_message_error e) in
 Alcotest.(check bool) "replay after actual telemetry codec" true (equal_items (replay_input_items message) input)

let legacy () =
 let message=make_message ~metadata:[Codec.response_phase_metadata Codec.Commentary] ~role:Assistant [Text"manual"] in
 Alcotest.(check bool) "existing manual metadata" true (equal_items (replay_input_items message) [item ~phase:(`String"commentary") ["manual"]])
end

module Streams = struct
let rec canonical = function
 | `Assoc fields -> `Assoc(List.map(fun(k,v)->k,canonical v)fields |> List.sort(fun(a,_)(b,_)->String.compare a b))
 | `List items -> `List(List.map canonical items)
 | (`Null|`Bool _|`Int _|`Intlit _|`Float _|`String _) as value -> value
let equal_items a b=canonical(`List a)=canonical(`List b)
let item ?phase texts=`Assoc(["type",`String"message";"role",`String"assistant";"content",`List(List.map(fun text->`Assoc["type",`String"output_text";"text",`String text])texts)] @ match phase with None->[]|Some phase->["phase",phase])
let call=`Assoc["type",`String"function_call";"call_id",`String"call";"name",`String"test";"arguments",`String"{}"]
let created=`Assoc["response",`Assoc["id",`String"response";"model",`String"fixture"]]
let feed state acc kind json=let events,_=Stream.responses_sse_to_events state (Some kind) (Yojson.Safe.to_string json) in List.iter(Acc.accumulate_event acc)events
let start ()=let state=Stream.create_openai_stream_state() and acc=Acc.create_stream_acc() in feed state acc "response.created" created;state,acc
let terminal ?(status="completed") ?reason state acc output=feed state acc (if status="incomplete" then "response.incomplete" else "response.completed") (`Assoc["response",`Assoc(["status",`String status;"output",`List output] @ match reason with None->[]|Some reason->["incomplete_details",`Assoc["reason",`String reason]])])
let done_item state acc output_index item=feed state acc "response.output_item.done" (`Assoc["output_index",`Int output_index;"item",item])
let delta state acc output_index content_index text=feed state acc "response.output_text.delta" (`Assoc["output_index",`Int output_index;"content_index",`Int content_index;"delta",`String text])
let result acc=match Acc.finalize_stream_acc acc with Ok response->response|Error _->Alcotest.fail "canonical stream refused response"
let replay acc=match assistant_message_of_response(result acc)with Ok message->replay_input_items message|Error error->Alcotest.fail(show_assistant_message_error error)
let native_order ()=
 let state,acc=start() in
 delta state acc 2 1 "two";delta state acc 0 0 "checking";
 feed state acc "response.output_item.added" (`Assoc["output_index",`Int 1;"item",call]);
 let output=[item ~phase:(`String"commentary") ["checking"];call;item ~phase:(`String"final_answer") ["one";"two"]] in
 List.iteri(done_item state acc)output;terminal state acc output;
 Alcotest.(check bool) "native order, equal indices in distinct items and multipart" true(equal_items(replay acc)output)
let nullable ()=List.iter(fun phase->let state,acc=start()in let output=[item ?phase["answer"]]in done_item state acc 0(List.hd output);terminal state acc output;Alcotest.(check bool) "per-item nullable phase" true(equal_items(replay acc)output)) [None;Some `Null;Some(`String"commentary");Some(`String"final_answer")]
let item_done_without_terminal_output ()=let state,acc=start()in let output=[item ~phase:(`String"commentary")["checking"];item ~phase:(`String"final_answer")["answer"]]in List.iteri(done_item state acc)output;feed state acc "response.completed" (`Assoc["response",`Assoc["status",`String"completed"]]);Alcotest.(check bool) "actual done boundaries retained" true(equal_items(replay acc)output)
let invalid_phase ()=let state,acc=start()in done_item state acc 0(item ~phase:(`String"invalid")["answer"]);terminal state acc [];match Acc.finalize_stream_acc acc with Error _->()|Ok _->Alcotest.fail"unknown native phase accepted"
let unterminated ()=let state,acc=start()in done_item state acc 0(item ~phase:(`String"commentary")["checking"]);match Acc.finalize_stream_acc acc with Error error->Alcotest.(check bool) "typed missing terminal" true (error=Stream_incomplete{reason="stream_terminated_without_stop_reason"})|Ok _->Alcotest.fail"missing terminal promoted"
let partial_tool ()=let state,acc=start()in let message=item ~phase:(`String"commentary")["checking"]in terminal ~status:"incomplete" ~reason:"max_output_tokens" state acc [message;call];let response=result acc in Alcotest.(check bool) "truncation retained" true(response.stop_reason=MaxTokens);Alcotest.(check bool) "partial tool excluded without losing message phase" true(equal_items(replay acc)[message])
let snapshot_conflict ()=let state,acc=start()in delta state acc 0 0 "different";terminal state acc[item ~phase:(`String"final_answer")["answer"]];match Acc.finalize_stream_acc acc with Error _->()|Ok _->Alcotest.fail"conflicting authoritative text silently replaced"
let no_duplicate_block ()=let state,acc=start()in delta state acc 0 0 "answer";Acc.accumulate_event acc(ResponsesOutputItems[Response_replay.Message Final_answer,[0;0]]);feed state acc "response.completed" (`Assoc["response",`Assoc["status",`String"completed"]]);match Acc.finalize_stream_acc acc with Error _->()|Ok _->Alcotest.fail"duplicate block witness accepted"
let conflicting_phase ()=let state,acc=start()in done_item state acc 0(item ~phase:(`String"commentary")["same"]);terminal state acc[item ~phase:(`String"final_answer")["same"]];match Acc.finalize_stream_acc acc with Error _->()|Ok _->Alcotest.fail"a completed item changed its phase"
let named id = function `Assoc fields->`Assoc(("id",`String id)::fields)|`Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _->Alcotest.fail"item fixture is not object"
let conflicting_identity ()=let state,acc=start()in let first=named "native-a"(item ~phase:(`String"commentary")["same"])in done_item state acc 0 first;terminal state acc[named "native-b"(item ~phase:(`String"commentary")["same"])];match Acc.finalize_stream_acc acc with Error _->()|Ok _->Alcotest.fail"output index rebound to another native item"
let omitted_terminal_phase ()=let state,acc=start()in let original=item ~phase:(`String"commentary")["checking"]in done_item state acc 0 original;terminal state acc[item["checking"]];Alcotest.(check bool)"known item phase survives a later omitted field"true(equal_items(replay acc)[original])
let malformed_terminal_calls ()=
 let fields=["type",`String"function_call";"call_id",`String"call";"name",`String"test";"arguments",`String"{}"]in
 let malformed=[`Assoc(List.remove_assoc "call_id" fields);`Assoc(List.remove_assoc "name" fields);`Assoc(("arguments",`String"private-provider-fragment")::List.remove_assoc "arguments" fields)]in
 List.iter(fun call->let state,acc=start()in terminal state acc[call];match Acc.finalize_stream_acc acc with
 | Error error->Alcotest.(check bool)"shared strict function-call refusal is public-safe"true(error=Stream_parse_failed{raw="";reason="responses_replay:malformed_function_call"})
 | Ok _->Alcotest.fail"malformed terminal function became executable")malformed
let unsupported_custom ()=
 let state,acc=start()in terminal state acc[`Assoc["type",`String"custom_tool_call";"call_id",`String"custom";"name",`String"test";"input",`String"plain input"]];
 match Acc.finalize_stream_acc acc with Error _->()|Ok response->Alcotest.(check bool)"unsupported custom terminal is never promoted"false(List.exists(function ToolUse _->true| Llm_provider.Types.Text _| Llm_provider.Types.Thinking _| Llm_provider.Types.ReasoningDetails _| Llm_provider.Types.RedactedThinking _| Llm_provider.Types.ToolResult _| Llm_provider.Types.Image _| Llm_provider.Types.Document _| Llm_provider.Types.Audio _->false)response.content)
let incomplete_malformed_tool ()=
 let state,acc=start()in let message=item ~phase:(`String"commentary")["checking"]in
 let partial=`Assoc["type",`String"function_call";"name",`String"test";"arguments",`String"{"]in
 terminal ~status:"incomplete" ~reason:"max_output_tokens" state acc[message;partial];
 Alcotest.(check bool)"cut-off tool is dropped under existing incomplete policy"true(equal_items(replay acc)[message])

let encrypted_reasoning_fields =
  [ "type", `String "reasoning"
  ; "id", `String "reasoning-item"
  ; "encrypted_content", `String "unchanged-opaque-ciphertext"
  ; "summary", `List []
  ]

let encrypted_reasoning_reordered () =
  let state, acc = start () in
  let original = `Assoc encrypted_reasoning_fields in
  done_item state acc 0 original;
  terminal state acc [`Assoc (List.rev encrypted_reasoning_fields)];
  match Acc.finalize_stream_acc acc with
  | Ok response ->
    Alcotest.(check bool) "first opaque replay artifact stays exact" true
      (response.content = [RedactedThinking (Yojson.Safe.to_string original)])
  | Error _ -> Alcotest.fail "identical reasoning object was refused after key reordering"

let encrypted_reasoning_changed () =
  let state, acc = start () in
  done_item state acc 0 (`Assoc encrypted_reasoning_fields);
  let changed =
    ("encrypted_content", `String "changed-ciphertext")
    :: List.remove_assoc "encrypted_content" encrypted_reasoning_fields
  in
  terminal state acc [`Assoc changed];
  match Acc.finalize_stream_acc acc with
  | Error error ->
    Alcotest.(check bool) "changed opaque ciphertext is still refused" true
      (error = Stream_parse_failed
        {reason="responses_replay:conflicting_reasoning_item";raw=""})
  | Ok _ -> Alcotest.fail "changed opaque ciphertext was accepted"
end

let cache_roundtrip () =
  let input=[Sync.item ~phase:(`String "commentary") ["checking"];
             Sync.item ~phase:(`String "final_answer") ["one";"two"]] in
  let response=Sync.ok(Codec.parse_response_result(Sync.response input)) in
  let cached=Cache.response_to_json response in
  let restored=match Cache.response_of_json cached with Some response->response
    | None->Alcotest.fail "valid native output cache entry rejected" in
  let message=match assistant_message_of_response restored with Ok message->message
    | Error error->Alcotest.fail(show_assistant_message_error error) in
  Alcotest.(check bool) "public cache retains native grouping" true
    (Sync.equal_items (replay_input_items message) input);
  let corrupt={response with content=[Text "shortened"]} in
  Alcotest.(check bool) "invalid grouping is a miss" true
    (Option.is_none(Cache.response_of_json(Cache.response_to_json corrupt)))

let chat_control () =
  let wire={|{"id":"chat","model":"gpt-5.5","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"answer"}}]}|} in
  let response=match Backend_openai_parse.parse_openai_response_result wire with
    | Ok response->response
    | Error error->Alcotest.fail(Backend_openai_parse.parse_error_to_string error) in
  let message=match assistant_message_of_response response with Ok message->message
    | Error error->Alcotest.fail(show_assistant_message_error error) in
  Alcotest.(check bool) "Chat does not invent Responses output boundaries" true
    (Response_replay.of_metadata ~content:message.content message.metadata=Ok None);
  let body=Backend_openai_request.build_request
    ~config:(config "/v1/chat/completions") ~messages:[message] ()
    |> Yojson.Safe.from_string in
  let messages=Yojson.Safe.Util.(body |> member "messages" |> to_list) in
  Alcotest.(check int) "one Chat assistant message" 1 (List.length messages);
  Alcotest.(check bool) "Chat has no phase field" true
    (List.for_all (function `Assoc fields->not(List.mem_assoc "phase" fields)
      | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _->false) messages)

let () = Alcotest.run "provider replay conformance" [
 "sync",[
  Alcotest.test_case "native groups" `Quick Sync.parts;
  Alcotest.test_case "absent and null" `Quick Sync.nullable;
  Alcotest.test_case "unknown phase refusal" `Quick Sync.bad_phase;
  Alcotest.test_case "tool ordering" `Quick Sync.tool_order;
  Alcotest.test_case "telemetry roundtrip" `Quick Sync.telemetry_roundtrip;
  Alcotest.test_case "manual phase control" `Quick Sync.legacy;
  Alcotest.test_case "public response cache" `Quick cache_roundtrip;
  Alcotest.test_case "Chat control" `Quick chat_control];
 "stream",[
  Alcotest.test_case "native multipart and order" `Quick Streams.native_order;
  Alcotest.test_case "nullable phases" `Quick Streams.nullable;
  Alcotest.test_case "done item authority" `Quick Streams.item_done_without_terminal_output;
  Alcotest.test_case "unknown phase refusal" `Quick Streams.invalid_phase;
  Alcotest.test_case "missing terminal" `Quick Streams.unterminated;
  Alcotest.test_case "partial tool truncation" `Quick Streams.partial_tool;
  Alcotest.test_case "conflicting snapshot" `Quick Streams.snapshot_conflict;
  Alcotest.test_case "duplicate identity" `Quick Streams.no_duplicate_block;
  Alcotest.test_case "conflicting item phase" `Quick Streams.conflicting_phase;
  Alcotest.test_case "conflicting native identity" `Quick Streams.conflicting_identity;
  Alcotest.test_case "omitted terminal phase" `Quick Streams.omitted_terminal_phase;
  Alcotest.test_case "malformed completed calls" `Quick Streams.malformed_terminal_calls;
  Alcotest.test_case "unsupported custom terminal" `Quick Streams.unsupported_custom;
  Alcotest.test_case "incomplete malformed call" `Quick Streams.incomplete_malformed_tool;
  Alcotest.test_case "encrypted reasoning key order" `Quick Streams.encrypted_reasoning_reordered;
  Alcotest.test_case "changed encrypted reasoning" `Quick Streams.encrypted_reasoning_changed]]
