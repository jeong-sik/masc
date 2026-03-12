open Masc_mcp
open Test_operator_control_support

let test_confirm_rejects_expired_token () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let pending_dir = Filename.concat (Room.masc_dir config) "operator" in
      Masc_mcp.Room_utils.mkdir_p pending_dir;
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
                       ("target_type", `String "team_session");
                       ("target_id", `String "session-1");
                       ("payload", `Assoc []);
                       ("delegated_tool", `String "masc_team_session_stop");
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

let test_swarm_run_continue_requires_confirm_then_executes () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      let run_id = "operator-swarm-continue" in
      let operation =
        setup_swarm_run_env config ~owner:"owner-root-node"
          ~worker_one:"alpha-lead-node" ~worker_two:"alpha-two-node" ~run_id
      in
      ignore
        (match
           Command_plane_v2.pause_operation_json config ~actor:"owner"
             (`Assoc [ ("operation_id", `String operation.operation_id) ])
         with
        | Ok _ -> ()
        | Error message -> failwith message);
      let ctx = operator_ctx env sw config "dashboard" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "swarm_run_continue");
              ("target_type", `String "swarm_run");
              ("target_id", `String run_id);
              ("payload", `Assoc [ ("operation_id", `String operation.operation_id) ]);
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check bool) "confirm required" true
        Yojson.Safe.Util.(action_json |> member "confirm_required" |> to_bool);
      Alcotest.(check string) "delegated tool" "swarm_run_continue_chain"
        Yojson.Safe.Util.(action_json |> member "delegated_tool" |> to_string);
      Alcotest.(check string) "preview kind" "continue"
        Yojson.Safe.Util.(action_json |> member "preview" |> member "resolution_kind" |> to_string);
      Alcotest.(check int) "preview step count" 2
        Yojson.Safe.Util.
          (action_json |> member "preview" |> member "tool_chain_preview" |> to_list
         |> List.length);
      let confirm_token =
        Yojson.Safe.Util.(action_json |> member "confirm_token" |> to_string)
      in
      let confirm_json =
        Operator_control.confirm_json ctx
          (`Assoc [ ("actor", `String "dashboard"); ("confirm_token", `String confirm_token) ])
      in
      let confirm_json =
        match confirm_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let delegated_result =
        Yojson.Safe.Util.member "delegated_tool_result" confirm_json
      in
      Alcotest.(check int) "executed steps" 2
        Yojson.Safe.Util.(delegated_result |> member "result" |> to_list |> List.length);
      Alcotest.(check string) "resolution persisted" "continued"
        Yojson.Safe.Util.
          (delegated_result |> member "resolution" |> member "status" |> to_string))

let test_swarm_run_abandon_records_soft_resolution () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      let run_id = "operator-swarm-abandon" in
      let operation =
        setup_swarm_run_env config ~owner:"owner-root-node"
          ~worker_one:"alpha-lead-node" ~worker_two:"alpha-two-node" ~run_id
      in
      let ctx = operator_ctx env sw config "dashboard" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "swarm_run_abandon");
              ("target_type", `String "swarm_run");
              ("target_id", `String run_id);
              ("payload", `Assoc [ ("reason", `String "operator chose to move on") ]);
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check bool) "confirm required" true
        Yojson.Safe.Util.(action_json |> member "confirm_required" |> to_bool);
      let confirm_token =
        Yojson.Safe.Util.(action_json |> member "confirm_token" |> to_string)
      in
      let confirm_json =
        Operator_control.confirm_json ctx
          (`Assoc [ ("actor", `String "dashboard"); ("confirm_token", `String confirm_token) ])
      in
      let confirm_json =
        match confirm_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let delegated_result =
        Yojson.Safe.Util.member "delegated_tool_result" confirm_json
      in
      Alcotest.(check string) "delegated tool" "swarm_run_resolution"
        Yojson.Safe.Util.(delegated_result |> member "delegated_tool" |> to_string);
      Alcotest.(check string) "resolution persisted" "abandoned"
        Yojson.Safe.Util.
          (delegated_result |> member "resolution" |> member "status" |> to_string);
      let operation_status =
        Command_plane_v2.operation_status_json config
          ~operation_id:operation.operation_id ()
        |> Yojson.Safe.Util.member "operations"
        |> Yojson.Safe.Util.index 0
        |> Yojson.Safe.Util.member "operation"
        |> Yojson.Safe.Util.member "status"
        |> Yojson.Safe.Util.to_string
      in
      Alcotest.(check string) "operation not stopped" "active" operation_status)
