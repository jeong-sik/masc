open Tool_command_plane_support
open Tool_command_plane_chain_common

let swarm_live_run_id_of_args args =
  match get_string_opt args "run_id" with
  | Some value -> value
  | None -> "swarm-live"

let swarm_live_worker_count_of_args args =
  match Yojson.Safe.Util.member "worker_count" args with
  | `Int value when value > 0 && value <= 100 -> value
  | `Int _ -> Agent_swarm_live_harness.default_config.worker_count
  | _ -> Agent_swarm_live_harness.default_config.worker_count

let persist_swarm_live_summary config ~run_id result_json =
  let run_dir =
    Filename.concat
      (Filename.concat (Cp_paths.control_plane_root_dir config) "swarm-live")
      (Agent_swarm_live_harness.safe_run_id run_id)
  in
  Room_utils.mkdir_p run_dir;
  Room_utils.write_json_local
    (Filename.concat run_dir "swarm-live-summary.json")
    result_json

let handle_swarm_live_run_with_runner config args ~runner : result =
  let run_id = swarm_live_run_id_of_args args in
  let worker_count = swarm_live_worker_count_of_args args in
  let cfg =
    { Agent_swarm_live_harness.default_config with run_id; worker_count }
  in
  try
    let result_json = runner cfg in
    persist_swarm_live_summary config ~run_id result_json;
    (true, Yojson.Safe.to_string result_json)
  with exn ->
    ( false,
      json_error
        (Printf.sprintf "swarm-live harness failed: %s"
           (Printexc.to_string exn)) )

