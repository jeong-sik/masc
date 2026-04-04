(** Swarm State Persistence tests (Gap B + Gap C).

    - checkpoint_of_yojson roundtrip
    - load_latest_checkpoint (empty / populated)
    - event_entry_of_yojson roundtrip
    - read_recent_events (empty / max_count cap)
*)

open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_swarm_persist_" "" in
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

let with_storage_type value f =
  let saved = Sys.getenv_opt "MASC_STORAGE_TYPE" in
  Unix.putenv "MASC_STORAGE_TYPE" value;
  Fun.protect ~finally:(fun () ->
      match saved with
      | Some prior -> Unix.putenv "MASC_STORAGE_TYPE" prior
      | None -> Unix.putenv "MASC_STORAGE_TYPE" "")
    f

(* ── Gap B: checkpoint roundtrip ─────────────────────────────── *)

let sample_checkpoint : Team_session_types.checkpoint =
  {
    ts = 1700000000.0;
    ts_iso = "2023-11-14T22:13:20.000Z";
    status = Team_session_types.Running;
    elapsed_sec = 120;
    remaining_sec = 480;
    progress_pct = 25.0;
    done_delta_total = 3;
    done_delta_by_agent = [ ("alice", 2); ("bob", 1) ];
    active_agents = [ "alice"; "bob" ];
  }

let test_checkpoint_roundtrip () =
  let json = Team_session_types.checkpoint_to_yojson sample_checkpoint in
  match Team_session_types.checkpoint_of_yojson json with
  | Error e -> Alcotest.fail ("roundtrip failed: " ^ e)
  | Ok cp ->
      Alcotest.(check (float 0.01)) "ts" sample_checkpoint.ts cp.ts;
      Alcotest.(check string) "ts_iso" sample_checkpoint.ts_iso cp.ts_iso;
      Alcotest.(check string) "status" "running"
        (Team_session_types.status_to_string cp.status);
      Alcotest.(check int) "elapsed_sec" 120 cp.elapsed_sec;
      Alcotest.(check int) "remaining_sec" 480 cp.remaining_sec;
      Alcotest.(check (float 0.01)) "progress_pct" 25.0 cp.progress_pct;
      Alcotest.(check int) "done_delta_total" 3 cp.done_delta_total;
      Alcotest.(check int) "agent count" 2 (List.length cp.done_delta_by_agent);
      Alcotest.(check int) "active count" 2 (List.length cp.active_agents)

let test_checkpoint_of_invalid_json () =
  match Team_session_types.checkpoint_of_yojson (`String "garbage") with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "should fail on invalid json"

(* ── Gap B: load_latest_checkpoint ───────────────────────────── *)

let test_load_latest_checkpoint_empty () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config base in
      let sid = "test-sess-empty" in
      Team_session_store.ensure_session_dirs config sid;
      match Team_session_store.load_latest_checkpoint config sid with
      | None -> ()
      | Some _ -> Alcotest.fail "expected None for empty checkpoints dir")

let test_load_latest_checkpoint_returns_latest () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config base in
      let sid = "test-sess-ckpt" in
      Team_session_store.ensure_session_dirs config sid;
      (* Write two checkpoints with different timestamps *)
      let cp1 = { sample_checkpoint with ts = 1700000001.0; progress_pct = 10.0 } in
      let cp2 = { sample_checkpoint with ts = 1700000002.0; progress_pct = 75.0 } in
      Team_session_store.write_checkpoint config sid cp1;
      Team_session_store.write_checkpoint config sid cp2;
      match Team_session_store.load_latest_checkpoint config sid with
      | None -> Alcotest.fail "expected Some for populated checkpoints dir"
      | Some cp ->
          (* cp2 has higher timestamp → last in sorted order *)
          Alcotest.(check (float 0.01)) "latest progress_pct" 75.0 cp.progress_pct)

(* ── Gap C: event_entry roundtrip ────────────────────────────── *)

let test_event_entry_roundtrip () =
  let entry : Team_session_types.event_entry =
    {
      ts = 1700000000.0;
      ts_iso = "2023-11-14T22:13:20.000Z";
      event_type = "test_event";
      detail = `Assoc [ ("key", `String "value") ];
    }
  in
  let json = Team_session_types.event_entry_to_yojson entry in
  match Team_session_types.event_entry_of_yojson json with
  | Error e -> Alcotest.fail ("event roundtrip failed: " ^ e)
  | Ok e ->
      Alcotest.(check (float 0.01)) "ts" entry.ts e.ts;
      Alcotest.(check string) "event_type" "test_event" e.event_type;
      Alcotest.(check string) "ts_iso" entry.ts_iso e.ts_iso

let test_event_entry_of_invalid_json () =
  match Team_session_types.event_entry_of_yojson (`Int 42) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "should fail on invalid json"

(* ── Gap C: read_recent_events ───────────────────────────────── *)

let test_read_recent_events_empty () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config base in
      let sid = "test-sess-no-events" in
      Team_session_store.ensure_session_dirs config sid;
      let events =
        Team_session_store.read_recent_events config sid ~max_count:5
      in
      Alcotest.(check int) "empty events" 0 (List.length events))

let test_read_recent_events_capped () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config base in
      let sid = "test-sess-events" in
      Team_session_store.ensure_session_dirs config sid;
      (* Write 10 events *)
      for i = 1 to 10 do
        Team_session_store.append_event config sid
          ~event_type:(Printf.sprintf "evt_%d" i)
          ~detail:(`Assoc [ ("i", `Int i) ])
      done;
      let events =
        Team_session_store.read_recent_events config sid ~max_count:5
      in
      Alcotest.(check int) "capped at 5" 5 (List.length events);
      (* Should be the last 5 events (evt_6..evt_10) *)
      let first = List.hd events in
      Alcotest.(check string) "first is evt_6" "evt_6" first.event_type;
      let last = List.nth events 4 in
      Alcotest.(check string) "last is evt_10" "evt_10" last.event_type)

