open Masc_mcp
module Oas = Agent_sdk

let temp_dir () =
  let dir = Filename.temp_file "test_tool_team_session_" "" in
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
  match Tool_team_session.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

let result_field json = Yojson.Safe.Util.member "result" json

let unwrap_ok = function
  | Ok v -> v
  | Error e -> failwith e

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
  | Some v -> Unix.putenv name v
  | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let get_session_id response_json =
  response_json |> result_field |> Yojson.Safe.Util.member "session_id"
  |> Yojson.Safe.Util.to_string

let session_status_of_body body =
  let json = parse_json_exn body in
  let result = result_field json in
  result |> Yojson.Safe.Util.member "session" |> Yojson.Safe.Util.member "status"
  |> Yojson.Safe.Util.to_string

let done_delta_total_of_status_body body =
  let json = parse_json_exn body in
  let result = result_field json in
  result |> Yojson.Safe.Util.member "summary"
  |> Yojson.Safe.Util.member "done_delta_total"
  |> Yojson.Safe.Util.to_int

let events_count_of_body body =
  let json = parse_json_exn body in
  let result = result_field json in
  result |> Yojson.Safe.Util.member "count" |> Yojson.Safe.Util.to_int

let events_list_of_body body =
  let json = parse_json_exn body in
  let result = result_field json in
  result |> Yojson.Safe.Util.member "events" |> Yojson.Safe.Util.to_list

let add_task_id config ~title =
  ignore (Room.add_task config ~title ~priority:1 ~description:"");
  let backlog = Room.read_backlog config in
  match List.rev backlog.tasks with
  | t :: _ -> t.id
  | [] -> failwith "failed to create task"

let with_eio f =
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Process_eio.reset_for_testing ();
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.fs env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun test_env_sw ->
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw:test_env_sw
    (fun () ->
      Fun.protect
        ~finally:(fun () ->
          Process_eio.reset_for_testing ();
          Time_compat.clear_clock ();
          Eio_guard.disable ())
        (fun () -> f env))

let transition_task_ok config ~agent_name ~task_id ~action =
  match Room.transition_task_r config ~agent_name ~task_id ~action () with
  | Ok _ -> ()
  | Error e -> failwith (Types.masc_error_to_string e)

let unit_update_exn config ~actor args =
  ignore (unwrap_ok (Command_plane_v2.unit_update_json config ~actor args))

let wait_until_terminal ctx session_id =
  let rec loop attempts =
    if attempts <= 0 then
      failwith "team session did not reach terminal state in time"
    else
      let ok, body =
        dispatch_exn ctx ~name:"masc_team_session_status"
          ~args:(`Assoc [ ("session_id", `String session_id) ])
      in
      if not ok then
        failwith "status check failed while waiting for terminal state"
      else
        match session_status_of_body body with
        | "running" ->
            Eio.Time.sleep ctx.clock 0.1;
            loop (attempts - 1)
        | status -> status
  in
  loop 200

let oas_trace_session_root base_dir =
  Worker_container.oas_trace_session_root ~base_path:base_dir

let oas_trace_file_path base_dir ~session_id ~worker_name =
  Filename.concat
    (Filename.concat
       (Filename.concat
          (Filename.concat (oas_trace_session_root base_dir) "sessions")
          session_id)
       "raw-traces")
    (worker_name ^ ".jsonl")

let rec start_session_exn ctx ~goal =
  start_session_custom_exn ctx ~goal ~min_agents:1 ~agents:[]
    ~operation_id:None