let handle_swarm_live_run (ctx : (_, _) context) args : result =
  let run_id =
    match get_string_opt args "run_id" with
    | Some value -> value
    | None -> "swarm-live"
  in
  match validate_run_id run_id with
  | Error message -> (false, json_error message)
  | Ok run_id ->
      let worker_count =
        match Yojson.Safe.Util.member "worker_count" args with
        | `Int value when value > 0 && value <= 100 -> value
        | _ -> Agent_swarm_live_harness.default_config.worker_count
      in
      let base_url =
        try Ok (Env_config.masc_http_base_url ())
        with Failure message ->
          Error
            (Printf.sprintf
               "swarm-live harness requires MASC_HTTP_BASE_URL in server runtime: %s"
               message)
      in
      (match base_url with
      | Error message -> (false, json_error message)
      | Ok base_url -> (
          match resolve_swarm_live_script () with
          | None ->
              ( false,
                json_error
                  "Unable to locate scripts/harness/workload/agent_swarm_live.sh relative to the running binary." )
          | Some script_path ->
              let preflight_timeout_sec =
                env_int_or ~name:"MASC_SWARM_LIVE_PREFLIGHT_TIMEOUT_SEC"
                  ~default:30
              in
              let allow_sync_self =
                env_bool_or ~name:"MASC_SWARM_LIVE_ALLOW_SYNC_SELF"
                  ~default:false
              in
              let harness_timeout_sec =
                env_int_or ~name:"MASC_SWARM_LIVE_TIMEOUT_SEC" ~default:180
              in
              let http_timeout_sec =
                env_int_or ~name:"MASC_SWARM_LIVE_HTTP_TIMEOUT_SEC" ~default:10
              in
              let provider_smoke_timeout_sec =
                env_int_or ~name:"MASC_SWARM_LIVE_PROVIDER_SMOKE_TIMEOUT_SEC"
                  ~default:15
              in
              let common_env =
                merge_env_overrides
                  [
                    ("RUN_ID", run_id);
                    ("WORKER_COUNT", string_of_int worker_count);
                    ("BASE_PATH", ctx.config.base_path);
                    ("MASC_URL", base_url);
                    ("MCP_URL", base_url ^ "/mcp");
                    ("START_SERVER", "0");
                    ("HARNESS_TIMEOUT_SEC", string_of_int harness_timeout_sec);
                    ("HTTP_TIMEOUT_SEC", string_of_int http_timeout_sec);
                    ( "PROVIDER_SMOKE_TIMEOUT_SEC",
                      string_of_int provider_smoke_timeout_sec );
                  ]
              in
              let preflight_proc =
                run_process_with_timeout ~clock_opt:ctx.clock
                  ~timeout_sec:preflight_timeout_sec ~prog:"/bin/bash"
                  ~argv:[ "bash"; script_path ]
                  ~env:
                    (merge_env_overrides
                       [
                         ("RUN_ID", run_id);
                         ("WORKER_COUNT", string_of_int worker_count);
                         ("BASE_PATH", ctx.config.base_path);
                         ("MASC_URL", base_url);
                         ("MCP_URL", base_url ^ "/mcp");
                         ("START_SERVER", "0");
                         ("PREFLIGHT_ONLY", "1");
                         ("HARNESS_TIMEOUT_SEC", string_of_int harness_timeout_sec);
                         ("HTTP_TIMEOUT_SEC", string_of_int http_timeout_sec);
                         ( "PROVIDER_SMOKE_TIMEOUT_SEC",
                           string_of_int provider_smoke_timeout_sec );
                       ])
              in
              let runtime_doctor =
                read_json_file_opt
                  (swarm_live_runtime_doctor_path ctx.config run_id)
              in
              if preflight_proc.exit_code <> 0 then
                ( false,
                  swarm_live_error_payload ctx.config ~run_id
                    ~message:
                      (swarm_live_error_message ?runtime_doctor
                         ~default:
                           (Printf.sprintf
                              "swarm-live preflight failed with exit %d. stderr: %s"
                             preflight_proc.exit_code
                             (tail_text preflight_proc.stderr))
                         ())
                    ~proc:preflight_proc ())
              else if not allow_sync_self then
                ( false,
                  json_error_fields
                    "swarm-live synchronous self-execution is disabled to avoid MCP server reentrancy hangs; run scripts/harness_agent_swarm_live.sh externally or enable MASC_SWARM_LIVE_ALLOW_SYNC_SELF=1."
                    [
                      assoc_field "run_id" (`String run_id);
                      assoc_field "runtime_blocker"
                        (`String "sync_self_unsupported");
                      assoc_field "detail"
                        (`String
                           "Preflight succeeded, but the live harness re-enters the same MCP server over HTTP and can deadlock when executed synchronously inside tools/call.");
                      assoc_field "runtime_doctor_path"
                        (`String
                           (swarm_live_runtime_doctor_path ctx.config run_id));
                      assoc_field "summary_path"
                        (`String (swarm_live_summary_path ctx.config run_id));
                      assoc_field "swarm"
                        (Command_plane_v2.swarm_live_json ctx.config ~run_id ());
                    ] )
              else
                let proc =
                  run_process_with_timeout ~clock_opt:ctx.clock
                    ~timeout_sec:harness_timeout_sec ~prog:"/bin/bash"
                    ~argv:[ "bash"; script_path ] ~env:common_env
                in
                let run_dir = swarm_live_run_dir ctx.config run_id in
                let artifact_exists =
                  Sys.file_exists (Filename.concat run_dir "swarm-live-summary.json")
                  || Sys.file_exists (Filename.concat run_dir "runtime-doctor.json")
                in
                let runtime_doctor =
                  read_json_file_opt
                    (swarm_live_runtime_doctor_path ctx.config run_id)
                in
                if proc.exit_code <> 0 then
                  ( false,
                    swarm_live_error_payload ctx.config ~run_id
                      ~message:
                        (swarm_live_error_message ?runtime_doctor
                           ~default:
                             (Printf.sprintf
                                "swarm-live harness exited with %d. stderr: %s"
                                proc.exit_code (tail_text proc.stderr))
                           ())
                      ~proc:proc ())
                else if not artifact_exists then
                  ( false,
                    swarm_live_error_payload ctx.config ~run_id
                      ~message:
                        "swarm-live harness completed without producing readable summary or runtime doctor artifacts."
                      ~proc:proc ())
                else
                  let detailed_json =
                    Command_plane_v2.swarm_live_json ctx.config ~run_id ()
                  in
                  let payload =
                    json_with_process_metadata detailed_json proc
                  in
                  (true, Yojson.Safe.to_string payload)))