let sample_session config ~session_id ~started_at ~updated_at_iso =
  {
    Team_session_types.session_id;
    goal = "recency sort";
    created_by = "tester";
    origin_kind = Team_session_types.Origin_human;
    room_id = "default";
    operation_id = None;
    status = Team_session_types.Running;
    duration_seconds = 60;
    execution_scope = Team_session_types.Observe_only;
    checkpoint_interval_sec = 10;
    min_agents = 1;
    orchestration_mode = Team_session_types.Assist;
    communication_mode = Team_session_types.Comm_broadcast;
    scale_profile = Team_session_types.Scale_standard;
    control_profile = Team_session_types.Control_flat;
    runtime_policy_ref = Some "glm:auto";
    model_cascade = [ "glm:auto" ];
    fallback_policy = Team_session_types.Fallback_cascade_then_task;
    instruction_profile = Team_session_types.Profile_standard;
    alert_channel = Team_session_types.Alert_both;
    auto_resume = false;
    report_formats = [ Team_session_types.Markdown; Team_session_types.Json ];
    turn_count = 0;
    agent_names = [ "tester" ];
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
    planned_end_at = started_at +. 60.0;
    stopped_at = None;
    last_checkpoint_at = None;
    last_event_at = None;
    last_turn_at = None;
    stop_reason = None;
    generated_report = false;
    delivery_contract = None;
    latest_delivery_verdict = None;
    artifacts_dir = Team_session_store.session_dir config session_id;
    created_at_iso = updated_at_iso;
    updated_at_iso;
  }

let test_list_sessions_uses_recency_order_for_limit () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config base in
      ignore (Room.init config ~agent_name:(Some "tester"));
      let sessions =
        [
          sample_session config ~session_id:"sess-old" ~started_at:10.0
            ~updated_at_iso:"2026-03-24T10:00:00Z";
          sample_session config ~session_id:"sess-mid" ~started_at:20.0
            ~updated_at_iso:"2026-03-24T10:05:00Z";
          sample_session config ~session_id:"sess-new" ~started_at:30.0
            ~updated_at_iso:"2026-03-24T10:10:00Z";
        ]
      in
      List.iter (Team_session_store.save_session config) sessions;
      let listed = Team_session_store.list_sessions ~limit:2 config in
      Alcotest.(check (list string)) "limit keeps newest sessions"
        [ "sess-new"; "sess-mid" ]
        (List.map (fun (session : Team_session_types.session) -> session.session_id) listed))

