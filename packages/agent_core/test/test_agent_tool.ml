(** Tests for Agent_tool — agent-as-tool wrapper. *)

open Agent_sdk

(* ── Mock runners ────────────────────────────────────────────── *)

let mock_runner text _prompt : (Types.api_response, Error.sdk_error) result =
  Ok
    { id = "r1"
    ; model = "test"
    ; stop_reason = EndTurn
    ; content = [ Text text ]
    ; usage = None
    ; telemetry = None
    }
;;

let echo_runner prompt : (Types.api_response, Error.sdk_error) result =
  Ok
    { id = "r1"
    ; model = "test"
    ; stop_reason = EndTurn
    ; content = [ Text (Printf.sprintf "echo: %s" prompt) ]
    ; usage = None
    ; telemetry = None
    }
;;

let error_runner _prompt : (Types.api_response, Error.sdk_error) result =
  Error (Error.Internal "agent crashed")
;;

let structured_runner prompt : (Types.api_response, Error.sdk_error) result =
  Ok
    { id = "child-run-1"
    ; model = "child-model"
    ; stop_reason = EndTurn
    ; content =
        [ Text (Printf.sprintf "child: %s" prompt)
        ; ToolResult
            { tool_use_id = "toolu-child"
            ; content = {|{"ok":true}|}
            ; outcome = Tool_succeeded
            ; json = Some (`Assoc [ "ok", `Bool true ])
            ; content_blocks = None
            }
        ]
    ; usage =
        Some
          { input_tokens = 3
          ; output_tokens = 5
          ; cache_creation_input_tokens = 0
          ; cache_read_input_tokens = 0
          ; cost_usd = Some 0.01
          }
    ; telemetry = None
    }
;;

(* ── Basic creation ──────────────────────────────────────────── *)

let test_create_simple () =
  let tool =
    Agent_tool.create_simple
      ~name:"helper"
      ~description:"A test helper"
      (mock_runner "hello")
  in
  Alcotest.(check string) "name" "helper" tool.schema.name;
  Alcotest.(check string) "desc" "A test helper" tool.schema.description;
  Alcotest.(check bool)
    "has prompt param"
    true
    (List.exists (fun (p : Types.tool_param) -> p.name = "prompt") tool.schema.parameters)
;;

(* ── Execution ───────────────────────────────────────────────── *)

let test_execute_with_prompt () =
  let tool =
    Agent_tool.create_simple ~name:"echo" ~description:"Echo agent" echo_runner
  in
  match Tool.execute tool (`Assoc [ "prompt", `String "test input" ]) with
  | Ok { content; _meta = _ } -> Alcotest.(check string) "echo" "echo: test input" content
  | Error { message; _ } -> Alcotest.failf "error: %s" message
;;