and start_session_custom_exn ctx ~goal ~min_agents ~agents ~operation_id =
  let agent_json = `List (List.map (fun a -> `String a) agents) in
  let args =
    [
      ("goal", `String goal);
      ("duration_seconds", `Int 90);
      ("checkpoint_interval_sec", `Int 10);
      ("min_agents", `Int min_agents);
      ("orchestration_mode", `String "assist");
      ("communication_mode", `String "hybrid");
      ("model_cascade", `List [ `String "glm:auto" ]);
      ("fallback_policy", `String "cascade_then_task");
      ("instruction_profile", `String "strict");
      ("alert_channel", `String "both");
      ("report_formats", `List [ `String "markdown"; `String "json" ]);
      ("agents", agent_json);
    ]
    @
    match operation_id with
    | Some value -> [ ("operation_id", `String value) ]
    | None -> []
  in
  let start_ok, start_body =
    dispatch_exn ctx ~name:"masc_team_session_start"
      ~args:(`Assoc args)
  in
  Alcotest.(check bool) "start ok" true start_ok;
  parse_json_exn start_body

let make_manual_session config ~goal ~created_by ~agent_names ~min_agents
    ~checkpoint_interval_sec ~started_at ~planned_end_at ~fallback_policy
    ~model_cascade =
  let session_id = Team_session_store.make_session_id () in
  Team_session_store.ensure_session_dirs config session_id;
  let session : Team_session_types.session =
    {
      session_id;
      goal;
      created_by;
      origin_kind =
        Team_session_types.infer_session_origin_kind
          ~created_by ~orchestration_mode:Team_session_types.Assist;
      room_id = "default";
      operation_id = None;
      status = Team_session_types.Running;
      duration_seconds = int_of_float (max 60.0 (planned_end_at -. started_at));
      execution_scope = Team_session_types.Limited_code_change;
      checkpoint_interval_sec;
      min_agents;
      orchestration_mode = Team_session_types.Assist;
      communication_mode = Team_session_types.Comm_broadcast;
      scale_profile = Team_session_types.Scale_standard;
      control_profile = Team_session_types.Control_flat;
      model_cascade;
      fallback_policy;
      instruction_profile = Team_session_types.Profile_strict;
      alert_channel = Team_session_types.Alert_both;
      auto_resume = true;
      report_formats = [ Team_session_types.Markdown; Team_session_types.Json ];
      turn_count = 0;
      agent_names;
      planned_workers = [];
      broadcast_count = 0;
      portal_count = 0;
      cascade_attempted = 0;
      cascade_success = 0;
      cascade_failed = 0;
      fallback_task_created = 0;
      min_agents_violation_streak = 0;
      policy_violations = [];
      baseline_done_counts = [];
      final_done_delta_total = None;
      final_done_delta_by_agent = None;
      started_at;
      planned_end_at;
      stopped_at = None;
      last_checkpoint_at = Some started_at;
      last_event_at = Some started_at;
      last_turn_at = None;
      stop_reason = None;
      generated_report = false;
      delivery_contract = None;
      latest_delivery_verdict = None;
      artifacts_dir = Team_session_store.session_dir config session_id;
      created_at_iso = Types.now_iso ();
      updated_at_iso = Types.now_iso ();
    }
  in
  Team_session_store.save_session config session;
  session

let raw_trace_run_ref_to_json (run_ref : Oas.Raw_trace.run_ref) =
  `Assoc
    [
      ("worker_run_id", `String run_ref.worker_run_id);
      ("start_seq", `Int run_ref.start_seq);
      ("end_seq", `Int run_ref.end_seq);
      ("agent_name", `String run_ref.agent_name);
      ( "session_id",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          run_ref.session_id );
    ]

let write_worker_run_raw_trace_exn config ~session_id ~worker_run_id
    ~worker_name =
  let base_dir =
    Team_session_store.session_dir config session_id
    |> Filename.dirname |> Filename.dirname |> Filename.dirname
  in
  let raw_trace_path = oas_trace_file_path base_dir ~session_id ~worker_name in
  let raw_worker_run_id = "wr-fixture-raw-1" in
  let lines =
    [
      `Assoc
        [
          ("trace_version", `Int 1);
          ("worker_run_id", `String raw_worker_run_id);
          ("seq", `Int 1);
          ("ts", `Float 1.0);
          ("agent_name", `String worker_name);
          ("session_id", `String session_id);
          ("record_type", `String "run_started");
          ("prompt", `String "inspect calc.py and fix it");
        ];
      `Assoc
        [
          ("trace_version", `Int 1);
          ("worker_run_id", `String raw_worker_run_id);
          ("seq", `Int 2);
          ("ts", `Float 2.0);
          ("agent_name", `String worker_name);
          ("session_id", `String session_id);
          ("record_type", `String "assistant_block");
          ("block_index", `Int 0);
          ("block_kind", `String "tool_use");
          ( "assistant_block",
            `Assoc
              [
                ("type", `String "tool_use");
                ("id", `String "toolu_read");
                ("name", `String "file_read");
                ( "input",
                  `Assoc
                    [
                      ("path", `String "test/fixtures/coding_worker_repo_smoke/calc.py");
                    ] );
              ] );
        ];
      `Assoc
        [
          ("trace_version", `Int 1);
          ("worker_run_id", `String raw_worker_run_id);
          ("seq", `Int 3);
          ("ts", `Float 3.0);
          ("agent_name", `String worker_name);
          ("session_id", `String session_id);
          ("record_type", `String "tool_execution_started");
          ("tool_use_id", `String "toolu_read");
          ("tool_name", `String "file_read");
          ( "tool_input",
            `Assoc
              [
                ("path", `String "test/fixtures/coding_worker_repo_smoke/calc.py");
              ] );
        ];
      `Assoc
        [
          ("trace_version", `Int 1);
          ("worker_run_id", `String raw_worker_run_id);
          ("seq", `Int 4);
          ("ts", `Float 4.0);
          ("agent_name", `String worker_name);
          ("session_id", `String session_id);
          ("record_type", `String "tool_execution_finished");
          ("tool_use_id", `String "toolu_read");
          ("tool_name", `String "file_read");
          ("tool_result", `String "def add_two_and_three():\n    return 4");
          ("tool_error", `Bool false);
        ];
      `Assoc
        [
          ("trace_version", `Int 1);
          ("worker_run_id", `String raw_worker_run_id);
          ("seq", `Int 5);
          ("ts", `Float 5.0);
          ("agent_name", `String worker_name);
          ("session_id", `String session_id);
          ("record_type", `String "tool_execution_started");
          ("tool_use_id", `String "toolu_write");
          ("tool_name", `String "file_write");
          ( "tool_input",
            `Assoc
              [
                ("path", `String "test/fixtures/coding_worker_repo_smoke/calc.py");
                ("content", `String "def add_two_and_three():\n    return 5\n");
              ] );
        ];
      `Assoc
        [
          ("trace_version", `Int 1);
          ("worker_run_id", `String raw_worker_run_id);
          ("seq", `Int 6);
          ("ts", `Float 6.0);
          ("agent_name", `String worker_name);
          ("session_id", `String session_id);
          ("record_type", `String "tool_execution_finished");
          ("tool_use_id", `String "toolu_write");
          ("tool_name", `String "file_write");
          ("tool_result", `String "Written 37 bytes");
          ("tool_error", `Bool false);
        ];
      `Assoc
        [
          ("trace_version", `Int 1);
          ("worker_run_id", `String raw_worker_run_id);
          ("seq", `Int 7);
          ("ts", `Float 7.0);
          ("agent_name", `String worker_name);
          ("session_id", `String session_id);
          ("record_type", `String "tool_execution_started");
          ("tool_use_id", `String "toolu_shell");
          ("tool_name", `String "shell_exec");
          ( "tool_input",
            `Assoc
              [
                ( "command",
                  `String "python3 test/fixtures/coding_worker_repo_smoke/check.py" );
              ] );
        ];
      `Assoc
        [
          ("trace_version", `Int 1);
          ("worker_run_id", `String raw_worker_run_id);
          ("seq", `Int 8);
          ("ts", `Float 8.0);
          ("agent_name", `String worker_name);
          ("session_id", `String session_id);
          ("record_type", `String "tool_execution_finished");
          ("tool_use_id", `String "toolu_shell");
          ("tool_name", `String "shell_exec");
          ("tool_result", `String "PASS\n");
          ("tool_error", `Bool false);
        ];
      `Assoc
        [
          ("trace_version", `Int 1);
          ("worker_run_id", `String raw_worker_run_id);
          ("seq", `Int 9);
          ("ts", `Float 9.0);
          ("agent_name", `String worker_name);
          ("session_id", `String session_id);
          ("record_type", `String "run_finished");
          ("final_text", `String "Patched calc.py and verification passed.");
          ("stop_reason", `String "end_turn");
        ];
    ]
  in
  Team_session_store.write_text_file raw_trace_path
    (String.concat "\n" (List.map Yojson.Safe.to_string lines) ^ "\n");
  Team_session_store.save_worker_run_meta_json config session_id worker_run_id
    (`Assoc
      [
        ("worker_run_id", `String worker_run_id);
        ("worker_name", `String worker_name);
        ("mode", `String "delegate");
        ("wait_mode", `String "blocking");
        ("trace_capability", `String "raw");
        ( "trace_ref",
          `Assoc
            [
              ("worker_run_id", `String raw_worker_run_id);
              ("start_seq", `Int 1);
              ("end_seq", `Int 9);
              ("agent_name", `String worker_name);
              ("session_id", `String session_id);
            ] );
      ]);
  {
    Oas.Raw_trace.worker_run_id = raw_worker_run_id;
    path = raw_trace_path;
    start_seq = 1;
    end_seq = 9;
    agent_name = worker_name;
    session_id = Some session_id;
  }
