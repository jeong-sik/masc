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
      ~default:(Masc_mcp.Keeper_types.keeper_agent_name name)
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
             Masc_mcp.Keeper_types.tool_access_to_json tool_access );
         ]
     | None -> [])
  in
  match Masc_test_deps.meta_of_json_fixture (`Assoc fields) with
  | Ok meta -> meta
  | Error err -> fail ("make_keeper_meta failed: " ^ err)

let contract_requiring_tools required_tools : Types.task_contract =
  {
    strict = false;
    completion_contract = [];
    required_tools;
    required_evidence = [];
    inspect_gate_evidence = [];
    verify_gate_evidence = [];
    links =
      {
        operation_id = None;
        session_id = None;
        autoresearch_loop_id = None;
      };
  }

let extract_json_from_text text =
  try
    let idx = String.index text '{' in
    Yojson.Safe.from_string (String.sub text idx (String.length text - idx))
  with Not_found ->
    failf "expected JSON payload in text: %s" text

let test_timeout_quality_is_error () =
  let quality =
    Masc_mcp.Mcp_server_eio_call_tool.quality_from_result
      ~success:false
      ~message:"Tool timed out after 30s"
      ~attempts:1
  in
  let issue = first_issue quality in
  check string "timeout code" "tool_timeout" (issue |> U.member "code" |> U.to_string);
  check string "timeout severity" "error" (issue |> U.member "severity" |> U.to_string)

let test_generic_failure_quality_is_error () =
  let quality =
    Masc_mcp.Mcp_server_eio_call_tool.quality_from_result
      ~success:false
      ~message:"subprocess exited 1"
      ~attempts:2
  in
  let issue = first_issue quality in
  check string "failure code" "tool_failure" (issue |> U.member "code" |> U.to_string);
  check string "failure severity" "error" (issue |> U.member "severity" |> U.to_string)

let test_success_quality_has_no_issues () =
  let quality =
    Masc_mcp.Mcp_server_eio_call_tool.quality_from_result
      ~success:true
      ~message:"ok"
      ~attempts:1
  in
  check bool "passed" true (quality |> U.member "passed" |> U.to_bool);
  check int "issue count" 0 (quality |> U.member "issues" |> U.to_list |> List.length)

let test_contains_casefold_keeps_semantics () =
  let contains = Masc_mcp.Mcp_server_eio_call_tool.contains_casefold in
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

let test_transition_has_no_fixed_timeout () =
  check bool "masc_transition has no fixed timeout"
    true
    (Masc_mcp.Mcp_server_eio_call_tool.tool_timeout_sec_opt
       ~tool_name:"masc_transition"
       ~_arguments:(`Assoc [])
     = None)

let test_persona_generate_timeout_exceeds_oas_budget () =
  match
    Masc_mcp.Mcp_server_eio_call_tool.tool_timeout_sec_opt
      ~tool_name:"masc_persona_generate"
      ~_arguments:(`Assoc [])
  with
  | Some timeout_sec ->
      check bool "persona generate timeout exceeds internal OAS budget" true
        (timeout_sec > 120.)
  | None -> fail "expected persona generation to keep a bounded outer timeout"

let test_regular_tool_uses_default_timeout () =
  match
    Masc_mcp.Mcp_server_eio_call_tool.tool_timeout_sec_opt
      ~tool_name:"masc_status"
      ~_arguments:(`Assoc [])
  with
  | Some timeout_sec -> check bool "default timeout remains enabled" true (timeout_sec >= 5.)
  | None -> fail "expected masc_status to keep fixed timeout"

