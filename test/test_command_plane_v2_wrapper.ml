open Masc_mcp
open Test_command_plane_v2_support

let test_swarm_live_run_with_runner_persists_summary () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      let ok, body =
        Tool_command_plane.handle_swarm_live_run_with_runner config
          (`Assoc
            [
              ("run_id", `String "swarm-live-wrapper");
              ("worker_count", `Int 3);
            ])
          ~runner:(fun cfg ->
            `Assoc
              [
                ("run_id", `String cfg.Agent_swarm_live_harness.run_id);
                ("worker_count", `Int cfg.worker_count);
              ])
      in
      Alcotest.(check bool) "wrapper success" true ok;
      let json = Yojson.Safe.from_string body in
      Alcotest.(check string) "run_id preserved" "swarm-live-wrapper"
        Yojson.Safe.Util.(json |> member "run_id" |> to_string);
      Alcotest.(check int) "worker_count preserved" 3
        Yojson.Safe.Util.(json |> member "worker_count" |> to_int);
      let summary_path =
        Filename.concat
          (Filename.concat
             (Filename.concat base_dir ".masc/control-plane/swarm-live")
             (Agent_swarm_live_harness.safe_run_id "swarm-live-wrapper"))
          "swarm-live-summary.json"
      in
      Alcotest.(check bool) "summary persisted" true (Sys.file_exists summary_path);
      let persisted = Yojson.Safe.from_file summary_path in
      Alcotest.(check string) "persisted run_id" "swarm-live-wrapper"
        Yojson.Safe.Util.(persisted |> member "run_id" |> to_string))

let test_swarm_live_run_with_runner_returns_error_on_exception () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      let ok, body =
        Tool_command_plane.handle_swarm_live_run_with_runner config
          (`Assoc [ ("run_id", `String "failing-run") ])
          ~runner:(fun _ -> failwith "runner exploded")
      in
      Alcotest.(check bool) "wrapper failure" false ok;
      let json = Yojson.Safe.from_string body in
      Alcotest.(check string) "status error" "error"
        Yojson.Safe.Util.(json |> member "status" |> to_string);
      Alcotest.(check bool) "error mentions runner" true
        (String.length Yojson.Safe.Util.(json |> member "message" |> to_string) > 0))

let test_swarm_live_run_rejects_invalid_run_id () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      let ctx : _ Tool_command_plane.context =
        {
          config;
          agent_name = "tester";
          sw = None;
          clock = None;
          net = None;
          mcp_state = None;
          mcp_session_id = None;
          auth_token = None;
        }
      in
      let ok, body =
        Tool_command_plane.handle_swarm_live_run ctx
          (`Assoc [ ("run_id", `String "bad run id") ])
      in
      Alcotest.(check bool) "invalid run id fails" false ok;
      let json = Yojson.Safe.from_string body in
      Alcotest.(check string) "status error" "error"
        Yojson.Safe.Util.(json |> member "status" |> to_string);
      Alcotest.(check string) "invalid run id message"
        "invalid chain run_id: only [A-Za-z0-9_-] are allowed"
        Yojson.Safe.Util.(json |> member "message" |> to_string))

let test_swarm_live_run_reports_sync_self_unsupported_after_preflight () =
  (* When allow_sync_self=false the harness is forked asynchronously
     after a successful preflight, returning (true, status:"started"). *)
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "tester"));
      let script_path = Filename.concat base_dir "fake_swarm_live.sh" in
      write_text_file script_path
        "#!/usr/bin/env bash\nset -euo pipefail\nif [ \"${PREFLIGHT_ONLY:-0}\" = \"1\" ]; then\n  exit 0\nfi\nexit 99\n";
      Unix.chmod script_path 0o755;
      let ctx : _ Tool_command_plane.context =
        {
          config;
          agent_name = "tester";
          sw = None;
          clock = None;
          net = None;
          mcp_state = None;
          mcp_session_id = None;
          auth_token = None;
        }
      in
      with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" (fun () ->
        with_env "MASC_SWARM_LIVE_SCRIPT" script_path (fun () ->
          with_env "MASC_SWARM_LIVE_ALLOW_SYNC_SELF" "0" (fun () ->
            let ok, body =
              Tool_command_plane.handle_swarm_live_run ctx
                (`Assoc
                  [
                    ("run_id", `String "sync-self-blocked");
                    ("worker_count", `Int 1);
                  ])
            in
            Alcotest.(check bool) "async fork ok" true ok;
            let json = Yojson.Safe.from_string body in
            Alcotest.(check string) "status started" "started"
              Yojson.Safe.Util.(json |> member "status" |> to_string);
            Alcotest.(check string) "run_id echoed" "sync-self-blocked"
              Yojson.Safe.Util.(json |> member "run_id" |> to_string)))))

