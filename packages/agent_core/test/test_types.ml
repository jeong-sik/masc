(** Test Types parsing, especially Unknown stop_reason variant. *)

open Agent_sdk

let test_known_stop_reasons () =
  Alcotest.(check string)
    "end_turn"
    "Types.EndTurn"
    (Types.show_stop_reason (Types.stop_reason_of_string "end_turn"));
  Alcotest.(check string)
    "tool_use"
    "Types.StopToolUse"
    (Types.show_stop_reason (Types.stop_reason_of_string "tool_use"));
  Alcotest.(check string)
    "max_tokens"
    "Types.MaxTokens"
    (Types.show_stop_reason (Types.stop_reason_of_string "max_tokens"));
  Alcotest.(check string)
    "stop_sequence"
    "Types.StopSequence"
    (Types.show_stop_reason (Types.stop_reason_of_string "stop_sequence"));
  (* 2025-2026 first-class variants: assert the exact wire strings parse,
     so a typo in a string literal cannot pass silently. *)
  Alcotest.(check string)
    "refusal"
    "Types.Refusal"
    (Types.show_stop_reason (Types.stop_reason_of_string "refusal"));
  Alcotest.(check string)
    "content_filter"
    "Types.ContentFilter"
    (Types.show_stop_reason (Types.stop_reason_of_string "content_filter"));
  Alcotest.(check string)
    "repetition_truncation"
    "Types.RepetitionTruncation"
    (Types.show_stop_reason (Types.stop_reason_of_string "repetition_truncation"));
  Alcotest.(check string)
    "pause_turn"
    "Types.PauseTurn"
    (Types.show_stop_reason (Types.stop_reason_of_string "pause_turn"));
  Alcotest.(check string)
    "compaction"
    "Types.Compaction"
    (Types.show_stop_reason (Types.stop_reason_of_string "compaction"));
  Alcotest.(check string)
    "model_context_window_exceeded"
    "Types.ContextWindowExceeded"
    (Types.show_stop_reason (Types.stop_reason_of_string "model_context_window_exceeded"))
;;

let test_unknown_stop_reason () =
  let sr = Types.stop_reason_of_string "some_new_reason" in
  let shown = Types.show_stop_reason sr in
  Alcotest.(check bool)
    "contains Unknown"
    true
    (String.length shown > 0
     &&
     try
       let _ = String.index shown 'U' in
       true
     with
     | Not_found -> false);
  match sr with
  | Types.Unknown s ->
    Alcotest.(check string) "preserves original string" "some_new_reason" s
  | _ -> Alcotest.fail (Printf.sprintf "expected Unknown variant, got %s" shown)
;;

let test_empty_stop_reason () =
  let sr = Types.stop_reason_of_string "" in
  match sr with
  | Types.Unknown s -> Alcotest.(check string) "empty string preserved" "" s
  | _ ->
    Alcotest.fail
      (Printf.sprintf "expected Unknown for empty, got %s" (Types.show_stop_reason sr))
;;

let test_model_to_string () =
  Alcotest.(check string)
    "exact opus"
    "claude-opus-4-6"
    (Types.model_to_string "claude-opus-4-6");
  Alcotest.(check string)
    "exact sonnet"
    "claude-sonnet-4-6"
    (Types.model_to_string "claude-sonnet-4-6");
  Alcotest.(check string)
    "exact haiku"
    "claude-haiku-4-5"
    (Types.model_to_string "claude-haiku-4-5");
  Alcotest.(check string) "custom" "my-model" (Types.model_to_string "my-model")
;;

let test_role_to_string () =
  Alcotest.(check string) "user" "user" (Types.role_to_string Types.User);
  Alcotest.(check string) "assistant" "assistant" (Types.role_to_string Types.Assistant)
;;

let test_param_type_to_string () =
  Alcotest.(check string) "string" "string" (Types.param_type_to_string Types.String);
  Alcotest.(check string) "integer" "integer" (Types.param_type_to_string Types.Integer);
  Alcotest.(check string) "number" "number" (Types.param_type_to_string Types.Number);
  Alcotest.(check string) "boolean" "boolean" (Types.param_type_to_string Types.Boolean);
  Alcotest.(check string) "array" "array" (Types.param_type_to_string Types.Array);
  Alcotest.(check string) "object" "object" (Types.param_type_to_string Types.Object)
;;

let test_tool_choice_auto () =
  let json = Types.tool_choice_to_json Types.Auto in
  match json with
  | `Assoc [ ("type", `String "auto") ] -> ()
  | _ -> Alcotest.fail "expected auto"
;;

let test_tool_choice_any () =
  let json = Types.tool_choice_to_json Types.Any in
  match json with
  | `Assoc [ ("type", `String "any") ] -> ()
  | _ -> Alcotest.fail "expected any"
;;