let test_board_write_tools_use_board_timeout () =
  List.iter (fun tool_name ->
    match
      Masc_mcp.Mcp_server_eio_call_tool.tool_timeout_sec_opt
        ~tool_name
        ~_arguments:(`Assoc [])
    with
    | Some timeout_sec ->
        check bool
          (Printf.sprintf "%s board timeout >= default 60 s" tool_name)
          true
          (timeout_sec >= 60.)
    | None ->
        fail (Printf.sprintf "expected %s to have a fixed timeout" tool_name))
  [ "masc_board_post"; "masc_board_comment"; "masc_board_vote"; "masc_board_comment_vote" ]


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
      Masc_mcp.Keeper_registry.unregister ~base_path keeper_name;
      cleanup_dir base_path)
    (fun () ->
      ignore
        (Masc_mcp.Keeper_registry.register_offline ~base_path keeper_name meta);
      Masc_mcp.Keeper_registry.mark_turn_started ~base_path keeper_name;
      let entry =
        match Masc_mcp.Keeper_registry.get ~base_path keeper_name with
        | Some entry -> entry
        | None -> fail "expected registered keeper entry"
      in
      let ctx =
        Masc_mcp.Mcp_server_eio_call_tool.runtime_mcp_keeper_log_context_of_entry
          ~mcp_session_id:"mcp-session-1"
          entry
          ~arguments:(`Assoc [ ("session_id", `String "session-explicit") ])
      in
      check (option string) "trace_id"
        (Some ("trace-test-" ^ keeper_name))
        ctx.trace_id;
      check (option string) "agent_name"
        (Some (Masc_mcp.Keeper_types.keeper_agent_name keeper_name))
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
      check bool "network mode present" true (Option.is_some ctx.network_mode);
      check bool "shared memory scope present" true
        (Option.is_some ctx.shared_memory_scope);
      check bool "tool surface class present" true
        (Option.is_some ctx.tool_surface_class);
      check bool "visible tool count present" true
        (Option.is_some ctx.visible_tool_count);
      check (option (list string)) "runtime mcp required tools empty"
        (Some []) ctx.required_tools;
      check (option (list string)) "runtime mcp missing required tools empty"
        (Some []) ctx.missing_required_tools;
      check (option string) "cascade profile" (Some meta.cascade_name)
        ctx.cascade_profile)

let test_runtime_mcp_keeper_log_context_loads_current_task_contract () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  let keeper_name = "sangsu-task-contract" in
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some keeper_name));
  let contract =
    contract_requiring_tools [ "keeper_bash"; "keeper_fs_edit" ]
  in
  ignore
    (Masc_mcp.Coord.add_task
       ~contract
       config
       ~title:"Needs execution tools"
       ~priority:1
       ~description:"exercise runtime MCP required tool logging");
  let meta =
    make_keeper_meta
      ~current_task_id:"task-001"
      ~tool_access:(Masc_mcp.Keeper_types.Custom [ "keeper_bash" ])
      keeper_name
  in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_registry.unregister ~base_path keeper_name;
      cleanup_dir base_path)
    (fun () ->
      ignore
        (Masc_mcp.Keeper_registry.register_offline ~base_path keeper_name meta);
      let entry =
        match Masc_mcp.Keeper_registry.get ~base_path keeper_name with
        | Some entry -> entry
        | None -> fail "expected registered keeper entry"
      in
      let ctx =
        Masc_mcp.Mcp_server_eio_call_tool.runtime_mcp_keeper_log_context_of_entry
          entry
          ~arguments:(`Assoc [])
      in
      check (option (list string)) "runtime mcp required tools"
        (Some [ "keeper_bash"; "keeper_fs_edit" ])
        ctx.required_tools;
      check (option (list string)) "runtime mcp missing required tools"
        (Some [ "keeper_fs_edit" ])
        ctx.missing_required_tools)

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
  Masc_mcp.Keeper_tool_call_log.reset_for_testing ();
  Masc_mcp.Keeper_tool_call_log.init ~base_path ();
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Sse.unsubscribe_external subscriber_id;
      Masc_mcp.Keeper_registry.unregister ~base_path keeper_name;
      Masc_mcp.Keeper_tool_call_log.reset_for_testing ();
      cleanup_dir base_path)
    (fun () ->
      ignore
        (Masc_mcp.Keeper_registry.register_offline ~base_path keeper_name meta);
      Masc_mcp.Keeper_registry.mark_turn_started ~base_path keeper_name;
      let entry =
        match Masc_mcp.Keeper_registry.get ~base_path keeper_name with
        | Some entry -> entry
        | None -> fail "expected registered keeper entry"
      in
      Masc_mcp.Sse.subscribe_external
        ~id:subscriber_id
        ~callback:(fun payload -> received_sse := Some payload)
        ();
      Masc_mcp.Mcp_server_eio_call_tool.record_runtime_mcp_keeper_tool_trace
        ~mcp_session_id:"mcp-session-9"
        entry
        ~tool_name:"keeper_bash"
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
        Masc_mcp.Keeper_tool_call_log.read_recent ~keeper_name ~n:1 ()
      in
      check int "logged row count" 1 (List.length rows);
      let row = List.hd rows in
      check string "tool" "keeper_bash" (row |> U.member "tool" |> U.to_string);
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
        (Masc_mcp.Keeper_types.keeper_agent_name keeper_name)
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
      check bool "runtime contract visible tool count present" true
        (match runtime_contract |> U.member "visible_tool_count" with
         | `Int n -> n > 0
         | _ -> false);
      check int "runtime contract required tools empty" 0
        (runtime_contract |> U.member "required_tools" |> U.to_list
         |> List.length);
      check int "runtime contract missing required tools empty" 0
        (runtime_contract |> U.member "missing_required_tools" |> U.to_list
         |> List.length);
      check string "runtime contract cascade profile" meta.cascade_name
        (runtime_contract |> U.member "cascade_profile" |> U.to_string);
      let masc_root =
        Filename.concat base_path Common.masc_dirname
      in
      let trace_id = "trace-test-" ^ keeper_name in
      let trajectory_entries =
        Masc_mcp.Trajectory.read_entries
          ~masc_root
          ~keeper_name
          ~trace_id
      in
      check int "trajectory row count" 1 (List.length trajectory_entries);
      let trajectory_entry = List.hd trajectory_entries in
      check string "trajectory tool" "keeper_bash"
        trajectory_entry.Masc_mcp.Trajectory.tool_name;
      check int "trajectory turn" 1
        trajectory_entry.Masc_mcp.Trajectory.turn;
      check int "trajectory round" 1
        trajectory_entry.Masc_mcp.Trajectory.round;
      let trajectory_json =
        let path =
          Masc_mcp.Trajectory.trajectory_path masc_root keeper_name trace_id
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
        (Masc_mcp.Keeper_types.keeper_agent_name keeper_name)
        (trajectory_json |> U.member "runtime_contract" |> U.member "agent_name"
         |> U.to_string);
      check string "trajectory runtime cascade profile" meta.cascade_name
        (trajectory_json |> U.member "runtime_contract"
         |> U.member "cascade_profile" |> U.to_string);
      check string "trajectory action tool" "keeper_bash"
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
      check string "sse tool name" "keeper_bash"
        (sse_payload |> U.member "tool_name" |> U.to_string);
      check bool "sse success" false
        (sse_payload |> U.member "success" |> U.to_bool);
      check string "sse error text" "command exited 1"
        (sse_payload |> U.member "error_text" |> U.to_string))

let () =
  run "mcp_server_eio_call_tool"
    [
      ( "quality",
        [
          test_case "timeout is error" `Quick test_timeout_quality_is_error;
          test_case "generic failure is error" `Quick test_generic_failure_quality_is_error;
          test_case "success has no issues" `Quick test_success_quality_has_no_issues;
          test_case "contains casefold keeps semantics" `Quick
            test_contains_casefold_keeps_semantics;
          test_case "transition has no fixed timeout" `Quick test_transition_has_no_fixed_timeout;
          test_case "persona generate timeout exceeds OAS budget" `Quick
            test_persona_generate_timeout_exceeds_oas_budget;
          test_case "regular tool keeps default timeout" `Quick test_regular_tool_uses_default_timeout;
          test_case "board write tools use dedicated board timeout" `Quick
            test_board_write_tools_use_board_timeout;
          test_case "runtime MCP log context uses keeper trace/current turn" `Quick
            test_runtime_mcp_keeper_log_context_uses_keeper_trace_and_current_turn;
          test_case "runtime MCP log context loads current task contract" `Quick
            test_runtime_mcp_keeper_log_context_loads_current_task_contract;
          test_case "runtime MCP trace logs and broadcasts" `Quick
            test_record_runtime_mcp_keeper_tool_trace_logs_and_broadcasts;
        ] );
    ]
