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
                (* Async fire-and-forget: fork harness in background,
                   return immediately with run_id for status polling. *)
                let run_dir = swarm_live_run_dir ctx.config run_id in
                Room_utils.mkdir_p run_dir;
                let pid_path = Filename.concat run_dir "harness.pid" in
                let log_path = Filename.concat run_dir "harness.log" in
                let started_path = Filename.concat run_dir "started_at.txt" in
                (try
                  let log_fd =
                    Unix.openfile log_path
                      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644
                  in
                  let dev_null =
                    Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0o000
                  in
                  let pid =
                    Unix.create_process_env "/bin/bash"
                      [| "bash"; script_path |]
                      common_env dev_null log_fd log_fd
                  in
                  Unix.close log_fd;
                  Unix.close dev_null;
                  Out_channel.with_open_text pid_path
                    (fun oc -> Out_channel.output_string oc (string_of_int pid));
                  Out_channel.with_open_text started_path
                    (fun oc ->
                      Out_channel.output_string oc
                        (Printf.sprintf "%.0f" (Unix.gettimeofday ())));
                  ( true,
                    Yojson.Safe.to_string
                      (`Assoc
                        [
                          ("status", `String "started");
                          ("run_id", `String run_id);
                          ("pid", `Int pid);
                          ("worker_count", `Int worker_count);
                          ( "monitor",
                            `String
                              "Use masc_swarm_live_status with this run_id to \
                               check progress." );
                          ("log_path", `String log_path);
                        ]) )
                with exn ->
                  ( false,
                    json_error
                      (Printf.sprintf
                         "Failed to launch async harness: %s"
                         (Printexc.to_string exn)) ))
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

(** Check whether a PID is still running (Unix-only). *)
let pid_is_alive pid =
  try
    Unix.kill pid 0;
    true
  with Unix.Unix_error (Unix.ESRCH, _, _) -> false

(** Read a file's contents, returning None on any error. *)
let read_file_opt path =
  try Some (In_channel.with_open_text path In_channel.input_all)
  with _ -> None

let handle_swarm_live_status (ctx : (_, _) context) args : result =
  let run_id =
    match get_string_opt args "run_id" with
    | Some value -> value
    | None -> "swarm-live"
  in
  match validate_run_id run_id with
  | Error message -> (false, json_error message)
  | Ok run_id ->
      let run_dir = swarm_live_run_dir ctx.config run_id in
      if not (Sys.file_exists run_dir) then
        ( false,
          json_error
            (Printf.sprintf "No swarm-live run found for run_id: %s" run_id) )
      else
        let pid_path = Filename.concat run_dir "harness.pid" in
        let summary_path =
          Filename.concat run_dir "swarm-live-summary.json"
        in
        let doctor_path =
          Filename.concat run_dir "runtime-doctor.json"
        in
        let log_path = Filename.concat run_dir "harness.log" in
        let pid_opt =
          match read_file_opt pid_path with
          | Some s -> int_of_string_opt (String.trim s)
          | None -> None
        in
        let is_running =
          match pid_opt with
          | Some pid -> pid_is_alive pid
          | None -> false
        in
        let has_summary = Sys.file_exists summary_path in
        let has_doctor = Sys.file_exists doctor_path in
        let status =
          if is_running then "running"
          else if has_summary then "completed"
          else if has_doctor then "failed"
          else "unknown"
        in
        let base_fields =
          [
            ("status", `String status);
            ("run_id", `String run_id);
          ]
        in
        let pid_field =
          match pid_opt with
          | Some pid -> [ ("pid", `Int pid) ]
          | None -> []
        in
        let summary_field =
          if has_summary then
            match read_json_file_opt summary_path with
            | Some json -> [ ("summary", json) ]
            | None -> []
          else []
        in
        let doctor_field =
          if has_doctor then
            match read_json_file_opt doctor_path with
            | Some json -> [ ("runtime_doctor", json) ]
            | None -> []
          else []
        in
        let log_tail =
          if Sys.file_exists log_path then
            match read_file_opt log_path with
            | Some content ->
                let lines =
                  String.split_on_char '\n' content
                  |> List.rev
                  |> List.filteri (fun i _ -> i < 20)
                  |> List.rev
                  |> String.concat "\n"
                in
                [ ("log_tail", `String lines) ]
            | None -> []
          else []
        in
        let swarm_field =
          if String.equal status "completed" || String.equal status "failed"
          then
            [ ("swarm",
               Command_plane_v2.swarm_live_json ctx.config ~run_id ()) ]
          else []
        in
        let payload =
          `Assoc
            (base_fields @ pid_field @ summary_field @ doctor_field
            @ log_tail @ swarm_field)
        in
        (true, Yojson.Safe.to_string payload)
