module Types = Masc_domain

open Alcotest

module U = Yojson.Safe.Util

let first_issue quality =
  quality |> U.member "issues" |> U.to_list |> List.hd

let temp_dir () =
  let dir = Filename.temp_file "test_mcp_server_eio_call_tool_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Unix.unlink path
  in
  try rm dir with _ -> ()

let make_keeper_meta ?agent_name ?current_task_id ?(goal_ids = [])
    ?tool_access name =
  let agent_name =
    Option.value agent_name
      ~default:(Masc.Keeper_identity.keeper_agent_name name)
  in
  let fields =
    [
      ("name", `String name);
      ("agent_name", `String agent_name);
      ("trace_id", `String ("trace-test-" ^ name));
    ]
    @
    (match current_task_id with
     | Some task_id -> [ ("current_task_id", `String task_id) ]
     | None -> [])
    @
    (match goal_ids with
     | [] -> []
     | ids ->
         [
           ( "active_goal_ids",
             `List (List.map (fun goal_id -> `String goal_id) goal_ids) );
         ])
    @
    (match tool_access with
     | Some tool_access ->
         [
           ( "tool_access",
             Json_util.json_string_list tool_access );
         ]
     | None -> [])
  in
  match Masc_test_deps.meta_of_json_fixture (`Assoc fields) with
  | Ok meta -> meta
  | Error err -> fail ("make_keeper_meta failed: " ^ err)

let empty_contract : Masc_domain.task_contract =
  {
    strict = false;
    completion_contract = [];
    required_evidence = [];
    inspect_gate_evidence = [];
    verify_gate_evidence = [];
    evidence_claims = [];
    stale_claim_timeout_sec = 0;
    links =
      {
        operation_id = None;
        session_id = None;
      };
  }

let extract_json_from_text text =
  try
    let idx = String.index text '{' in
    Yojson.Safe.from_string (String.sub text idx (String.length text - idx))
  with Not_found ->
    failf "expected JSON payload in text: %s" text

let rec check_json_strings_valid_utf8 label = function
  | `String value ->
      check bool (label ^ " string is valid UTF-8") true
        (String.is_valid_utf_8 value)
  | `Assoc fields ->
      List.iter
        (fun (key, value) -> check_json_strings_valid_utf8 (label ^ "." ^ key) value)
        fields
  | `List values ->
      List.iteri
        (fun idx value ->
           check_json_strings_valid_utf8
             (Printf.sprintf "%s[%d]" label idx)
             value)
        values
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ -> ()

let test_timeout_quality_is_error () =
  let quality =
    Masc.Mcp_server_eio_call_tool.quality_from_result
      ~success:false
      ~message:"Tool timed out after 30s"
      ~attempts:1
  in
  let issue = first_issue quality in
  check string "timeout code" "tool_timeout" (issue |> U.member "code" |> U.to_string);
  check string "timeout severity" "error" (issue |> U.member "severity" |> U.to_string)

let test_generic_failure_quality_is_error () =
  let quality =
    Masc.Mcp_server_eio_call_tool.quality_from_result
      ~success:false
      ~message:"subprocess exited 1"
      ~attempts:2
  in
  let issue = first_issue quality in
  check string "failure code" "tool_failure" (issue |> U.member "code" |> U.to_string);
  check string "failure severity" "error" (issue |> U.member "severity" |> U.to_string)

let test_success_quality_has_no_issues () =
  let quality =
    Masc.Mcp_server_eio_call_tool.quality_from_result
      ~success:true
      ~message:"ok"
      ~attempts:1
  in
  check bool "passed" true (quality |> U.member "passed" |> U.to_bool);
  check int "issue count" 0 (quality |> U.member "issues" |> U.to_list |> List.length)

let test_activity_payload_sanitizes_invalid_utf8 () =
  let payload =
    Masc.Mcp_server_eio_call_tool.For_testing.activity_tool_called_payload
      ~tool_name:"tool_execute"
      ~success:false
      ~duration_ms:42
      ~source:"keeper_internal"
      ~error_detail:"bad\xfferror"
      ~tool_args_preview:"preview\xfe"
      (`Assoc
        [
          ("cmd", `String "printf '\xff'");
          ("message", `String "message\xfd");
          ("title", `String "title\xfc");
          ("pr_number", `Int 15310);
        ])
  in
  check_json_strings_valid_utf8 "activity_payload" payload;
  check string "tool name preserved" "tool_execute"
    (payload |> U.member "tool_name" |> U.to_string);
  check int "numeric field preserved" 15310
    (payload |> U.member "pr_number" |> U.to_int)

let test_records_mcp_server_operation_duration_metric () =
  let context =
    { Otel_dispatch_hook.jsonrpc_request_id = Some "metric-request-otel"
    ; mcp_session_id = Some "metric-session-otel"
    ; mcp_protocol_version = Some "2025-06-18"
    ; transport =
        Some
          (Otel_dispatch_hook.http_transport_context ~protocol_version:"2")
    }
  in
  let result : Tool_result.result =
    Ok
      { Tool_result.data = `String "ok"
      ; tool_name = "get-weather"
      ; duration_ms = 123.0
      }
  in
  let labels =
    [ Otel_genai.Mcp_attr_key.mcp_method_name
    , Otel_genai.Mcp_value.tools_call_method
    ; Otel_genai.Attr_key.gen_ai_operation_name, "execute_tool"
    ; Otel_genai.Attr_key.gen_ai_tool_name, "get-weather"
    ; Otel_genai.Mcp_attr_key.mcp_protocol_version, "2025-06-18"
    ; Otel_genai.Mcp_attr_key.network_protocol_name, "http"
    ; Otel_genai.Mcp_attr_key.network_protocol_version, "2"
    ; Otel_genai.Mcp_attr_key.network_transport, "tcp"
    ]
  in
  let metric_name = Otel_genai.Mcp_metric_name.server_operation_duration in
  let before_value =
    Masc.Otel_metric_store.metric_value_or_zero metric_name ~labels ()
  in
  let before_count =
    Masc.Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ()
  in
  Eio_main.run (fun _env ->
    Otel_dispatch_hook.with_request_context context (fun () ->
      Masc.Mcp_server_eio_call_tool.For_testing.record_mcp_server_operation_duration
        result
        ~duration_ms:250));
  check (float 0.0001) "duration seconds delta" 0.250
    (Masc.Otel_metric_store.metric_value_or_zero metric_name ~labels ()
     -. before_value);
  check (float 0.0001) "duration count delta" 1.0
    (Masc.Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ()
     -. before_count)

let test_contains_casefold_keeps_semantics () =
  let contains = Masc.Mcp_server_eio_call_tool.contains_casefold in
  check bool "empty needle" true (contains "anything" "");
  check bool "exact match" true (contains "auth required" "auth required");
  check bool "ascii casefold" true
    (contains "Auth REQUIRED by server" "auth required");
  check bool "middle substring" true
    (contains "prefix temporary network suffix" "TEMPORARY NETWORK");
  check bool "numeric literal" true
    (contains "HTTP 503 Service Unavailable" "503");
  check bool "needle longer than haystack" false (contains "short" "shorter");
  check bool "absent substring" false (contains "Invalid JSON" "timeout")

(* Per-caller wrapper timeout was removed on 2026-06-08 (PR cleanup,
   spirit: "tool 자체가 알아서 타임아웃으로 튕기든 해야지 그걸 왜 되나 안
   되나 우리가 관찰하고 있나?").  The previous test_block asserted caller
   timeout policy (default/board-write/min-max clamps) — that domain is
   gone, so the tests are deleted rather than rewritten to assert "no
   timeout".  The tool itself owns hang protection. *)

let test_runtime_mcp_keeper_log_context_uses_keeper_trace_and_current_turn () =
  let base_path = temp_dir () in
  let keeper_name = "sangsu-context" in
  let meta =
    make_keeper_meta
      ~current_task_id:"task-123"
      ~goal_ids:[ "goal-1"; "goal-2" ]
      keeper_name
  in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.unregister ~base_path keeper_name;
      cleanup_dir base_path)
    (fun () ->
      ignore
        (Masc.Keeper_registry.register_offline ~base_path keeper_name meta);
      Masc.Keeper_registry.mark_turn_started ~base_path
        ~wake:Masc.Keeper_registry.Proactive_tick keeper_name;
      let entry =
        match Masc.Keeper_registry.get ~base_path keeper_name with
        | Some entry -> entry
        | None -> fail "expected registered keeper entry"
      in
      let ctx =
        Masc.Mcp_server_eio_call_tool.runtime_mcp_keeper_log_context_of_entry
          ~mcp_session_id:"mcp-session-1"
          entry
          ~arguments:(`Assoc [ ("session_id", `String "session-explicit") ])
      in
      check (option string) "trace_id"
        (Some ("trace-test-" ^ keeper_name))
        ctx.trace_id;
      check (option string) "agent_name"
        (Some (Masc.Keeper_identity.keeper_agent_name keeper_name))
        ctx.agent_name;
      check (option string) "session_id"
        (Some "session-explicit")
        ctx.session_id;
      check bool "generation present" true (Option.is_some ctx.generation);
      check (option int) "turn" (Some 1) ctx.turn;
      check (option int) "keeper_turn_id" (Some 1) ctx.keeper_turn_id;
      check (option string) "task_id" (Some "task-123") ctx.task_id;
      check (option (list string)) "goal_ids"
        (Some [ "goal-1"; "goal-2" ])
        ctx.goal_ids;
      check bool "model populated" true (String.trim ctx.model <> "");
      check bool "sandbox profile present" true (Option.is_some ctx.sandbox_profile);
      check bool "sandbox root present" true (Option.is_some ctx.sandbox_root);
      check bool "allowed paths present" true (Option.is_some ctx.allowed_paths);
      check bool "network mode present" true (Option.is_some ctx.network_mode))

