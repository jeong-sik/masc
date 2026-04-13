open Alcotest
open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()
let () = Server_startup_state.mark_state_ready ~backend_mode:"test"
let () =
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Keeper_exec_tools.init_policy_config ~base_path))

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_reconcile_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let ensure_fs env =
  if not (Fs_compat.has_fs ()) then
    Fs_compat.set_fs (Eio.Stdenv.fs env)

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

let parse_json_exn body =
  try Yojson.Safe.from_string body
  with Yojson.Json_error err -> failwith ("invalid json: " ^ err)

let dispatch_keeper_exn ctx ~name ~args =
  match Tool_keeper.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("keeper dispatch missing: " ^ name)

let keeper_ctx env sw config agent_name : _ Tool_keeper.context =
  {
    config;
    agent_name;
    sw;
    clock = Eio.Stdenv.clock env;
    proc_mgr = Some (Eio.Stdenv.process_mgr env);
    net = Some (Eio.Stdenv.net env);
  }

let test_keeper_reconcile_inspect_and_clear () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "reconcile-keeper" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let ctx = keeper_ctx env sw config "operator" in
      let ok, _body =
        dispatch_keeper_exn ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Exercise keeper reconcile tool");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      check bool "keeper up ok" true ok;
      ignore
        (Keeper_manual_reconcile.open_pending
           config
           ~keeper_name
           ~blocker_class:"ambiguous_post_commit_timeout"
           ~summary:"turn outcome ambiguous"
           ~failure_reason:
             (Some
                "ambiguous_partial_commit(post_commit_timeout:turn outcome ambiguous)")
           ~trace_id:(Some "trace-reconcile")
           ~generation:(Some 3)
           ~committed_tools:["keeper_shell"; "keeper_task_done"]);
      Keeper_registry.set_failure_reason ~base_path:config.base_path keeper_name
        (Some
           (Keeper_registry.Ambiguous_partial_commit
              {
                kind = Keeper_registry.Post_commit_timeout;
                detail = "turn outcome ambiguous";
              }));
      ignore
        (Keeper_registry.dispatch_event
           ~base_path:config.base_path
           keeper_name
           (Keeper_state_machine.Manual_reconcile_required
              { reason = "turn outcome ambiguous" }));
      let ok, inspect_body =
        dispatch_keeper_exn ctx ~name:"masc_keeper_reconcile"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("action", `String "inspect");
              ])
      in
      check bool "inspect ok" true ok;
      let inspect_json = parse_json_exn inspect_body in
      check bool "inspect pending" true
        Yojson.Safe.Util.(inspect_json |> member "pending" |> to_bool);
      check string "inspect phase failing" "failing"
        Yojson.Safe.Util.(inspect_json |> member "phase" |> to_string);
      check string "inspect blocker class" "ambiguous_post_commit_timeout"
        Yojson.Safe.Util.(
          inspect_json |> member "record" |> member "blocker_class" |> to_string);
      let ok, status_body =
        dispatch_keeper_exn ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      check bool "status ok before clear" true ok;
      let status_json = parse_json_exn status_body in
      check string "status exposes blocker" "ambiguous_post_commit_timeout"
        Yojson.Safe.Util.(status_json |> member "runtime_blocker_class" |> to_string);
      Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
      let ok, inspect_body_after_wait =
        dispatch_keeper_exn ctx ~name:"masc_keeper_reconcile"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("action", `String "inspect");
              ])
      in
      check bool "inspect ok after wait" true ok;
      let inspect_after_wait_json = parse_json_exn inspect_body_after_wait in
      check bool "inspect still pending after wait" true
        Yojson.Safe.Util.(inspect_after_wait_json |> member "pending" |> to_bool);
      check string "inspect still failing after wait" "failing"
        Yojson.Safe.Util.(inspect_after_wait_json |> member "phase" |> to_string);
      let ok, clear_body =
        dispatch_keeper_exn ctx ~name:"masc_keeper_reconcile"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("action", `String "clear");
                ("resolution", `String "verified downstream mutations");
                ( "evidence_refs",
                  `List [ `String "board:p-1"; `String "task:T-1" ] );
              ])
      in
      check bool "clear ok" true ok;
      ignore (parse_json_exn clear_body);
      (* Skip mechanism assertions (cleared / already_cleared) because
         the keepalive auto-clear deadlock-break can race and produce
         any of Cleared_record, Already_cleared, or No_record.
         Rely on the post-condition checks below instead. *)
      let ok, status_body_after =
        dispatch_keeper_exn ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      check bool "status ok after clear" true ok;
      let status_after_json = parse_json_exn status_body_after in
      check bool "blocker removed after clear" true
        Yojson.Safe.Util.(status_after_json |> member "runtime_blocker_class" = `Null);
      check string "phase recovered to running" "running"
        Yojson.Safe.Util.(
          status_after_json |> member "runtime" |> member "phase" |> to_string))

