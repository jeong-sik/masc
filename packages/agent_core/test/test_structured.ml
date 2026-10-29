(** Unit tests for Structured output module. *)

open Agent_core
module Types = Llm_provider.Types
open Types

(* --- Test schema --- *)

let person_schema : (string * int) Structured.schema =
  { params =
      [ { name = "name"
        ; description = "Person name"
        ; param_type = String
        ; required = true
        }
      ; { name = "age"
        ; description = "Person age"
        ; param_type = Integer
        ; required = true
        }
      ]
  ; parse =
      (fun json ->
        let open Yojson.Safe.Util in
        try
          let name = json |> member "name" |> to_string in
          let age = json |> member "age" |> to_int in
          Ok (name, age)
        with
        | exn -> Error (Printexc.to_string exn))
  }
;;

(* --- schema_to_json_schema --- *)

let test_schema_to_json_structure () =
  let json = Structured.schema_to_json_schema person_schema in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type is object" "object" (json |> member "type" |> to_string);
  let props = json |> member "properties" in
  Alcotest.(check string)
    "name prop type"
    "string"
    (props |> member "name" |> member "type" |> to_string);
  Alcotest.(check string)
    "age prop type"
    "integer"
    (props |> member "age" |> member "type" |> to_string);
  let required = json |> member "required" |> to_list |> List.map to_string in
  Alcotest.(check bool) "name required" true (List.mem "name" required);
  Alcotest.(check bool) "age required" true (List.mem "age" required)
;;

let test_schema_to_json_schema_structure () =
  let json = Structured.schema_to_json_schema person_schema in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "object" (json |> member "type" |> to_string);
  Alcotest.(check bool)
    "no tool wrapper name"
    true
    (match member "name" json with
     | `Null -> true
     | _ -> false);
  let props = json |> member "properties" in
  Alcotest.(check string)
    "name prop type"
    "string"
    (props |> member "name" |> member "type" |> to_string)
;;

let test_schema_optional_params () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "required_f"; description = "R"; param_type = String; required = true }
        ; { name = "optional_f"
          ; description = "O"
          ; param_type = String
          ; required = false
          }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let required = json |> member "required" |> to_list |> List.map to_string in
  Alcotest.(check bool) "required_f in list" true (List.mem "required_f" required);
  Alcotest.(check bool) "optional_f not in list" false (List.mem "optional_f" required)
;;

let test_schema_empty_params () =
  let schema : unit Structured.schema = { params = []; parse = (fun _ -> Ok ()) } in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let props = json |> member "properties" |> to_assoc in
  Alcotest.(check int) "no properties" 0 (List.length props);
  let required = json |> member "required" |> to_list in
  Alcotest.(check int) "no required" 0 (List.length required)
;;

let test_schema_all_param_types () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "s"; description = "string"; param_type = String; required = true }
        ; { name = "i"; description = "integer"; param_type = Integer; required = true }
        ; { name = "n"; description = "number"; param_type = Number; required = false }
        ; { name = "b"; description = "boolean"; param_type = Boolean; required = false }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let props = json |> member "properties" in
  Alcotest.(check string)
    "string type"
    "string"
    (props |> member "s" |> member "type" |> to_string);
  Alcotest.(check string)
    "integer type"
    "integer"
    (props |> member "i" |> member "type" |> to_string);
  Alcotest.(check string)
    "number type"
    "number"
    (props |> member "n" |> member "type" |> to_string);
  Alcotest.(check string)
    "boolean type"
    "boolean"
    (props |> member "b" |> member "type" |> to_string);
  let required = json |> member "required" |> to_list |> List.map to_string in
  Alcotest.(check int) "2 required" 2 (List.length required);
  Alcotest.(check bool) "s required" true (List.mem "s" required);
  Alcotest.(check bool) "i required" true (List.mem "i" required);
  Alcotest.(check bool) "n not required" false (List.mem "n" required);
  Alcotest.(check bool) "b not required" false (List.mem "b" required)
;;

let test_param_description_preserved () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "x"
          ; description = "field X description"
          ; param_type = String
          ; required = true
          }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let x_desc =
    json |> member "properties" |> member "x" |> member "description" |> to_string
  in
  Alcotest.(check string) "param desc" "field X description" x_desc
;;

let test_schema_mixed_required () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "a"; description = "A"; param_type = String; required = true }
        ; { name = "b"; description = "B"; param_type = String; required = false }
        ; { name = "c"; description = "C"; param_type = Integer; required = true }
        ; { name = "d"; description = "D"; param_type = Boolean; required = false }
        ; { name = "e"; description = "E"; param_type = Number; required = true }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  let required = json |> member "required" |> to_list |> List.map to_string in
  Alcotest.(check int) "3 required" 3 (List.length required);
  Alcotest.(check bool) "a required" true (List.mem "a" required);
  Alcotest.(check bool) "c required" true (List.mem "c" required);
  Alcotest.(check bool) "e required" true (List.mem "e" required)
;;

(* --- Extractors --- *)

let make_response ?(stop_reason = EndTurn) content : Types.api_response =
  { id = "m"
  ; model = "m"
  ; stop_reason
  ; content
  ; usage = None
  ; telemetry = None
  }
;;

let test_json_extractor_success () =
  let extract =
    Structured.json_extractor (fun json ->
      Yojson.Safe.Util.(json |> member "value" |> to_int))
  in
  let resp = make_response [ Text {|{"value": 42}|} ] in
  match extract resp with
  | Ok v -> Alcotest.(check int) "extracted value" 42 v
  | Error e -> Alcotest.fail e
;;

let test_json_extractor_invalid_json () =
  let extract = Structured.json_extractor (fun _ -> 0) in
  let resp = make_response [ Text "not json" ] in
  match extract resp with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected parse error"
;;

let test_json_extractor_no_text () =
  let extract = Structured.json_extractor (fun _ -> 0) in
  let resp = make_response [] in
  match extract resp with
  | Error msg -> Alcotest.(check bool) "mentions no text" true (String.length msg > 0)
  | Ok _ -> Alcotest.fail "expected error"
;;

let test_response_json_extractor_object_success () =
  let extract = Structured.response_json_extractor ~shape:Structured.Object_json () in
  let resp = make_response [ Text {|{"value": 42}|} ] in
  match extract resp with
  | Ok (`Assoc fields) ->
    Alcotest.(check bool) "value field present" true (List.mem_assoc "value" fields)
  | Ok _ -> Alcotest.fail "expected JSON object"
  | Error e -> Alcotest.fail e
