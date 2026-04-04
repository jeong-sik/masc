(** Minimal test helpers retained after Tool_team_session pruning (Phase 2).
    Only the functions used by test_dashboard_collaboration_evidence remain. *)

open Masc_mcp

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