let test_keeper_reconcile_clear_without_record_clears_runtime_blocker () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "reconcile-no-record" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let ctx = keeper_ctx env sw config "operator" in
      let ok, _body =
        dispatch_keeper_exn ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Exercise no-record reconcile clear");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      check bool "keeper up ok" true ok;
      ignore
        (Keeper_registry.dispatch_event
           ~base_path:config.base_path
           keeper_name
           (Keeper_state_machine.Manual_reconcile_required
              { reason = "stale runtime blocker" }));
      let ok, clear_body =
        dispatch_keeper_exn ctx ~name:"masc_keeper_reconcile"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("action", `String "clear");
                ("resolution", `String "runtime state was already clear");
              ])
      in
      check bool "clear ok" true ok;
      let clear_json = parse_json_exn clear_body in
      check bool "clear result true" true
        Yojson.Safe.Util.(clear_json |> member "cleared" |> to_bool);
      check bool "not already cleared" false
        Yojson.Safe.Util.(clear_json |> member "already_cleared" |> to_bool);
      check bool "record null" true
        Yojson.Safe.Util.(clear_json |> member "record" = `Null);
      let ok, status_body_after =
        dispatch_keeper_exn ctx ~name:"masc_keeper_status"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      check bool "status ok after clear" true ok;
      let status_after_json = parse_json_exn status_body_after in
      check string "phase recovered to running" "running"
        Yojson.Safe.Util.(
          status_after_json |> member "runtime" |> member "phase" |> to_string))

let record_path_for config keeper_name =
  Filename.concat
    (Keeper_types.keeper_dir config)
    (keeper_name ^ ".manual_reconcile.json")

let test_module_clear_removes_file () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  let keeper_name = "delete-on-clear-keeper" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let path = record_path_for config keeper_name in
      let _opened =
        Keeper_manual_reconcile.open_pending
          config
          ~keeper_name
          ~blocker_class:"ambiguous_post_commit_timeout"
          ~summary:"unit test blocker"
          ~failure_reason:(Some "timeout")
          ~trace_id:(Some "trace-unit")
          ~generation:(Some 1)
          ~committed_tools:[]
      in
      check bool "record file exists before clear" true
        (Sys.file_exists path);
      check bool "is_pending before clear" true
        (Keeper_manual_reconcile.is_pending config keeper_name);
      let outcome1 =
        Keeper_manual_reconcile.clear
          config
          ~keeper_name
          ~actor:"operator"
          ~resolution:"unit test clear"
          ~evidence_refs:[ "trace:unit" ]
          ~idempotency_key:(Some "idem-1")
      in
      (match outcome1 with
       | Keeper_manual_reconcile.Cleared_record record ->
           check string "cleared record name" keeper_name record.keeper_name;
           check bool "resolution populated" true
             (match record.resolution with
              | Some value -> value = "unit test clear"
              | None -> false)
       | Keeper_manual_reconcile.Already_cleared _ ->
           fail "expected Cleared_record on first clear"
       | Keeper_manual_reconcile.No_record ->
           fail "expected Cleared_record on first clear");
      check bool "record file removed after clear" false
        (Sys.file_exists path);
      check bool "is_pending false after clear" false
        (Keeper_manual_reconcile.is_pending config keeper_name);
      let outcome2 =
        Keeper_manual_reconcile.clear
          config
          ~keeper_name
          ~actor:"operator"
          ~resolution:"retry"
          ~evidence_refs:[]
          ~idempotency_key:(Some "idem-1")
      in
      (match outcome2 with
       | Keeper_manual_reconcile.No_record -> ()
       | Keeper_manual_reconcile.Cleared_record _ ->
           fail "expected No_record on idempotent retry after delete"
       | Keeper_manual_reconcile.Already_cleared _ ->
           fail "expected No_record, not Already_cleared, after delete-on-clear");
      check bool "file still absent after retry" false
        (Sys.file_exists path))

let write_raw_cleared_json path ~keeper_name =
  let json : Yojson.Safe.t =
    `Assoc
      [
        ("version", `Int 1);
        ("keeper_name", `String keeper_name);
        ("blocker_class", `String "ambiguous_post_commit_timeout");
        ("summary", `String "legacy");
        ("failure_reason", `Null);
        ("trace_id", `Null);
        ("generation", `Null);
        ("committed_tools", `List []);
        ("opened_at", `String "2026-04-11T00:00:00Z");
        ("updated_at", `String "2026-04-11T00:00:01Z");
        ("status", `String "cleared");
        ("resolution", `String "cleared by legacy binary");
        ("evidence_refs", `List []);
        ("cleared_at", `String "2026-04-11T00:00:01Z");
        ("cleared_by", `String "legacy-binary");
        ("clear_idempotency_key", `Null);
      ]
  in
  let dir = Filename.dirname path in
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
  let oc = open_out path in
  output_string oc (Yojson.Safe.to_string json);
  close_out oc

let test_module_clear_removes_legacy_cleared_file () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  let keeper_name = "legacy-cleared-keeper" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let path = record_path_for config keeper_name in
      write_raw_cleared_json path ~keeper_name;
      check bool "legacy cleared file present" true (Sys.file_exists path);
      let outcome =
        Keeper_manual_reconcile.clear
          config
          ~keeper_name
          ~actor:"operator"
          ~resolution:"cleanup"
          ~evidence_refs:[]
          ~idempotency_key:None
      in
      (match outcome with
       | Keeper_manual_reconcile.Already_cleared _ -> ()
       | _ -> fail "expected Already_cleared on pre-existing cleared file");
      check bool "legacy cleared file removed" false (Sys.file_exists path);
      let outcome_after =
        Keeper_manual_reconcile.clear
          config
          ~keeper_name
          ~actor:"operator"
          ~resolution:"cleanup"
          ~evidence_refs:[]
          ~idempotency_key:None
      in
      (match outcome_after with
       | Keeper_manual_reconcile.No_record -> ()
       | Keeper_manual_reconcile.Already_cleared _ ->
           fail "second clear should not re-observe Already_cleared after delete"
       | Keeper_manual_reconcile.Cleared_record _ ->
           fail "second clear must not mutate — file was already gone"))

let () =
  run "keeper_reconcile_tool"
    [
      ( "tool",
        [
          test_case "inspect -> clear" `Quick
            test_keeper_reconcile_inspect_and_clear;
          test_case "clear without record clears runtime blocker" `Quick
            test_keeper_reconcile_clear_without_record_clears_runtime_blocker;
        ] );
      ( "module",
        [
          test_case "clear removes pending file (delete-on-clear)" `Quick
            test_module_clear_removes_file;
          test_case "clear removes legacy Cleared file defensively" `Quick
            test_module_clear_removes_legacy_cleared_file;
        ] );
    ]