;;

let test_response_json_extractor_rejects_fenced_object () =
  let extract = Structured.response_json_extractor ~shape:Structured.Object_json () in
  let resp = make_response [ Text "```json\n{\"ok\":true}\n```" ] in
  match extract resp with
  | Error e -> Alcotest.(check bool) "has parse error text" true (String.length e > 0)
  | Ok _ -> Alcotest.fail "expected fenced JSON rejection"
;;

let test_response_json_extractor_any_accepts_array () =
  let extract = Structured.response_json_extractor () in
  let resp = make_response [ Text "[1,2,3]" ] in
  match extract resp with
  | Ok (`List values) -> Alcotest.(check int) "array length" 3 (List.length values)
  | Ok _ -> Alcotest.fail "expected JSON array"
  | Error e -> Alcotest.fail e
;;

let test_response_json_extractor_object_rejects_array () =
  let extract = Structured.response_json_extractor ~shape:Structured.Object_json () in
  let resp = make_response [ Text "[1,2,3]" ] in
  match extract resp with
  | Error e -> Alcotest.(check bool) "has error text" true (String.length e > 0)
  | Ok _ -> Alcotest.fail "expected object shape error"
;;

(* A tool result is an execution payload, not the answer. It used to be
   joined to the Text block before parsing, so a turn carrying both could
   not parse as JSON (#27868). *)
let test_response_json_extractor_ignores_tool_result () =
  let extract = Structured.response_json_extractor ~shape:Structured.Object_json () in
  let resp =
    make_response
      [ ToolResult
          { tool_use_id = "t1"
          ; content = "tool stdout, not JSON"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ; Text {|{"value": 42}|}
      ]
  in
  match extract resp with
  | Ok (`Assoc fields) ->
    Alcotest.(check bool) "value field present" true (List.mem_assoc "value" fields)
  | Ok _ -> Alcotest.fail "expected JSON object"
  | Error e -> Alcotest.fail e
