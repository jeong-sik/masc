(** Public Responses output → cache → assistant → checkpoint → request.
    Synthetic wire fixtures establish no MiniMax activation or HTTP behavior. *)
open Llm_provider
open Types
open Yojson.Safe.Util
module Codec = Backend_openai_responses

let openai_config = Provider_config.make ~kind:Provider_config.OpenAI_compat
  ~provider_id:"openai" ~model_id:"gpt-5.5" ~base_url:"https://api.openai.com"
  ~request_path:"/v1/responses" ~max_tokens:128 ()
(* Explicit synthetic plaintext replay policy. This does not activate a
   MiniMax binding or change OpenAI's production opaque-only policy. *)
let config = Provider_config.make ~kind:Provider_config.OpenAI_compat
  ~provider_id:"responses-text-fixture" ~model_id:"responses-text-fixture"
  ~base_url:"https://fixture.invalid" ~request_path:"/v1/responses" ~max_tokens:128
  ~model_capabilities_override:{Capabilities.default_capabilities with
    supports_reasoning=true;reasoning_replay_override=Capabilities.Force_preserve_responses_text} ()
let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let text_part kind text = `Assoc ["type",`String kind;"text",`String text]
let reasoning ?(summary=[]) ?(content=[]) ?encrypted id =
  `Assoc (["type",`String "reasoning";"id",`String id;"summary",`List summary
    ;"content",`List content] @ match encrypted with
      | None -> [] | Some encrypted -> ["encrypted_content",`String encrypted])
let call = `Assoc ["type",`String "function_call";"call_id",`String "call-weather"
  ;"name",`String "weather";"arguments",`String {|{"city":"Seoul"}|}]
let answer = `Assoc ["type",`String "message";"role",`String "assistant"
  ;"content",`List [text_part "output_text" "visible answer"]]
let parse items = Codec.parse_response_result (Yojson.Safe.to_string (`Assoc
  ["id",`String "reasoning-fixture";"model",`String "fixture";"status",`String "completed"
  ;"output",`List items])) |> get
let restored_assistant ?(config=config) response =
  let response = Complete_common.patch_telemetry response ~config None in
  let response = Cache.response_to_json response |> Yojson.Safe.to_string
    |> Yojson.Safe.from_string |> Cache.response_of_json in
  let response = match response with Some response -> response
    | None -> Alcotest.fail "actual response cache rejected valid evidence" in
  let message = match assistant_message_of_response response with
    | Ok message -> message | Error error -> Alcotest.fail (show_assistant_message_error error) in
  let media_store = Agent_core.History.Memory_store.create () in
  let message = match Agent_core.History.of_wire_message media_store message with
    | Ok message -> message | Error error -> Alcotest.fail (Agent_core.History.show_media_error error) in
  let bytes = Agent_core.Checkpoint.message_to_json message |> Yojson.Safe.to_string in
  let path = Filename.temp_file "responses-reasoning-history-" ".json" in
  let restored = Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    Out_channel.with_open_bin path (fun channel -> output_string channel bytes);
    In_channel.with_open_bin path In_channel.input_all) in
  match Agent_core.Checkpoint.message_of_json (Yojson.Safe.from_string restored) with
  | Error _ -> Alcotest.fail "actual checkpoint message codec rejected history"
  | Ok message ->
    match Agent_core.History.to_wire_message media_store message with
    | Ok message -> message | Error error -> Alcotest.fail (Agent_core.History.show_media_error error)
let input ?(config=config) message trailing = Codec.build_request ~config ~messages:(message :: trailing) ()
  |> Yojson.Safe.from_string |> member "input" |> to_list
let check_reasoning label expected response =
  let actual = List.filter_map (function Thinking {content;_} -> Some content
    | Llm_provider.Types.Text _ | Llm_provider.Types.ReasoningDetails _ | Llm_provider.Types.RedactedThinking _ | Llm_provider.Types.ToolUse _ | Llm_provider.Types.ToolResult _
    | Llm_provider.Types.Image _ | Llm_provider.Types.Document _ | Llm_provider.Types.Audio _ -> None) response.content in
  Alcotest.(check (list string)) label expected actual
let replay_text item = item |> member "summary" |> to_list
  |> List.map (fun part -> member "text" part |> to_string) |> String.concat "\n"

let full_tool_history () =
  let item = reasoning "r1" ~content:[text_part "reasoning_text" "full thought"] in
  let response = parse [item;call] in
  check_reasoning "full output content retained" ["full thought"] response;
  let message = restored_assistant response in
  let result = make_message ~role:Tool [ToolResult {tool_use_id="call-weather"
    ;content="weather receipt";outcome=Tool_succeeded;json=None;content_blocks=None}] in
  let later = make_message ~role:User [Text "continue after tool"] in
  let rows = input message [result;later] in
  Alcotest.(check (list string)) "reasoning, call, result, later user order"
    ["reasoning";"function_call";"function_call_output";""]
    (List.map (fun item -> match member "type" item with `String kind -> kind
      | `Null -> "" | _ -> Alcotest.fail "invalid item type") rows);
  Alcotest.(check string) "full text mapped to documented input summary" "full thought"
    (replay_text (List.nth rows 0));
  Alcotest.(check string) "tool call ID" "call-weather" (member "call_id" (List.nth rows 1) |> to_string);
  Alcotest.(check string) "result call ID" "call-weather" (member "call_id" (List.nth rows 2) |> to_string);
  Alcotest.(check bool) "later user content" true
    (member "content" (List.nth rows 3) = `List [text_part "input_text" "continue after tool"])
let full_over_summary () =
  let response=parse [reasoning "r" ~summary:[text_part "summary_text" "condensed"]
    ~content:[text_part "reasoning_text" "full one";text_part "reasoning_text" "full two"];answer] in
  check_reasoning "full reasoning takes precedence over condensation" ["full one\nfull two"] response;
  let rows=input (restored_assistant response) [] in
  Alcotest.(check string) "full reasoning replayed once" "full one\nfull two" (replay_text(List.hd rows));
  Alcotest.(check int) "one reasoning, one visible answer" 2 (List.length rows)
let summary_control () =
  let response=parse [reasoning "r" ~summary:[text_part "summary_text" "existing summary"];answer] in
  check_reasoning "existing summary retained" ["existing summary"] response;
  Alcotest.(check string) "summary replay unchanged" "existing summary"
    (replay_text(List.hd(input(restored_assistant response)[])))
let blank_full_falls_back () =
  let response=parse [reasoning "r" ~content:[text_part "reasoning_text" "  "]
    ~summary:[text_part "summary_text" "nonempty summary"];answer] in
  check_reasoning "blank full text permits summary" ["nonempty summary"] response
let encrypted_control () =
  let item=reasoning "opaque" ~encrypted:"ciphertext"
    ~content:[text_part "reasoning_text" "plaintext"]
    ~summary:[text_part "summary_text" "condensed"] in
  let response=parse [item;answer] in
  (match response.content with RedactedThinking raw :: _ ->
    Alcotest.(check bool) "entire opaque item unchanged" true
      (Yojson.Safe.equal item (Yojson.Safe.from_string raw))
   | _ -> Alcotest.fail "opaque carrier lost priority");
  let rows=input(restored_assistant response)[] in
  Alcotest.(check bool) "opaque replay unchanged" true (Yojson.Safe.equal item (List.hd rows))
let multiple_items () =
  let response=parse [reasoning "first" ~content:[text_part "reasoning_text" "first thought"]
    ;call;reasoning "second" ~content:[text_part "reasoning_text" "second thought"];answer] in
  check_reasoning "distinct native items retain order" ["first thought";"second thought"] response;
  let rows=input(restored_assistant response)[] in
  Alcotest.(check (list string)) "native item order after persistence" ["reasoning";"function_call";"reasoning";"message"]
    (List.map(fun row->member "type" row |> to_string)rows)

let blank_encrypted () =
  let response=parse [reasoning "r" ~encrypted:" "
    ~content:[text_part "reasoning_text" "plaintext without opaque carrier"];answer] in
  check_reasoning "blank encrypted content is not opaque" ["plaintext without opaque carrier"] response
let unknown_content_part () =
  let response=parse [reasoning "r" ~content:[text_part "future_part" "extension"
    ;text_part "reasoning_text" "recognized reasoning"];answer] in
  check_reasoning "extensible parts do not discard recognized text" ["recognized reasoning"] response
let malformed_content () =
  let malformed = `Assoc ["type",`String "reasoning_text";"text",`Int 7] in
  let json = `Assoc ["id",`String "malformed";"status",`String "completed"
    ;"output",`List [reasoning "r" ~content:[malformed];answer]] in
  match Codec.parse_response_result (Yojson.Safe.to_string json) with
  | Error error -> Alcotest.(check string) "malformed recognized text fails closed"
      "malformed_responses_reasoning:text" error
  | Ok _ -> Alcotest.fail "malformed recognized text silently disappeared"
let malformed_carrier () =
  let json=`Assoc ["id",`String "malformed";"status",`String "completed"
    ;"output",`List [`Assoc["type",`String "reasoning";"content",`Int 7];answer]] in
  match Codec.parse_response_result (Yojson.Safe.to_string json) with
  | Error error -> Alcotest.(check string) "malformed content carrier fails closed"
      "malformed_responses_reasoning:content" error
  | Ok _ -> Alcotest.fail "malformed content carrier silently disappeared"

let openai_opaque_policy_control () =
  let response=parse [reasoning "r" ~content:[text_part "reasoning_text" "plain reasoning"];answer] in
  let rows=input ~config:openai_config
    (restored_assistant ~config:openai_config response) [] in
  Alcotest.(check (list string)) "existing OpenAI policy still excludes plaintext" ["message"]
    (List.map(fun row->member "type" row |> to_string)rows)

let dedicated_contract () =
  let source=get(Reasoning_dialect.reasoning_source_for_provider_config config) in
  List.iter(fun tools_present ->
    let capability=get(Reasoning_dialect.replay_capability_for_provider_config ~tools_present config) in
    Alcotest.(check bool) "stamped source and request contract agree" true
      (source=capability.target && source.replay_contract=capability.contract
       && capability.contract.replay_policy=Reasoning_replay_contract.All_assistant_messages
       && capability.rotation=Reasoning_replay_contract.Require_identical_source)) [false;true]
let other_protocol_defaults () =
  List.iter(fun(kind,path)->
    let make override=Provider_config.make ~kind ~provider_id:"protocol-control"
      ~model_id:"protocol-control" ~base_url:"https://fixture.invalid" ~request_path:path
      ~model_capabilities_override:{Capabilities.default_capabilities with
        reasoning_replay_override=override} () in
    let before=Reasoning_dialect.for_provider_config(make Capabilities.Default_reasoning_replay) in
    let after=Reasoning_dialect.for_provider_config(make Capabilities.Force_preserve_responses_text) in
    Alcotest.(check bool) "Responses-only option leaves other protocol defaults" true (before=after))
    [Provider_config.OpenAI_compat,"/v1/chat/completions"
    ;Provider_config.Ollama,"/api/chat"
    ;Provider_config.Anthropic,"/v1/messages"
    ;Provider_config.Gemini,"/v1beta/models/fixture:generateContent"]
let chat_override_does_not_activate_responses () =
  let shared={config with Provider_config.model_capabilities_override=
    Some {Capabilities.default_capabilities with reasoning_replay_override=Force_preserve_always}} in
  let capability=get(Reasoning_dialect.replay_capability_for_provider_config shared) in
  Alcotest.(check bool) "Chat preserve-always cannot opt Responses into plaintext" true
    (capability.contract.replay_policy=Reasoning_replay_contract.Provider_opaque_state)
let manifest_declaration () =
  let manifest=get(Capability_manifest.of_json (Yojson.Safe.from_string
    {|{"schema_version":2,"models":[{"model_id":"declared-responses","reasoning_replay":"preserve_responses_text"}]}|})) in
  match Capability_manifest.entries manifest with
  | [entry] -> Alcotest.(check bool) "public manifest parses dedicated typed policy" true
      ((Capabilities.apply_manifest_entry entry).reasoning_replay_override=Force_preserve_responses_text)
  | [] | _::_ -> Alcotest.fail "one manifest entry expected"

let opaque_endpoint_control () =
  let response=parse [reasoning "r" ~encrypted:"endpoint-bound-token";answer] in
  let message=restored_assistant response in
  let rotated={config with Provider_config.base_url="https://rotated.invalid"} in
  let rows=input ~config:rotated message [] in
  Alcotest.(check (list string)) "plaintext admission does not rotate opaque tokens" ["message"]
    (List.map(fun row->member "type" row |> to_string)rows)

let () = Alcotest.run "responses_reasoning_content"
  ["public history",List.map(fun(name,fn)->Alcotest.test_case name `Quick fn)
    ["full content through tool and later turn",full_tool_history
    ;"full text precedes summary",full_over_summary
    ;"existing summary control",summary_control
    ;"blank full content fallback",blank_full_falls_back
    ;"opaque carrier control",encrypted_control
    ;"multiple native reasoning items",multiple_items
    ;"blank encrypted content",blank_encrypted
    ;"unknown content extensions",unknown_content_part
    ;"malformed recognized text",malformed_content
    ;"malformed content carrier",malformed_carrier
    ;"OpenAI opaque policy control",openai_opaque_policy_control
    ;"producer consumer contract identity",dedicated_contract
    ;"other protocol default controls",other_protocol_defaults
    ;"Chat override cannot activate Responses",chat_override_does_not_activate_responses
    ;"public manifest declaration",manifest_declaration
    ;"opaque endpoint binding",opaque_endpoint_control]]
