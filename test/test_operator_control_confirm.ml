open Masc
open Test_operator_control_support

let test_confirm_rejects_expired_token () =
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let pending_dir = Filename.concat (Workspace.masc_dir config) "operator" in
      Workspace_utils.mkdir_p pending_dir;
      let path = Filename.concat pending_dir "pending_confirms.json" in
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
          output_string oc
            (Yojson.Safe.to_string
               (`List
                 [
                   `Assoc
                     [
                       ("confirm_token", `String "expired-token");
                       ("trace_id", `String "ops_expired");
                       ("actor", `String "operator");
                       ("action_type", `String "namespace_pause");
                       ( "target_type"
                       , `String Operator_action_constants.workspace_target_type );
                       ("target_id", `Null);
                       ("payload", `Assoc []);
                       ("delegated_tool", `String "masc_pause");
                       ("created_at", `String "2026-03-06T00:00:00Z");
                       ("expires_at", `String "2026-03-06T00:00:01Z");
                     ];
                 ])));
      let ctx = operator_ctx env sw config "operator" in
      Operator_control.invalidate_snapshot_cache ();
      ignore
        (Operator_control_snapshot_cache.get_or_compute "expired-sentinel"
           ~ttl:60.0 (fun () -> `String "stale"));
      let projection_computes = ref 0 in
      let projection () =
        Dashboard_projection_cache.get_or_compute_snapshot_json ~config
          ~actor:(Some "operator") (fun _ ->
            incr projection_computes;
            `Int !projection_computes)
      in
      ignore (projection ());
      match
        Operator_control.confirm_json ctx
          (`Assoc [ ("actor", `String "operator"); ("confirm_token", `String "expired-token") ])
      with
      | Ok _ -> Alcotest.fail "expected expired confirmation error"
      | Error err ->
          Alcotest.(check string) "expired error" "pending confirmation expired" err;
          Alcotest.(check bool) "expired removal clears operator snapshot cache"
            false
            (Option.is_some
               (Operator_control_snapshot_cache.peek "expired-sentinel"));
          ignore (projection ());
          Alcotest.(check int) "expired removal clears dashboard projection" 2
            !projection_computes)
