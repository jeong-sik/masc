(** Native catalog binding, without a capability override or provider HTTP. *)
open Llm_provider
open Types
open Yojson.Safe.Util

let models =
  [ "MiniMax-M2"; "MiniMax-M2.1"; "MiniMax-M2.1-highspeed"
  ; "MiniMax-M2.5"; "MiniMax-M2.5-highspeed"; "MiniMax-M2.7"
  ; "MiniMax-M2.7-highspeed"; "MiniMax-M3"; "MiniMax-M3.1-Flash" ]
let part kind text = `Assoc ["type",`String kind;"text",`String text]
let thought = `Assoc ["type",`String "reasoning";"id",`String "r1";
  "summary",`List [part "summary_text" "short"];"content",`List [part "reasoning_text" "full thought"]]
let call = `Assoc ["type",`String "function_call";"id",`String "item-call";
  "call_id",`String "call";"name",`String "lookup";"arguments",`String "{}"]
let tools = [`Assoc ["type",`String "function";"function",`Assoc [
  "name",`String "lookup";"parameters",`Assoc ["type",`String "object";"properties",`Assoc []]]]]
let response_json model = `Assoc ["id",`String "response";"model",`String model;
  "status",`String "completed";"output",`List [thought;call]]
let config model =
  let entry = match Provider_registry.find (Provider_registry.default ()) "minimax_responses" with
    | Some entry -> entry
    | None -> Alcotest.fail "shipped MiniMax Responses provider is absent" in
  Alcotest.(check string) "declared native endpoint" "https://api.minimax.io" entry.defaults.base_url;
  Alcotest.(check string) "declared Responses route" "/v1/responses" entry.defaults.request_path;
  Provider_config.make ~kind:entry.defaults.kind ~provider_id:entry.name ~model_id:model
    ~base_url:entry.defaults.base_url ~request_path:entry.defaults.request_path ~max_tokens:128 ()
let restored config response =
  let response = Complete_common.patch_telemetry response ~config None in
  let response = match Cache.response_of_json (Cache.response_to_json response) with
    | Some response -> response | None -> Alcotest.fail "response cache rejected native source" in
  let message = match assistant_message_of_response response with
    | Ok message -> message | Error error -> Alcotest.fail (show_assistant_message_error error) in
  let path = Filename.temp_file "minimax-responses-" ".json" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    Out_channel.with_open_bin path (fun ch -> output_string ch
      (Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json message)));
    let json = In_channel.with_open_bin path In_channel.input_all |> Yojson.Safe.from_string in
    match Agent_core.Checkpoint.message_of_json json with
    | Ok message -> message | Error _ -> Alcotest.fail "checkpoint message rejected native source")
let stream model =
  let state = Streaming.create_openai_stream_state () in
  let acc = Complete_stream_acc.create_stream_acc () in
  let feed event json =
    let events,_ = Streaming.responses_sse_to_events state (Some event) (Yojson.Safe.to_string json) in
    List.iter (Complete_stream_acc.accumulate_event acc) events in
  feed "response.created" (`Assoc ["response",`Assoc ["id",`String "response";"model",`String model]]);
  feed "response.reasoning_summary_text.delta" (`Assoc ["output_index",`Int 0;"summary_index",`Int 0;"delta",`String "short"]);
  feed "response.reasoning_text.delta" (`Assoc ["output_index",`Int 0;"content_index",`Int 0;"delta",`String "full thought"]);
  feed "response.completed" (`Assoc ["response",response_json model]);
  match Complete_stream_acc.finalize_stream_acc acc with
  | Ok response -> response | Error _ -> Alcotest.fail "native Responses stream failed"
let request config messages = Backend_openai_responses.build_request ~config ~messages ~tools ()
  |> Yojson.Safe.from_string
let native_replay model =
  let config = config model in
  let caps = match Provider_config.capabilities_for_config_model config with
    | Some caps -> caps | None -> Alcotest.fail "exact native Responses model is absent" in
  Alcotest.(check bool) "dedicated Responses plaintext declaration" true
    (caps.reasoning_replay_override=Capabilities.Force_preserve_responses_text);
  let capability = match Reasoning_dialect.replay_capability_for_provider_config config with
    | Ok capability -> capability | Error detail -> Alcotest.fail detail in
  let producer = capability.target.replay_contract in
  let consumer = capability.contract in
  Alcotest.(check bool) "native producer and consumer contract agree" true
    (producer=consumer && producer.replay_policy=All_assistant_messages);
  let sync = match Backend_openai_responses.parse_response_result
      (Yojson.Safe.to_string (response_json model)) with
    | Ok response -> response | Error detail -> Alcotest.fail detail in
  List.iter (fun (mode,response) ->
    let first = restored config response in
    let messages = [first;make_message ~role:Tool [ToolResult {tool_use_id="call";
      content="receipt";outcome=Tool_succeeded;json=None;content_blocks=None}];
      make_message ~role:User [Text "later user"]] in
    let rows = request config messages |> member "input" |> to_list in
    Alcotest.(check int) (mode^" reasoning/call/result/user order") 4 (List.length rows);
    Alcotest.(check string) (mode^" full reasoning reaches documented summary input") "full thought"
      (List.hd rows |> member "summary" |> to_list |> List.hd |> member "text" |> to_string);
    Alcotest.(check string) (mode^" original call identity") "call" (List.nth rows 1 |> member "call_id" |> to_string);
    Alcotest.(check string) (mode^" tool result identity") "call" (List.nth rows 2 |> member "call_id" |> to_string);
    Alcotest.(check bool) (mode^" later human input retained") true
      (List.nth rows 3 |> member "content" = `List [part "input_text" "later user"]))
    ["sync",sync;"SSE",stream model];
  let auto = request {config with tool_choice=Some Auto} [] in
  Alcotest.(check string) "documented automatic tool choice" "auto" (member "tool_choice" auto |> to_string);
  List.iter (fun choice -> Alcotest.(check bool) "undocumented forcing rejected before HTTP" true
    (Result.is_error (Provider_config.validate_tool_choice_request_typed {config with tool_choice=Some choice})))
    [Any;Tool "lookup"];
  let without_tools = request {config with tool_choice=Some None_} [] in
  Alcotest.(check bool) "tool-free request emits no undocumented none value" true
    (member "tools" without_tools=`Null && member "tool_choice" without_tools=`Null);
  List.iter (fun effort ->
    let request = request {config with reasoning_effort=Some effort} [] in
    Alcotest.(check string) "documented effort stays in Responses reasoning object"
      (Reasoning_effort.to_string effort) (request |> member "reasoning" |> member "effort" |> to_string))
    [Reasoning_effort.Low;Medium;High;XHigh;Max];
  let flash = String.equal model "MiniMax-M3.1-Flash" in
  List.iter (fun effort -> Alcotest.(check bool) "model-specific effort boundary" (not flash)
    (Result.is_ok (Provider_config.validate_reasoning_effort_request_typed
      {config with reasoning_effort=Some effort}))) [Reasoning_effort.None_;Minimal];
  Alcotest.(check bool) "explicit disable follows the declared model ladder" (not flash)
    (Result.is_ok (Provider_config.validate_reasoning_effort_request_typed {config with enable_thinking=Some false}))

let () = Alcotest.run "minimax_responses_binding"
  ["native models",List.map (fun model -> model,`Quick,(fun () -> native_replay model)) models]
