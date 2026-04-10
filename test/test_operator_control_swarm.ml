open Masc_mcp
open Test_operator_control_support

let expect_unsupported_action ~action_type result =
  let expected = Printf.sprintf "unsupported action_type: %s" action_type in
  match result with
  | Ok body ->
      Alcotest.failf "expected error %S, got success: %s" expected
        (Yojson.Safe.to_string body)
  | Error err ->
      if String.equal err expected then ()
      else
        Alcotest.failf "expected error %S, got error %S" expected err

let test_confirm_rejects_expired_token () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let pending_dir = Filename.concat (Room.masc_dir config) "operator" in
      Room_utils.mkdir_p pending_dir;
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
                       ("token", `String "expired-token");
                       ("trace_id", `String "ops_expired");
                       ("actor", `String "operator");
                       ("action_type", `String "team_stop");
                       ("target_type", `String "execution_session");
                       ("target_id", `String "session-1");
                       ("payload", `Assoc []);
                       ("delegated_tool", `String "masc_operator_action");
                       ("created_at", `String "2026-03-06T00:00:00Z");
                       ("expires_at", `String "2026-03-06T00:00:01Z");
                     ];
                 ])));
      let ctx = operator_ctx env sw config "operator" in
      match
        Operator_control.confirm_json ctx
          (`Assoc [ ("actor", `String "operator"); ("confirm_token", `String "expired-token") ])
      with
      | Ok _ -> Alcotest.fail "expected expired confirmation error"
      | Error err ->
          Alcotest.(check string) "expired error" "pending confirmation expired" err)

let test_swarm_run_continue_removed_from_operator_actions () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "dashboard"));
      let ctx = operator_ctx env sw config "dashboard" in
      Operator_control.action_json ctx
        (`Assoc
          [
            ("actor", `String "dashboard");
            ("action_type", `String "swarm_run_continue");
            ("target_type", `String "swarm_run");
            ("target_id", `String "operator-swarm-continue");
            ("payload", `Assoc []);
          ])
      |> expect_unsupported_action ~action_type:"swarm_run_continue")

let test_swarm_run_abandon_removed_from_operator_actions () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "dashboard"));
      let ctx = operator_ctx env sw config "dashboard" in
      Operator_control.action_json ctx
        (`Assoc
          [
            ("actor", `String "dashboard");
            ("action_type", `String "swarm_run_abandon");
            ("target_type", `String "swarm_run");
            ("target_id", `String "operator-swarm-abandon");
            ("payload", `Assoc [ ("reason", `String "operator chose to move on") ]);
          ])
      |> expect_unsupported_action ~action_type:"swarm_run_abandon")

let test_swarm_run_rerun_removed_from_operator_actions () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "dashboard"));
      let ctx = operator_ctx env sw config "dashboard" in
      Operator_control.action_json ctx
        (`Assoc
          [
            ("actor", `String "dashboard");
            ("action_type", `String "swarm_run_rerun");
            ("target_type", `String "swarm_run");
            ("target_id", `String "operator-swarm-rerun");
            ("payload", `Assoc []);
          ])
      |> expect_unsupported_action ~action_type:"swarm_run_rerun")
