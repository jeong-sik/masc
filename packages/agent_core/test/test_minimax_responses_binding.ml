(** Native catalog binding, without a capability override or provider HTTP. *)
open Llm_provider
open Types
open Yojson.Safe.Util

type family = Toggle_only | Effort_depth
let models = ["MiniMax-M3",Toggle_only;"MiniMax-M3.1-Flash",Effort_depth]

let part kind text = `Assoc ["type",`String kind;"text",`String text]
let thought = `Assoc ["type",`String "reasoning";"id",`String "r1";
  "summary",`List [part "summary_text" "short"];"content",`List [part "reasoning_text" "full thought"]]
let call = `Assoc ["type",`String "function_call";"id",`String "item-call";
  "call_id",`String "call";"name",`String "lookup";"arguments",`String "{}"]
let tools = [`Assoc ["name",`String "lookup";"description",`String "Lookup a receipt";
  "input_schema",`Assoc ["type",`String "object";"properties",`Assoc []]]]
let response_json model = `Assoc ["id",`String "response";"model",`String model;
  "status",`String "completed";"output",`List [thought;call]]
let config model =
  let entry = match Provider_registry.find (Provider_registry.default ()) "minimax_responses" with
    | Some entry -> entry
    | None -> Alcotest.fail "shipped MiniMax Responses provider is absent" in
  Alcotest.(check bool) "native provider requires explicit credentials" true entry.defaults.requires_api_key;
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
  let media_store = Agent_core.History.Memory_store.create () in
  let message = match Agent_core.History.of_wire_message media_store message with
    | Ok message -> message | Error error -> Alcotest.fail (Agent_core.History.show_media_error error) in
  let path = Filename.temp_file "minimax-responses-" ".json" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    Out_channel.with_open_bin path (fun ch -> output_string ch
      (Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json message)));
    let json = In_channel.with_open_bin path In_channel.input_all |> Yojson.Safe.from_string in
    match Agent_core.Checkpoint.message_of_json json with
    | Error _ -> Alcotest.fail "checkpoint message rejected native source"
    | Ok message ->
      match Agent_core.History.to_wire_message media_store message with
      | Ok message -> message | Error error -> Alcotest.fail (Agent_core.History.show_media_error error))
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
let request config messages =
  match Complete_common.serialize_http_request ~stream:false ~config ~messages ~tools with
  | Ok serialized -> Yojson.Safe.from_string serialized.Complete_common.body
  | Error _ -> Alcotest.fail "native registry binding failed final HTTP serialization"
let native_replay model family =
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
    let config = {config with reasoning_effort=Some effort} in
    match family with
    | Toggle_only | Effort_depth ->
      let request = request config [] in
      Alcotest.(check string) "documented effort stays in Responses reasoning object"
        (Reasoning_effort.to_string effort) (request |> member "reasoning" |> member "effort" |> to_string))
    [Reasoning_effort.Low;Medium;High;XHigh;Max];
  List.iter (fun effort ->
    let accepted = match family with Toggle_only -> true | Effort_depth -> false in
    Alcotest.(check bool) "model-specific effort boundary" accepted
      (Result.is_ok (Provider_config.validate_reasoning_effort_request_typed
        {config with reasoning_effort=Some effort}))) [Reasoning_effort.None_;Minimal];
  let can_disable = match family with Toggle_only -> true | Effort_depth -> false in
  Alcotest.(check bool) "explicit disable follows the declared control semantics" can_disable
    (Complete_common.thinking_control_request_rejection ~caps {config with enable_thinking=Some false}=None)

(* Admission must honor the native default before final wire serialization. *)
let native_default_control model family =
  let config = config model in
  let request stream config =
    Alcotest.(check bool) "full public admission" true
      (Result.is_ok (Complete_common.validate_all config));
    match Complete_common.serialize_http_request ~stream ~config
        ~messages:[make_message ~role:User [Text "Compare receipts"]] ~tools:[] with
    | Ok serialized -> Yojson.Safe.from_string serialized.Complete_common.body
    | Error _ -> Alcotest.fail "admitted native control failed serialization" in
  List.iter (fun stream ->
    let body = request stream config in
    Alcotest.(check bool) "omitted depth stays omitted" true
      (member "reasoning" body = `Null);
    match family with
    | Toggle_only ->
      Alcotest.(check bool) "M3 enable requires a non-none effort" true
        (Result.is_error (Complete_common.validate_all
          {config with enable_thinking=Some true}));
      let body = request stream {config with enable_thinking=Some true;
        reasoning_effort=Some Reasoning_effort.Low} in
      Alcotest.(check string) "M3 explicit enable carries its effort" "low"
        (body |> member "reasoning" |> member "effort" |> to_string)
    | Effort_depth ->
      let body = request stream {config with enable_thinking=Some true} in
      Alcotest.(check bool) "default-on enable does not invent a depth" true
        (member "reasoning" body = `Null);
      Alcotest.(check bool) "no competing thinking object" true
        (member "thinking" body = `Null);
      List.iter (fun effort ->
        Alcotest.(check bool) "unsupported M3.1 effort fails full admission" true
          (Result.is_error (Complete_common.validate_all
            {config with reasoning_effort=Some effort}))) [Reasoning_effort.None_;Minimal];
      Alcotest.(check bool) "M3.1 cannot disable thinking" true
        (Result.is_error (Complete_common.validate_all
          {config with enable_thinking=Some false}))) [false;true]

let () = Alcotest.run "minimax_responses_binding"
  ["native models",List.map (fun (model,family) -> model,`Quick,(fun () -> native_replay model family)) models;
   "default control",List.map (fun (model,family) -> model,`Quick,(fun () -> native_default_control model family)) models]
