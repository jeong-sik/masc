(** Native grouping is evidence about existing content, not a second payload. *)
open Llm_provider.Types
module Replay = Response_replay

let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let rejected label = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail label
let group kind content_count : Replay.group = { kind; content_count }
let content = [Text "checking"; Text "one"; Text "two"]
let groups = [group (Message Commentary) 1; group (Message Final_answer) 2]

let partition_roundtrip () =
  let replay = ok (Replay.make ~content groups) in
  let restored = ok (Replay.of_metadata ~content [Replay.metadata replay]) in
  Alcotest.(check bool) "native item and multi-part boundaries" true (restored = Some groups);
  Alcotest.(check bool) "parts stay in their own native item" true
    (ok (Replay.partition ~content replay) =
      [Message Commentary, [Text "checking"]; Message Final_answer, [Text "one"; Text "two"]])

let authority_failures () =
  rejected "phase witness must not cover tool content"
    (Replay.make ~content:[ToolUse {id="call";name="test";input=`Assoc []}]
       [group (Message Commentary) 1]);
  rejected "content is not silently dropped" (Replay.make ~content [group (Message Commentary) 1]);
  rejected "negative extent" (Replay.make ~content [group (Message Commentary) (-1)]);
  let entry = Replay.metadata groups in
  rejected "duplicate witness" (Replay.of_metadata ~content [entry;entry]);
  rejected "unknown phase" (Replay.of_metadata ~content
    [Replay.metadata_key, `List [`Assoc ["kind", `List [`String "Message"; `List [`String "future_phase"]]; "content_count", `Int 3]]])

let nullable_phase () =
  List.iter (fun phase ->
    let replay = ok (Replay.make ~content:[Text "answer"] [group (Message phase) 1]) in
    Alcotest.(check bool) "absent and null remain distinct" true
      (ok (Replay.of_metadata ~content:[Text "answer"] [Replay.metadata replay]) = Some replay))
    [Absent;Null;Commentary;Final_answer]

let assistant_history () =
  let response : api_response =
    {id="response";model="native";stop_reason=EndTurn;content;usage=None;
     telemetry=Some {default_inference_telemetry with response_replay=Some groups}} in
  let message = match assistant_message_of_response response with
    | Ok message -> message
    | Error error -> Alcotest.fail (show_assistant_message_error error) in
  Alcotest.(check bool) "canonical assistant content unchanged" true (message.content = content);
  Alcotest.(check bool) "no aggregate phase invented" false
    (List.mem_assoc "openai.responses.phase" message.metadata);
  Alcotest.(check bool) "group carrier reaches actual history projection" true
    (ok (Replay.of_metadata ~content:message.content message.metadata) = Some groups);
  let telemetry = ok (inference_telemetry_of_yojson
    (inference_telemetry_to_yojson (Option.get response.telemetry))) in
  Alcotest.(check bool) "cache telemetry roundtrip" true (telemetry.response_replay = Some groups);
  let invalid = {response with content=[Text "different extent"]} in
  (match assistant_message_of_response invalid with
   | Error (Invalid_response_replay _) -> ()
   | Error (Reasoning_source_telemetry_missing | Reasoning_source_missing) | Ok _ ->
     Alcotest.fail "stale grouping admitted")

let admission_remap () =
  let original = [group (Message Commentary) 1;group Function_call 1;group Function_call 1;group (Message Final_answer) 1] in
  let original_content = [Text "checking";
    ToolUse {id="denied";name="not_registered";input=`Assoc []};
    ToolUse {id="accepted";name="original";input=`Assoc []};Text "answer"] in
  let retained = [Text "checking";ToolUse {id="accepted";name="normalized";input=`Assoc []};Text "answer"] in
  let replay = ok (Replay.retain ~original_content ~content:retained ~retained_indices:[0;2;3] original) in
  Alcotest.(check bool) "rejected tool group removed and later phase retained" true
    (replay = [group (Message Commentary) 1;group Function_call 1;group (Message Final_answer) 1]);
  rejected "repeated source position" (Replay.retain ~original_content ~content:retained ~retained_indices:[0;0;3] original);
  rejected "an invalid original partition cannot become valid by filtering"
    (Replay.retain ~original_content:[Text "short"] ~content:[]
       ~retained_indices:[] original)

let chat_control () =
  let response : api_response =
    {id="chat";model="fixture";stop_reason=EndTurn;content;usage=None;telemetry=None} in
  match assistant_message_of_response response with
  | Ok {metadata=[];content=actual;_} -> Alcotest.(check bool) "chat remains unchanged" true (actual=content)
  | Ok _ | Error _ -> Alcotest.fail "ordinary Chat gained native grouping"

let () = Alcotest.run "Responses replay carrier" ["carrier",[
  Alcotest.test_case "partition and roundtrip" `Quick partition_roundtrip;
  Alcotest.test_case "authority failures" `Quick authority_failures;
  Alcotest.test_case "nullable phase" `Quick nullable_phase;
  Alcotest.test_case "actual assistant projection" `Quick assistant_history;
  Alcotest.test_case "admission remap" `Quick admission_remap;
  Alcotest.test_case "Chat control" `Quick chat_control]]
