open Masc_mcp

(** {1 Test helpers} *)

let temp_dir () =
  let dir = Filename.temp_file "test_goals_cov_" "" in
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

let dispatch_opt ctx ~name ~args =
  Tool_goals.dispatch ctx ~name ~args

let upsert_goal ctx args =
  dispatch_exn ctx ~name:"masc_goal_upsert" ~args

let make_ctx base_dir =
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : Tool_goals.context =
    { config; agent_name = "tester"; call_keeper_msg = None }
  in
  (ctx, config)

(** {2 Group 1: Dispatch Routing} *)

let test_dispatch_unknown_returns_none () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  let result = dispatch_opt ctx ~name:"masc_goal_nonexistent" ~args:(`Assoc []) in
  Alcotest.(check bool) "unknown tool returns None" true (result = None);
  cleanup_dir base_dir

let test_dispatch_all_tool_names () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  let valid_names = [
    "masc_goal_upsert"; "masc_goal_list"; "masc_goal_snapshot";
    "masc_goal_refresh"; "masc_goal_dispatch"; "masc_goal_review"
  ] in
  List.iter (fun name ->
    let result = dispatch_opt ctx ~name ~args:(`Assoc []) in
    Alcotest.(check bool) (Printf.sprintf "%s dispatches" name) true
      (result <> None)
  ) valid_names;
  cleanup_dir base_dir

(** {2 Group 2: Schema Validation} *)

let test_schemas_count () =
  Alcotest.(check int) "6 schemas" 6 (List.length Tool_goals.schemas)

let test_schemas_unique_names () =
  let names = List.map (fun (s : Types.tool_schema) -> s.name) Tool_goals.schemas in
  let unique = List.sort_uniq String.compare names in
  Alcotest.(check int) "all unique" (List.length names) (List.length unique)

let test_schemas_have_descriptions () =
  List.iter (fun (s : Types.tool_schema) ->
    Alcotest.(check bool) (Printf.sprintf "%s has desc" s.name) true
      (String.length s.description > 0)
  ) Tool_goals.schemas

(** {2 Group 3: Goal Snapshot} *)

let test_snapshot_manual_mode () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  (* Create a goal first *)
  let ok1, _ = upsert_goal ctx
    (`Assoc [("horizon", `String "short"); ("title", `String "Snap target")]) in
  Alcotest.(check bool) "upsert ok" true ok1;
  let ok, body = dispatch_exn ctx ~name:"masc_goal_snapshot"
    ~args:(`Assoc [("mode", `String "manual")]) in
  Alcotest.(check bool) "snapshot ok" true ok;
  let json = parse_json_exn body in
  let snap = Yojson.Safe.Util.member "snapshot" json in
  Alcotest.(check bool) "has snapshot field" true (snap <> `Null);
  cleanup_dir base_dir

let test_snapshot_empty_goals () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  let ok, body = dispatch_exn ctx ~name:"masc_goal_snapshot"
    ~args:(`Assoc []) in
  Alcotest.(check bool) "snapshot ok even empty" true ok;
  let json = parse_json_exn body in
  Alcotest.(check bool) "has snapshot" true
    (Yojson.Safe.Util.member "snapshot" json <> `Null);
  cleanup_dir base_dir

(** {2 Group 4: Horizon / Status Validation} *)

let test_list_invalid_horizon () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  let ok, body = dispatch_exn ctx ~name:"masc_goal_list"
    ~args:(`Assoc [("horizon", `String "invalid_horizon")]) in
  Alcotest.(check bool) "invalid horizon fails" false ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "error status" "error"
    (json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir

let test_list_invalid_status () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  let ok, body = dispatch_exn ctx ~name:"masc_goal_list"
    ~args:(`Assoc [("status", `String "invalid_status")]) in
  Alcotest.(check bool) "invalid status fails" false ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "error status" "error"
    (json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir

let test_list_valid_horizon_filter () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  let ok1, _ = upsert_goal ctx
    (`Assoc [("horizon", `String "short"); ("title", `String "Short goal")]) in
  Alcotest.(check bool) "upsert short" true ok1;
  let ok2, _ = upsert_goal ctx
    (`Assoc [("horizon", `String "long"); ("title", `String "Long goal")]) in
  Alcotest.(check bool) "upsert long" true ok2;
  let ok, body = dispatch_exn ctx ~name:"masc_goal_list"
    ~args:(`Assoc [("horizon", `String "short")]) in
  Alcotest.(check bool) "list short ok" true ok;
  let json = parse_json_exn body in
  let count = json |> Yojson.Safe.Util.member "count" |> Yojson.Safe.Util.to_int in
  Alcotest.(check int) "only short goals" 1 count;
  cleanup_dir base_dir