let test_runtime_mcp_keeper_log_context_loads_current_task_contract () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let keeper_name = "sangsu-task-contract" in
  let config = Masc.Workspace.default_config base_path in
  ignore (Masc.Workspace.init config ~agent_name:(Some keeper_name));
  let contract = empty_contract in
  ignore
    (Masc.Workspace.add_task
       ~contract
       config
       ~title:"Needs execution tools"
       ~priority:1
       ~description:"exercise runtime MCP tool logging");
  let meta =
    make_keeper_meta
      ~current_task_id:"task-001"
      ~tool_access:([ "tool_execute" ])
      keeper_name
  in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.unregister ~base_path keeper_name;
      cleanup_dir base_path)
    (fun () ->
      ignore
        (Masc.Keeper_registry.register_offline ~base_path keeper_name meta);
      let entry =
        match Masc.Keeper_registry.get ~base_path keeper_name with
        | Some entry -> entry
        | None -> fail "expected registered keeper entry"
      in
      let ctx =
        Masc.Mcp_server_eio_call_tool.runtime_mcp_keeper_log_context_of_entry
          entry
          ~arguments:(`Assoc [])
      in
      check bool "runtime mcp keeps task contract out of log context" true
        (Option.is_some ctx.task_id))

let test_record_runtime_mcp_keeper_tool_trace_logs_and_broadcasts () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let keeper_name = "sangsu-runtime-mcp" in
  let meta =
    make_keeper_meta
      ~current_task_id:"task-456"
      ~goal_ids:[ "goal-runtime" ]
      keeper_name
  in
  let subscriber_id = "test-runtime-mcp-tool-trace" in
  let received_sse = ref None in
  Masc.Keeper_tool_call_log.reset_for_testing ();
  Masc.Keeper_tool_call_log.init ~base_path ();
  Fun.protect
    ~finally:(fun () ->
      Masc.Sse.unsubscribe_external subscriber_id;
      Masc.Keeper_registry.unregister ~base_path keeper_name;
      Masc.Keeper_tool_call_log.reset_for_testing ();
      cleanup_dir base_path)
    (fun () ->
      ignore
        (Masc.Keeper_registry.register_offline ~base_path keeper_name meta);
      Masc.Keeper_registry.mark_turn_started ~base_path
        ~wake:Masc.Keeper_registry.Proactive_tick keeper_name;
      let entry =
        match Masc.Keeper_registry.get ~base_path keeper_name with
        | Some entry -> entry
        | None -> fail "expected registered keeper entry"
      in
      Masc.Sse.subscribe_external
        ~id:subscriber_id
        ~callback:(fun payload -> received_sse := Some payload)
        ();
      Masc.Mcp_server_eio_call_tool.record_runtime_mcp_keeper_tool_trace
        ~mcp_session_id:"mcp-session-9"
        entry
        ~tool_name:"tool_execute"
        ~arguments:
          (`Assoc
            [
              ("cmd", `String "false");
              ("session_id", `String "session-explicit");
            ])
        ~message:"command exited 1"
        ~success:false
        ~duration_ms:87;
      let rows =
        Masc.Keeper_tool_call_log.read_recent ~keeper_name ~n:1 ()
      in
      check int "logged row count" 1 (List.length rows);
      let row = List.hd rows in
      check string "tool" "tool_execute" (row |> U.member "tool" |> U.to_string);
      check bool "success" false (row |> U.member "success" |> U.to_bool);
      check string "output" "command exited 1"
        (row |> U.member "output" |> U.to_string);
      check string "lane" "runtime_mcp"
        (row |> U.member "lane" |> U.to_string);
      check string "trace id" ("trace-test-" ^ keeper_name)
        (row |> U.member "trace_id" |> U.to_string);
      check string "session id" "session-explicit"
        (row |> U.member "session_id" |> U.to_string);
      check int "turn" 1 (row |> U.member "turn" |> U.to_int);
      check int "keeper turn id" 1
        (row |> U.member "keeper_turn_id" |> U.to_int);
      check string "task id" "task-456"
        (row |> U.member "task_id" |> U.to_string);
      check int "goal id count" 1
        (row |> U.member "goal_ids" |> U.to_list |> List.length);
      let runtime_contract = row |> U.member "runtime_contract" in
      check string "runtime contract agent"
        (Masc.Keeper_identity.keeper_agent_name keeper_name)
        (runtime_contract |> U.member "agent_name" |> U.to_string);
      check bool "runtime contract has generation" true
        (match runtime_contract |> U.member "generation" with
         | `Int _ -> true
         | _ -> false);
      check string "runtime contract sandbox profile"
        (row |> U.member "sandbox_profile" |> U.to_string)
        (runtime_contract |> U.member "sandbox_profile" |> U.to_string);
      check bool "runtime contract allowed paths present" true
        (runtime_contract |> U.member "allowed_paths" |> U.to_list
         |> List.length
         > 0);
      let omits_field name =
        match runtime_contract with
        | `Assoc fields -> not (List.mem_assoc name fields)
        | _ -> false
      in
      check bool "runtime contract omits legacy required_tools" true
        (omits_field "required_tools");
      check bool "runtime contract omits legacy missing_required_tools" true
        (omits_field "missing_required_tools");
      check bool "runtime contract has runtime_profile field" true
        (match runtime_contract |> U.member "runtime_profile" with
         | `String _ | `Null -> true
         | _ -> false);
      let masc_root =
        Filename.concat base_path Common.masc_dirname
      in
      let trace_id = "trace-test-" ^ keeper_name in
      let trajectory_entries =
        Trajectory.read_entries
          ~masc_root
          ~keeper_name
          ~trace_id
      in
      check int "trajectory row count" 1 (List.length trajectory_entries);
      let trajectory_entry = List.hd trajectory_entries in
      check string "trajectory tool" "tool_execute"
        trajectory_entry.Trajectory.tool_name;
      check int "trajectory turn" 1
        trajectory_entry.Trajectory.turn;
      check int "trajectory round" 1
        trajectory_entry.Trajectory.round;
      let trajectory_json =
        let path =
          Trajectory.trajectory_path masc_root keeper_name trace_id
        in
        let ic = open_in path in
        let content =
          Fun.protect
            ~finally:(fun () -> close_in_noerr ic)
            (fun () -> really_input_string ic (in_channel_length ic))
        in
        content
        |> String.split_on_char '\n'
        |> List.find (fun line -> String.trim line <> "")
        |> Yojson.Safe.from_string
      in
      check string "trajectory runtime keeper" keeper_name
        (trajectory_json |> U.member "runtime_contract" |> U.member "keeper_name"
         |> U.to_string);
      check string "trajectory runtime agent"
        (Masc.Keeper_identity.keeper_agent_name keeper_name)
        (trajectory_json |> U.member "runtime_contract" |> U.member "agent_name"
         |> U.to_string);
      check bool "trajectory runtime has runtime_profile field" true
        (match trajectory_json |> U.member "runtime_contract"
               |> U.member "runtime_profile" with
         | `String _ | `Null -> true
         | _ -> false);
      check string "trajectory action tool" "tool_execute"
        (trajectory_json |> U.member "action_radius" |> U.member "tool_name"
         |> U.to_string);
      let sse_payload =
        match !received_sse with
        | Some payload -> extract_json_from_text payload
        | None -> fail "expected runtime MCP SSE payload"
      in
      check string "sse type" "keeper_tool_call"
        (sse_payload |> U.member "type" |> U.to_string);
      check string "sse keeper name" keeper_name
        (sse_payload |> U.member "name" |> U.to_string);
      check string "sse tool name" "tool_execute"
        (sse_payload |> U.member "tool_name" |> U.to_string);
      check bool "sse success" false
        (sse_payload |> U.member "success" |> U.to_bool);
      check string "sse error text" "command exited 1"
        (sse_payload |> U.member "error_text" |> U.to_string);
      check string "sse args structured input" "false"
        (sse_payload |> U.member "tool_args" |> U.member "cmd" |> U.to_string);
      check string "sse result structured text" "command exited 1"
        (sse_payload |> U.member "tool_result" |> U.to_string);
      check string "sse args preview includes input" {|{"cmd":"false","session_id":"session-explicit"}|}
        (sse_payload |> U.member "tool_args_preview" |> U.to_string);
      check string "sse output preview includes result" "command exited 1"
        (sse_payload |> U.member "tool_output_preview" |> U.to_string))

let () =
  run "mcp_server_eio_call_tool"
    [
      ( "quality",
        [
          test_case "timeout is error" `Quick test_timeout_quality_is_error;
          test_case "generic failure is error" `Quick test_generic_failure_quality_is_error;
          test_case "success has no issues" `Quick test_success_quality_has_no_issues;
          test_case "activity payload sanitizes invalid UTF-8" `Quick
            test_activity_payload_sanitizes_invalid_utf8;
          test_case "records MCP server operation duration metric" `Quick
            test_records_mcp_server_operation_duration_metric;
          test_case "contains casefold keeps semantics" `Quick
            test_contains_casefold_keeps_semantics;
          test_case "runtime MCP log context uses keeper trace/current turn" `Quick
            test_runtime_mcp_keeper_log_context_uses_keeper_trace_and_current_turn;
          test_case "runtime MCP log context loads current task contract" `Quick
            test_runtime_mcp_keeper_log_context_loads_current_task_contract;
          test_case "runtime MCP trace logs and broadcasts" `Quick
            test_record_runtime_mcp_keeper_tool_trace_logs_and_broadcasts;
        ] );
    ]
