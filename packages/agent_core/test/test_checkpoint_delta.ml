open Agent_sdk
open Types

let small_string_gen =
  let open QCheck.Gen in
  map
    (fun chars -> chars |> List.to_seq |> String.of_seq)
    (list_size (int_range 0 12) printable)
;;

let yojson_simple_gen =
  let open QCheck.Gen in
  oneof
    [ map (fun s -> `String s) small_string_gen
    ; map (fun n -> `Int n) (int_range 0 50)
    ; map (fun b -> `Bool b) bool
    ]
;;

let response_format_gen =
  let open QCheck.Gen in
  oneof
    [ return Off
    ; return JsonMode
    ; map (fun value -> JsonSchema (`Assoc [ "schema", value ])) yojson_simple_gen
    ]
;;

let message_gen =
  let open QCheck.Gen in
  map2
    (fun role text ->
       { role; content = [ Text text ]; name = None; tool_call_id = None; metadata = [] })
    (oneof [ return User; return Assistant ])
    small_string_gen
;;

let usage_stats_gen =
  let open QCheck.Gen in
  let* input_tokens = int_range 0 500 in
  let* output_tokens = int_range 0 500 in
  let* cache_creation = int_range 0 50 in
  let* cache_read = int_range 0 50 in
  let* api_calls = int_range 0 10 in
  let* estimated_cost_cents = int_range 0 100 in
  return
    { total_input_tokens = input_tokens
    ; total_output_tokens = output_tokens
    ; total_cache_creation_input_tokens = cache_creation
    ; total_cache_read_input_tokens = cache_read
    ; api_calls
    ; estimated_cost_usd = float_of_int estimated_cost_cents /. 100.0
    ; pricing_gap = None
    }
;;

let tool_param_gen =
  let open QCheck.Gen in
  map4
    (fun name description param_type required ->
       { name; description; param_type; required })
    small_string_gen
    small_string_gen
    (oneof
       [ return String
       ; return Integer
       ; return Number
       ; return Boolean
       ; return Array
       ; return Object
       ])
    bool
;;

let tool_schema_gen =
  let open QCheck.Gen in
  map3
    (fun name description parameters ->
       Types.tool_schema_of_params ~name ~description ~parameters ())
    small_string_gen
    small_string_gen
    (list_size (int_range 0 2) tool_param_gen)
;;

let context_gen =
  let open QCheck.Gen in
  map
    (fun pairs ->
       let ctx = Context.create_sync () in
       List.iter (fun (key, value) -> Context.set ctx key value) pairs;
       ctx)
    (list_size (int_range 0 3) (pair small_string_gen yojson_simple_gen))
;;

let tool_choice_gen =
  let open QCheck.Gen in
  oneof
    [ return None
    ; return (Some Auto)
    ; return (Some Any)
    ; map (fun s -> Some (Tool s)) small_string_gen
    ; return (Some None_)
    ]
;;

let mcp_info_gen =
  let open QCheck.Gen in
  map4
    (fun server_name command args tool_schemas ->
       { Mcp_session.server_name
       ; command
       ; args
       ; env = []
       ; http_base_url = None
       ; http_headers = []
       ; tool_schemas
       ; transport_kind = Mcp_session.Stdio
       })
    small_string_gen
    small_string_gen
    (list_size (int_range 0 2) small_string_gen)
    (list_size (int_range 0 1) tool_schema_gen)
;;