let test_list_sessions_records_fallback_diagnostics () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config base in
      ignore (Room.init config ~agent_name:(Some "tester"));
      Team_session_store.save_session config
        (sample_session config ~session_id:"sess-one" ~started_at:10.0
           ~updated_at_iso:"2026-03-24T10:00:00Z");
      ignore (Team_session_store.list_sessions ~since_unix:1.0 ~limit:1 config);
      let diagnostics = Team_session_store.session_list_diagnostics_json () in
      Alcotest.(check string) "fallback source" "backend_get_all"
        Yojson.Safe.Util.(diagnostics |> member "source" |> to_string);
      Alcotest.(check bool) "pg recent not attempted" false
        Yojson.Safe.Util.(diagnostics |> member "pg_recent_attempted" |> to_bool);
      Alcotest.(check string) "fallback reason" "pg_recent_unavailable"
        Yojson.Safe.Util.(diagnostics |> member "fallback_reason" |> to_string);
      Alcotest.(check bool) "last error mentions pg recent" true
        (String.length Yojson.Safe.Util.(diagnostics |> member "last_error" |> to_string) > 0);
      Alcotest.(check int) "limit recorded" 1
        Yojson.Safe.Util.(diagnostics |> member "limit" |> to_int))

let test_list_sessions_flat_namespace_uses_flat_prefix () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room.default_config base in
      Team_session_store.save_session config
        (sample_session config ~session_id:"sess-flat" ~started_at:10.0
           ~updated_at_iso:"2026-03-24T10:00:00Z");
      let listed = Team_session_store.list_sessions ~limit:1 config in
      Alcotest.(check (list string)) "flat namespace session listed"
        [ "sess-flat" ]
        (List.map (fun (session : Team_session_types.session) -> session.session_id) listed);
      let diagnostics = Team_session_store.session_list_diagnostics_json () in
      let expected_prefix =
        match Room.key_of_path config (Team_session_store.sessions_root config) with
        | Some key -> key ^ ":"
        | None -> Alcotest.fail "expected scoped backend key"
      in
      Alcotest.(check string) "query prefix tracks flat namespace path" expected_prefix
        Yojson.Safe.Util.(diagnostics |> member "query_prefix" |> to_string))

let test_list_sessions_memory_backend_uses_project_prefix () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
      with_storage_type "memory" (fun () ->
          Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
          let config = Room.default_config base in
          Team_session_store.save_session config
            (sample_session config ~session_id:"sess-memory" ~started_at:10.0
               ~updated_at_iso:"2026-03-24T10:00:00Z");
          let listed = Team_session_store.list_sessions ~limit:1 config in
          Alcotest.(check (list string)) "memory backend session listed"
            [ "sess-memory" ]
            (List.map (fun (session : Team_session_types.session) -> session.session_id) listed);
          let diagnostics = Team_session_store.session_list_diagnostics_json () in
          let expected_prefix =
            match Room.key_of_path config (Team_session_store.sessions_root config) with
            | Some key -> key ^ ":"
            | None -> Alcotest.fail "expected project-prefixed backend key"
          in
          Alcotest.(check string) "query prefix includes project key prefix" expected_prefix
            Yojson.Safe.Util.(diagnostics |> member "query_prefix" |> to_string)))

(* ── Runner ──────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Swarm Persistence (Gap B+C)"
    [
      ( "checkpoint_roundtrip",
        [
          Alcotest.test_case "to/of_yojson" `Quick test_checkpoint_roundtrip;
          Alcotest.test_case "invalid json" `Quick test_checkpoint_of_invalid_json;
        ] );
      ( "load_latest_checkpoint",
        [
          Alcotest.test_case "empty dir → None" `Quick
            test_load_latest_checkpoint_empty;
          Alcotest.test_case "returns latest" `Quick
            test_load_latest_checkpoint_returns_latest;
        ] );
      ( "event_entry_roundtrip",
        [
          Alcotest.test_case "to/of_yojson" `Quick test_event_entry_roundtrip;
          Alcotest.test_case "invalid json" `Quick test_event_entry_of_invalid_json;
        ] );
      ( "read_recent_events",
        [
          Alcotest.test_case "empty → []" `Quick test_read_recent_events_empty;
          Alcotest.test_case "capped at max_count" `Quick
            test_read_recent_events_capped;
          Alcotest.test_case "list_sessions limit prefers newest" `Quick
            test_list_sessions_uses_recency_order_for_limit;
          Alcotest.test_case "list_sessions diagnostics record fallback"
            `Quick test_list_sessions_records_fallback_diagnostics;
          Alcotest.test_case "list_sessions flat namespace uses flat prefix"
            `Quick test_list_sessions_flat_namespace_uses_flat_prefix;
          Alcotest.test_case "list_sessions memory backend uses project prefix"
            `Quick test_list_sessions_memory_backend_uses_project_prefix;
        ] );
    ]