;;

let test_text_extractor_success () =
  let extract =
    Structured.text_extractor (fun s ->
      if String.length s > 0 then Some (String.length s) else None)
  in
  let resp = make_response [ Text "hello world" ] in
  match extract resp with
  | Ok v -> Alcotest.(check int) "text length" 11 v
  | Error e -> Alcotest.fail e
;;

let test_text_extractor_none () =
  let extract = Structured.text_extractor (fun _ -> None) in
  let resp = make_response [ Text "anything" ] in
  match extract resp with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error"
;;

let test_schema_extractor_success () =
  let extract = Structured.schema_extractor person_schema in
  let resp = make_response [ Text "{\"name\":\"Dana\",\"age\":42}" ] in
  match extract resp with
  | Ok (name, age) ->
    Alcotest.(check string) "name" "Dana" name;
    Alcotest.(check int) "age" 42 age
  | Error e -> Alcotest.fail e
;;

let test_schema_extractor_parse_failure () =
  let extract = Structured.schema_extractor person_schema in
  let resp = make_response [ Text "{\"name\":123}" ] in
  match extract resp with
  | Error e -> Alcotest.(check bool) "has error text" true (String.length e > 0)
  | Ok _ -> Alcotest.fail "expected schema parse error"
;;

let test_schema_extractor_parser_json_error () =
  let schema : unit Structured.schema =
    { params = []
    ; parse =
        (fun json ->
          let open Yojson.Safe.Util in
          let nested = json |> member "nested" |> to_string in
          ignore (Yojson.Safe.from_string nested : Yojson.Safe.t);
          Ok ())
    }
  in
  let extract = Structured.schema_extractor schema in
  let resp = make_response [ Text {|{"nested":"{"}|} ] in
  match extract resp with
  | Error e -> Alcotest.(check bool) "has json error text" true (String.length e > 0)
  | Ok _ -> Alcotest.fail "expected parser json error"
;;

(* --- Runner --- *)

let check_private_evidence ~reason ~raw = function
  | Error (Error.Serialization (StructuredOutputParseError evidence) as error) ->
    Alcotest.(check bool) "closed failure class" true (evidence.reason = reason);
    Alcotest.(check int) "original response byte count" (String.length raw) evidence.raw_len;
    Alcotest.(check bool) "preview is bounded" true (String.length evidence.raw_preview <= 4096);
    Alcotest.(check string) "preview preserves the original prefix"
      (String.sub raw 0 (String.length evidence.raw_preview)) evidence.raw_preview;
    Alcotest.(check string) "public message contains no private fragments"
      (Printf.sprintf "Structured output parse error: %s (response bytes: %d)"
         (Error.structured_failure_label reason) (String.length raw))
      (Error.to_string error);
    Alcotest.(check bool) "parse failure remains nonretryable" false (Error.is_retryable error)
  | Error ((Api _ | Provider _ | Agent _ | Mcp _ | Config _
           | Serialization (JsonParseError _ | StructuredOutputStateError _ | VersionMismatch _ | UnknownVariant _)
           | Io _ | Orchestration _ | Internal _ | Internal_carried _ | Media _) as error) ->
    Alcotest.failf "expected structured evidence, got %s" (Error.to_string error)
  | Ok _ -> Alcotest.fail "invalid response was accepted"
;;

let test_malformed_response_retains_original_evidence () =
  let raw = " \n```json\n{\"secret\":\"private-model-output\"}\n``` \n" in
  Structured.extract_response_json (make_response [Text raw])
  |> check_private_evidence ~reason:Error.Invalid_json ~raw
;;

let test_empty_response_has_public_failure_class () =
  let raw = " \n\t " in
  Structured.extract_response_json (make_response [Text raw])
  |> check_private_evidence ~reason:Error.Empty_response ~raw
;;

let test_schema_refusal_retains_response_without_public_detail () =
  let raw = " {\"name\":123,\"secret\":\"private-model-output\"} " in
  let schema : unit Structured.schema =
    { params = []; parse = (fun _ -> Error ("private-schema-detail:" ^ raw)) }
  in
  Structured.extract_response ~schema (make_response [Text raw])
  |> check_private_evidence ~reason:Error.Schema_rejected ~raw
