open Agent_sdk

let invocation tool_use_id =
  let schedule : Tool_contract.schedule =
    { planned_index = 0
    ; batch_index = 0
    ; batch_size = 1
    ; execution_mode = Tool_contract.Serial
    }
  in
  Tool_contract.Invocation.create
    ~tool_use_id
    ~turn:0
    ~schedule
    ~completion:Tool_contract.Continue_after_success
;;

let check_context_backend label expected ctx =
  Alcotest.(check bool) label true (Context.concurrency_backend ctx = expected)
;;

let check_response_format label expected actual =
  Alcotest.(check string)
    label
    (Types.show_response_format expected)
    (Types.show_response_format actual)
;;

(* Helper: build a minimal checkpoint for testing *)
let make_checkpoint
      ?(session_id = "test-session")
      ?(agent_name = "test-agent")
      ?(model = "claude-sonnet-4-6")
      ?(system_prompt = Some "You are helpful.")
      ?(messages = [])
      ?(usage = Types.empty_usage)
      ?(turn_count = 0)
      ?(tools = [])
      ?(tool_choice = None)
      ?(context = Context.create_sync ())
      ?(enable_thinking = None)
      ?(preserve_thinking = None)
      ?(thinking_budget = None)
      ?(reasoning_effort = None)
      ?(mcp_sessions = [])
      ()
  : Checkpoint.t
  =
  { version = Checkpoint.checkpoint_version
  ; session_id
  ; agent_name
  ; model
  ; system_prompt
  ; messages
  ; usage
  ; turn_count
  ; created_at = 1000.0
  ; tools
  ; tool_choice
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; enable_thinking
  ; preserve_thinking
  ; response_format = Types.Off
  ; thinking_budget
  ; reasoning_effort
  ; cache_system_prompt = false
  ; context
  ; mcp_sessions
  ; working_context = None
  }
;;

let reported_tool_failure =
  Types.Tool_failed { failure_kind = Types.Reported_tool_error; error_class = None }
;;

let replace_json_field name value = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (field_name, field_value) ->
            if String.equal name field_name
            then field_name, value
            else field_name, field_value)
         fields)
  | json -> json
;;

let update_json_field name update = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (field_name, field_value) ->
            if String.equal name field_name
            then field_name, update field_value
            else field_name, field_value)
         fields)
  | json -> json
;;

let update_first_json update = function
  | `List (first :: rest) -> `List (update first :: rest)
  | json -> json
;;

let append_json_field name value = function
  | `Assoc fields -> `Assoc (fields @ [ name, value ])
  | json -> json
;;

let checkpoint_json_with_tool_result ?(extra_fields = []) outcome =
  let block =
    Types.ToolResult
      { tool_use_id = "tool-result-outcome"
      ; content = "result"
      ; outcome
      ; json = None
      ; content_blocks = None
      }
    |> Llm_provider.Api_common.content_block_to_json
    |> function
    | `Assoc fields -> `Assoc (fields @ extra_fields)
    | json ->
      Alcotest.failf
        "provider ToolResult must serialize to an object, got %s"
        (Yojson.Safe.to_string json)
  in
  match Checkpoint.to_json (make_checkpoint ()) with
  | `Assoc fields ->
    let message = `Assoc [ "role", `String "tool"; "content", `List [ block ] ] in
    `Assoc (("messages", `List [ message ]) :: List.remove_assoc "messages" fields)
  | json ->
    Alcotest.failf
      "checkpoint must serialize to an object, got %s"
      (Yojson.Safe.to_string json)
;;

(* Helper: a sample tool_schema *)
let sample_tool_schema : Types.tool_schema =
  Types.tool_schema_of_params
    ~name:"get_weather"
    ~description:"Get weather for a city"
    ~parameters:
      [ { Types.name = "city"
        ; description = "City name"
        ; param_type = Types.String
        ; required = true
        }
      ; { Types.name = "units"
        ; description = "Temperature units"
        ; param_type = Types.String
        ; required = false
        }
      ]
    ()
;;

let sample_echo_tool =
  Tool.create
    ~name:"echo"
    ~description:"Echo input"
    ~parameters:
      [ { name = "msg"
        ; description = "Message"
        ; param_type = Types.String
        ; required = true
        }
      ]
    (fun input ->
       let msg = Yojson.Safe.Util.(input |> member "msg" |> to_string) in
       Ok { Types.content = msg; _meta = None })
;;