let test_list_with_rollup () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  let ok1, _ = upsert_goal ctx
    (`Assoc [("horizon", `String "short"); ("title", `String "Goal A"); ("priority", `Int 1)]) in
  Alcotest.(check bool) "upsert A" true ok1;
  let ok2, _ = upsert_goal ctx
    (`Assoc [("horizon", `String "mid"); ("title", `String "Goal B"); ("priority", `Int 3)]) in
  Alcotest.(check bool) "upsert B" true ok2;
  let ok, body = dispatch_exn ctx ~name:"masc_goal_list" ~args:(`Assoc []) in
  Alcotest.(check bool) "list ok" true ok;
  let json = parse_json_exn body in
  let rollup = Yojson.Safe.Util.member "rollup" json in
  Alcotest.(check bool) "has rollup" true (rollup <> `Null);
  cleanup_dir base_dir

(** {2 Group 5: Refresh Edge Cases} *)

let test_refresh_invalid_mode () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  let ok, body = dispatch_exn ctx ~name:"masc_goal_refresh"
    ~args:(`Assoc [("mode", `String "invalid_mode")]) in
  Alcotest.(check bool) "invalid mode fails" false ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "error status" "error"
    (json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir

let test_refresh_auto_no_due () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  (* Without force, auto mode may skip if no cadence window is due *)
  let ok, body = dispatch_exn ctx ~name:"masc_goal_refresh"
    ~args:(`Assoc [("mode", `String "auto"); ("force", `Bool false)]) in
  Alcotest.(check bool) "auto no-force ok" true ok;
  let json = parse_json_exn body in
  (* May skip or execute depending on scheduler state *)
  let mode = json |> Yojson.Safe.Util.member "mode" |> Yojson.Safe.Util.to_string in
  Alcotest.(check string) "mode is auto" "auto" mode;
  cleanup_dir base_dir

let test_refresh_monthly_force () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  let ok1, _ = upsert_goal ctx
    (`Assoc [("horizon", `String "long"); ("title", `String "Monthly target")]) in
  Alcotest.(check bool) "upsert ok" true ok1;
  let ok, body = dispatch_exn ctx ~name:"masc_goal_refresh"
    ~args:(`Assoc [("mode", `String "monthly"); ("force", `Bool true)]) in
  Alcotest.(check bool) "monthly force ok" true ok;
  let json = parse_json_exn body in
  let skipped = json |> Yojson.Safe.Util.member "skipped" |> Yojson.Safe.Util.to_bool in
  Alcotest.(check bool) "not skipped with force" false skipped;
  cleanup_dir base_dir

(** {2 Group 6: Dispatch (dry-run / execute=false)} *)

let test_dispatch_no_execute () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  let ok1, _ = upsert_goal ctx
    (`Assoc [("horizon", `String "short"); ("title", `String "Dry run target")]) in
  Alcotest.(check bool) "upsert ok" true ok1;
  let ok, body = dispatch_exn ctx ~name:"masc_goal_dispatch"
    ~args:(`Assoc [("execute", `Bool false)]) in
  Alcotest.(check bool) "dry run ok" true ok;
  let json = parse_json_exn body in
  let executed = json |> Yojson.Safe.Util.member "executed" |> Yojson.Safe.Util.to_bool in
  Alcotest.(check bool) "not executed" false executed;
  let plan = Yojson.Safe.Util.member "plan" json in
  Alcotest.(check bool) "has plan" true (plan <> `Null);
  cleanup_dir base_dir

(** {2 Group 7: Review Edge Cases} *)

let test_review_missing_fields () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  let ok, body = dispatch_exn ctx ~name:"masc_goal_review"
    ~args:(`Assoc []) in
  Alcotest.(check bool) "missing fields fails" false ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "error status" "error"
    (json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir

let test_review_nonexistent_goal () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  let ok, body = dispatch_exn ctx ~name:"masc_goal_review"
    ~args:(`Assoc [("goal_id", `String "fake-id"); ("outcome", `String "done")]) in
  Alcotest.(check bool) "nonexistent goal fails" false ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "error status" "error"
    (json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir

let test_review_blocked_outcome () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  let ctx, _ = make_ctx base_dir in
  let ok1, body1 = upsert_goal ctx
    (`Assoc [("horizon", `String "short"); ("title", `String "Block me")]) in
  Alcotest.(check bool) "upsert ok" true ok1;
  let json = parse_json_exn body1 in
  let goal_id = json |> Yojson.Safe.Util.member "goal"
    |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string in
  let ok, body = dispatch_exn ctx ~name:"masc_goal_review"
    ~args:(`Assoc [("goal_id", `String goal_id); ("outcome", `String "blocked");
                    ("note", `String "Depends on external team")]) in
  Alcotest.(check bool) "blocked review ok" true ok;
  let result_json = parse_json_exn body in
  let status = result_json |> Yojson.Safe.Util.member "goal"
    |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string in
  Alcotest.(check string) "blocked outcome maps to paused status" "paused" status;
  cleanup_dir base_dir