;;

let test_schema_type_exception_retains_response () =
  let raw = {|{"name":123}|} in
  let schema : string Structured.schema =
    { params = []; parse = (fun json -> Ok Yojson.Safe.Util.(json |> member "name" |> to_string)) }
  in
  Structured.extract_response ~schema (make_response [Text raw])
  |> check_private_evidence ~reason:Error.Schema_type_mismatch ~raw
;;

let test_schema_json_exception_has_distinct_schema_class () =
  let raw = {|{"nested":"private-schema-fragment"}|} in
  let schema : Yojson.Safe.t Structured.schema =
    { params = []
    ; parse = (fun json -> Ok (Yojson.Safe.from_string Yojson.Safe.Util.(json |> member "nested" |> to_string)))
    }
  in
  Structured.extract_response ~schema (make_response [Text raw])
  |> check_private_evidence ~reason:Error.Schema_rejected ~raw
;;

let test_response_shape_failure_retains_response () =
  let raw = " [1,2,3] \n" in
  Structured.extract_response_json ~shape:Structured.Object_json (make_response [Text raw])
  |> check_private_evidence ~reason:Error.Expected_object ~raw
;;

let test_long_response_evidence_keeps_utf8_boundary () =
  let raw = String.make 4095 'x' ^ "한글-private-model-output" ^ String.make 10000 'y' in
  let error = Error.structured_output_parse_error ~reason:Error.Invalid_json ~detail:raw ~raw in
  check_private_evidence ~reason:Error.Invalid_json ~raw (Error error);
  match error with
  | Error.Serialization (StructuredOutputParseError evidence) ->
    Alcotest.(check int) "no split UTF-8 character" 4095 (String.length evidence.raw_preview);
    Alcotest.(check bool) "valid UTF-8 preview" true (String.is_valid_utf_8 evidence.raw_preview);
    Alcotest.(check bool) "private diagnostic is also bounded" true (String.length evidence.detail <= 4096)
  | Api _ | Provider _ | Agent _ | Mcp _ | Config _
  | Serialization (JsonParseError _ | StructuredOutputStateError _ | VersionMismatch _ | UnknownVariant _)
  | Io _ | Orchestration _ | Internal _ | Internal_carried _ | Media _ ->
    Alcotest.fail "wrong evidence constructor"
;;

let test_public_extractors_keep_safe_failure_class () =
  let check_public label raw = function
    | Error message ->
      Alcotest.(check string) "public class without model/parser fragments"
        (Printf.sprintf "Structured output parse error: %s (response bytes: %d)"
           label (String.length raw)) message
    | Ok _ -> Alcotest.fail "invalid response was accepted"
  in
  let check_json ?shape label raw =
    Structured.response_json_extractor ?shape () (make_response [Text raw])
    |> check_public label raw
  in
  check_json "empty_response" " \n ";
  check_json "invalid_json" "private-model-output";
  check_json ~shape:Structured.Object_json "expected_object" "[]";
  let raw = {|{"name":123}|} in
  let refused : unit Structured.schema =
    {params=[]; parse=(fun _ -> Error "private-schema-fragment")} in
  Structured.schema_extractor refused (make_response [Text raw])
  |> check_public "schema_rejected" raw;
  let typed : string Structured.schema =
    {params=[]; parse=(fun json -> Ok Yojson.Safe.Util.(json |> member "name" |> to_string))} in
  Structured.schema_extractor typed (make_response [Text raw])
  |> check_public "schema_type_mismatch" raw
;;