let checkpoint_gen =
  let open QCheck.Gen in
  let* session_id = small_string_gen in
  let* agent_name = small_string_gen in
  let* model =
    oneof [ return "claude-sonnet-4-6"; return "claude-opus-4-6"; small_string_gen ]
  in
  let* system_prompt = option small_string_gen in
  let* messages = list_size (int_range 0 5) message_gen in
  let* usage = usage_stats_gen in
  let* turn_count = int_range 0 10 in
  let* created_at = int_range 0 10_000 in
  let* tools = list_size (int_range 0 2) tool_schema_gen in
  let* tool_choice = tool_choice_gen in
  let* disable_parallel_tool_use = bool in
  let* temperature = option (map float_of_int (int_range 0 2)) in
  let* top_p = option (map (fun n -> float_of_int n /. 10.0) (int_range 0 10)) in
  let* top_k = option (int_range 1 40) in
  let* min_p = option (map (fun n -> float_of_int n /. 20.0) (int_range 0 20)) in
  let* enable_thinking = option bool in
  let* preserve_thinking = option bool in
  let* response_format = response_format_gen in
  let* thinking_budget = option (int_range 0 2048) in
  let* reasoning_effort = option (oneof_list Llm_provider.Reasoning_effort.all) in
  let* cache_system_prompt = bool in
  let* context = context_gen in
  let* mcp_sessions = list_size (int_range 0 1) mcp_info_gen in
  let* working_context = option yojson_simple_gen in
  return
    { Checkpoint.version = Checkpoint.checkpoint_version
    ; session_id
    ; agent_name
    ; model
    ; system_prompt
    ; messages
    ; usage
    ; turn_count
    ; created_at = float_of_int created_at
    ; tools
    ; tool_choice
    ; disable_parallel_tool_use
    ; temperature
    ; top_p
    ; top_k
    ; min_p
    ; enable_thinking
    ; preserve_thinking
    ; response_format
    ; thinking_budget
    ; reasoning_effort
    ; cache_system_prompt
    ; context
    ; mcp_sessions
    ; working_context
    }
;;

let arb_checkpoint =
  QCheck.make checkpoint_gen ~print:(fun checkpoint ->
    Yojson.Safe.to_string (Checkpoint.to_json checkpoint))
;;

let checkpoint_equal left right = Checkpoint.to_json left = Checkpoint.to_json right

let make_unit_checkpoint
      ?(messages = [])
      ?(session_id = "sess-a")
      ?(agent_name = "agent-a")
      ?(turn_count = 0)
      ?(context = Context.create_sync ())
      ?(tool_choice = None)
      ?(working_context = None)
      ()
  =
  { Checkpoint.version = Checkpoint.checkpoint_version
  ; session_id
  ; agent_name
  ; model = "claude-sonnet-4-6"
  ; system_prompt = Some "Be careful."
  ; messages
  ; usage = Types.empty_usage
  ; turn_count
  ; created_at = 1000.0
  ; tools = []
  ; tool_choice
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Off
  ; thinking_budget = None
  ; reasoning_effort = None
  ; cache_system_prompt = false
  ; context
  ; mcp_sessions = []
  ; working_context
  }
;;

let sample_tool_schema =
  Types.tool_schema_of_params
    ~name:"lookup"
    ~description:"Lookup a value"
    ~parameters:
      [ { Types.name = "key"; description = "Key"; param_type = String; required = true }
      ]
    ()
;;

let sample_mcp_session =
  { Mcp_session.server_name = "memory"
  ; command = "memory-server"
  ; args = [ "--stdio" ]
  ; env = [ "MODE", "test" ]
  ; http_base_url = None
  ; http_headers = []
  ; tool_schemas = [ sample_tool_schema ]
  ; transport_kind = Mcp_session.Stdio
  }
;;

let test_delta_roundtrip_property =
  QCheck.Test.make
    ~count:100
    ~name:"checkpoint delta round-trip"
    QCheck.(pair arb_checkpoint arb_checkpoint)
    (fun (base, target) ->
       match Checkpoint.apply_delta base (Checkpoint.compute_delta base target) with
       | Ok rebuilt -> checkpoint_equal rebuilt target
       | Error _ -> false)
;;

