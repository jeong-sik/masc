open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_tool_goals_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let parse_json_exn s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error e -> failwith ("invalid json: " ^ e)

let dispatch_exn ctx ~name ~args =
  match Tool_goals.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

let upsert_goal_exn ctx args =
  let ok, body = dispatch_exn ctx ~name:"masc_goal_upsert" ~args in
  Alcotest.(check bool) "goal upsert ok" true ok;
  let json = parse_json_exn body in
  json |> Yojson.Safe.Util.member "goal" |> Yojson.Safe.Util.member "id"
  |> Yojson.Safe.Util.to_string

let test_goal_upsert_and_list () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : Tool_goals.context =
    { config; agent_name = "tester"; call_keeper_msg = None }
  in
  let goal_id =
    upsert_goal_exn ctx
      (`Assoc
        [
          ("horizon", `String "short");
          ("title", `String "Ship MVP");
          ("priority", `Int 2);
        ])
  in
  Alcotest.(check bool) "goal id generated" true (String.length goal_id > 0);
  let ok, body = dispatch_exn ctx ~name:"masc_goal_list" ~args:(`Assoc []) in
  Alcotest.(check bool) "goal list ok" true ok;
  let json = parse_json_exn body in
  Alcotest.(check int) "goal count" 1
    (json |> Yojson.Safe.Util.member "count" |> Yojson.Safe.Util.to_int);
  cleanup_dir base_dir

let test_goal_refresh_daily_reprioritizes () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : Tool_goals.context =
    { config; agent_name = "tester"; call_keeper_msg = None }
  in
  let goal_id =
    upsert_goal_exn ctx
      (`Assoc
        [
          ("horizon", `String "short");
          ("title", `String "Overdue short goal");
          ("priority", `Int 5);
          ("due_date", `String "2000-01-01");
        ])
  in
  let ok_refresh, _refresh_body =
    dispatch_exn ctx ~name:"masc_goal_refresh"
      ~args:(`Assoc [ ("mode", `String "daily"); ("force", `Bool true) ])
  in
  Alcotest.(check bool) "goal refresh ok" true ok_refresh;
  let ok_list, list_body = dispatch_exn ctx ~name:"masc_goal_list" ~args:(`Assoc []) in
  Alcotest.(check bool) "goal list after refresh ok" true ok_list;
  let json = parse_json_exn list_body in
  let goals = json |> Yojson.Safe.Util.member "goals" |> Yojson.Safe.Util.to_list in
  let goal =
    List.find
      (fun g ->
        g |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string = goal_id)
      goals
  in
  let priority = goal |> Yojson.Safe.Util.member "priority" |> Yojson.Safe.Util.to_int in
  Alcotest.(check int) "overdue reprioritized to 1" 1 priority;
  cleanup_dir base_dir

let test_goal_dispatch_requires_approval () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : Tool_goals.context =
    { config; agent_name = "tester"; call_keeper_msg = None }
  in
  Unix.putenv "MASC_GOAL_REQUIRE_APPROVAL" "true";
  ignore
    (upsert_goal_exn ctx
       (`Assoc [ ("horizon", `String "short"); ("title", `String "Dispatch target A") ]));
  ignore
    (upsert_goal_exn ctx
       (`Assoc [ ("horizon", `String "mid"); ("title", `String "Dispatch target B") ]));
  let ok_pending, pending_body =
    dispatch_exn ctx ~name:"masc_goal_dispatch"
      ~args:
        (`Assoc
          [ ("depth", `Int 2); ("execute", `Bool true); ("approved", `Bool false) ])
  in
  Alcotest.(check bool) "dispatch pending ok" true ok_pending;
  let pending_json = parse_json_exn pending_body in
  Alcotest.(check bool) "approval required true" true
    (pending_json |> Yojson.Safe.Util.member "approval_required"
   |> Yojson.Safe.Util.to_bool);
  Alcotest.(check int) "no tasks created before approval" 0
    (List.length (Room.get_tasks_raw config));

  let ok_exec, exec_body =
    dispatch_exn ctx ~name:"masc_goal_dispatch"
      ~args:
        (`Assoc
          [ ("depth", `Int 2); ("execute", `Bool true); ("approved", `Bool true) ])
  in
  Alcotest.(check bool) "dispatch execute ok" true ok_exec;
  let exec_json = parse_json_exn exec_body in
  let created_count =
    exec_json |> Yojson.Safe.Util.member "execution" |> Yojson.Safe.Util.member "created_task_count"
    |> Yojson.Safe.Util.to_int
  in
  Alcotest.(check bool) "tasks created after approval" true (created_count > 0);
  Alcotest.(check bool) "room backlog populated" true
    (List.length (Room.get_tasks_raw config) > 0);
  cleanup_dir base_dir