let () =
  let open Alcotest in
  run
    "Checkpoint"
    [ ( "version"
      , [ test_case "checkpoint_version is 10" `Quick (fun () ->
            check int "version" 10 Checkpoint.checkpoint_version)
        ; test_case "version field in to_json" `Quick (fun () ->
            let cp = make_checkpoint () in
            let json = Checkpoint.to_json cp in
            let v = Yojson.Safe.Util.(json |> member "version" |> to_int) in
            check int "version" 10 v)
        ; test_case "wrong version returns Error" `Quick (fun () ->
            let cp = make_checkpoint () in
            let json = Checkpoint.to_json cp in
            let bad =
              match json with
              | `Assoc pairs ->
                `Assoc
                  (List.map
                     (fun (k, v) -> if k = "version" then k, `Int 999 else k, v)
                     pairs)
              | other -> other
            in
            check bool "is error" true (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "old version 4 is rejected" `Quick (fun () ->
            match Checkpoint.of_json (`Assoc [ "version", `Int 4 ]) with
            | Error (Error.Serialization (Error.VersionMismatch { got = 4; _ })) -> ()
            | Error error -> fail ("unexpected error: " ^ Error.to_string error)
            | Ok _ -> fail "checkpoint v4 must be rejected")
        ; test_case "released v5 is rejected" `Quick (fun () ->
            let json =
              match Checkpoint.to_json (make_checkpoint ()) with
              | `Assoc fields ->
                `Assoc (("version", `Int 5) :: List.remove_assoc "version" fields)
              | _ -> fail "current checkpoint serializer must return an object"
            in
            match Checkpoint.of_json json with
            | Error (Error.Serialization (Error.VersionMismatch { got = 5; _ })) -> ()
            | Error error -> fail ("unexpected error: " ^ Error.to_string error)
            | Ok _ -> fail "checkpoint v5 must be rejected")
        ; test_case "released v6 is rejected" `Quick (fun () ->
            let json =
              match Checkpoint.to_json (make_checkpoint ()) with
              | `Assoc fields ->
                `Assoc (("version", `Int 6) :: List.remove_assoc "version" fields)
              | _ -> fail "current checkpoint serializer must return an object"
            in
            match Checkpoint.of_json json with
            | Error (Error.Serialization (Error.VersionMismatch { got = 6; _ })) -> ()
            | Error error -> fail ("unexpected error: " ^ Error.to_string error)
            | Ok _ -> fail "checkpoint v6 must be rejected")
        ; test_case "version 7 is rejected" `Quick (fun () ->
            match Checkpoint.of_json (`Assoc [ "version", `Int 7 ]) with
            | Error (Error.Serialization (Error.VersionMismatch { got = 7; _ })) -> ()
            | Error error -> fail ("unexpected error: " ^ Error.to_string error)
            | Ok _ -> fail "checkpoint v7 must be rejected")
        ; test_case "released v8 is rejected" `Quick (fun () ->
            let json =
              match Checkpoint.to_json (make_checkpoint ()) with
              | `Assoc fields ->
                `Assoc (("version", `Int 8) :: List.remove_assoc "version" fields)
              | _ -> fail "current checkpoint serializer must return an object"
            in
            match Checkpoint.of_json json with
            | Error (Error.Serialization (Error.VersionMismatch { got = 8; _ })) -> ()
            | Error error -> fail ("unexpected error: " ^ Error.to_string error)
            | Ok _ -> fail "checkpoint v8 must be rejected")
        ; test_case "released v9 is rejected" `Quick (fun () ->
            let json =
              match Checkpoint.to_json (make_checkpoint ()) with
              | `Assoc fields ->
                `Assoc (("version", `Int 9) :: List.remove_assoc "version" fields)
              | _ -> fail "current checkpoint serializer must return an object"
            in
            match Checkpoint.of_json json with
            | Error (Error.Serialization (Error.VersionMismatch { got = 9; _ })) -> ()
            | Error error -> fail ("unexpected error: " ^ Error.to_string error)
            | Ok _ -> fail "checkpoint v9 must be rejected")
        ; test_case "missing version is rejected explicitly" `Quick (fun () ->
            match Checkpoint.of_json (`Assoc []) with
            | Error (Error.Serialization (Error.JsonParseError { detail })) ->
              check string "missing detail" "Checkpoint is missing version" detail
            | Error error -> fail ("unexpected error: " ^ Error.to_string error)
            | Ok _ -> fail "checkpoint without version must be rejected")
        ; test_case "non-integer version is rejected explicitly" `Quick (fun () ->
            match Checkpoint.of_json (`Assoc [ "version", `String "6" ]) with
            | Error (Error.Serialization (Error.JsonParseError { detail })) ->
              check string "type detail" "Checkpoint version must be an integer" detail
            | Error error -> fail ("unexpected error: " ^ Error.to_string error)
            | Ok _ -> fail "string checkpoint version must be rejected")
        ; test_case "duplicate version is rejected explicitly" `Quick (fun () ->
            let ambiguous = `Assoc [ "version", `Int 6; "version", `Int 6 ] in
            match Checkpoint.of_json ambiguous with
            | Error (Error.Serialization (Error.JsonParseError { detail })) ->
              check string "duplicate detail" "Checkpoint duplicates field version" detail
            | Error error -> fail ("unexpected error: " ^ Error.to_string error)
            | Ok _ -> fail "duplicate v6 version must be rejected")
        ] )
    ; ( "roundtrip_basic"
      , [ test_case "empty checkpoint roundtrip" `Quick (fun () ->
            let cp = make_checkpoint () in
            let json = Checkpoint.to_json cp in
            let cp2 = Result.get_ok (Checkpoint.of_json json) in
            check string "session_id" cp.session_id cp2.session_id;
            check string "agent_name" cp.agent_name cp2.agent_name;
            check int "turn_count" cp.turn_count cp2.turn_count)
        ; test_case "to_string / of_string roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~session_id:"s1" ~turn_count:5 () in
            let s = Checkpoint.to_string cp in
            let cp2 = Result.get_ok (Checkpoint.of_string s) in
            check string "session_id" "s1" cp2.session_id;
            check int "turn_count" 5 cp2.turn_count)
        ; test_case "system_prompt None roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~system_prompt:None () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check (option string) "system_prompt" None cp2.system_prompt)
        ; test_case "system_prompt Some roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~system_prompt:(Some "Be concise.") () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check (option string) "system_prompt" (Some "Be concise.") cp2.system_prompt)
        ; test_case "reasoning effort exact roundtrip" `Quick (fun () ->
            let cp =
              make_checkpoint
                ~reasoning_effort:(Some Llm_provider.Reasoning_effort.Max)
                ()
            in
            let json = Checkpoint.to_json cp in
            check
              string
              "wire value"
              "max"
              Yojson.Safe.Util.(json |> member "reasoning_effort" |> to_string);
            let cp2 = Result.get_ok (Checkpoint.of_json json) in
            check
              (option string)
              "typed value"
              (Some "max")
              (Option.map Llm_provider.Reasoning_effort.to_string cp2.reasoning_effort))
        ; test_case "context roundtrip" `Quick (fun () ->
            let ctx = Context.create_sync () in
            Context.set_scoped ctx Context.Session "trace_id" (`String "abc");
            Context.set_scoped ctx Context.User "theme" (`String "dark");
            let cp = make_checkpoint ~context:ctx () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check
              bool
              "session state restored"
              true
              (Context.get_scoped cp2.context Context.Session "trace_id"
               = Some (`String "abc"));
            check
              bool
              "user state restored"
              true
              (Context.get_scoped cp2.context Context.User "theme" = Some (`String "dark")))
        ] )
    ; ( "messages"
      , [ test_case "Text message roundtrip" `Quick (fun () ->
            let msgs =
              [ { Types.role = Types.User
                ; content = [ Types.Text "Hello" ]
                ; name = None
                ; tool_call_id = None
                ; metadata = []
                }
              ; { Types.role = Types.Assistant
                ; content = [ Types.Text "Hi there" ]
                ; name = None
                ; tool_call_id = None
                ; metadata = []
                }
              ]
            in
            let cp = make_checkpoint ~messages:msgs () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check int "message count" 2 (List.length cp2.messages);
            let first = List.hd cp2.messages in
            check bool "user role" true (first.role = Types.User);
            match List.hd first.content with
            | Types.Text t -> check string "text" "Hello" t
            | _ -> fail "expected Text")
        ; test_case "ToolUse message roundtrip" `Quick (fun () ->
            let msgs =
              [ { Types.role = Types.Assistant
                ; content =
                    [ Types.ToolUse
                        { id = "id1"
                        ; name = "get_weather"
                        ; input = `Assoc [ "city", `String "Seoul" ]
                        }
                    ]
                ; name = None
                ; tool_call_id = None
                ; metadata = []
                }
              ]
            in
            let cp = make_checkpoint ~messages:msgs () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            match (List.hd cp2.messages).content with
            | [ Types.ToolUse { id; name; _ } ] ->
              check string "id" "id1" id;
              check string "name" "get_weather" name
            | _ -> fail "expected ToolUse")
        ; test_case "ToolResult message roundtrip" `Quick (fun () ->
            let msgs =
              [ { Types.role = Types.Tool
                ; content =
                    [ Types.ToolResult
                        { tool_use_id = "id1"
                        ; content = "Sunny 22C"
                        ; outcome = Tool_succeeded
                        ; json = None
                        ; content_blocks = None
                        }
                    ]
                ; name = None
                ; tool_call_id = None
                ; metadata = []
                }
              ]
            in
            let cp = make_checkpoint ~messages:msgs () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check bool "tool role" true ((List.hd cp2.messages).role = Types.Tool);
            match (List.hd cp2.messages).content with
            | [ Types.ToolResult { tool_use_id; content; outcome; _ } ] ->
              check string "id" "id1" tool_use_id;
              check string "content" "Sunny 22C" content;
              check bool "is_error" false (Types.tool_result_outcome_is_error outcome)
            | _ -> fail "expected ToolResult")
        ; test_case "nested ToolResult provenance roundtrip" `Quick (fun () ->
            let nested_failure =
              Types.ToolResult
                { tool_use_id = "nested-failure"
                ; content = "legacy failure without attribution"
                ; outcome =
                    Tool_failed
                      { failure_kind = Types.Unattributed_tool_error; error_class = None }
                ; json = None
                ; content_blocks = None
                }
            in
            let outer_result =
              Types.ToolResult
                { tool_use_id = "outer-result"
                ; content = "nested result"
                ; outcome = Tool_succeeded
                ; json = None
                ; content_blocks = Some [ nested_failure ]
                }
            in
            let messages =
              [ { Types.role = Types.Tool
                ; content = [ outer_result ]
                ; name = None
                ; tool_call_id = None
                ; metadata = []
                }
              ]
            in
            let restored =
              make_checkpoint ~messages ()
              |> Checkpoint.to_json
              |> Checkpoint.of_json
              |> Result.get_ok
            in
            match (List.hd restored.messages).content with
            | [ Types.ToolResult
                  { content_blocks =
                      Some
                        [ Types.ToolResult
                            { outcome =
                                Tool_failed
                                  { failure_kind = Types.Unattributed_tool_error
                                  ; error_class = None
                                  }
                            ; _
                            }
                        ]
                  ; _
                  }
              ] -> ()
            | _ -> fail "nested ToolResult provenance was not preserved")
        ; test_case
            "typed failed ToolResult survives execution projection and checkpoint"
            `Quick
            (fun () ->
               let execution_result : Agent_tools.tool_execution_result =
                 { invocation = invocation "failed-1"
                 ; tool_name = "Execute"
                 ; input = `Assoc [ "cwd", `String "/missing" ]
                 ; content = "working directory is unavailable"
                 ; outcome =
                     Tool_failed
                       { failure_kind = Agent_tools.Validation_error
                       ; error_class = Some Types.Deterministic
                       }
                 }
               in
               let content = Agent_turn.make_tool_results [ execution_result ] in
               let block = List.hd content in
               let wire_json = Llm_provider.Api_common.content_block_to_json block in
               let open Yojson.Safe.Util in
               check
                 bool
                 "provider wire omits failure_kind"
                 true
                 (wire_json |> member "failure_kind" = `Null);
               check
                 bool
                 "provider wire omits error_class"
                 true
                 (wire_json |> member "error_class" = `Null);
               let messages =
                 [ { Types.role = Types.Tool
                   ; content
                   ; name = None
                   ; tool_call_id = Some "failed-1"
                   ; metadata = []
                   }
                 ]
               in
               let checkpoint = make_checkpoint ~messages () in
               let checkpoint_json = Checkpoint.to_json checkpoint in
               let stored_block =
                 checkpoint_json
                 |> member "messages"
                 |> index 0
                 |> member "content"
                 |> index 0
               in
               check
                 bool
                 "checkpoint stores failure_kind"
                 true
                 (stored_block |> member "failure_kind" <> `Null);
               check
                 bool
                 "checkpoint stores error_class"
                 true
                 (stored_block |> member "error_class" <> `Null);
               let restored = Result.get_ok (Checkpoint.of_json checkpoint_json) in
               match (List.hd restored.messages).content with
               | [ Types.ToolResult
                     { outcome =
                         Tool_failed
                           { failure_kind = Types.Validation_error
                           ; error_class = Some Types.Deterministic
                           }
                     ; _
                     }
                 ] -> ()
               | _ -> fail "expected typed ToolResult")
        ; test_case "failed ToolResult without provenance is rejected" `Quick (fun () ->
            let checkpoint_json =
              checkpoint_json_with_tool_result reported_tool_failure
            in
            check
              bool
              "rejected"
              true
              (Result.is_error (Checkpoint.of_json checkpoint_json)))
        ; test_case "success with failure provenance is rejected" `Quick (fun () ->
            let checkpoint_json =
              checkpoint_json_with_tool_result
                ~extra_fields:
                  [ ( "failure_kind"
                    , Types.tool_failure_kind_to_yojson Types.Validation_error )
                  ]
                Types.Tool_succeeded
            in
            check
              bool
              "rejected"
              true
              (Result.is_error (Checkpoint.of_json checkpoint_json)))
        ; test_case "error_class without failure_kind is rejected" `Quick (fun () ->
            let checkpoint_json =
              checkpoint_json_with_tool_result
                ~extra_fields:
                  [ "error_class", Types.tool_error_class_to_yojson Types.Deterministic ]
                reported_tool_failure
            in
            check
              bool
              "rejected"
              true
              (Result.is_error (Checkpoint.of_json checkpoint_json)))
        ; test_case "duplicate failure_kind is rejected" `Quick (fun () ->
            let checkpoint_json =
              checkpoint_json_with_tool_result
                ~extra_fields:
                  [ ( "failure_kind"
                    , Types.tool_failure_kind_to_yojson Types.Validation_error )
                  ; ( "failure_kind"
                    , Types.tool_failure_kind_to_yojson Types.Recoverable_tool_error )
                  ]
                reported_tool_failure
            in
            check
              bool
              "rejected"
              true
              (Result.is_error (Checkpoint.of_json checkpoint_json)))
        ; test_case "duplicate error_class is rejected" `Quick (fun () ->
            let checkpoint_json =
              checkpoint_json_with_tool_result
                ~extra_fields:
                  [ ( "failure_kind"
                    , Types.tool_failure_kind_to_yojson Types.Validation_error )
                  ; "error_class", Types.tool_error_class_to_yojson Types.Deterministic
                  ; "error_class", Types.tool_error_class_to_yojson Types.Transient
                  ]
                reported_tool_failure
            in
            check
              bool
              "rejected"
              true
              (Result.is_error (Checkpoint.of_json checkpoint_json)))
        ; test_case "empty messages roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~messages:[] () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check int "no messages" 0 (List.length cp2.messages))
        ; test_case "canonical tool turn content blocks" `Quick (fun () ->
            let msgs =
              [ { Types.role = Types.Assistant
                ; content =
                    [ Types.Text "Let me check."
                    ; Types.ToolUse
                        { id = "t1"
                        ; name = "search"
                        ; input = `Assoc [ "q", `String "test" ]
                        }
                    ]
                ; name = None
                ; tool_call_id = None
                ; metadata = []
                }
              ; { Types.role = Types.Tool
                ; content =
                    [ Types.ToolResult
                        { tool_use_id = "t1"
                        ; content = "found it"
                        ; outcome = Tool_succeeded
                        ; json = None
                        ; content_blocks = None
                        }
                    ]
                ; name = None
                ; tool_call_id = None
                ; metadata = []
                }
              ]
            in
            let cp = make_checkpoint ~messages:msgs () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check int "2 messages" 2 (List.length cp2.messages);
            let first = List.hd cp2.messages in
            check int "2 blocks in first" 2 (List.length first.content))
        ; test_case "user ToolResult is rejected" `Quick (fun () ->
            let messages =
              [ { Types.role = Types.User
                ; content =
                    [ Types.ToolResult
                        { tool_use_id = "t1"
                        ; content = "invalid role/content pair"
                        ; outcome = Tool_succeeded
                        ; json = None
                        ; content_blocks = None
                        }
                    ]
                ; name = None
                ; tool_call_id = None
                ; metadata = []
                }
              ]
            in
            match Checkpoint.to_json (make_checkpoint ~messages ()) with
            | _ -> fail "invalid current checkpoint was serialized"
            | exception Invalid_argument message ->
              check
                bool
                "serializer rejects non-canonical role/content"
                true
                (String.starts_with ~prefix:"Checkpoint.to_json:" message))
        ; test_case "message metadata roundtrip" `Quick (fun () ->
            let replay_metadata =
              [ ( "replay.namespace"
                , `Assoc
                    [ "kind", `String "state_snapshot"
                    ; "version", `Int 1
                    ; "payload", `Assoc [ "goal", `String "ship" ]
                    ] )
              ]
            in
            let msgs =
              [ { Types.role = Types.Assistant
                ; content = [ Types.Text "Visible reply" ]
                ; name = Some "agent_role_a"
                ; tool_call_id = Some "call_1"
                ; metadata = replay_metadata
                }
              ]
            in
            let cp = make_checkpoint ~messages:msgs () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            match cp2.messages with
            | [ msg ] ->
              check (option string) "name" (Some "agent_role_a") msg.name;
              check (option string) "tool_call_id" (Some "call_1") msg.tool_call_id;
              check
                string
                "metadata preserved"
                (Yojson.Safe.to_string (`Assoc replay_metadata))
                (Yojson.Safe.to_string (`Assoc msg.metadata))
            | _ -> fail "expected one message")
        ] )
    ; ( "usage"
      , [ test_case "usage roundtrip" `Quick (fun () ->
            let u : Types.usage_stats =
              { total_input_tokens = 1000
              ; total_output_tokens = 500
              ; total_cache_creation_input_tokens = 200
              ; total_cache_read_input_tokens = 100
              ; api_calls = 3
              ; estimated_cost_usd = 0.0
              ; pricing_gap = None
              }
            in
            let cp = make_checkpoint ~usage:u () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check int "input" 1000 cp2.usage.total_input_tokens;
            check int "output" 500 cp2.usage.total_output_tokens;
            check int "cache_create" 200 cp2.usage.total_cache_creation_input_tokens;
            check int "cache_read" 100 cp2.usage.total_cache_read_input_tokens;
            check int "api_calls" 3 cp2.usage.api_calls)
        ; test_case "empty usage roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~usage:Types.empty_usage () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check int "input" 0 cp2.usage.total_input_tokens;
            check int "api_calls" 0 cp2.usage.api_calls)
        ; test_case "usage pricing gap roundtrip" `Quick (fun () ->
            let usage =
              { Types.empty_usage with
                estimated_cost_usd = 1.0
              ; pricing_gap = Some (Types.Pricing_unavailable "custom-model")
              }
            in
            let decoded =
              Checkpoint.usage_of_json (Checkpoint.usage_to_json usage) |> Result.get_ok
            in
            check (float 0.001) "known cost" 1.0 decoded.estimated_cost_usd;
            check bool "typed gap" true (decoded.pricing_gap = usage.pricing_gap))
        ; test_case "legacy usage field rejected" `Quick (fun () ->
            let result =
              Checkpoint.usage_of_json
                (`Assoc [ "unpriced_model", `String "custom-model" ])
            in
            check bool "explicit error" true (Result.is_error result))
        ] )
    ; ( "tools"
      , [ test_case "tool_schema roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~tools:[ sample_tool_schema ] () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check int "1 tool" 1 (List.length cp2.tools);
            let t = List.hd cp2.tools in
            check string "name" "get_weather" t.name;
            check string "desc" "Get weather for a city" t.description;
            check int "2 params" 2 (List.length t.parameters);
            let p1 = List.hd t.parameters in
            check string "param name" "city" p1.name;
            check bool "required" true p1.required)
        ; test_case "authoritative schema is a v10 wire" `Quick (fun () ->
            let input_schema : Yojson.Safe.t =
              `Assoc
                [ "type", `String "object"
                ; "properties", `Assoc [ "city", `Assoc [ "type", `String "string" ] ]
                ]
            in
            let tool =
              match
                Types.tool_schema_of_input_schema
                  ~name:"weather"
                  ~description:"Weather"
                  ~input_schema
                  ()
              with
              | Ok schema -> schema
              | Error detail -> fail detail
            in
            let json = Checkpoint.to_json (make_checkpoint ~tools:[ tool ] ()) in
            let open Yojson.Safe.Util in
            check int "new wire version" 10 (json |> member "version" |> to_int);
            check
              string
              "authoritative schema persisted"
              (Yojson.Safe.to_string input_schema)
              (json
               |> member "tools"
               |> index 0
               |> member "input_schema"
               |> Yojson.Safe.to_string))
        ; test_case "empty tools roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~tools:[] () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check int "no tools" 0 (List.length cp2.tools))
        ; test_case "param_type variants" `Quick (fun () ->
            let params =
              List.map
                (fun (n, pt) ->
                   { Types.name = n; description = n; param_type = pt; required = true })
                [ "s", Types.String
                ; "i", Types.Integer
                ; "n", Types.Number
                ; "b", Types.Boolean
                ; "a", Types.Array
                ; "o", Types.Object
                ]
            in
            let tool : Types.tool_schema =
              Types.tool_schema_of_params
                ~name:"multi"
                ~description:"test"
                ~parameters:params
                ()
            in
            let cp = make_checkpoint ~tools:[ tool ] () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            let t = List.hd cp2.tools in
            check int "6 params" 6 (List.length t.parameters))
        ] )
    ; ( "tool_choice"
      , [ test_case "Auto roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~tool_choice:(Some Types.Auto) () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check bool "auto" true (cp2.tool_choice = Some Types.Auto))
        ; test_case "Any roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~tool_choice:(Some Types.Any) () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check bool "any" true (cp2.tool_choice = Some Types.Any))
        ; test_case "Tool name roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~tool_choice:(Some (Types.Tool "search")) () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check bool "tool" true (cp2.tool_choice = Some (Types.Tool "search")))
        ; test_case "None roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~tool_choice:None () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check bool "none" true (cp2.tool_choice = None))
        ; test_case "None_ roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~tool_choice:(Some Types.None_) () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check bool "none_" true (cp2.tool_choice = Some Types.None_))
        ] )
    ; ( "model"
      , [ test_case "Opus model roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~model:"claude-opus-4-6" () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check string "model" "claude-opus-4-6" cp2.model)
        ; test_case "Custom model roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~model:"my-model-v1" () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check string "custom" "my-model-v1" cp2.model)
        ] )
    ; ( "helpers"
      , [ test_case "message_count" `Quick (fun () ->
            let msgs =
              [ { Types.role = Types.User
                ; content = [ Types.Text "a" ]
                ; name = None
                ; tool_call_id = None
                ; metadata = []
                }
              ; { Types.role = Types.Assistant
                ; content = [ Types.Text "b" ]
                ; name = None
                ; tool_call_id = None
                ; metadata = []
                }
              ; { Types.role = Types.User
                ; content = [ Types.Text "c" ]
                ; name = None
                ; tool_call_id = None
                ; metadata = []
                }
              ]
            in
            let cp = make_checkpoint ~messages:msgs () in
            check int "count" 3 (Checkpoint.message_count cp))
        ; test_case "token_usage returns usage" `Quick (fun () ->
            let u : Types.usage_stats =
              { total_input_tokens = 42
              ; total_output_tokens = 10
              ; total_cache_creation_input_tokens = 0
              ; total_cache_read_input_tokens = 0
              ; api_calls = 1
              ; estimated_cost_usd = 0.0
              ; pricing_gap = None
              }
            in
            let cp = make_checkpoint ~usage:u () in
            let result = Checkpoint.token_usage cp in
            check int "input" 42 result.total_input_tokens)
        ; test_case "Agent.checkpoint captures live state" `Quick (fun () ->
            Eio_main.run
            @@ fun env ->
            let net = Eio.Stdenv.net env in
            let config =
              { (Types.default_config ~model:"test-model") with
                name = "checkpoint-agent"
              ; tool_choice = Some Types.Auto
              }
            in
            let agent = Agent.create ~net ~config ~tools:[ sample_echo_tool ] () in
            Agent.set_state
              agent
              { (Agent.state agent) with
                messages =
                  [ { Types.role = Types.User
                    ; content = [ Types.Text "hello" ]
                    ; name = None
                    ; tool_call_id = None
                    ; metadata = []
                    }
                  ; { Types.role = Types.Assistant
                    ; content = [ Types.Text "hi" ]
                    ; name = None
                    ; tool_call_id = None
                    ; metadata = []
                    }
                  ]
              ; turn_count = 2
              ; usage =
                  { Types.total_input_tokens = 9
                  ; total_output_tokens = 4
                  ; total_cache_creation_input_tokens = 0
                  ; total_cache_read_input_tokens = 0
                  ; api_calls = 1
                  ; estimated_cost_usd = 0.0
                  ; pricing_gap = None
                  }
              };
            let cp = Agent.checkpoint ~session_id:"sess-1" agent in
            check string "session_id" "sess-1" cp.session_id;
            check string "agent_name" "checkpoint-agent" cp.agent_name;
            check int "turn_count" 2 cp.turn_count;
            check int "message_count" 2 (Checkpoint.message_count cp);
            check int "tool_count" 1 (List.length cp.tools);
            check
              (option string)
              "tool_choice auto"
              (Some "auto")
              (match cp.tool_choice with
               | Some Types.Auto -> Some "auto"
               | _ -> None))
        ; test_case "Agent.checkpoint preserves working_context sidecar" `Quick (fun () ->
            Eio_main.run
            @@ fun env ->
            let net = Eio.Stdenv.net env in
            let agent =
              Agent.create ~config:(Types.default_config ~model:"test-model") ~net ()
            in
            let sidecar =
              `Assoc
                [ "kind", `String "test_context_v1"
                ; "max_tokens", `Int 4096
                ; "generation", `Int 3
                ]
            in
            let cp =
              Agent.checkpoint ~session_id:"sess-sidecar" ~working_context:sidecar agent
            in
            Alcotest.(check bool)
              "sidecar preserved"
              true
              (match cp.working_context with
               | Some json -> json = sidecar
               | None -> false))
        ] )
    ; ( "build_resume"
      , [ test_case "roundtrip preserves fields" `Quick (fun () ->
            let ctx = Context.create_sync () in
            Context.set ctx "key" (`String "val");
            let cp =
              make_checkpoint
                ~agent_name:"resume-agent"
                ~model:"claude-opus-4-6"
                ~system_prompt:(Some "Be precise.")
                ~turn_count:3
                ~context:ctx
                ()
            in
            let { Agent_checkpoint.state; context = ctx2 } =
              Agent_checkpoint.build_resume ~checkpoint:cp ()
            in
            check string "agent_name" "resume-agent" state.config.name;
            check int "turn_count" 3 state.turn_count;
            check
              (option string)
              "system_prompt"
              (Some "Be precise.")
              state.config.system_prompt;
            check
              bool
              "context preserved"
              true
              (Context.get ctx2 "key" = Some (`String "val")))
        ; test_case "eio_context rehydrates checkpoint context backend" `Quick (fun () ->
            Eio_main.run
            @@ fun _env ->
            let ctx = Context.create_sync () in
            Context.set ctx "key" (`String "val");
            let cp = make_checkpoint ~context:ctx () in
            let { Agent_checkpoint.context = ctx2; _ } =
              Agent_checkpoint.build_resume ~checkpoint:cp ~eio_context:true ()
            in
            check_context_backend "rehydrated backend" Context.Eio_mutex ctx2;
            check
              bool
              "context preserved"
              true
              (Context.get ctx2 "key" = Some (`String "val")))
        ; test_case "override config takes precedence" `Quick (fun () ->
            let cp =
              make_checkpoint
                ~agent_name:"orig-agent"
                ~model:"claude-sonnet-4-6"
                ~enable_thinking:(Some true)
                ~preserve_thinking:(Some true)
                ~thinking_budget:(Some 2048)
                ~reasoning_effort:(Some Llm_provider.Reasoning_effort.High)
                ()
            in
            let override =
              { (Types.default_config ~model:"test-model") with
                name = "current-agent"
              ; system_prompt = Some "current runtime prompt"
              ; enable_thinking = Some false
              ; preserve_thinking = Some false
              ; thinking_budget = Some 512
              ; reasoning_effort = Some Llm_provider.Reasoning_effort.Max
              }
            in
            let { Agent_checkpoint.state; _ } =
              Agent_checkpoint.build_resume ~checkpoint:cp ~config:override ()
            in
            check string "agent_name from caller" "current-agent" state.config.name;
            check string "model from caller" "test-model" state.config.model;
            check
              (option string)
              "system prompt from caller"
              (Some "current runtime prompt")
              state.config.system_prompt;
            check
              (option bool)
              "enable_thinking from override"
              (Some false)
              state.config.enable_thinking;
            check
              (option bool)
              "preserve_thinking from override"
              (Some false)
              state.config.preserve_thinking;
            check
              (option int)
              "thinking_budget from override"
              (Some 512)
              state.config.thinking_budget;
            check
              (option string)
              "reasoning_effort from override"
              (Some "max")
              (Option.map
                 Llm_provider.Reasoning_effort.to_string
                 state.config.reasoning_effort))
        ; test_case "caller config does not inherit checkpoint opinions" `Quick (fun () ->
            let cp =
              make_checkpoint
                ~enable_thinking:(Some true)
                ~preserve_thinking:(Some true)
                ~thinking_budget:(Some 2048)
                ~reasoning_effort:(Some Llm_provider.Reasoning_effort.High)
                ()
            in
            let override = Types.default_config ~model:"test-model" in
            let { Agent_checkpoint.state; _ } =
              Agent_checkpoint.build_resume ~checkpoint:cp ~config:override ()
            in
            check
              (option bool)
              "enable_thinking from caller"
              None
              state.config.enable_thinking;
            check
              (option bool)
              "preserve_thinking from caller"
              None
              state.config.preserve_thinking;
            check
              (option int)
              "thinking_budget from caller"
              None
              state.config.thinking_budget;
            check
              (option string)
              "reasoning_effort from caller"
              None
              (Option.map
                 Llm_provider.Reasoning_effort.to_string
                 state.config.reasoning_effort))
        ; test_case "override context replaces checkpoint context" `Quick (fun () ->
            let cp_ctx = Context.create_sync () in
            Context.set cp_ctx "old" (`String "old-val");
            let cp = make_checkpoint ~context:cp_ctx () in
            let new_ctx = Context.create_sync () in
            Context.set new_ctx "new" (`String "new-val");
            let { Agent_checkpoint.context = result_ctx; _ } =
              Agent_checkpoint.build_resume ~checkpoint:cp ~context:new_ctx ()
            in
            check
              bool
              "has new key"
              true
              (Context.get result_ctx "new" = Some (`String "new-val"));
            check bool "no old key" true (Context.get result_ctx "old" = None))
        ; test_case "build_checkpoint -> build_resume roundtrip" `Quick (fun () ->
            Eio_main.run
            @@ fun env ->
            let net = Eio.Stdenv.net env in
            let config =
              { (Types.default_config ~model:"test-model") with
                name = "roundtrip-agent"
              ; system_prompt = Some "Be brief."
              ; temperature = Some 0.5
              }
            in
            let agent = Agent.create ~net ~config () in
            Agent.set_state
              agent
              { (Agent.state agent) with
                messages =
                  [ { Types.role = Types.User
                    ; content = [ Types.Text "test" ]
                    ; name = None
                    ; tool_call_id = None
                    ; metadata = []
                    }
                  ]
              ; turn_count = 7
              };
            let cp = Agent.checkpoint ~session_id:"rt-sess" agent in
            let { Agent_checkpoint.state; _ } =
              Agent_checkpoint.build_resume ~checkpoint:cp ()
            in
            check string "name" "roundtrip-agent" state.config.name;
            check int "turn_count" 7 state.turn_count;
            check
              (option string)
              "system_prompt"
              (Some "Be brief.")
              state.config.system_prompt;
            check int "messages" 1 (List.length state.messages))
        ; test_case
            "Agent.resume rehydrates JSON checkpoint context for Eio"
            `Quick
            (fun () ->
               Eio_main.run
               @@ fun env ->
               let net = Eio.Stdenv.net env in
               let ctx = Context.create_sync () in
               Context.set ctx "resume-key" (`String "resume-value");
               let cp = make_checkpoint ~context:ctx () in
               let decoded =
                 match Checkpoint.of_json (Checkpoint.to_json cp) with
                 | Ok cp -> cp
                 | Error err ->
                   Alcotest.fail
                     (Printf.sprintf
                        "checkpoint decode failed: %s"
                        (Agent_sdk.Error.to_string err))
               in
               let agent = Agent.resume ~net ~checkpoint:decoded () in
               let resumed_context = Agent.context agent in
               check_context_backend
                 "agent context backend"
                 Context.Eio_mutex
                 resumed_context;
               check
                 bool
                 "context value preserved"
                 true
                 (Context.get resumed_context "resume-key" = Some (`String "resume-value")))
        ] )
    ; ( "error_cases"
      , [ test_case "malformed JSON string" `Quick (fun () ->
            check
              bool
              "error"
              true
              (Result.is_error (Checkpoint.of_string "not json at all")))
        ; test_case "missing required field" `Quick (fun () ->
            let bad = `Assoc [ "version", `Int 1 ] in
            check bool "error" true (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "wrong type for field" `Quick (fun () ->
            let cp = make_checkpoint () in
            let json = Checkpoint.to_json cp in
            let bad =
              match json with
              | `Assoc pairs ->
                `Assoc
                  (List.map
                     (fun (k, v) ->
                        if k = "turn_count" then k, `String "not_int" else k, v)
                     pairs)
              | other -> other
            in
            check bool "error" true (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "empty JSON object" `Quick (fun () ->
            check bool "error" true (Result.is_error (Checkpoint.of_json (`Assoc []))))
        ; test_case "any string is valid model" `Quick (fun () ->
            let cp = make_checkpoint () in
            let json = Checkpoint.to_json cp in
            let custom =
              match json with
              | `Assoc pairs ->
                `Assoc
                  (List.map
                     (fun (k, v) ->
                        if k = "model" then k, `String "my-custom-model" else k, v)
                     pairs)
              | other -> other
            in
            check bool "ok" true (Result.is_ok (Checkpoint.of_json custom)))
        ; test_case "invalid role returns Error" `Quick (fun () ->
            let cp =
              make_checkpoint
                ~messages:
                  [ { Types.role = Types.User
                    ; content = [ Types.Text "hello" ]
                    ; name = None
                    ; tool_call_id = None
                    ; metadata = []
                    }
                  ]
                ()
            in
            let json = Checkpoint.to_json cp in
            let bad =
              match json with
              | `Assoc pairs ->
                `Assoc
                  (List.map
                     (fun (k, v) ->
                        if k = "messages"
                        then (
                          match v with
                          | `List (`Assoc msg_fields :: rest) ->
                            let msg_fields =
                              List.map
                                (fun (mk, mv) ->
                                   if mk = "role" then mk, `String "bad_role" else mk, mv)
                                msg_fields
                            in
                            k, `List (`Assoc msg_fields :: rest)
                          | other -> k, other)
                        else k, v)
                     pairs)
              | other -> other
            in
            check bool "error" true (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "invalid param_type returns Error" `Quick (fun () ->
            let cp = make_checkpoint ~tools:[ sample_tool_schema ] () in
            let json = Checkpoint.to_json cp in
            let bad =
              match json with
              | `Assoc pairs ->
                `Assoc
                  (List.map
                     (fun (k, v) ->
                        if k = "tools"
                        then (
                          match v with
                          | `List (`Assoc tool_fields :: rest_tools) ->
                            let tool_fields =
                              List.map
                                (fun (tk, tv) ->
                                   if tk = "parameters"
                                   then (
                                     match tv with
                                     | `List (`Assoc param_fields :: rest_params) ->
                                       let param_fields =
                                         List.map
                                           (fun (pk, pv) ->
                                              if pk = "param_type"
                                              then pk, `String "bad_type"
                                              else pk, pv)
                                           param_fields
                                       in
                                       tk, `List (`Assoc param_fields :: rest_params)
                                     | other -> tk, other)
                                   else tk, tv)
                                tool_fields
                            in
                            k, `List (`Assoc tool_fields :: rest_tools)
                          | other -> k, other)
                        else k, v)
                     pairs)
              | other -> other
            in
            check bool "error" true (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "invalid tool_choice returns Error" `Quick (fun () ->
            let cp = make_checkpoint ~tool_choice:(Some Types.Auto) () in
            let json = Checkpoint.to_json cp in
            let bad =
              match json with
              | `Assoc pairs ->
                `Assoc
                  (List.map
                     (fun (k, v) ->
                        if k = "tool_choice"
                        then "tool_choice", `Assoc [ "type", `Int 3 ]
                        else k, v)
                     pairs)
              | other -> other
            in
            check bool "error" true (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "unknown content block returns Error" `Quick (fun () ->
            let cp =
              make_checkpoint
                ~messages:
                  [ { Types.role = Types.User
                    ; content = [ Types.Text "hello" ]
                    ; name = None
                    ; tool_call_id = None
                    ; metadata = []
                    }
                  ]
                ()
            in
            let json = Checkpoint.to_json cp in
            let bad =
              match json with
              | `Assoc pairs ->
                `Assoc
                  (List.map
                     (fun (k, v) ->
                        if k = "messages"
                        then (
                          match v with
                          | `List (`Assoc msg_fields :: rest) ->
                            let msg_fields =
                              List.map
                                (fun (mk, mv) ->
                                   if mk = "content"
                                   then mk, `List [ `Assoc [ "type", `String "mystery" ] ]
                                   else mk, mv)
                                msg_fields
                            in
                            k, `List (`Assoc msg_fields :: rest)
                          | other -> k, other)
                        else k, v)
                     pairs)
              | other -> other
            in
            check bool "error" true (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "malformed mcp_sessions returns Error" `Quick (fun () ->
            let cp = make_checkpoint () in
            let json = Checkpoint.to_json cp in
            let bad =
              match json with
              | `Assoc pairs ->
                `Assoc
                  (List.map
                     (fun (k, v) -> if k = "mcp_sessions" then k, `Int 42 else k, v)
                     pairs)
              | other -> other
            in
            check bool "error" true (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "message metadata must be object" `Quick (fun () ->
            let cp =
              make_checkpoint
                ~messages:
                  [ { Types.role = Types.Assistant
                    ; content = [ Types.Text "hello" ]
                    ; name = None
                    ; tool_call_id = None
                    ; metadata = []
                    }
                  ]
                ()
            in
            let json = Checkpoint.to_json cp in
            let bad =
              match json with
              | `Assoc pairs ->
                `Assoc
                  (List.map
                     (fun (k, v) ->
                        if k = "messages"
                        then (
                          match v with
                          | `List (`Assoc msg_fields :: rest) ->
                            ( k
                            , `List
                                (`Assoc (("metadata", `String "bad") :: msg_fields)
                                 :: rest) )
                          | other -> k, other)
                        else k, v)
                     pairs)
              | other -> other
            in
            check bool "error" true (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "current v10 rejects unknown nested message field" `Quick (fun () ->
            let message : Types.message =
              { role = Types.User
              ; content = [ Types.Text "hello" ]
              ; name = None
              ; tool_call_id = None
              ; metadata = []
              }
            in
            let bad =
              make_checkpoint ~messages:[ message ] ()
              |> Checkpoint.to_json
              |> update_json_field
                   "messages"
                   (update_first_json (append_json_field "unexpected" (`Bool true)))
            in
            check
              bool
              "unknown message field"
              true
              (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "current v10 rejects normalized empty metadata" `Quick (fun () ->
            let message : Types.message =
              { role = Types.User
              ; content = [ Types.Text "hello" ]
              ; name = None
              ; tool_call_id = None
              ; metadata = []
              }
            in
            let bad =
              make_checkpoint ~messages:[ message ] ()
              |> Checkpoint.to_json
              |> update_json_field
                   "messages"
                   (update_first_json (append_json_field "metadata" (`Assoc [])))
            in
            check bool "empty metadata" true (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "current v10 preserves blank reasoning content" `Quick (fun () ->
            let message : Types.message =
              { role = Types.Assistant
              ; content =
                  [ Types.ReasoningDetails
                      { reasoning_content = Some "reasoning"
                      ; details =
                          [ { raw = `Assoc [ "text", `String "reasoning" ]
                            ; text = Some "reasoning"
                            }
                          ]
                      }
                  ]
              ; name = None
              ; tool_call_id = None
              ; metadata = []
              }
            in
            let bad =
              make_checkpoint ~messages:[ message ] ()
              |> Checkpoint.to_json
              |> update_json_field
                   "messages"
                   (update_first_json (fun message_json ->
                      update_json_field
                        "content"
                        (update_first_json
                           (replace_json_field "reasoning_content" (`String " ")))
                        message_json))
            in
            let restored = Result.get_ok (Checkpoint.of_json bad) in
            (match (List.hd restored.messages).content with
             | [ Types.ReasoningDetails { reasoning_content = Some " "; _ } ] -> ()
             | _ -> fail "blank reasoning_content was silently normalized");
            let open Yojson.Safe.Util in
            check
              string
              "blank reasoning content"
              " "
              (restored
               |> Checkpoint.to_json
               |> member "messages"
               |> index 0
               |> member "content"
               |> index 0
               |> member "reasoning_content"
               |> to_string))
        ; test_case "current v10 rejects duplicate nested content field" `Quick (fun () ->
            let message : Types.message =
              { role = Types.User
              ; content = [ Types.Text "hello" ]
              ; name = None
              ; tool_call_id = None
              ; metadata = []
              }
            in
            let bad =
              make_checkpoint ~messages:[ message ] ()
              |> Checkpoint.to_json
              |> update_json_field
                   "messages"
                   (update_first_json (fun message_json ->
                      update_json_field
                        "content"
                        (update_first_json
                           (append_json_field "text" (`String "duplicate")))
                        message_json))
            in
            check
              bool
              "duplicate content field"
              true
              (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "current v10 rejects unknown nested tool field" `Quick (fun () ->
            let bad =
              make_checkpoint ~tools:[ sample_tool_schema ] ()
              |> Checkpoint.to_json
              |> update_json_field
                   "tools"
                   (update_first_json (append_json_field "legacy" (`Bool true)))
            in
            check
              bool
              "unknown tool field"
              true
              (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "current v10 rejects noncanonical response format" `Quick (fun () ->
            let bad =
              make_checkpoint ()
              |> Checkpoint.to_json
              |> replace_json_field "response_format" (`Bool true)
            in
            check
              bool
              "legacy response format"
              true
              (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "current v10 rejects malformed nested MCP headers" `Quick (fun () ->
            let session : Mcp_session.info =
              { server_name = "http-tools"
              ; command = "http"
              ; args = []
              ; env = []
              ; http_base_url = Some "https://mcp.example.test"
              ; http_headers = [ "Authorization", "redacted" ]
              ; tool_schemas = []
              ; transport_kind = Http
              }
            in
            let bad =
              make_checkpoint ~mcp_sessions:[ session ] ()
              |> Checkpoint.to_json
              |> update_json_field
                   "mcp_sessions"
                   (update_first_json (replace_json_field "http_headers" (`Assoc [])))
            in
            check bool "malformed headers" true (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "current v10 rejects duplicate context keys" `Quick (fun () ->
            let bad =
              make_checkpoint ()
              |> Checkpoint.to_json
              |> replace_json_field
                   "context"
                   (`Assoc [ "channel", `String "one"; "channel", `String "two" ])
            in
            check bool "duplicate context" true (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "current v10 rejects normalized reasoning effort" `Quick (fun () ->
            let bad =
              make_checkpoint ()
              |> Checkpoint.to_json
              |> replace_json_field "reasoning_effort" (`String " HIGH ")
            in
            check
              bool
              "noncanonical reasoning effort"
              true
              (Result.is_error (Checkpoint.of_json bad)))
        ; test_case "working_context value decodes on exact schema" `Quick (fun () ->
            let cp = make_checkpoint () in
            let working_context =
              `Assoc [ "kind", `String "ctx"; "generation", `Int 1 ]
            in
            let json =
              match Checkpoint.to_json cp with
              | `Assoc pairs ->
                `Assoc
                  (List.map
                     (fun (k, v) ->
                        match k with
                        | "working_context" -> k, working_context
                        | _ -> k, v)
                     pairs)
              | other -> other
            in
            let decoded = Result.get_ok (Checkpoint.of_json json) in
            check
              (option (testable Yojson.Safe.pp Yojson.Safe.equal))
              "working context"
              (Some working_context)
              decoded.working_context)
        ] )
    ; ( "mcp_sessions"
      , [ test_case "empty mcp_sessions roundtrip" `Quick (fun () ->
            let cp = make_checkpoint ~mcp_sessions:[] () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check int "no sessions" 0 (List.length cp2.mcp_sessions))
        ; test_case "mcp_sessions with tools roundtrip" `Quick (fun () ->
            let info : Mcp_session.info =
              { server_name = "test-server"
              ; command = "/usr/bin/mcp-server"
              ; args = [ "--port"; "8080" ]
              ; env = [ "API_KEY", "secret123" ]
              ; http_base_url = None
              ; http_headers = []
              ; tool_schemas = [ sample_tool_schema ]
              ; transport_kind = Stdio
              }
            in
            let cp = make_checkpoint ~mcp_sessions:[ info ] () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check int "1 session" 1 (List.length cp2.mcp_sessions);
            let s = List.hd cp2.mcp_sessions in
            check string "server_name" "test-server" s.server_name;
            check string "command" "/usr/bin/mcp-server" s.command;
            check int "args count" 2 (List.length s.args);
            check int "env count" 1 (List.length s.env);
            check int "tools count" 1 (List.length s.tool_schemas);
            let t = List.hd s.tool_schemas in
            check string "tool name" "get_weather" t.name)
        ; test_case "multiple mcp_sessions roundtrip" `Quick (fun () ->
            let info1 : Mcp_session.info =
              { server_name = "server-a"
              ; command = "mcp-a"
              ; args = []
              ; env = []
              ; http_base_url = None
              ; http_headers = []
              ; tool_schemas = []
              ; transport_kind = Stdio
              }
            in
            let info2 : Mcp_session.info =
              { server_name = "server-b"
              ; command = "mcp-b"
              ; args = [ "--verbose" ]
              ; env = [ "X", "1" ]
              ; http_base_url = None
              ; http_headers = []
              ; tool_schemas = [ sample_tool_schema ]
              ; transport_kind = Stdio
              }
            in
            let cp = make_checkpoint ~mcp_sessions:[ info1; info2 ] () in
            let cp2 = Result.get_ok (Checkpoint.of_json (Checkpoint.to_json cp)) in
            check int "2 sessions" 2 (List.length cp2.mcp_sessions);
            let s1 = List.hd cp2.mcp_sessions in
            let s2 = List.nth cp2.mcp_sessions 1 in
            check string "first" "server-a" s1.server_name;
            check string "second" "server-b" s2.server_name)
        ; test_case "Agent.checkpoint has empty mcp_sessions" `Quick (fun () ->
            Eio_main.run
            @@ fun env ->
            let net = Eio.Stdenv.net env in
            let agent =
              Agent.create
                ~net
                ~config:
                  { (Types.default_config ~model:"test-model") with name = "mcp-test" }
                ()
            in
            let cp = Agent.checkpoint agent in
            check int "no mcp sessions" 0 (List.length cp.mcp_sessions))
        ; test_case "Agent.checkpoint passes working_context" `Quick (fun () ->
            Eio_main.run
            @@ fun env ->
            let net = Eio.Stdenv.net env in
            let agent =
              Agent.create
                ~net
                ~config:
                  { (Types.default_config ~model:"test-model") with name = "wc-test" }
                ()
            in
            let wc =
              `Assoc [ "kind", `String "test_context_v1"; "max_tokens", `Int 4096 ]
            in
            let cp = Agent.checkpoint ~working_context:wc agent in
            check
              (option (testable Yojson.Safe.pp Yojson.Safe.equal))
              "working_context roundtrip"
              (Some wc)
              cp.working_context)
        ; test_case "Agent.checkpoint omits working_context by default" `Quick (fun () ->
            Eio_main.run
            @@ fun env ->
            let net = Eio.Stdenv.net env in
            let agent =
              Agent.create
                ~net
                ~config:
                  { (Types.default_config ~model:"test-model") with name = "wc-none" }
                ()
            in
            let cp = Agent.checkpoint agent in
            check
              (option (testable Yojson.Safe.pp Yojson.Safe.equal))
              "working_context absent"
              None
              cp.working_context)
        ] )
    ]
;;