let test_tool_choice_tool () =
  let json = Types.tool_choice_to_json (Types.Tool "calculator") in
  match json with
  | `Assoc [ ("type", `String "tool"); ("name", `String "calculator") ] -> ()
  | _ -> Alcotest.fail "expected tool with name"
;;

let test_tool_choice_none () =
  let json = Types.tool_choice_to_json Types.None_ in
  (match json with
   | `Assoc [ ("type", `String "none") ] -> ()
   | _ -> Alcotest.fail "expected none type");
  let rt = Types.tool_choice_of_json json in
  match rt with
  | Ok Types.None_ -> ()
  | Ok _ -> Alcotest.fail "expected None_ variant"
  | Error _ -> Alcotest.fail "expected Ok"
;;

let test_response_format_json () =
  let schema = `Assoc [ "type", `String "object" ] in
  let cases =
    [ Types.Off, `Assoc [ "type", `String "off" ]
    ; Types.JsonMode, `Assoc [ "type", `String "json_mode" ]
    ; Types.JsonSchema schema, `Assoc [ "type", `String "json_schema"; "schema", schema ]
    ]
  in
  List.iter
    (fun (format, expected) ->
       Alcotest.(check string)
         "response_format json"
         (Yojson.Safe.to_string expected)
         (Types.response_format_to_json format |> Yojson.Safe.to_string))
    cases;
  Alcotest.(check bool)
    "boolean compatibility shape rejected"
    true
    (Result.is_error (Types.response_format_of_json (`Bool true)));
  Alcotest.(check bool)
    "null compatibility shape rejected"
    true
    (Result.is_error (Types.response_format_of_json `Null))
;;

let test_add_usage () =
  let stats = Types.empty_usage in
  let u : Types.api_usage =
    { input_tokens = 10
    ; output_tokens = 20
    ; cache_creation_input_tokens = 5
    ; cache_read_input_tokens = 3
    ; cost_usd = None
    }
  in
  let result = Types.add_usage stats u in
  Alcotest.(check int) "input" 10 result.total_input_tokens;
  Alcotest.(check int) "output" 20 result.total_output_tokens;
  Alcotest.(check int) "cache_creation" 5 result.total_cache_creation_input_tokens;
  Alcotest.(check int) "cache_read" 3 result.total_cache_read_input_tokens;
  Alcotest.(check int) "api_calls" 1 result.api_calls
;;

let test_add_usage_accumulates () =
  let u1 : Types.api_usage =
    { input_tokens = 10
    ; output_tokens = 5
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 0
    ; cost_usd = None
    }
  in
  let u2 : Types.api_usage =
    { input_tokens = 20
    ; output_tokens = 15
    ; cache_creation_input_tokens = 3
    ; cache_read_input_tokens = 7
    ; cost_usd = None
    }
  in
  let stats = Types.add_usage Types.empty_usage u1 in
  let stats = Types.add_usage stats u2 in
  Alcotest.(check int) "total input" 30 stats.total_input_tokens;
  Alcotest.(check int) "total output" 20 stats.total_output_tokens;
  Alcotest.(check int) "api_calls" 2 stats.api_calls
;;

let test_default_config () =
  let c = Types.default_config ~model:"test-model" in
  Alcotest.(check string) "name" "agent" c.name;
  Alcotest.(check (option int)) "max_tokens" None c.max_tokens;
  Alcotest.(check bool) "no system prompt" true (c.system_prompt = None);
  Alcotest.(check bool) "no top_p" true (c.top_p = None);
  Alcotest.(check bool) "no top_k" true (c.top_k = None);
  Alcotest.(check bool) "no min_p" true (c.min_p = None);
  Alcotest.(check bool) "no enable_thinking" true (c.enable_thinking = None);
  Alcotest.(check bool) "no thinking_budget" true (c.thinking_budget = None);
  Alcotest.(check bool) "no reasoning_effort" true (c.reasoning_effort = None);
  Alcotest.(check bool) "cache off" false c.cache_system_prompt
;;

(* ── yojson roundtrips (Phase 3) ──────────────────────────────── *)

let test_model_yojson_roundtrip () =
  let variants =
    [ "claude-opus-4-6"
    ; "claude-sonnet-4-6"
    ; "claude-opus-4-5"
    ; "claude-sonnet-4"
    ; "claude-haiku-4-5"
    ; "claude-3-7-sonnet"
    ; "my-model"
    ]
  in
  List.iter
    (fun m ->
       let json = Types.model_to_yojson m in
       match Types.model_of_yojson json with
       | Ok decoded ->
         Alcotest.(check string)
           "model roundtrip"
           (Types.show_model m)
           (Types.show_model decoded)
       | Error msg -> Alcotest.fail ("model_of_yojson: " ^ msg))
    variants
;;

let test_role_yojson_roundtrip () =
  List.iter
    (fun r ->
       let json = Types.role_to_yojson r in
       match Types.role_of_yojson json with
       | Ok decoded ->
         Alcotest.(check string)
           "role roundtrip"
           (Types.show_role r)
           (Types.show_role decoded)
       | Error msg -> Alcotest.fail ("role_of_yojson: " ^ msg))
    [ Types.System; Types.User; Types.Assistant; Types.Tool ]
;;

let test_param_type_yojson_roundtrip () =
  let variants =
    [ Types.String
    ; Types.Integer
    ; Types.Number
    ; Types.Boolean
    ; Types.Array
    ; Types.Object
    ]
  in
  List.iter
    (fun p ->
       let json = Types.param_type_to_yojson p in
       match Types.param_type_of_yojson json with
       | Ok decoded ->
         Alcotest.(check string)
           "param_type roundtrip"
           (Types.show_param_type p)
           (Types.show_param_type decoded)
       | Error msg -> Alcotest.fail ("param_type_of_yojson: " ^ msg))
    variants
;;

let test_tool_choice_of_json_error_bogus () =
  let json = `Assoc [ "type", `String "bogus" ] in
  match Types.tool_choice_of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for bogus type"
;;

let test_tool_choice_of_json_error_non_object () =
  let json = `String "not an object" in
  match Types.tool_choice_of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for non-object"
;;

let test_show_content_block_variants () =
  let blocks =
    [ Types.Text "hello"
    ; Types.Thinking { signature = Some "sig"; content = "hmm" }
    ; Types.RedactedThinking "redacted"
    ; Types.ToolUse { id = "tu1"; name = "read"; input = `Null }
    ; Types.ToolResult
        { tool_use_id = "tu1"
        ; content = "ok"
        ; outcome = Tool_succeeded
        ; json = None
        ; content_blocks = None
        }
    ; Types.Image { media_type = "image/png"; data = "abc"; source_type = Types.Base64 }
    ; Types.Document
        { media_type = "application/pdf"; data = "pdf"; source_type = Types.Base64 }
    ]
  in
  List.iter
    (fun b ->
       let s = Types.show_content_block b in
       Alcotest.(check bool) "show non-empty" true (String.length s > 0))
    blocks
;;

let test_show_message () =
  let m : Types.message =
    { role = Types.User
    ; content = [ Types.Text "test" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let s = Types.show_message m in
  Alcotest.(check bool) "show_message non-empty" true (String.length s > 0)
;;

let test_show_agent_config () =
  let s = Types.show_agent_config (Types.default_config ~model:"test-model") in
  Alcotest.(check bool) "show_agent_config non-empty" true (String.length s > 0)
;;

let test_show_agent_state () =
  let state : Types.agent_state =
    { config = Types.default_config ~model:"test-model"
    ; messages = []
    ; turn_count = 0
    ; usage = Types.empty_usage
    }
  in
  let s = Types.show_agent_state state in
  Alcotest.(check bool) "show_agent_state non-empty" true (String.length s > 0)
;;

let test_show_api_response () =
  let r : Types.api_response =
    { id = "msg-1"
    ; model = "test"
    ; stop_reason = Types.EndTurn
    ; content = [ Types.Text "hi" ]
    ; usage = None
    ; telemetry = None
    }
  in
  let s = Types.show_api_response r in
  Alcotest.(check bool) "show_api_response non-empty" true (String.length s > 0)
;;

let test_tool_choice_roundtrip_all () =
  let variants = [ Types.Auto; Types.Any; Types.Tool "calc"; Types.None_ ] in
  List.iter
    (fun tc ->
       let json = Types.tool_choice_to_json tc in
       match Types.tool_choice_of_json json with
       | Ok decoded ->
         Alcotest.(check string)
           "tool_choice roundtrip"
           (Types.show_tool_choice tc)
           (Types.show_tool_choice decoded)
       | Error _ -> Alcotest.fail "tool_choice roundtrip failed")
    variants
;;

let test_tool_param_manual_json_helpers () =
  let params =
    [ { Types.name = "q"
      ; description = "Query"
      ; param_type = Types.String
      ; required = true
      }
    ; { Types.name = "limit"
      ; description = "Limit"
      ; param_type = Types.Integer
      ; required = false
      }
    ]
  in
  let schema = Types.params_to_input_schema params in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "schema type" "object" (schema |> member "type" |> to_string);
  Alcotest.(check int)
    "required count"
    1
    (schema |> member "required" |> to_list |> List.length);
  let param_json = Types.tool_param_to_json (List.hd params) in
  (match Types.tool_param_of_json param_json with
   | Ok decoded -> Alcotest.(check string) "decoded" "q" decoded.name
   | Error msg -> Alcotest.fail msg);
  let bad_param =
    `Assoc
      [ "name", `String "x"
      ; "description", `String "bad"
      ; "param_type", `String "bad_type"
      ; "required", `Bool true
      ]
  in
  (match Types.tool_param_of_json bad_param with
   | Error msg ->
     Alcotest.(check bool)
       "mentions param_type"
       true
       (Agent_sdk.Util.contains_substring_ci ~haystack:msg ~needle:"param_type")
   | Ok _ -> Alcotest.fail "expected bad param type");
  let tool_schema =
    Types.tool_schema_of_params ~name:"search" ~description:"Search" ~parameters:params ()
  in
  let manual_json = Types.tool_schema_to_json tool_schema in
  (* strict = None must not emit the field, and must round-trip back to None. *)
  Alcotest.(check bool)
    "strict omitted when None"
    false
    (List.mem_assoc "strict" (Yojson.Safe.Util.to_assoc manual_json));
  (match Types.tool_schema_of_json manual_json with
   | Ok decoded ->
     Alcotest.(check int) "params" 2 (List.length decoded.parameters);
     Alcotest.(check bool) "strict stays None" true (decoded.strict = None)
   | Error msg -> Alcotest.fail msg);
  (* strict = Some true must emit "strict": true and round-trip to Some true. *)
  let strict_json =
    Types.tool_schema_to_json
      (Types.tool_schema_of_params
         ~strict:true
         ~name:tool_schema.name
         ~description:tool_schema.description
         ~parameters:tool_schema.parameters
         ())
  in
  Alcotest.(check bool)
    "strict emitted when Some"
    true
    (Yojson.Safe.Util.(member "strict" strict_json) = `Bool true);
  match Types.tool_schema_of_json strict_json with
  | Ok decoded ->
    Alcotest.(check bool) "strict round-trips" true (decoded.strict = Some true)
  | Error msg -> Alcotest.fail msg
;;

let test_tool_schema_manual_json_rejects_bad_param () =
  let bad_schema =
    `Assoc
      [ "name", `String "broken"
      ; "description", `String "Broken schema"
      ; ( "parameters"
        , `List
            [ `Assoc
                [ "name", `String "x"
                ; "description", `String "bad"
                ; "param_type", `String "not-a-type"
                ; "required", `Bool true
                ]
            ] )
      ]
  in
  match Types.tool_schema_of_json bad_schema with
  | Error msg ->
    Alcotest.(check bool)
      "propagates bad param"
      true
      (Agent_sdk.Util.contains_substring_ci ~haystack:msg ~needle:"not-a-type")
  | Ok _ -> Alcotest.fail "expected tool_schema_of_json error"
;;

let test_result_all_helper () =
  Alcotest.(check (list int))
    "all ok"
    [ 1; 2 ]
    (Result.get_ok (Types.result_all [ Ok 1; Ok 2 ]));
  match Types.result_all [ Ok 1; Error "boom"; Ok 3 ] with
  | Error "boom" -> ()
  | Error other -> Alcotest.fail ("unexpected error: " ^ other)
  | Ok _ -> Alcotest.fail "expected first error"
;;

let test_tool_error_class_yojson_roundtrip () =
  List.iter
    (fun error_class ->
       let json = Types.tool_error_class_to_yojson error_class in
       (match Types.tool_error_class_of_yojson json with
        | Ok decoded ->
          Alcotest.(check string)
            "tool_error_class"
            (Types.show_tool_error_class error_class)
            (Types.show_tool_error_class decoded)
        | Error msg -> Alcotest.fail msg);
       Alcotest.(check bool)
         "show non-empty"
         true
         (String.length (Types.show_tool_error_class error_class) > 0))
    [ Types.Transient; Types.Deterministic; Types.Unknown ]
;;

let test_usage_and_inference_telemetry_yojson_roundtrip () =
  let usage : Types.api_usage =
    { input_tokens = 11
    ; output_tokens = 22
    ; cache_creation_input_tokens = 3
    ; cache_read_input_tokens = 4
    ; cost_usd = Some 0.25
    }
  in
  (match Types.api_usage_of_yojson (Types.api_usage_to_yojson usage) with
   | Ok decoded ->
     Alcotest.(check int) "usage input" 11 decoded.input_tokens;
     Alcotest.(check bool)
       "usage show"
       true
       (String.length (Types.show_api_usage decoded) > 0)
   | Error msg -> Alcotest.fail msg);
  let timings : Types.inference_timings =
    { prompt_n = Some 10
    ; prompt_ms = Some 20.5
    ; prompt_per_second = Some 30.5
    ; predicted_n = Some 4
    ; predicted_ms = Some 5.5
    ; predicted_per_second = Some 6.5
    ; cache_n = Some 7
    }
  in
  (match
     Types.inference_timings_of_yojson (Types.inference_timings_to_yojson timings)
   with
   | Ok decoded ->
     Alcotest.(check (option int)) "cache_n" (Some 7) decoded.cache_n;
     Alcotest.(check bool)
       "timings show"
       true
       (String.length (Types.show_inference_timings decoded) > 0)
   | Error msg -> Alcotest.fail msg);
  let telemetry : Types.inference_telemetry =
    { system_fingerprint = Some "fp"
    ; timings = Some timings
    ; reasoning_tokens = Some 12
    ; request_latency_ms = Some 123
    ; peak_memory_gb = Some 4.5
    ; provider_kind = Some Llm_provider.Provider_config.OpenAI_compat
    ; reasoning_effort = Some "medium"
    ; canonical_model_id = Some "gpt"
    ; reasoning_source = None
    ; effective_context_window = Some 8192
    ; provider_internal_action_count = Some 2
    ; ttfrc_ms = Some 10.0
    ; prefill_ms = Some 11.0
    }
  in
  match
    Types.inference_telemetry_of_yojson (Types.inference_telemetry_to_yojson telemetry)
  with
  | Ok decoded ->
    Alcotest.(check (option string)) "fingerprint" (Some "fp") decoded.system_fingerprint;
    Alcotest.(check bool)
      "telemetry show"
      true
      (String.length (Types.show_inference_telemetry decoded) > 0)
  | Error msg -> Alcotest.fail msg
;;

let test_default_inference_telemetry () =
  let telemetry = Types.default_inference_telemetry in
  Alcotest.(check (option string))
    "default system fingerprint unknown"
    None
    telemetry.system_fingerprint;
  Alcotest.(check bool) "default timings unknown" true (Option.is_none telemetry.timings);
  Alcotest.(check (option int))
    "default reasoning tokens unknown"
    None
    telemetry.reasoning_tokens;
  Alcotest.(check (option int))
    "default latency unknown"
    None
    telemetry.request_latency_ms;
  Alcotest.(check (option (float 0.001)))
    "default peak memory unknown"
    None
    telemetry.peak_memory_gb;
  Alcotest.(check bool)
    "default provider kind unknown"
    true
    (Option.is_none telemetry.provider_kind);
  Alcotest.(check (option string))
    "default reasoning effort unknown"
    None
    telemetry.reasoning_effort;
  Alcotest.(check (option string))
    "default canonical model unknown"
    None
    telemetry.canonical_model_id;
  Alcotest.(check bool)
    "default reasoning source unknown"
    true
    (Option.is_none telemetry.reasoning_source);
  Alcotest.(check (option int))
    "default context window unknown"
    None
    telemetry.effective_context_window;
  Alcotest.(check (option int))
    "default provider actions unknown"
    None
    telemetry.provider_internal_action_count;
  Alcotest.(check (option (float 0.001))) "default ttfrc unknown" None telemetry.ttfrc_ms;
  Alcotest.(check (option (float 0.001)))
    "default prefill unknown"
    None
    telemetry.prefill_ms
;;

(* ── role_of_string ──────────────────────────────────────── *)

let test_role_of_string () =
  Alcotest.(check (option string))
    "system"
    (Some "system")
    (Option.map Types.role_to_string (Types.role_of_string "system"));
  Alcotest.(check (option string))
    "user"
    (Some "user")
    (Option.map Types.role_to_string (Types.role_of_string "user"));
  Alcotest.(check (option string))
    "assistant"
    (Some "assistant")
    (Option.map Types.role_to_string (Types.role_of_string "assistant"));
  Alcotest.(check (option string))
    "tool"
    (Some "tool")
    (Option.map Types.role_to_string (Types.role_of_string "tool"));
  Alcotest.(check bool) "unknown" true (Types.role_of_string "unknown" = None)
;;

(* ── Convenience message constructors ──────────────────── *)

let test_text_message () =
  let m = Types.text_message Types.User "hello" in
  Alcotest.(check string) "role" "user" (Types.role_to_string m.role);
  match m.content with
  | [ Types.Text "hello" ] -> ()
  | _ -> Alcotest.fail "expected single Text block"
;;

let test_system_msg () =
  let m = Types.system_msg "system prompt" in
  Alcotest.(check string) "role" "system" (Types.role_to_string m.role);
  match m.content with
  | [ Types.Text "system prompt" ] -> ()
  | _ -> Alcotest.fail "expected Text"
;;

let test_user_msg () =
  let m = Types.user_msg "question" in
  Alcotest.(check string) "role" "user" (Types.role_to_string m.role);
  match m.content with
  | [ Types.Text "question" ] -> ()
  | _ -> Alcotest.fail "expected Text"
;;

let test_assistant_msg () =
  let m = Types.assistant_msg "answer" in
  Alcotest.(check string) "role" "assistant" (Types.role_to_string m.role);
  match m.content with
  | [ Types.Text "answer" ] -> ()
  | _ -> Alcotest.fail "expected Text"
;;

let test_tool_result_msg () =
  let m = Types.tool_result_msg ~tool_use_id:"tu1" ~content:"result" () in
  Alcotest.(check string) "role" "tool" (Types.role_to_string m.role);
  match m.content with
  | [ Types.ToolResult
        { tool_use_id = "tu1"; content = "result"; outcome = Tool_succeeded; _ }
    ] -> ()
  | _ -> Alcotest.fail "expected ToolResult"
;;

let test_tool_result_msg_error () =
  let outcome =
    Types.Tool_failed
      { failure_kind = Types.Non_retryable_tool_error
      ; error_class = Some Types.Deterministic
      }
  in
  let m = Types.tool_result_msg ~tool_use_id:"tu2" ~content:"err" ~outcome () in
  match m.content with
  | [ Types.ToolResult { outcome = Tool_failed _; _ } ] -> ()
  | _ -> Alcotest.fail "expected error ToolResult"
;;

let test_tool_result_msg_json_detection () =
  let m = Types.tool_result_msg ~tool_use_id:"tu-json" ~content:{|{"ok":true}|} () in
  (match m.content with
   | [ Types.ToolResult { json = Some (`Assoc _); _ } ] -> ()
   | _ -> Alcotest.fail "expected parsed JSON payload");
  let explicit = `Assoc [ "explicit", `Bool true ] in
  let m =
    Types.tool_result_msg ~tool_use_id:"tu-explicit" ~content:"not-json" ~json:explicit ()
  in
  match m.content with
  | [ Types.ToolResult { json = Some json; _ } ] ->
    Alcotest.(check string)
      "explicit json wins"
      (Yojson.Safe.to_string explicit)
      (Yojson.Safe.to_string json)
  | _ -> Alcotest.fail "expected explicit JSON payload"
;;

(* ── text_of_content / text_of_message ─────────────────── *)

let test_text_of_content_text_only () =
  let content = [ Types.Text "hello"; Types.Text "world" ] in
  Alcotest.(check string) "joined" "hello\nworld" (Types.text_of_content content)
;;

let test_text_of_content_mixed () =
  let content =
    [ Types.Text "start"
    ; Types.Thinking { signature = Some "sig"; content = "hmm" }
    ; Types.ToolUse { id = "tu1"; name = "search"; input = `Null }
    ; Types.Text "end"
    ]
  in
  Alcotest.(check string) "skips non-text" "start\nend" (Types.text_of_content content)
;;

let test_text_of_content_tool_result () =
  let content =
    [ Types.ToolResult
        { tool_use_id = "tu1"
        ; content = "result text"
        ; outcome = Tool_succeeded
        ; json = None
        ; content_blocks = None
        }
    ]
  in
  Alcotest.(check string)
    "includes tool result"
    "result text"
    (Types.text_of_content content)
;;

let test_visible_text_of_content_excludes_non_answer_blocks () =
  let content =
    [ Types.Text "answer"
    ; Types.Thinking { signature = Some "sig"; content = "private reasoning" }
    ; Types.RedactedThinking "opaque"
    ; Types.ToolUse { id = "tu1"; name = "search"; input = `Assoc [] }
    ; Types.ToolResult
        { tool_use_id = "tu1"
        ; content = "tool payload"
        ; outcome = Tool_succeeded
        ; json = Some (`Assoc [ "ok", `Bool true ])
        ; content_blocks = Some [ Types.Text "structured tool payload" ]
        }
    ; Types.Image { media_type = "image/png"; data = "bytes"; source_type = Types.Base64 }
    ; Types.Document
        { media_type = "application/pdf"; data = "doc"; source_type = Types.Base64 }
    ; Types.Audio
        { media_type = "audio/mpeg"; data = "audio"; source_type = Types.Base64 }
    ; Types.Text "tail"
    ]
  in
  Alcotest.(check string)
    "visible text"
    "answer\ntail"
    (Types.visible_text_of_content content)
;;

let test_reasoning_details_text_prefers_reasoning_content () =
  let details =
    [ { Types.raw = `Assoc [ "text", `String "detail" ]; text = Some "detail" } ]
  in
  Alcotest.(check string)
    "reasoning_content wins"
    "content"
    (Types.reasoning_details_text ~reasoning_content:(Some "content") ~details)
;;

let test_reasoning_details_text_projects_detail_text_in_order () =
  let details =
    [ { Types.raw = `Assoc [ "text", `String "a" ]; text = Some "a" }
    ; { Types.raw = `Assoc [ "opaque", `Bool true ]; text = None }
    ; { Types.raw = `Assoc [ "text", `String "b" ]; text = Some "b" }
    ]
  in
  Alcotest.(check string)
    "detail text"
    "ab"
    (Types.reasoning_details_text ~reasoning_content:None ~details);
  Alcotest.(check string)
    "empty reasoning_content falls back"
    "ab"
    (Types.reasoning_details_text ~reasoning_content:(Some "") ~details)
;;

let test_reasoning_details_text_ignores_raw_only_details () =
  let details =
    [ { Types.raw = `Assoc [ "opaque", `Bool true ]; text = None }
    ; { Types.raw = `Assoc [ "encrypted", `String "payload" ]; text = None }
    ]
  in
  Alcotest.(check string)
    "raw-only details are not serialized"
    ""
    (Types.reasoning_details_text ~reasoning_content:None ~details)
;;

let test_text_of_content_empty () =
  Alcotest.(check string) "empty" "" (Types.text_of_content [])
;;

let test_text_of_message () =
  let m : Types.message =
    { role = Types.User
    ; content = [ Types.Text "hi" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  Alcotest.(check string) "text" "hi" (Types.text_of_message m)
;;

let test_text_of_response_and_usage_helpers () =
  let usage =
    { Types.input_tokens = 1
    ; output_tokens = 2
    ; cache_creation_input_tokens = 3
    ; cache_read_input_tokens = 4
    ; cost_usd = Some 0.01
    }
  in
  let response : Types.api_response =
    { id = "resp"
    ; model = "model"
    ; stop_reason = Types.EndTurn
    ; content =
        [ Types.Text "hello"
        ; Types.ToolResult
            { tool_use_id = "tu"
            ; content = "tool text"
            ; outcome = Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ; Types.Thinking { signature = Some "sig"; content = "hidden" }
        ]
    ; usage = Some usage
    ; telemetry = None
    }
  in
  Alcotest.(check string)
    "response text"
    "hello\ntool text"
    (Types.text_of_response response);
  Alcotest.(check string)
    "visible response text excludes tool result and thinking"
    "hello"
    (Types.visible_text_of_response response);
  Alcotest.(check (option int))
    "usage"
    (Some 1)
    (Option.map (fun u -> u.Types.input_tokens) (Types.usage_of_response response));
  Alcotest.(check int) "zero input" 0 Types.zero_api_usage.input_tokens
;;

let test_validate_tool_result_shape () =
  let object_result =
    Types.ToolResult
      { tool_use_id = "obj"
      ; content = {|{"ok":true}|}
      ; outcome = Tool_succeeded
      ; json = Some (`Assoc [ "ok", `Bool true ])
      ; content_blocks = None
      }
  in
  let array_result =
    Types.ToolResult
      { tool_use_id = "arr"
      ; content = "[1,2]"
      ; outcome = Tool_succeeded
      ; json = Some (`List [ `Int 1; `Int 2 ])
      ; content_blocks = None
      }
  in
  let invalid_json_result =
    Types.ToolResult
      { tool_use_id = "bad"
      ; content = "not-json"
      ; outcome = Tool_succeeded
      ; json = None
      ; content_blocks = None
      }
  in
  let empty_result =
    Types.ToolResult
      { tool_use_id = "empty"
      ; content = " "
      ; outcome = Tool_succeeded
      ; json = None
      ; content_blocks = None
      }
  in
  Alcotest.(check bool)
    "object ok"
    true
    (Result.is_ok
       (Types.validate_tool_result_shape
          ~expect_object:true
          ~expect_array:false
          object_result));
  Alcotest.(check bool)
    "array ok"
    true
    (Result.is_ok
       (Types.validate_tool_result_shape
          ~expect_object:false
          ~expect_array:true
          array_result));
  Alcotest.(check bool)
    "both accepts any json"
    true
    (Result.is_ok
       (Types.validate_tool_result_shape
          ~expect_object:true
          ~expect_array:true
          array_result));
  Alcotest.(check bool)
    "object expected"
    true
    (Result.is_error
       (Types.validate_tool_result_shape
          ~expect_object:true
          ~expect_array:false
          array_result));
  Alcotest.(check bool)
    "array expected"
    true
    (Result.is_error
       (Types.validate_tool_result_shape
          ~expect_object:false
          ~expect_array:true
          object_result));
  Alcotest.(check bool)
    "parse error"
    true
    (Result.is_error
       (Types.validate_tool_result_shape
          ~expect_object:true
          ~expect_array:false
          invalid_json_result));
  Alcotest.(check bool)
    "empty content"
    true
    (Result.is_error
       (Types.validate_tool_result_shape
          ~expect_object:false
          ~expect_array:false
          empty_result));
  Alcotest.(check bool)
    "non tool result ignored"
    true
    (Result.is_ok
       (Types.validate_tool_result_shape
          ~expect_object:true
          ~expect_array:false
          (Types.Text "plain")))
;;

(* ── Audio content block show ──────────────────────────── *)

let test_show_audio_block () =
  let block =
    Types.Audio { media_type = "audio/wav"; data = "data"; source_type = Types.Base64 }
  in
  let s = Types.show_content_block block in
  Alcotest.(check bool) "show non-empty" true (String.length s > 0)
;;

(* ── role System / Tool ────────────────────────────────── *)

let test_role_system_tool_strings () =
  Alcotest.(check string) "system" "system" (Types.role_to_string Types.System);
  Alcotest.(check string) "tool" "tool" (Types.role_to_string Types.Tool)
;;

(* ── response shape diagnostics ───────────────────────── *)

let response ?(content = []) ?(stop_reason = Types.EndTurn) () : Types.api_response =
  { id = "resp-test"
  ; model = "model-test"
  ; stop_reason
  ; content
  ; usage = None
  ; telemetry = None
  }
;;

let summary_contains ~needle response =
  let haystack = Response_shape.diagnostic_summary response in
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0
;;

let test_response_shape_thinking_only_is_not_deliverable () =
  let response =
    response ~content:[ Types.Thinking { signature = None; content = "hidden" } ] ()
  in
  let shape = Response_shape.summarize response in
  Alcotest.(check bool)
    "no deliverable content"
    false
    (Response_shape.has_deliverable_content shape);
  Alcotest.(check bool)
    "ended without deliverable content"
    true
    (Response_shape.ended_without_deliverable_content response);
  Alcotest.(check string)
    "shape label"
    "thinking_only"
    (Response_shape.content_shape_to_string (Response_shape.content_shape response shape));
  Alcotest.(check bool)
    "counts thinking chars without exposing content"
    true
    (summary_contains ~needle:"thinking_chars=6" response);
  Alcotest.(check bool)
    "does not expose hidden thinking text"
    false
    (summary_contains ~needle:"hidden" response)
;;

let test_response_shape_empty_end_turn_is_not_deliverable () =
  let response = response () in
  let shape = Response_shape.summarize response in
  Alcotest.(check bool)
    "no deliverable content"
    false
    (Response_shape.has_deliverable_content shape);
  Alcotest.(check bool)
    "ended without deliverable content"
    true
    (Response_shape.ended_without_deliverable_content response);
  Alcotest.(check string)
    "shape label"
    "empty"
    (Response_shape.content_shape_to_string (Response_shape.content_shape response shape));
  Alcotest.(check bool)
    "summary includes empty shape"
    true
    (summary_contains ~needle:"shape=empty" response);
  Alcotest.(check bool)
    "summary includes end_turn"
    true
    (summary_contains ~needle:"stop_reason=end_turn" response);
  Alcotest.(check bool)
    "summary includes no content blocks"
    true
    (summary_contains ~needle:"content_blocks=0" response);
  Alcotest.(check bool)
    "summary includes no content kinds"
    true
    (summary_contains ~needle:"content_kinds=[none]" response)
;;

let test_response_shape_unknown_stop_reason_is_escaped_in_diagnostics () =
  let newline_response = response ~stop_reason:(Types.Unknown "provider\nmessage") () in
  let summary = Response_shape.diagnostic_summary newline_response in
  Alcotest.(check bool)
    "escapes unknown stop reason"
    true
    (summary_contains
       ~needle:"stop_reason=unknown(\"provider\\nmessage\")"
       newline_response);
  Alcotest.(check bool) "keeps summary single-line" false (String.contains summary '\n');
  let empty_response = response ~stop_reason:(Types.Unknown "") () in
  Alcotest.(check bool)
    "empty unknown remains visible"
    true
    (summary_contains ~needle:"stop_reason=unknown(\"\")" empty_response)
;;

let test_response_shape_thinking_plus_text_is_deliverable () =
  let response =
    response
      ~content:
        [ Types.Thinking { signature = None; content = "hidden" }
        ; Types.Text " final answer "
        ]
      ()
  in
  let shape = Response_shape.summarize response in
  Alcotest.(check bool)
    "deliverable content"
    true
    (Response_shape.has_deliverable_content shape);
  Alcotest.(check bool)
    "not ended without deliverable content"
    false
    (Response_shape.ended_without_deliverable_content response);
  Alcotest.(check string)
    "shape label"
    "has_deliverable_content"
    (Response_shape.content_shape_to_string (Response_shape.content_shape response shape))
;;

let test_response_shape_media_only_is_deliverable () =
  let responses =
    [ ( "image"
      , response
          ~content:
            [ Types.Image
                { media_type = "image/png"; data = "AAAA"; source_type = Types.Base64 }
            ]
          () )
    ; ( "document"
      , response
          ~content:
            [ Types.Document
                { media_type = "application/pdf"
                ; data = "AAAA"
                ; source_type = Types.Base64
                }
            ]
          () )
    ; ( "audio"
      , response
          ~content:
            [ Types.Audio
                { media_type = "audio/wav"; data = "AAAA"; source_type = Types.Base64 }
            ]
          () )
    ]
  in
  List.iter
    (fun (label, response) ->
       let shape = Response_shape.summarize response in
       Alcotest.(check bool)
         (label ^ " is deliverable")
         true
         (Response_shape.has_deliverable_content shape);
       Alcotest.(check bool)
         (label ^ " is not an empty completion")
         false
         (Response_shape.ended_without_deliverable_content response);
       Alcotest.(check string)
         (label ^ " retains the typed media-only diagnostic")
         "media_only"
         (Response_shape.content_shape_to_string
            (Response_shape.content_shape response shape)))
    responses
;;

let test_response_shape_thinking_plus_tool_use_is_deliverable () =
  let response =
    response
      ~content:
        [ Types.Thinking { signature = None; content = "hidden" }
        ; Types.ToolUse { id = "tool-1"; name = "search"; input = `Assoc [] }
        ]
      ()
  in
  let shape = Response_shape.summarize response in
  Alcotest.(check bool)
    "deliverable tool use"
    true
    (Response_shape.has_deliverable_content shape);
  Alcotest.(check bool)
    "not ended without deliverable content"
    false
    (Response_shape.ended_without_deliverable_content response)
;;

let () =
  Alcotest.run
    "Types"
    [ ( "stop_reason"
      , [ Alcotest.test_case "known stop reasons" `Quick test_known_stop_reasons
        ; Alcotest.test_case "unknown stop reason" `Quick test_unknown_stop_reason
        ; Alcotest.test_case "empty stop reason" `Quick test_empty_stop_reason
        ] )
    ; "model", [ Alcotest.test_case "model_to_string" `Quick test_model_to_string ]
    ; ( "role"
      , [ Alcotest.test_case "role_to_string" `Quick test_role_to_string
        ; Alcotest.test_case "role_of_string" `Quick test_role_of_string
        ; Alcotest.test_case "system/tool strings" `Quick test_role_system_tool_strings
        ] )
    ; ( "param_type"
      , [ Alcotest.test_case "param_type_to_string" `Quick test_param_type_to_string ] )
    ; ( "tool_choice"
      , [ Alcotest.test_case "auto" `Quick test_tool_choice_auto
        ; Alcotest.test_case "any" `Quick test_tool_choice_any
        ; Alcotest.test_case "tool" `Quick test_tool_choice_tool
        ; Alcotest.test_case "none roundtrip" `Quick test_tool_choice_none
        ] )
    ; "response_format", [ Alcotest.test_case "json" `Quick test_response_format_json ]
    ; ( "response_shape"
      , [ Alcotest.test_case
            "thinking-only is not deliverable"
            `Quick
            test_response_shape_thinking_only_is_not_deliverable
        ; Alcotest.test_case
            "empty end_turn is not deliverable"
            `Quick
            test_response_shape_empty_end_turn_is_not_deliverable
        ; Alcotest.test_case
            "unknown stop reason is escaped in diagnostics"
            `Quick
            test_response_shape_unknown_stop_reason_is_escaped_in_diagnostics
        ; Alcotest.test_case
            "thinking plus text is deliverable"
            `Quick
            test_response_shape_thinking_plus_text_is_deliverable
        ; Alcotest.test_case
            "media-only is deliverable"
            `Quick
            test_response_shape_media_only_is_deliverable
        ; Alcotest.test_case
            "thinking plus tool use is deliverable"
            `Quick
            test_response_shape_thinking_plus_tool_use_is_deliverable
        ] )
    ; ( "usage"
      , [ Alcotest.test_case "add_usage" `Quick test_add_usage
        ; Alcotest.test_case "accumulates" `Quick test_add_usage_accumulates
        ; Alcotest.test_case
            "usage and telemetry yojson"
            `Quick
            test_usage_and_inference_telemetry_yojson_roundtrip
        ; Alcotest.test_case
            "default inference telemetry"
            `Quick
            test_default_inference_telemetry
        ] )
    ; "config", [ Alcotest.test_case "default_config" `Quick test_default_config ]
    ; ( "yojson_roundtrip"
      , [ Alcotest.test_case "model" `Quick test_model_yojson_roundtrip
        ; Alcotest.test_case "role" `Quick test_role_yojson_roundtrip
        ; Alcotest.test_case "param_type" `Quick test_param_type_yojson_roundtrip
        ; Alcotest.test_case "tool_choice all" `Quick test_tool_choice_roundtrip_all
        ] )
    ; ( "tool_choice_errors"
      , [ Alcotest.test_case "bogus type" `Quick test_tool_choice_of_json_error_bogus
        ; Alcotest.test_case "non-object" `Quick test_tool_choice_of_json_error_non_object
        ] )
    ; ( "show_functions"
      , [ Alcotest.test_case
            "content_block variants"
            `Quick
            test_show_content_block_variants
        ; Alcotest.test_case "message" `Quick test_show_message
        ; Alcotest.test_case "agent_config" `Quick test_show_agent_config
        ; Alcotest.test_case "agent_state" `Quick test_show_agent_state
        ; Alcotest.test_case "api_response" `Quick test_show_api_response
        ; Alcotest.test_case "audio block" `Quick test_show_audio_block
        ] )
    ; ( "message_constructors"
      , [ Alcotest.test_case "text_message" `Quick test_text_message
        ; Alcotest.test_case "system_msg" `Quick test_system_msg
        ; Alcotest.test_case "user_msg" `Quick test_user_msg
        ; Alcotest.test_case "assistant_msg" `Quick test_assistant_msg
        ; Alcotest.test_case "tool_result_msg" `Quick test_tool_result_msg
        ; Alcotest.test_case "tool_result_msg error" `Quick test_tool_result_msg_error
        ] )
    ; ( "tool_schema_yojson"
      , [ Alcotest.test_case "roundtrip" `Quick (fun () ->
            let schema : Types.tool_schema =
              Types.tool_schema_of_params
                ~name:"calc"
                ~description:"Calculate"
                ~parameters:
                  [ { Types.name = "expr"
                    ; description = "Expression"
                    ; param_type = Types.String
                    ; required = true
                    }
                  ; { Types.name = "precision"
                    ; description = "Decimal places"
                    ; param_type = Types.Integer
                    ; required = false
                    }
                  ]
                ()
            in
            let json = Types.tool_schema_to_yojson schema in
            match Types.tool_schema_of_yojson json with
            | Ok decoded ->
              Alcotest.(check string) "name" "calc" decoded.name;
              Alcotest.(check int) "params" 2 (List.length decoded.parameters)
            | Error msg -> Alcotest.fail ("tool_schema_of_yojson: " ^ msg))
        ; Alcotest.test_case "tool_param roundtrip" `Quick (fun () ->
            let param : Types.tool_param =
              { name = "x"
              ; description = "Value"
              ; param_type = Types.Number
              ; required = true
              }
            in
            let json = Types.tool_param_to_yojson param in
            match Types.tool_param_of_yojson json with
            | Ok decoded ->
              Alcotest.(check string) "name" "x" decoded.name;
              Alcotest.(check bool) "required" true decoded.required
            | Error msg -> Alcotest.fail ("tool_param_of_yojson: " ^ msg))
        ; Alcotest.test_case
            "manual json helpers"
            `Quick
            test_tool_param_manual_json_helpers
        ; Alcotest.test_case "result_all" `Quick test_result_all_helper
        ; Alcotest.test_case
            "tool_schema_of_json bad param"
            `Quick
            test_tool_schema_manual_json_rejects_bad_param
        ; Alcotest.test_case
            "tool_error_class yojson"
            `Quick
            test_tool_error_class_yojson_roundtrip
        ] )
    ; ( "text_extraction"
      , [ Alcotest.test_case "text only" `Quick test_text_of_content_text_only
        ; Alcotest.test_case "mixed" `Quick test_text_of_content_mixed
        ; Alcotest.test_case "tool result" `Quick test_text_of_content_tool_result
        ; Alcotest.test_case
            "visible text excludes non-answer blocks"
            `Quick
            test_visible_text_of_content_excludes_non_answer_blocks
        ; Alcotest.test_case
            "reasoning details text prefers content"
            `Quick
            test_reasoning_details_text_prefers_reasoning_content
        ; Alcotest.test_case
            "reasoning details text projects details"
            `Quick
            test_reasoning_details_text_projects_detail_text_in_order
        ; Alcotest.test_case
            "reasoning details text ignores raw-only details"
            `Quick
            test_reasoning_details_text_ignores_raw_only_details
        ; Alcotest.test_case "empty" `Quick test_text_of_content_empty
        ; Alcotest.test_case "text_of_message" `Quick test_text_of_message
        ; Alcotest.test_case
            "text_of_response and usage"
            `Quick
            test_text_of_response_and_usage_helpers
        ] )
    ; ( "tool_result_validation"
      , [ Alcotest.test_case "shape checks" `Quick test_validate_tool_result_shape
        ; Alcotest.test_case "json detection" `Quick test_tool_result_msg_json_detection
        ] )
    ]
;;