let test_delta_json_roundtrip () =
  let base =
    make_unit_checkpoint
      ~messages:
        [ { role = User
          ; content = [ Text "hello" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ]
      ()
  in
  let ctx = Context.create_sync () in
  Context.set ctx "trace_id" (`String "abc");
  let target =
    make_unit_checkpoint
      ~session_id:"sess-b"
      ~agent_name:"agent-b"
      ~turn_count:2
      ~context:ctx
      ~tool_choice:(Some Auto)
      ~working_context:(Some (`Assoc [ "kind", `String "test_context_v1" ]))
      ~messages:
        [ { role = User
          ; content = [ Text "hello" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ; { role = Assistant
          ; content = [ Text "world" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ]
      ()
  in
  let delta = Checkpoint.compute_delta base target in
  let decoded =
    delta |> Checkpoint.delta_to_json |> Checkpoint.delta_of_json |> Result.get_ok
  in
  Alcotest.(check bool)
    "delta apply works after JSON roundtrip"
    true
    (match Checkpoint.apply_delta base decoded with
     | Ok rebuilt -> checkpoint_equal rebuilt target
     | Error _ -> false)
;;

let test_delta_json_all_replacement_ops () =
  let base = make_unit_checkpoint ~tool_choice:(Some Auto) () in
  let target =
    { base with
      system_prompt = None
    ; usage =
        { total_input_tokens = 11
        ; total_output_tokens = 7
        ; total_cache_creation_input_tokens = 3
        ; total_cache_read_input_tokens = 2
        ; api_calls = 4
        ; estimated_cost_usd = 0.42
        ; pricing_gap = Some (Types.Pricing_unavailable "custom-unpriced")
        }
    ; turn_count = 9
    ; tools = [ sample_tool_schema ]
    ; tool_choice = Some (Tool "lookup")
    ; temperature = Some 0.2
    ; top_p = Some 0.9
    ; top_k = Some 40
    ; min_p = Some 0.05
    ; enable_thinking = Some true
    ; thinking_budget = Some 128
    ; reasoning_effort = Some Llm_provider.Reasoning_effort.Max
    ; disable_parallel_tool_use = true
    ; response_format = JsonSchema (`Assoc [ "type", `String "object" ])
    ; cache_system_prompt = true
    ; mcp_sessions = [ sample_mcp_session ]
    ; working_context = Some (`Assoc [ "kind", `String "full_replace" ])
    }
  in
  let delta = Checkpoint.compute_delta base target in
  let delta_json = Checkpoint.delta_to_json delta in
  let kinds =
    match delta_json with
    | `Assoc fields ->
      (match List.assoc_opt "operations" fields with
       | Some (`List operations) ->
         List.filter_map
           (function
             | `Assoc op_fields ->
               (match List.assoc_opt "kind" op_fields with
                | Some (`String kind) -> Some kind
                | _ -> None)
             | _ -> None)
           operations
       | _ -> Alcotest.fail "operations missing")
    | _ -> Alcotest.fail "delta json should be an object"
  in
  List.iter
    (fun kind -> Alcotest.(check bool) kind true (List.mem kind kinds))
    [ "replace_system_prompt"
    ; "replace_usage"
    ; "replace_turn_count"
    ; "replace_tools"
    ; "replace_tool_choice"
    ; "replace_sampling"
    ; "replace_limits"
    ; "replace_mcp_sessions"
    ; "replace_working_context"
    ];
  let decoded = delta_json |> Checkpoint.delta_of_json |> Result.get_ok in
  match Checkpoint.apply_delta base decoded with
  | Ok rebuilt ->
    Alcotest.(check bool)
      "decoded replacement delta applies"
      true
      (checkpoint_equal rebuilt target)
  | Error err ->
    Alcotest.failf "expected delta to apply: %s" (Agent_sdk.Error.to_string err)
;;

let test_delta_json_null_and_rejected_legacy_limit_paths () =
  let base = make_unit_checkpoint ~tool_choice:(Some Any) () in
  let target = { base with tool_choice = None; working_context = None } in
  let delta = Checkpoint.compute_delta base target in
  let decoded =
    delta |> Checkpoint.delta_to_json |> Checkpoint.delta_of_json |> Result.get_ok
  in
  (match Checkpoint.apply_delta base decoded with
   | Ok rebuilt ->
     Alcotest.(check bool) "tool choice none" true (Option.is_none rebuilt.tool_choice)
   | Error err ->
     Alcotest.failf "expected null delta to apply: %s" (Agent_sdk.Error.to_string err));
  let with_operations operations =
    match Checkpoint.delta_to_json (Checkpoint.compute_delta base base) with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
              if key = "operations" then key, `List operations else key, value)
           fields)
    | _ -> Alcotest.fail "delta json should be an object"
  in
  let legacy_limits_json =
    with_operations
      [ `Assoc
          [ "kind", `String "replace_limits"
          ; "disable_parallel_tool_use", `Bool false
          ; "response_format", `Null
          ; "response_format_json", `Bool true
          ; "cache_system_prompt", `Bool false
          ]
      ]
  in
  Alcotest.(check bool)
    "legacy response_format_json rejected"
    true
    (Result.is_error (Checkpoint.delta_of_json legacy_limits_json));
  let unknown_op_json = with_operations [ `Assoc [ "kind", `String "bogus" ] ] in
  Alcotest.(check bool)
    "unknown op rejected"
    true
    (Result.is_error (Checkpoint.delta_of_json unknown_op_json))
;;

let test_delta_json_rejects_malformed_context_removed () =
  let base_context = Context.create_sync () in
  let target_context = Context.create_sync () in
  Context.set target_context "trace_id" (`String "abc");
  let base = make_unit_checkpoint ~context:base_context () in
  let target =
    make_unit_checkpoint
      ~context:target_context
      ~messages:
        [ { role = User
          ; content = [ Text "hello" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ]
      ()
  in
  let malformed_json =
    Checkpoint.compute_delta base target
    |> Checkpoint.delta_to_json
    |> function
    | `Assoc fields ->
      let operations =
        match List.assoc_opt "operations" fields with
        | Some (`List ops) ->
          `List
            (List.map
               (function
                 | `Assoc op_fields as op_json ->
                   let is_patch_context =
                     List.assoc_opt "kind" op_fields = Some (`String "patch_context")
                   in
                   if not is_patch_context
                   then op_json
                   else
                     `Assoc
                       (List.map
                          (fun (key, value) ->
                             if key = "diff"
                             then (
                               match value with
                               | `Assoc diff_fields ->
                                 let patched_diff =
                                   List.map
                                     (fun (diff_key, diff_value) ->
                                        if diff_key = "removed"
                                        then diff_key, `String "bad"
                                        else diff_key, diff_value)
                                     diff_fields
                                 in
                                 key, `Assoc patched_diff
                               | _ -> key, value)
                             else key, value)
                          op_fields)
                 | op_json -> op_json)
               ops)
        | _ -> List.assoc "operations" fields
      in
      `Assoc
        (List.map
           (fun (key, value) ->
              if key = "operations" then key, operations else key, value)
           fields)
    | json -> json
  in
  Alcotest.(check bool)
    "malformed removed field rejected"
    true
    (Result.is_error (Checkpoint.delta_of_json malformed_json))
;;

let test_empty_delta_roundtrip () =
  let checkpoint =
    make_unit_checkpoint
      ~session_id:"sess-a"
      ~agent_name:"agent-a"
      ~turn_count:3
      ~messages:
        [ { role = User
          ; content = [ Text "steady" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ]
      ()
  in
  let delta = Checkpoint.compute_delta checkpoint checkpoint in
  Alcotest.(check int) "no operations" 0 (List.length delta.operations);
  Alcotest.(check bool)
    "noop delta applies cleanly"
    true
    (match Checkpoint.apply_delta checkpoint delta with
     | Ok rebuilt -> checkpoint_equal rebuilt checkpoint
     | Error _ -> false)
;;

let test_delta_roundtrip_preserves_message_metadata () =
  let replay_metadata =
    [ ( "replay.namespace"
      , `Assoc
          [ "kind", `String "state_snapshot"
          ; "version", `Int 1
          ; "payload", `Assoc [ "goal", `String "persist" ]
          ] )
    ]
  in
  let base =
    make_unit_checkpoint
      ~messages:
        [ { role = User
          ; content = [ Text "start" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ]
      ()
  in
  let target =
    make_unit_checkpoint
      ~messages:
        [ { role = User
          ; content = [ Text "start" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ; { role = Assistant
          ; content = [ Text "done" ]
          ; name = Some "agent_role_a"
          ; tool_call_id = Some "call_1"
          ; metadata = replay_metadata
          }
        ]
      ()
  in
  let delta = Checkpoint.compute_delta base target in
  match Checkpoint.apply_delta base delta with
  | Error err ->
    Alcotest.failf "expected delta to apply, got %s" (Agent_sdk.Error.to_string err)
  | Ok rebuilt ->
    (match rebuilt.messages with
     | _ :: [ assistant ] ->
       Alcotest.(check (option string)) "name" (Some "agent_role_a") assistant.name;
       Alcotest.(check (option string))
         "tool_call_id"
         (Some "call_1")
         assistant.tool_call_id;
       Alcotest.(check string)
         "metadata preserved"
         (Yojson.Safe.to_string (`Assoc replay_metadata))
         (Yojson.Safe.to_string (`Assoc assistant.metadata))
     | _ -> Alcotest.fail "expected assistant message with metadata")
;;

let test_apply_delta_rejects_version_and_hash_mismatch () =
  let base = make_unit_checkpoint () in
  let target = make_unit_checkpoint ~session_id:"sess-b" () in
  let delta = Checkpoint.compute_delta base target in
  let bad_version = { delta with delta_version = delta.delta_version + 1 } in
  let bad_checkpoint_version =
    { delta with base_checkpoint_version = delta.base_checkpoint_version + 1 }
  in
  let bad_base_hash = { delta with base_checkpoint_hash = "bad-hash" } in
  let bad_result_hash = { delta with result_checkpoint_hash = "bad-result-hash" } in
  Alcotest.(check bool)
    "delta version mismatch"
    true
    (Result.is_error (Checkpoint.apply_delta base bad_version));
  Alcotest.(check bool)
    "checkpoint version mismatch"
    true
    (Result.is_error (Checkpoint.apply_delta base bad_checkpoint_version));
  Alcotest.(check bool)
    "base hash mismatch"
    true
    (Result.is_error (Checkpoint.apply_delta base bad_base_hash));
  Alcotest.(check bool)
    "result hash mismatch"
    true
    (Result.is_error (Checkpoint.apply_delta base bad_result_hash))
;;

let test_apply_delta_rejects_invalid_splice () =
  let base =
    make_unit_checkpoint
      ~messages:
        [ { role = User
          ; content = [ Text "a" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ]
      ()
  in
  let target =
    make_unit_checkpoint
      ~messages:
        [ { role = User
          ; content = [ Text "a" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ; { role = Assistant
          ; content = [ Text "b" ]
          ; name = None
          ; tool_call_id = None
          ; metadata = []
          }
        ]
      ()
  in
  let delta = Checkpoint.compute_delta base target in
  let invalid_delta =
    { delta with
      operations =
        [ Checkpoint.Splice_messages { start_index = 3; delete_count = 1; insert = [] } ]
    }
  in
  Alcotest.(check bool)
    "invalid splice rejected"
    true
    (Result.is_error (Checkpoint.apply_delta base invalid_delta))
;;

let test_apply_delta_rejects_noncanonical_message () =
  let base = make_unit_checkpoint () in
  let invalid_message =
    { role = User
    ; content =
        [ ToolResult
            { tool_use_id = "call-1"
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
  in
  let valid_delta = Checkpoint.compute_delta base base in
  let invalid_delta =
    { valid_delta with
      operations =
        [ Checkpoint.Splice_messages
            { start_index = 0; delete_count = 0; insert = [ invalid_message ] }
        ]
    }
  in
  Alcotest.(check bool)
    "non-canonical inserted message rejected before hash comparison"
    true
    (Result.is_error (Checkpoint.apply_delta base invalid_delta))
;;

let () =
  Alcotest.run
    "Checkpoint_delta"
    [ "properties", List.map QCheck_alcotest.to_alcotest [ test_delta_roundtrip_property ]
    ; ( "unit"
      , [ Alcotest.test_case "delta JSON roundtrip" `Quick test_delta_json_roundtrip
        ; Alcotest.test_case
            "delta JSON rejects malformed context removed"
            `Quick
            test_delta_json_rejects_malformed_context_removed
        ; Alcotest.test_case
            "delta JSON all replacement ops"
            `Quick
            test_delta_json_all_replacement_ops
        ; Alcotest.test_case
            "delta JSON null and rejected legacy limit paths"
            `Quick
            test_delta_json_null_and_rejected_legacy_limit_paths
        ; Alcotest.test_case "empty delta roundtrip" `Quick test_empty_delta_roundtrip
        ; Alcotest.test_case
            "metadata delta roundtrip"
            `Quick
            test_delta_roundtrip_preserves_message_metadata
        ; Alcotest.test_case
            "apply_delta rejects version/hash mismatch"
            `Quick
            test_apply_delta_rejects_version_and_hash_mismatch
        ; Alcotest.test_case
            "apply_delta rejects invalid splice"
            `Quick
            test_apply_delta_rejects_invalid_splice
        ; Alcotest.test_case
            "apply_delta rejects non-canonical message"
            `Quick
            test_apply_delta_rejects_noncanonical_message
        ] )
    ]
;;