let test_execute_with_string_input () =
  let tool = Agent_tool.create_simple ~name:"echo" ~description:"d" echo_runner in
  match Tool.execute tool (`String "direct string") with
  | Error { message; _ } ->
    Alcotest.(check string)
      "object contract"
      {|Agent_tool input must be an object: "direct string"|}
      message
  | Ok _ -> Alcotest.fail "string input is outside the declared tool schema"
;;

let test_execute_error_propagation () =
  let tool = Agent_tool.create_simple ~name:"fail" ~description:"d" error_runner in
  match Tool.execute tool (`Assoc [ "prompt", `String "test" ]) with
  | Error { recoverable; _ } -> Alcotest.(check bool) "not recoverable" false recoverable
  | Ok _ -> Alcotest.fail "expected error"
;;

let test_execute_untyped_malformed_input_errors () =
  (* RFC-OAS-029 S4.3: the untyped handler delegates to the typed parser and
     propagates its Error instead of silently serializing malformed input as
     the prompt (regression: missing/non-string prompt used to echo back the
     serialized JSON as a successful run). *)
  let tool = Agent_tool.create_simple ~name:"echo" ~description:"d" echo_runner in
  (match Tool.execute tool (`Assoc [ "other", `String "x" ]) with
   | Error { message; _ } ->
     Alcotest.(check string)
       "missing prompt surfaced"
       "Agent_tool input requires a prompt field"
       message
   | Ok { content; _meta = _ } ->
     Alcotest.failf "expected error (missing prompt), got: %s" content);
  match Tool.execute tool (`Assoc [ "prompt", `Int 5 ]) with
  | Error { message; _ } ->
    Alcotest.(check string)
      "non-string prompt surfaced"
      "Agent_tool prompt must be a string"
      message
  | Ok { content; _meta = _ } ->
    Alcotest.failf "expected error (non-string prompt), got: %s" content
;;

(* ── Output summarizer ───────────────────────────────────────── *)

let test_output_summarizer () =
  let tool =
    Agent_tool.create
      { name = "summarized"
      ; description = "d"
      ; runner = mock_runner "this is a very long response from the agent"
      ; output_summarizer =
          Some (fun s -> if String.length s > 10 then String.sub s 0 10 ^ "..." else s)
      }
  in
  match Tool.execute tool (`Assoc [ "prompt", `String "q" ]) with
  | Ok { content; _meta = _ } ->
    Alcotest.(check string) "truncated" "this is a ..." content
  | Error { message; _ } -> Alcotest.failf "error: %s" message
;;

(* ── Schema/parser SSOT ──────────────────────────────────────── *)

let test_declared_inputs_match_parser () =
  let tool =
    Agent_tool.create
      { name = "t"
      ; description = "d"
      ; runner = mock_runner "ok"
      ; output_summarizer = None
      }
  in
  Alcotest.(check int) "one consumed input" 1 (List.length tool.schema.parameters);
  Alcotest.(check string) "prompt" "prompt" (List.hd tool.schema.parameters).name
;;

(* ── Multi-content response ──────────────────────────────────── *)

let test_multi_content () =
  let runner _prompt : (Types.api_response, Error.sdk_error) result =
    Ok
      { id = "r1"
      ; model = "test"
      ; stop_reason = EndTurn
      ; content = [ Text "line 1"; Text "line 2"; Text "line 3" ]
      ; usage = None
      ; telemetry = None
      }
  in
  let tool = Agent_tool.create_simple ~name:"multi" ~description:"d" runner in
  match Tool.execute tool (`Assoc [ "prompt", `String "test" ]) with
  | Ok { content; _meta = _ } ->
    Alcotest.(check string) "joined" "line 1\nline 2\nline 3" content
  | Error { message; _ } -> Alcotest.failf "error: %s" message
;;

(* ── Typed child invocation ──────────────────────────────────── *)

let typed_config runner =
  { Agent_tool.name = "typed_child"
  ; description = "Typed child agent"
  ; runner
  ; output_summarizer = None
  }
;;

let test_create_typed_schema () =
  let tool = Agent_tool.create_typed (typed_config structured_runner) in
  let schema = tool.schema in
  Alcotest.(check string) "name" "typed_child" schema.name;
  Alcotest.(check bool)
    "has prompt param"
    true
    (List.exists (fun (p : Types.tool_param) -> p.name = "prompt") schema.parameters)
;;

let test_typed_child_output_json () =
  let open Yojson.Safe.Util in
  let tool = Agent_tool.create_typed (typed_config structured_runner) in
  match Tool.execute tool (`Assoc [ "prompt", `String "hello" ]) with
  | Error { message; _ } -> Alcotest.failf "error: %s" message
  | Ok { content; _meta = _ } ->
    let json = Yojson.Safe.from_string content in
    Alcotest.(check string)
      "type"
      "agent_tool_child_output"
      (json |> member "type" |> to_string);
    Alcotest.(check string)
      "response_id"
      "child-run-1"
      (json |> member "response_id" |> to_string);
    Alcotest.(check string) "model" "child-model" (json |> member "model" |> to_string);
    Alcotest.(check string) "text" "child: hello" (json |> member "text" |> to_string);
    Alcotest.(check int)
      "content blocks"
      2
      (json |> member "content" |> to_list |> List.length);
    Alcotest.(check int)
      "input tokens"
      3
      (json |> member "usage" |> member "input_tokens" |> to_int)
;;

let test_typed_constructor_returns_canonical_tool () =
  let open Yojson.Safe.Util in
  let tool = Agent_tool.create_typed (typed_config structured_runner) in
  match Tool.execute tool (`Assoc [ "prompt", `String "bridge" ]) with
  | Error { message; _ } -> Alcotest.failf "error: %s" message
  | Ok { content; _meta = _ } ->
    let json = Yojson.Safe.from_string content in
    Alcotest.(check string) "text" "child: bridge" (json |> member "text" |> to_string)
;;

let test_typed_missing_prompt_recoverable () =
  let tool = Agent_tool.create_typed (typed_config structured_runner) in
  match Tool.execute tool (`Assoc [ "other", `String "x" ]) with
  | Ok _ -> Alcotest.fail "expected parse error"
  | Error { recoverable; message; _ } ->
    Alcotest.(check bool) "recoverable" true recoverable;
    Alcotest.(check string) "message" "Agent_tool input requires a prompt field" message
;;

(* ── Suite ───────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "agent_tool"
    [ "create", [ Alcotest.test_case "simple" `Quick test_create_simple ]
    ; ( "execute"
      , [ Alcotest.test_case "with_prompt" `Quick test_execute_with_prompt
        ; Alcotest.test_case "string_input" `Quick test_execute_with_string_input
        ; Alcotest.test_case "error" `Quick test_execute_error_propagation
        ; Alcotest.test_case
            "untyped malformed input errors"
            `Quick
            test_execute_untyped_malformed_input_errors
        ] )
    ; "summarizer", [ Alcotest.test_case "truncate" `Quick test_output_summarizer ]
    ; ( "params"
      , [ Alcotest.test_case "schema parser SSOT" `Quick test_declared_inputs_match_parser
        ] )
    ; "multi_content", [ Alcotest.test_case "joined" `Quick test_multi_content ]
    ; ( "typed_child"
      , [ Alcotest.test_case "schema" `Quick test_create_typed_schema
        ; Alcotest.test_case "output_json" `Quick test_typed_child_output_json
        ; Alcotest.test_case
            "canonical_tool"
            `Quick
            test_typed_constructor_returns_canonical_tool
        ; Alcotest.test_case "missing_prompt" `Quick test_typed_missing_prompt_recoverable
        ] )
    ]
;;