let check_response_state expected response =
  let state =
    match Structured.inspect_response_json response with
    | Awaiting_tool_results -> Error.Awaiting_tool_results
    | Refused reason -> Error.Refused_response reason
    | Truncated reason -> Error.Truncated_response reason
    | Interrupted reason -> Error.Interrupted_response reason
    | Ready _ -> Alcotest.fail "nonterminal response was accepted as JSON"
    | Invalid error -> Alcotest.failf "response state became parse failure: %s"
        (Error.to_string error)
  in
  Alcotest.(check bool) "closed response state" true (state = expected);
  let check_result = function
    | Error (Error.Serialization (StructuredOutputStateError actual)) ->
      Alcotest.(check bool) "Result wrapper preserves state" true (actual = expected)
    | Error ((Api _ | Provider _ | Agent _ | Mcp _ | Config _
             | Serialization (JsonParseError _ | StructuredOutputParseError _
                 | VersionMismatch _ | UnknownVariant _)
             | Io _ | Orchestration _ | Internal _ | Internal_carried _ | Media _) as error) ->
      Alcotest.failf "wrong error family: %s" (Error.to_string error)
    | Ok _ -> Alcotest.fail "Result wrapper accepted a nonterminal response"
  in
  check_result (Structured.extract_response_json response);
  let parse_calls = ref 0 in
  let schema : unit Structured.schema =
    {params=[]; parse=(fun _ -> incr parse_calls; Ok ())} in
  check_result (Structured.extract_response ~schema response);
  Alcotest.(check int) "schema parser was not invoked" 0 !parse_calls;
  Alcotest.(check string) "public state has no provider fragments"
    ("Structured output response state: " ^ Error.structured_response_state_label expected)
    (Error.to_string (Error.Serialization (StructuredOutputStateError state)))
;;

let test_authoritative_stop_states_precede_valid_json () =
  List.iter (fun (stop_reason, expected) ->
    check_response_state expected
      (make_response ~stop_reason [Text {|{"value":"private-provider-text"}|}]))
    [ Refusal, Error.Refused_response Policy_refusal
    ; ContentFilter, Error.Refused_response Content_filtered
    ; MaxTokens, Error.Truncated_response Token_limit
    ; RepetitionTruncation, Error.Truncated_response Repetition_limit
    ; ContextWindowExceeded, Error.Truncated_response Context_limit
    ; PauseTurn, Error.Interrupted_response Paused_turn
    ; Compaction, Error.Interrupted_response Compacted_turn
    ; UnmatchedToolCalls, Error.Interrupted_response Missing_tool_calls
    ; StopToolUse, Error.Interrupted_response Missing_tool_calls
    ; Unknown "private-provider-text", Error.Interrupted_response Unknown_stop
    ]
;;

