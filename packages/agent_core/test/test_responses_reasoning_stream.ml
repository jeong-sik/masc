(** Public SSE → canonical/cache/checkpoint-message bytes → request conformance.
    Controlled wire payloads, not MiniMax activation or a live vendor session. *)
open Llm_provider
open Types
open Yojson.Safe.Util
module Stream=Streaming
module Acc=Complete_stream_acc
let get = function Ok value->value | Error detail->Alcotest.fail detail
let config=Provider_config.make ~kind:Provider_config.OpenAI_compat
  ~provider_id:"responses-stream-fixture" ~model_id:"responses-stream-fixture"
  ~base_url:"https://fixture.invalid" ~request_path:"/v1/responses"
  ~model_capabilities_override:{Capabilities.default_capabilities with
    supports_reasoning=true;reasoning_replay_override=Force_preserve_responses_text} ()
let part kind text=`Assoc["type",`String kind;"text",`String text]
let reasoning ?summary ?full ?encrypted id = `Assoc
  (["type",`String "reasoning";"id",`String id]
   @ (match summary with None->[]|Some values->["summary",`List(List.map(part "summary_text")values)])
   @ (match full with None->[]|Some values->["content",`List(List.map(part "reasoning_text")values)])
   @ (match encrypted with None->[]|Some value->["encrypted_content",`String value]))
let call=`Assoc["type",`String "function_call";"id",`String "call-item";"call_id",`String "call"
  ;"name",`String "lookup";"arguments",`String "{}"]
let answer=`Assoc["type",`String "message";"role",`String "assistant"
  ;"content",`List[part "output_text" "answer"]]
let wire output=`Assoc["id",`String "response";"model",`String "fixture";"status",`String "completed"
  ;"output",`List output]
let feed (state,acc) event json =
  let events,_=Stream.responses_sse_to_events state (Some event) (Yojson.Safe.to_string json) in
  List.iter(Acc.accumulate_event acc)events
let start () = let s=Stream.create_openai_stream_state(),Acc.create_stream_acc() in
  feed s "response.created" (`Assoc["response",`Assoc["id",`String "response";"model",`String "fixture"]]);s
let delta ?(output=0) ?(index=0) ?id s channel text =
  let event,index_key=match channel with `Full->"response.reasoning_text.delta","content_index"
    | `Summary->"response.reasoning_summary_text.delta","summary_index" in
  feed s event (`Assoc(["output_index",`Int output;index_key,`Int index;"delta",`String text]
    @ match id with None->[]|Some id->["item_id",`String id]))
let done_item s index item=feed s "response.output_item.done" (`Assoc["output_index",`Int index;"item",item])
let terminal s output=feed s "response.completed" (`Assoc["response",wire output])
let omitted s=feed s "response.completed" (`Assoc["response",`Assoc["status",`String "completed"]])
let result (_,acc)=match Acc.finalize_stream_acc acc with
  | Ok response->response | Error _->Alcotest.fail "actual canonical stream failed"
let fails s=match Acc.finalize_stream_acc(snd s)with
  | Error _->() | Ok _->Alcotest.fail "contradictory stream was accepted"
let texts response=List.filter_map(function Thinking{content;_}->Some content
  | Llm_provider.Types.Text _| Llm_provider.Types.RedactedThinking _| Llm_provider.Types.ReasoningDetails _| Llm_provider.Types.ToolUse _| Llm_provider.Types.ToolResult _| Llm_provider.Types.Image _| Llm_provider.Types.Document _| Llm_provider.Types.Audio _->None)response.content
let check expected s=Alcotest.(check(list string))"canonical reasoning"expected(texts(result s))
let persisted_input response =
  let response=Complete_common.patch_telemetry response ~config None in
  let restored=match Cache.response_of_json(Cache.response_to_json response)with
    | Some r->r | None->Alcotest.fail "response cache rejected stream" in
  let message=match assistant_message_of_response restored with Ok m->m
    | Error e->Alcotest.fail(show_assistant_message_error e) in
  let media_store=Agent_core.History.Memory_store.create () in
  let message=match Agent_core.History.of_wire_message media_store message with Ok m->m
    | Error e->Alcotest.fail(Agent_core.History.show_media_error e) in
  let path=Filename.temp_file "responses-sse-history-" ".json" in
  let message=Fun.protect ~finally:(fun()->Sys.remove path)(fun()->
    Out_channel.with_open_bin path(fun ch->output_string ch
      (Agent_core.Checkpoint.message_to_json message |> Yojson.Safe.to_string));
    let json=In_channel.with_open_bin path In_channel.input_all |> Yojson.Safe.from_string in
    match Agent_core.Checkpoint.message_of_json json with
    | Error _->Alcotest.fail "checkpoint message refused"
    | Ok m->(match Agent_core.History.to_wire_message media_store m with Ok m->m
      | Error e->Alcotest.fail(Agent_core.History.show_media_error e))) in
  let tool=make_message ~role:Tool[ToolResult{tool_use_id="call";content="receipt";outcome=Tool_succeeded
    ;json=None;content_blocks=None}] in
  Backend_openai_responses.build_request ~config
    ~messages:[message;tool;make_message ~role:User[Text "next user"]] ()
  |> Yojson.Safe.from_string |> member "input" |> to_list
let full_history () =
  let s=start() in let output=[reasoning ~summary:[] ~full:["full thought"] "r";call] in
  terminal s output;check ["full thought"] s;
  let sync=get(Backend_openai_responses.parse_response_result(Yojson.Safe.to_string(wire output))) in
  Alcotest.(check bool) "sync/SSE canonical parity" true (sync.content=(result s).content);
  let rows=persisted_input(result s)in
  Alcotest.(check(list string)) "reasoning/call/result/later-user after persistence"
    ["reasoning";"function_call";"function_call_output";""]
    (List.map(fun row->match member "type" row with `String k->k|_->"")rows);
  Alcotest.(check string) "full input reasoning" "full thought"
    (List.hd rows |> member "summary" |> to_list |> List.hd |> member "text" |> to_string)
let summary_then_full () =
  let s=start()in delta s `Summary "condensed";delta s `Full "full ";delta s `Full "thought";
  terminal s[reasoning ~summary:["condensed"] ~full:["full thought"]"r";call];check["full thought"]s;
  ignore(persisted_input(result s))
let full_then_summary () = let s=start()in delta s `Full "thought";delta s `Summary "different summary";
  terminal s[reasoning ~full:["thought"]~summary:["different summary"]"r"];check["thought"]s
let summary_only () = let s=start()in terminal s[reasoning ~summary:["summary"]"r"];check["summary"]s
let parts_reordered () = let s=start()in delta ~index:1 s `Full "second";delta ~index:0 s `Full "first";
  terminal s[reasoning ~full:["first";"second"]"r"];check["first\nsecond"]s
let repeated_boundaries () = let s=start()in delta s `Full "full";
  let item=reasoning ~full:["full thought"]"r"in done_item s 0 item;done_item s 0 item;
  terminal s[item];check["full thought"]s
let item_done_no_output () = let s=start()in done_item s 0(reasoning ~full:["complete"]"r");
  omitted s;check["complete"]s
let delta_no_output () = let s=start()in delta s `Full "received";omitted s;check["received"]s
let contradictory () = let s=start()in delta s `Full "observed";
  terminal s[reasoning ~full:["different"]"r"];fails s
let truncated () = let s=start()in delta s `Full "whole thought";
  terminal s[reasoning ~full:["whole"]"r"];fails s
let explicit_empty () = let s=start()in delta s `Full "observed";
  terminal s[reasoning ~full:[]"r"];fails s
let missing_item () = let s=start()in delta s `Full "observed";terminal s[];fails s
let omitted_channel () = let s=start()in delta s `Full "observed";
  terminal s[reasoning ~summary:["condensed"]"r"];check["observed"]s
let whitespace_first () = let s=start()in delta s `Summary "summary";delta s `Full "  ";delta s `Full "full";
  terminal s[reasoning ~summary:["summary"]~full:["  full"]"r"];check["  full"]s
let unicode_fragments () = let s=start()in let text="한글 🌊"in
  delta s `Full(String.sub text 0 1);delta s `Full(String.sub text 1(String.length text-1));
  terminal s[reasoning ~full:[text]"r"];check[text]s
let multiple_items () = let s=start()in delta ~output:2 s `Full "second";delta ~output:0 s `Full "first";
  terminal s[reasoning ~full:["first"]"a";call;reasoning ~full:["second"]"b"];check["first";"second"]s
let opaque_transition () = let s=start()in delta s `Summary "summary";delta s `Full "plaintext";
  let opaque=reasoning ~summary:[] ~encrypted:"token""r"in done_item s 0 opaque;terminal s[opaque];
  match(result s).content with [RedactedThinking raw]->
    Alcotest.(check bool)"opaque exact"true(Yojson.Safe.equal opaque(Yojson.Safe.from_string raw))
  | _->Alcotest.fail "opaque lost priority"
let opaque_changed () = let s=start()in done_item s 0(reasoning ~encrypted:"first""r");
  terminal s[reasoning ~encrypted:"other""r"];fails s
let late_plaintext () = let s=start()in done_item s 0(reasoning ~encrypted:"token""r");
  delta s `Full "late";omitted s;fails s
let wrong_identity () = let s=start()in delta ~id:"first" s `Full "text";
  terminal s[reasoning ~full:["text"]"other"];fails s
let invalid_snapshot_target signed =
  let acc=Acc.create_stream_acc() in
  let events=[MessageStart{id="guard";model="fixture";usage=None}
    ;ContentBlockStart{index=0;content_type=(if signed then "thinking" else "text");tool_id=None;tool_name=None}]
    @ (if signed then [ContentBlockDelta{index=0;delta=ThinkingSignatureDelta "signature"}] else [])
    @ [ContentBlockDelta{index=0;delta=ThinkingSnapshot "replacement"}
       ;MessageDelta{stop_reason=Some EndTurn;usage=None};MessageStop] in
  List.iter(Acc.accumulate_event acc)events;
  match Acc.finalize_stream_acc acc with Error _->()|Ok _->Alcotest.fail "snapshot rewrote an ineligible block"

let () = Alcotest.run "responses_reasoning_stream"
  ["public SSE",List.map(fun(name,fn)->Alcotest.test_case name `Quick fn)
   ["full history",full_history;"summary then full",summary_then_full;"full then summary",full_then_summary
   ;"summary-only control",summary_only;"part ordering",parts_reordered;"repeated boundaries",repeated_boundaries
   ;"item done without output",item_done_no_output;"delta without output",delta_no_output
   ;"conflict",contradictory;"truncation",truncated;"explicit empty",explicit_empty;"missing item",missing_item
   ;"omitted channel",omitted_channel;"whitespace then full",whitespace_first;"Unicode chunks",unicode_fragments
   ;"multiple native items",multiple_items;"opaque transition",opaque_transition;"opaque conflict",opaque_changed
   ;"late plaintext",late_plaintext;"item identity",wrong_identity
   ;"signed thinking guard",(fun()->invalid_snapshot_target true)
   ;"wrong block guard",(fun()->invalid_snapshot_target false)]]
