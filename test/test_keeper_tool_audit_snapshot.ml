let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/"
  then ()
  else if Sys.file_exists dir
  then ()
  else (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

let temp_dir () =
  let dir = Filename.temp_file "keeper_tool_audit_snapshot_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String ("trace-" ^ name)
        ; "updated_at", `String "2026-06-03T00:00:00Z"
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta fixture failed: " ^ err)
;;

let string_list_member json key =
  Yojson.Safe.Util.(json |> member key |> to_list |> List.map to_string)
;;

let test_tool_exec_decision_row_feeds_lightweight_tool_audit () =
  Dashboard_cache.invalidate_all ();
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Dashboard_cache.invalidate_all ();
      remove_tree base_dir)
    (fun () ->
      let config = Masc.Workspace.default_config base_dir in
      let keeper_name = "tool-audit-row" in
      let decision_path =
        Masc.Keeper_types_support.keeper_decision_log_path config keeper_name
      in
      mkdir_p (Filename.dirname decision_path);
      Masc.Keeper_types_support.append_jsonl_line decision_path
        (`Assoc
          [ "ts", `String "2026-06-03T00:00:00Z"
          ; "event", `String "tool_exec"
          ; "tool", `String "keeper_tools_list"
          ; "ok", `Bool true
          ]);
      let snapshot =
        match
          Masc.Keeper_status_metrics.latest_tool_audit_snapshot_from_files
            config
            ~keeper_name
        with
        | Some snapshot -> snapshot
        | None -> Alcotest.fail "expected tool audit snapshot"
      in
      Alcotest.(check (list string))
        "latest tool_exec row names"
        [ "keeper_tools_list" ]
        snapshot.latest_tool_names;
      Alcotest.(check (option int))
        "tool call count inferred from tool name"
        (Some 1)
        snapshot.latest_tool_call_count;
      Alcotest.(check (option string))
        "decision log source"
        (Some "keeper_decision_log")
        snapshot.tool_audit_source;
      let audit =
        Operator_control_snapshot.cached_tool_audit_json
          ~lightweight:true
          config
          (make_meta keeper_name)
      in
      Alcotest.(check string)
        "lightweight cache reads decision log immediately"
        "keeper_decision_log"
        Yojson.Safe.Util.(audit |> member "tool_audit_source" |> to_string);
      Alcotest.(check int)
        "lightweight cache call count"
        1
        Yojson.Safe.Util.(audit |> member "latest_tool_call_count" |> to_int);
      Alcotest.(check (list string))
        "lightweight latest names"
        [ "keeper_tools_list" ]
        (string_list_member audit "latest_tool_names");
      Alcotest.(check (list string))
        "lightweight recent names"
        [ "keeper_tools_list" ]
        (string_list_member audit "recent_tool_names"))
;;

let () =
  Alcotest.run
    "keeper_tool_audit_snapshot"
    [ ( "tool_exec_decision_rows"
      , [ Alcotest.test_case
            "feed lightweight keeper tool audit"
            `Quick
            test_tool_exec_decision_row_feeds_lightweight_tool_audit
        ] )
    ]
;;
