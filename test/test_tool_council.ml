open Masc_mcp
open Alcotest

let test_counter = ref 0

let temp_dir prefix =
  incr test_counter;
  let dir = Filename.temp_file (Printf.sprintf "%s_%d_" prefix !test_counter) "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let parse_json_exn s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error e -> failwith ("invalid json: " ^ e)

let contains_substring ~needle haystack =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    idx + needle_len <= hay_len
    && ((String.sub haystack idx needle_len = needle) || loop (idx + 1))
  in
  needle_len = 0 || loop 0

let make_ctx ~base_path ~agent_name : Tool_council.context =
  { base_path; agent_name; room_config = None }

let dispatch_exn ctx ~name ~args =
  match Tool_council.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

let with_base_path f =
  let base_path = temp_dir "test_tool_council_v2" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      Council.Governance_v2.reset_legacy_storage base_path;
      f base_path)

let field key json = Yojson.Safe.Util.member key json

let test_petition_submit_creates_case_and_pending_ruling () =
  with_base_path @@ fun base_path ->
  let ctx = make_ctx ~base_path ~agent_name:"alice" in
  let ok, body =
    dispatch_exn ctx ~name:"masc_petition_submit"
      ~args:
        (`Assoc
          [
            ("title", `String "Create onboarding task");
            ("origin", `String "human");
            ( "requested_action",
              `Assoc
                [
                  ("action_type", `String "add_task");
                  ("payload", `Assoc [ ("description", `String "capture onboarding work") ]);
                ] );
          ])
  in
  check bool "petition ok" true ok;
  let json = parse_json_exn body in
  check string "case pending" "pending_ruling"
    (json |> field "case" |> field "status" |> Yojson.Safe.Util.to_string);
  check string "ruling pending" "pending_ruling"
    (json |> field "ruling" |> field "auto_execution_state" |> Yojson.Safe.Util.to_string)

let test_case_brief_auto_executes_low_risk_task () =
  with_base_path @@ fun base_path ->
  let starter = make_ctx ~base_path ~agent_name:"alice" in
  let briefer = make_ctx ~base_path ~agent_name:"bob" in
  let ok, body =
    dispatch_exn starter ~name:"masc_petition_submit"
      ~args:
        (`Assoc
          [
            ("title", `String "Ship onboarding task");
            ("origin", `String "human");
            ( "requested_action",
              `Assoc
                [
                  ("action_type", `String "add_task");
                  ("payload", `Assoc [ ("priority", `Int 1); ("description", `String "auto task") ]);
                ] );
          ])
  in
  check bool "petition ok" true ok;
  let case_id = parse_json_exn body |> field "case" |> field "id" |> Yojson.Safe.Util.to_string in
  let ok, body =
    dispatch_exn briefer ~name:"masc_case_brief_submit"
      ~args:
        (`Assoc
          [
            ("case_id", `String case_id);
            ("stance", `String "support");
            ("summary", `String "Low risk and ready");
            ("evidence_refs", `List [ `String "memo:ready" ]);
          ])
  in
  check bool "brief ok" true ok;
  let json = parse_json_exn body in
  check string "case executed" "executed"
    (json |> field "case" |> field "status" |> Yojson.Safe.Util.to_string);
  check string "order auto executed" "auto_executed"
    (json |> field "execution_order" |> field "status" |> Yojson.Safe.Util.to_string);
  let tasks = Room.get_tasks_raw (Room.default_config base_path) in
  check bool "task created" true (List.length tasks = 1)

let test_human_gate_requires_confirm_then_executes () =
  with_base_path @@ fun base_path ->
  let starter = make_ctx ~base_path ~agent_name:"alice" in
  let briefer = make_ctx ~base_path ~agent_name:"judge" in
  let approver = make_ctx ~base_path ~agent_name:"operator" in
  let ok, body =
    dispatch_exn starter ~name:"masc_petition_submit"
      ~args:
        (`Assoc
          [
            ("title", `String "High risk task gate");
            ("origin", `String "human");
            ("risk_class", `String "high");
            ( "requested_action",
              `Assoc
                [
                  ("action_type", `String "add_task");
                  ("payload", `Assoc [ ("description", `String "gated task") ]);
                ] );
          ])
  in
  check bool "petition ok" true ok;
  let case_id = parse_json_exn body |> field "case" |> field "id" |> Yojson.Safe.Util.to_string in
  let ok, body =
    dispatch_exn briefer ~name:"masc_case_brief_submit"
      ~args:
        (`Assoc
          [
            ("case_id", `String case_id);
            ("stance", `String "support");
            ("summary", `String "Needs human gate");
          ])
  in
  check bool "brief ok" true ok;
  let json = parse_json_exn body in
  check string "case gated" "needs_human_gate"
    (json |> field "case" |> field "status" |> Yojson.Safe.Util.to_string);
  check string "order gated" "needs_human_gate"
    (json |> field "execution_order" |> field "status" |> Yojson.Safe.Util.to_string);
  let ok, body =
    dispatch_exn approver ~name:"masc_execution_orders"
      ~args:(`Assoc [ ("case_id", `String case_id); ("decision", `String "confirm") ])
  in
  check bool "confirm ok" true ok;
  let order = parse_json_exn body in
  check string "confirmed order done" "done"
    (order |> field "status" |> Yojson.Safe.Util.to_string);
  let tasks = Room.get_tasks_raw (Room.default_config base_path) in
  check bool "task created after confirm" true (List.length tasks = 1)

let test_legacy_surfaces_return_removed_error () =
  with_base_path @@ fun base_path ->
  let ctx = make_ctx ~base_path ~agent_name:"alice" in
  let ok, body =
    dispatch_exn ctx ~name:"masc_debate_start"
      ~args:(`Assoc [ ("topic", `String "legacy") ])
  in
  check bool "legacy fails" false ok;
  check bool "mentions removed" true
    (contains_substring ~needle:"removed in governance v2" body)

let test_duplicate_petition_merges_by_source_ref () =
  with_base_path @@ fun base_path ->
  let module GV2 = Council.Governance_v2 in
  (* First petition: stuck task claimed by agent-a *)
  let result1 =
    GV2.submit_petition base_path
      ~title:"Stuck task: QA-TEST-01 (claimed by agent-a)"
      ~origin:"sentinel" ~subject_type:"task" ~risk_class:GV2.Low
      ~requested_action:(Some { action_type = "release_task";
                                target_type = Some "task";
                                target_id = None; payload = None })
      ~source_refs:["task-QA-TEST-01"] ~created_by:"sentinel"
  in
  let result1 = Result.get_ok result1 in
  check bool "first petition not merged" false result1.merged;
  let case_id_1 = result1.case_.id in
  (* Second petition: same task, different title (assignee changed) *)
  let result2 =
    GV2.submit_petition base_path
      ~title:"Stuck task: QA-TEST-01 (in_progress by agent-b)"
      ~origin:"sentinel" ~subject_type:"task" ~risk_class:GV2.Low
      ~requested_action:(Some { action_type = "release_task";
                                target_type = Some "task";
                                target_id = None; payload = None })
      ~source_refs:["task-QA-TEST-01"] ~created_by:"sentinel"
  in
  let result2 = Result.get_ok result2 in
  check bool "second petition merged (source_ref dedup)" true result2.merged;
  check string "merged into same case" case_id_1 result2.case_.id;
  (* Third petition: identical to first (repeated sweep) *)
  let result3 =
    GV2.submit_petition base_path
      ~title:"Stuck task: QA-TEST-01 (claimed by agent-a)"
      ~origin:"sentinel" ~subject_type:"task" ~risk_class:GV2.Low
      ~requested_action:(Some { action_type = "release_task";
                                target_type = Some "task";
                                target_id = None; payload = None })
      ~source_refs:["task-QA-TEST-01"] ~created_by:"sentinel"
  in
  let result3 = Result.get_ok result3 in
  check bool "third petition merged" true result3.merged;
  check string "third merged into same case" case_id_1 result3.case_.id;
  (* Verify only 1 active case exists *)
  let cases = GV2.list_cases ~include_test:true base_path in
  check int "exactly 1 case" 1 (List.length cases);
  (* After BUG-1627/1608 fix: merged duplicates do not add new petitions,
     so the case has only the original petition. *)
  let the_case = List.hd cases in
  check int "case has 1 petition (dedup)" 1 (List.length the_case.petition_ids)

let test_petition_rejects_unsupported_action_type () =
  with_base_path @@ fun base_path ->
  let ctx = make_ctx ~base_path ~agent_name:"alice" in
  let ok, body =
    dispatch_exn ctx ~name:"masc_petition_submit"
      ~args:
        (`Assoc
          [
            ("title", `String "Unsupported action");
            ( "requested_action",
              `Assoc
                [
                  ("action_type", `String "room_pause");
                ] );
          ])
  in
  check bool "unsupported action rejected" false ok;
  check bool "mentions unsupported action" true
    (contains_substring ~needle:"unsupported requested_action.action_type" body)

let () =
  run "Tool_council_v2"
    [
      ( "governance_v2",
        [
          test_case "petition submit creates pending ruling" `Quick
            test_petition_submit_creates_case_and_pending_ruling;
          test_case "brief auto executes low risk task" `Quick
            test_case_brief_auto_executes_low_risk_task;
          test_case "human gate confirm executes" `Quick
            test_human_gate_requires_confirm_then_executes;
          test_case "legacy surfaces removed" `Quick
            test_legacy_surfaces_return_removed_error;
          test_case "unsupported action type rejected" `Quick
            test_petition_rejects_unsupported_action_type;
          test_case "duplicate petitions merge by source_ref" `Quick
            test_duplicate_petition_merges_by_source_ref;
        ] );
    ]
