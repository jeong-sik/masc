open Alcotest
module Commit = Masc.Dashboard_observation_commit
module Telemetry = Telemetry_unified

let fixture f = Eio_main.run (fun env ->
  let previous = Fs_compat.get_fs_opt () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = Masc_test_deps.setup_test_workspace () in
  let config = Masc.Workspace.default_config base in
  Fun.protect ~finally:(fun () ->
    Masc_test_deps.cleanup_test_workspace base;
    match previous with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ())
    (fun () -> f config))

let count config source =
  let open Yojson.Safe.Util in
  Telemetry.summary_json ~masc_root:(Masc.Workspace.masc_dir config) ()
  |> member "sources" |> to_list
  |> List.find (fun row -> row |> member "source" |> to_string = source)
  |> member "entry_count" |> to_int

let test_original_writers_notify_their_store () = fixture (fun config ->
  let commits = ref [] and goal_owners = ref [] in
  let remove = Commit.subscribe (fun change -> commits := change :: !commits) in
  let remove_goal = Goal_event_observation.subscribe (fun ~base_path ->
    goal_owners := base_path :: !goal_owners) in
  Fun.protect ~finally:(fun () -> remove (); remove_goal ()) (fun () ->
    let before = List.map (fun source -> source, count config source)
        ["agent_event"; "tool_usage"; "goal_event"] in
    Masc.Telemetry_eio.track_agent_session_bound config ~agent_id:"source-fixture" ();
    Masc.Tool_usage_log.init ~base_path:config.base_path ();
    Masc.Tool_usage_log.log_call ~on_io_failure:(fun ~site:_ exn -> raise exn)
      ~tool_name:"source-fixture" ~disposition:(Tool_result.Completed ()) ~caller:None;
    let result = Goal_store.append_audit_event config
        (`Assoc ["ts", `Float (Time_compat.now ()); "event", `String "verified"]) in
    check bool "original goal transaction succeeds" true (Result.is_ok result);
    List.iter (fun (source, previous) ->
      check int (source ^ " actual source row") (previous + 1) (count config source)) before;
    check bool "actual flat-store writes reach the existing workspace Commit consumer" true
      (List.length (List.filter (function
        | Commit.Workspace {base_path; payload} ->
            base_path = config.base_path && payload.topic = `Telemetry && payload.scope = `Workspace
        | Commit.Process _ -> false) !commits) >= 2);
    check (list string) "goal leaf retains its actual workspace owner" [config.base_path] !goal_owners))

let entry : Trajectory.tool_call_entry =
  { ts=Time_compat.now (); ts_iso="2026-11-10T00:00:00Z"; turn=1; round=1
  ; tool_name="source-fixture"; args_json="{}"; gate_decision=Trajectory.Pass
  ; result=Some "ok"; duration_ms=1; error=None; execution_id=None }

let test_buffered_flush_keeps_original_owner () = fixture (fun config ->
  let other_base = Masc_test_deps.setup_test_workspace () in
  let other = Masc.Workspace.default_config other_base in
  Fun.protect ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace other_base) (fun () ->
    let seen = ref [] in
    let remove = Trajectory_write_observation.subscribe (fun owner -> seen := owner :: !seen) in
    Fun.protect ~finally:remove (fun () ->
      let make config = Trajectory.create_accumulator
        ~masc_root:(Masc.Workspace.masc_dir config) ~keeper_name:"keeper" ~trace_id:"source-fixture" () in
      let older = make config in
      check bool "first source accepts its row" true (Trajectory.record_entry older entry = Trajectory.Recorded);
      let newer = make other in
      check bool "replacement source accepts its row" true (Trajectory.record_entry newer entry = Trajectory.Recorded);
      check int "enqueue is not a file write notification" 0 (List.length !seen);
      Trajectory.flush_all_pending ();
      check bool "flush metadata names both original stores" true
        (List.exists (fun owner -> owner.Trajectory_write_observation.masc_root = Masc.Workspace.masc_dir config) !seen
         && List.exists (fun owner -> owner.Trajectory_write_observation.masc_root = Masc.Workspace.masc_dir other) !seen);
      check int "old source was not reattributed after replacement" 1 (count config "trajectory_tool_call");
      check int "new source has only its own actual row" 1 (count other "trajectory_tool_call");
      ignore (Trajectory.finalize older Trajectory.Completed);
      ignore (Trajectory.finalize newer Trajectory.Completed))))

let test_goal_callback_cancellation_preserves_result () = fixture (fun config ->
  let before = count config "goal_event" in
  let returned = ref false and failed = Goal_event_observation.failed_notifications () in
  let reason = Failure "source observer cancels its writer owner" in
  (match Eio.Cancel.sub (fun cancellation ->
    let remove = Goal_event_observation.subscribe (fun ~base_path:_ ->
      Eio.Cancel.cancel cancellation reason;
      raise (Eio.Cancel.Cancelled Exit)) in
    Fun.protect ~finally:remove (fun () ->
      let result = Goal_store.append_audit_event config
          (`Assoc ["ts", `Float (Time_compat.now ()); "event", `String "verified"]) in
      returned := Result.is_ok result;
      Eio.Fiber.check ())) with
  | () -> fail "actual owner cancellation disappeared"
  | exception Eio.Cancel.Cancelled actual when actual == reason -> ()
  | exception exn -> raise exn);
  check bool "the ledger returned its original successful result" true !returned;
  check int "failed observer is recorded" (failed + 1) (Goal_event_observation.failed_notifications ());
  check int "cancellation neither lost nor replayed the actual event" (before + 1) (count config "goal_event"))

let test_cadence_handshake_notifies_both_transitions () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () and sleeping = Atomic.make false in
    let observed = ref [] in
    let failures = Masc.Keeper_keepalive_signal.failed_cadence_notifications () in
    let result = Masc.Keeper_keepalive_signal.interruptible_sleep
      ~cadence_sleeping:sleeping
      ~on_cadence_sleeping_changed:(fun () ->
        observed := Atomic.get sleeping :: !observed;
        raise Exit)
      ~clock ~stop:(Atomic.make false) ~wakeup:(Atomic.make false) (fun () -> 0.0) in
    check bool "the original zero-duration sleep result is preserved" true
      (result = Masc.Keeper_keepalive_signal.Timeout);
    check (list bool) "actual entry and cleanup transitions both notify" [false; true] !observed;
    check bool "the handshake cleanup is committed" false (Atomic.get sleeping);
    check int "metadata failures do not replace either transition" (failures + 2)
      (Masc.Keeper_keepalive_signal.failed_cadence_notifications ());
    check bool "there is no healthy observation timer" false (Eio_mock.Clock.try_advance clock))

let () = run "telemetry authoritative source writes"
  ["source", [test_case "original writers and scoped metadata" `Quick test_original_writers_notify_their_store;
              test_case "buffered flush keeps original owner" `Quick test_buffered_flush_keeps_original_owner;
              test_case "observer cancellation preserves ledger result" `Quick test_goal_callback_cancellation_preserves_result;
              test_case "cadence entry and cleanup notify" `Quick test_cadence_handshake_notifies_both_transitions]]