let test_tool_call_turn_requires_tool_results_before_json () =
  let tool = Llm_provider.Types.ToolUse {id="call";name="lookup";input=`Assoc []} in
  List.iter (fun stop_reason ->
    List.iter (fun content ->
      check_response_state Error.Awaiting_tool_results
        (make_response ~stop_reason content))
      [[tool]; [Text {|{"value":42}|}; tool]])
    [StopToolUse; EndTurn; StopSequence];
  let terminal = make_response
      [Thinking {content="private thought";signature=None}
      ;ToolResult {tool_use_id="call";content="not-json";outcome=Tool_succeeded;
          json=None;content_blocks=None}
      ;Text " \n{\"value\":42} \n"] in
  match Structured.inspect_response_json terminal with
  | Ready json -> Alcotest.(check string) "terminal JSON after tool results"
      {|{"value":42}|} (Yojson.Safe.to_string json)
  | Awaiting_tool_results | Refused _ | Truncated _ | Interrupted _ | Invalid _ ->
    Alcotest.fail "terminal single Text payload was not accepted"
;;

let test_multiple_text_blocks_are_ambiguous_even_at_whitespace_boundaries () =
  List.iter (fun texts ->
    let content = List.map (fun text -> Text text) texts in
    let raw = String.concat "\n" texts in
    Structured.extract_response_json (make_response content)
    |> check_private_evidence ~reason:Error.Multiple_text_blocks ~raw)
    [["{}";"{}"]; ["{";"}"]; [" \n";"{}"]; ["{}";"\t "]]
;;

(* #27868: exercise wire parser -> canonical response -> structured outcome,
   rather than constructing the terminal stop reason in the fixture. *)
module Wire_stream = Llm_provider.Streaming
module Wire_acc = Llm_provider.Complete_stream_acc

let finalized_wire_response acc =
  match Wire_acc.finalize_stream_acc acc with
  | Ok response -> response
  | Error _ -> Alcotest.fail "provider wire fixture did not finalize"
;;

let check_wire_ready response =
  match Structured.inspect_response_json response with
  | Ready json -> Alcotest.(check string) "terminal JSON" "{}" (Yojson.Safe.to_string json)
  | Awaiting_tool_results | Refused _ | Truncated _ | Interrupted _ | Invalid _ ->
    Alcotest.fail "normal terminal wire JSON was not accepted"
;;

let test_chat_wire_states_reach_structured () =
  let call = `Assoc ["id", `String "call"; "type", `String "function";
    "function", `Assoc ["name", `String "lookup"; "arguments", `String "{}"]] in
  let cases =
    [ "refusal", "stop", ["refusal", `String "declined"], `Null,
        Some (Error.Refused_response Policy_refusal)
    ; "refusal with JSON", "stop", ["refusal", `String "declined"], `String "{}",
        Some (Error.Refused_response Policy_refusal)
    ; "filter", "content_filter", [], `Null,
        Some (Error.Refused_response Content_filtered)
    ; "token limit with JSON", "length", [], `String "{}",
        Some (Error.Truncated_response Token_limit)
    ; "tool intermediate", "tool_calls", ["tool_calls", `List [call]], `Null,
        Some Error.Awaiting_tool_results
    ; "terminal", "stop", [], `String "{}", None ] in
  List.iter (fun (label, finish, fields, content, expected) ->
    let project response = match expected with
      | Some state -> check_response_state state response
      | None -> check_wire_ready response in
    let wire_message = `Assoc (("content", content) :: ("role", `String "assistant") :: fields) in
    let sync = `Assoc ["id", `String "structured-wire"; "model", `String "chat-fixture";
      "choices", `List [`Assoc ["message", wire_message; "finish_reason", `String finish]]] in
    (match Llm_provider.Backend_openai_parse.parse_openai_response_result_json sync with
     | Ok response -> project response
     | Error error -> Alcotest.failf "%s sync: %s" label
         (Llm_provider.Backend_openai_parse.parse_error_to_string error));
    let state = Wire_stream.create_openai_stream_state () in
    let acc = Wire_acc.create_stream_acc () in
    let feed wire =
      let parsed = Wire_stream.parse_openai_sse_chunk
          ~streaming_reasoning:Llm_provider.Reasoning_dialect.No_streaming_reasoning wire in
      let events, _ = Wire_stream.openai_sse_parse_result_to_events state parsed in
      List.iter (Wire_acc.accumulate_event acc) events in
    let indexed_fields = List.map (fun (name, value) ->
      match name, value with
      | "tool_calls", `List [_] ->
        (match call with
         | `Assoc fields -> name, `List [`Assoc (("index", `Int 0) :: fields)]
         | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
           Alcotest.fail "tool fixture must be an object")
      | _ -> name, value) fields in
    feed (Yojson.Safe.to_string (`Assoc ["id", `String "structured-wire";
      "model", `String "chat-fixture"; "choices", `List [`Assoc ["index", `Int 0;
      "delta", `Assoc (("content", content) :: indexed_fields);
      "finish_reason", `String finish]]]));
    feed "[DONE]";
    project (finalized_wire_response acc)) cases
;;

let test_responses_wire_states_reach_structured () =
  let response ~status ~output extra = `Assoc
      (["id", `String "structured-response"; "model", `String "responses-fixture";
        "status", `String status; "output", `List output] @ extra) in
  let text = `Assoc ["type", `String "message"; "id", `String "message";
      "role", `String "assistant"; "content", `List
      [`Assoc ["type", `String "output_text"; "text", `String "{}"; "annotations", `List []]]] in
  let refused = `Assoc ["type", `String "message"; "role", `String "assistant";
      "content", `List [`Assoc ["type", `String "refusal"; "refusal", `String "declined"]]] in
  let call = `Assoc ["type", `String "function_call"; "id", `String "item-call";
      "call_id", `String "call"; "name", `String "lookup"; "arguments", `String "{}"] in
  List.iter (fun (wire, expected) ->
    match Llm_provider.Backend_openai_responses.parse_response_result (Yojson.Safe.to_string wire) with
    | Error detail -> Alcotest.fail detail
    | Ok response -> (match expected with
      | Some state -> check_response_state state response
      | None -> check_wire_ready response))
    [ response ~status:"completed" ~output:[refused] [], Some (Error.Refused_response Policy_refusal)
    ; response ~status:"incomplete" ~output:[text]
        ["incomplete_details", `Assoc ["reason", `String "max_output_tokens"]],
        Some (Error.Truncated_response Token_limit)
    ; response ~status:"completed" ~output:[call] [], Some Error.Awaiting_tool_results
    ; response ~status:"completed" ~output:[text] [], None ];
  (* Both refusal event families must survive even when the terminal snapshot
     has no refusal item. JSON text already emitted must not become success. *)
  List.iter (fun (refusal_event, refusal_fields) ->
    let state = Wire_stream.create_openai_stream_state () in
    let acc = Wire_acc.create_stream_acc () in
    let feed kind fields =
      let events, _ = Wire_stream.responses_sse_to_events state (Some kind)
          (Yojson.Safe.to_string (`Assoc fields)) in
      List.iter (Wire_acc.accumulate_event acc) events in
    feed "response.created" ["response", response ~status:"in_progress" ~output:[] []];
    feed "response.output_text.delta" ["output_index", `Int 0; "content_index", `Int 0;
      "delta", `String "{}"];
    feed refusal_event refusal_fields;
    feed "response.completed" ["response", response ~status:"completed" ~output:[] []];
    check_response_state (Error.Refused_response Policy_refusal) (finalized_wire_response acc))
    ["response.refusal.delta", ["delta", `String "declined"];
     "response.refusal.done", ["refusal", `String "declined"]]
;;

let test_gemini_wire_states_reach_structured () =
  List.iter (fun (finish, expected) ->
    let wire = `Assoc ["responseId", `String "gemini-structured";
      "modelVersion", `String "gemini-fixture"; "candidates", `List [`Assoc
        ["content", `Assoc ["parts", `List [`Assoc ["text", `String "{}"]]];
         "finishReason", `String finish]]] in
    let project response = match expected with
      | Some state -> check_response_state state response
      | None -> check_wire_ready response in
    project (Llm_provider.Backend_gemini.parse_response wire);
    let state = Wire_stream.create_openai_stream_state () in
    let acc = Wire_acc.create_stream_acc () in
    let chunk = match Wire_stream.parse_gemini_sse_chunk (Yojson.Safe.to_string wire) with
      | Gemini_chunk chunk -> chunk
      | Gemini_provider_error _ | Gemini_unsupported_part _ | Gemini_unsupported_response _
      | Gemini_parse_failed _ ->
        Alcotest.fail "Gemini wire fixture did not parse" in
    (match Wire_stream.gemini_chunk_to_events state chunk with
     | Error error -> Alcotest.fail error.reason
     | Ok (events, _) -> List.iter (Wire_acc.accumulate_event acc) events);
    project (finalized_wire_response acc))
    ["SAFETY", Some (Error.Refused_response Policy_refusal);
     "MAX_TOKENS", Some (Error.Truncated_response Token_limit); "STOP", None]
;;

let test_anthropic_wire_thinking_precedes_terminal_text () =
  let acc = Wire_acc.create_stream_acc () in
  List.iter (fun wire ->
    match Wire_stream.parse_sse_event None wire with
    | Some event -> Wire_acc.accumulate_event acc event
    | None -> Alcotest.fail "Anthropic structured wire fixture was ignored")
    [ {|{"type":"message_start","message":{"id":"structured-anthropic","model":"claude-fixture"}}|}
    ; {|{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}|}
    ; {|{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private thought"}}|}
    ; {|{"type":"content_block_stop","index":0}|}
    ; {|{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}|}
    ; {|{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"{}"}}|}
    ; {|{"type":"content_block_stop","index":1}|}
    ; {|{"type":"message_delta","delta":{"stop_reason":"end_turn"}}|}
    ; {|{"type":"message_stop"}|} ];
  let response = finalized_wire_response acc in
  (match response.content with
   | Thinking _ :: Text "{}" :: [] -> ()
   | _ -> Alcotest.fail "fixture must retain thinking before final text");
  check_wire_ready response
;;

let () =
  Alcotest.run
    "structured"
    [ ( "provider wire conformance"
      , [ Alcotest.test_case "Chat sync/SSE states reach extraction" `Quick test_chat_wire_states_reach_structured
        ; Alcotest.test_case "Responses sync/refusal SSE reach extraction" `Quick test_responses_wire_states_reach_structured
        ; Alcotest.test_case "Gemini sync/SSE states reach extraction" `Quick test_gemini_wire_states_reach_structured
        ; Alcotest.test_case "Anthropic thinking precedes JSON text" `Quick test_anthropic_wire_thinking_precedes_terminal_text
        ] )
    ; ( "response states"
      , [ Alcotest.test_case "authoritative stops precede JSON" `Quick test_authoritative_stop_states_precede_valid_json
        ; Alcotest.test_case "tool turn then terminal JSON" `Quick test_tool_call_turn_requires_tool_results_before_json
        ; Alcotest.test_case "multiple Text whitespace boundaries" `Quick test_multiple_text_blocks_are_ambiguous_even_at_whitespace_boundaries
        ] )
    ; ( "private failure evidence"
      , [ Alcotest.test_case "malformed response" `Quick test_malformed_response_retains_original_evidence
        ; Alcotest.test_case "empty response failure class" `Quick test_empty_response_has_public_failure_class
        ; Alcotest.test_case "schema refusal" `Quick test_schema_refusal_retains_response_without_public_detail
        ; Alcotest.test_case "schema type exception" `Quick test_schema_type_exception_retains_response
        ; Alcotest.test_case "schema JSON exception" `Quick test_schema_json_exception_has_distinct_schema_class
        ; Alcotest.test_case "object shape" `Quick test_response_shape_failure_retains_response
        ; Alcotest.test_case "bounded UTF-8 evidence" `Quick test_long_response_evidence_keeps_utf8_boundary
        ; Alcotest.test_case "public extractors keep safe failure class" `Quick test_public_extractors_keep_safe_failure_class
        ] )
    ; ( "schema_to_json_schema"
      , [ Alcotest.test_case "structure" `Quick test_schema_to_json_structure
        ; Alcotest.test_case "optional params" `Quick test_schema_optional_params
        ; Alcotest.test_case
            "json schema structure"
            `Quick
            test_schema_to_json_schema_structure
        ; Alcotest.test_case "empty params" `Quick test_schema_empty_params
        ; Alcotest.test_case "all param types" `Quick test_schema_all_param_types
        ; Alcotest.test_case
            "parameter description preserved"
            `Quick
            test_param_description_preserved
        ; Alcotest.test_case "mixed required" `Quick test_schema_mixed_required
        ] )
    ; ( "extractors"
      , [ Alcotest.test_case "json_extractor success" `Quick test_json_extractor_success
        ; Alcotest.test_case
            "json_extractor invalid"
            `Quick
            test_json_extractor_invalid_json
        ; Alcotest.test_case "json_extractor no text" `Quick test_json_extractor_no_text
        ; Alcotest.test_case
            "response_json_extractor object"
            `Quick
            test_response_json_extractor_object_success
        ; Alcotest.test_case
            "response_json_extractor rejects fenced object"
            `Quick
            test_response_json_extractor_rejects_fenced_object
        ; Alcotest.test_case
            "response_json_extractor any array"
            `Quick
            test_response_json_extractor_any_accepts_array
        ; Alcotest.test_case
            "response_json_extractor object rejects array"
            `Quick
            test_response_json_extractor_object_rejects_array
        ; Alcotest.test_case
            "response_json_extractor ignores tool result"
            `Quick
            test_response_json_extractor_ignores_tool_result
        ; Alcotest.test_case "text_extractor success" `Quick test_text_extractor_success
        ; Alcotest.test_case "text_extractor none" `Quick test_text_extractor_none
        ; Alcotest.test_case
            "schema_extractor success"
            `Quick
            test_schema_extractor_success
        ; Alcotest.test_case
            "schema_extractor parse failure"
            `Quick
            test_schema_extractor_parse_failure
        ; Alcotest.test_case
            "schema_extractor parser json error"
            `Quick
            test_schema_extractor_parser_json_error
        ] )
    ]
;;