(** {2 Group 8: Helper Functions} *)

let test_normalize_runtime () =
  Alcotest.(check (option string)) "task" (Some "task")
    (Tool_goals.normalize_runtime "task");
  Alcotest.(check (option string)) "TASK" (Some "task")
    (Tool_goals.normalize_runtime "TASK");
  Alcotest.(check (option string)) "keeper" (Some "keeper")
    (Tool_goals.normalize_runtime "keeper");
  Alcotest.(check (option string)) "invalid" None
    (Tool_goals.normalize_runtime "invalid");
  Alcotest.(check (option string)) "empty" None
    (Tool_goals.normalize_runtime "")

let test_sanitize_keeper_name () =
  let name = Tool_goals.sanitize_keeper_name "Goal - Ship MVP" in
  Alcotest.(check bool) "lowercase" true (name = String.lowercase_ascii name);
  Alcotest.(check bool) "no spaces" true (not (String.contains name ' '));
  Alcotest.(check bool) "max 48 chars" true (String.length name <= 48);
  let empty = Tool_goals.sanitize_keeper_name "" in
  Alcotest.(check string) "empty defaults to goal-keeper" "goal-keeper" empty;
  let long = Tool_goals.sanitize_keeper_name (String.make 100 'a') in
  Alcotest.(check bool) "long truncated to 48" true (String.length long <= 48)

let test_tool_result_json () =
  let json_str = Tool_goals.tool_result_json [("key", `String "val")] in
  let json = parse_json_exn json_str in
  Alcotest.(check string) "status ok" "ok"
    (json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "key present" "val"
    (json |> Yojson.Safe.Util.member "key" |> Yojson.Safe.Util.to_string)

let test_error_result_json () =
  let json_str = Tool_goals.error_result_json "something failed" in
  let json = parse_json_exn json_str in
  Alcotest.(check string) "status error" "error"
    (json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  let msg = json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
  Alcotest.(check bool) "has error msg" true (String.length msg > 0)

let test_split_csv () =
  let result = Tool_goals.split_csv "a, b , c" in
  Alcotest.(check (list string)) "trimmed" ["a"; "b"; "c"] result;
  let empty = Tool_goals.split_csv "" in
  Alcotest.(check (list string)) "empty" [] empty

(** {1 Test Runner} *)

let () =
  Alcotest.run "Tool_goals_coverage"
    [
      ( "dispatch_routing",
        [
          Alcotest.test_case "unknown returns None" `Quick test_dispatch_unknown_returns_none;
          Alcotest.test_case "all tools dispatch" `Quick test_dispatch_all_tool_names;
        ] );
      ( "schemas",
        [
          Alcotest.test_case "schema count" `Quick test_schemas_count;
          Alcotest.test_case "unique names" `Quick test_schemas_unique_names;
          Alcotest.test_case "have descriptions" `Quick test_schemas_have_descriptions;
        ] );
      ( "snapshot",
        [
          Alcotest.test_case "manual mode" `Quick test_snapshot_manual_mode;
          Alcotest.test_case "empty goals" `Quick test_snapshot_empty_goals;
        ] );
      ( "validation",
        [
          Alcotest.test_case "invalid horizon" `Quick test_list_invalid_horizon;
          Alcotest.test_case "invalid status" `Quick test_list_invalid_status;
          Alcotest.test_case "valid horizon filter" `Quick test_list_valid_horizon_filter;
          Alcotest.test_case "list with rollup" `Quick test_list_with_rollup;
        ] );
      ( "refresh",
        [
          Alcotest.test_case "invalid mode" `Quick test_refresh_invalid_mode;
          Alcotest.test_case "auto no due" `Quick test_refresh_auto_no_due;
          Alcotest.test_case "monthly force" `Quick test_refresh_monthly_force;
        ] );
      ( "dispatch_goals",
        [
          Alcotest.test_case "no execute dry run" `Quick test_dispatch_no_execute;
        ] );
      ( "review",
        [
          Alcotest.test_case "missing fields" `Quick test_review_missing_fields;
          Alcotest.test_case "nonexistent goal" `Quick test_review_nonexistent_goal;
          Alcotest.test_case "blocked outcome" `Quick test_review_blocked_outcome;
        ] );
      ( "helpers",
        [
          Alcotest.test_case "normalize_runtime" `Quick test_normalize_runtime;
          Alcotest.test_case "sanitize_keeper_name" `Quick test_sanitize_keeper_name;
          Alcotest.test_case "tool_result_json" `Quick test_tool_result_json;
          Alcotest.test_case "error_result_json" `Quick test_error_result_json;
          Alcotest.test_case "split_csv" `Quick test_split_csv;
        ] );
    ]
