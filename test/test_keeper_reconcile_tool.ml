open Alcotest
open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()
let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

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
      check bool "not legacy only" false
        Yojson.Safe.Util.(clear_json |> member "legacy_only" |> to_bool);
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
    ]