let test_goal_review_done_and_promote () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : Tool_goals.context =
    { config; agent_name = "tester"; call_keeper_msg = None }
  in
  let goal_id =
    upsert_goal_exn ctx
      (`Assoc
        [
          ("horizon", `String "short");
          ("title", `String "Review candidate");
          ("priority", `Int 3);
        ])
  in
  let ok_review, review_body =
    dispatch_exn ctx ~name:"masc_goal_review"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal_id);
            ("outcome", `String "done");
            ("new_horizon", `String "long");
            ("note", `String "Completed and promoted");
          ])
  in
  Alcotest.(check bool) "goal review ok" true ok_review;
  let json = parse_json_exn review_body in
  let goal_json = json |> Yojson.Safe.Util.member "goal" in
  Alcotest.(check string) "status done" "done"
    (goal_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "horizon long" "long"
    (goal_json |> Yojson.Safe.Util.member "horizon" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir

let test_goal_dispatch_runtime_validation () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : Tool_goals.context =
    { config; agent_name = "tester"; call_keeper_msg = None }
  in
  ignore
    (upsert_goal_exn ctx
       (`Assoc [ ("horizon", `String "short"); ("title", `String "Runtime target") ]));
  let ok, body =
    dispatch_exn ctx ~name:"masc_goal_dispatch"
      ~args:
        (`Assoc
          [
            ("runtime", `String "invalid-runtime");
            ("execute", `Bool true);
            ("approved", `Bool true);
          ])
  in
  Alcotest.(check bool) "invalid runtime fails" false ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "status error" "error"
    (json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir

let test_goal_dispatch_task_runtime_requires_manual_current_task_binding () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : Tool_goals.context =
    { config; agent_name = "tester"; call_keeper_msg = None }
  in
  ignore
    (upsert_goal_exn ctx
       (`Assoc
         [ ("horizon", `String "short"); ("title", `String "Dispatch task hygiene") ]));
  let ok, body =
    dispatch_exn ctx ~name:"masc_goal_dispatch"
      ~args:
        (`Assoc
          [
            ("runtime", `String "task");
            ("execute", `Bool true);
            ("approved", `Bool true);
          ])
  in
  Alcotest.(check bool) "task runtime dispatch ok" true ok;
  let json = parse_json_exn body in
  Alcotest.(check bool) "current task not bound" false
    (json |> Yojson.Safe.Util.member "current_task_bound"
   |> Yojson.Safe.Util.to_bool);
  Alcotest.(check string) "task hygiene message"
    "dispatch created backlog tasks only; claim one and call masc_plan_set_task to bind current_task"
    (json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string);
  Alcotest.(check (option string)) "planning current_task still unset" None
    (Planning_eio.get_current_task config);
  cleanup_dir base_dir

let test_goal_dispatch_unknown_goal_ids_fail () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : Tool_goals.context =
    { config; agent_name = "tester"; call_keeper_msg = None }
  in
  ignore
    (upsert_goal_exn ctx
       (`Assoc [ ("horizon", `String "short"); ("title", `String "Known goal") ]));
  let ok, body =
    dispatch_exn ctx ~name:"masc_goal_dispatch"
      ~args:
        (`Assoc
          [
            ("goal_ids", `List [ `String "goal-missing" ]);
            ("execute", `Bool true);
            ("approved", `Bool true);
          ])
  in
  Alcotest.(check bool) "unknown goal ids fail" false ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "status error" "error"
    (json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "unknown goal ids message"
    "unknown goal_ids: goal-missing"
    (json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir

let () =
  Alcotest.run "Tool_goals"
    [
      ( "goal tools",
        [
          Alcotest.test_case "upsert and list" `Quick test_goal_upsert_and_list;
          Alcotest.test_case "refresh daily reprioritize" `Quick
            test_goal_refresh_daily_reprioritizes;
          Alcotest.test_case "dispatch approval gate" `Quick
            test_goal_dispatch_requires_approval;
          Alcotest.test_case "review done promote" `Quick
            test_goal_review_done_and_promote;
          Alcotest.test_case "dispatch runtime validation" `Quick
            test_goal_dispatch_runtime_validation;
          Alcotest.test_case
            "dispatch task runtime requires manual current_task binding" `Quick
            test_goal_dispatch_task_runtime_requires_manual_current_task_binding;
          Alcotest.test_case "dispatch unknown goal_ids fail" `Quick
            test_goal_dispatch_unknown_goal_ids_fail;
        ] );
    ]
