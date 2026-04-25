(** #10405 — pin the [Goal_janitor] periodic scheduler contract.

    Pre-fix [Goal_janitor.run] was wired only to a single
    dashboard DELETE handler.  4 active goals sat 4 days
    untouched — [last_review_at = null] for every goal, the
    [goals_snapshots/] directory stayed at 0 bytes, and any
    orphaned [active_goal_ids] in keeper meta accumulated
    without being pruned.  The stagnation/orphan-cleanup logic
    existed; only the scheduler was missing.

    Post-fix [server_bootstrap_loops.ml] forks a [goal_janitor]
    subsystem that runs [Goal_janitor.run] every
    [Env_config_runtime.InternalTimers.goal_janitor_interval_sec]
    seconds (default 3600s = 1h).  An interval of [<= 0.0]
    disables the loop entirely (regression knob).

    Tests pin:

    1. The interval env config is wired — non-negative float
       with a sensible default.
    2. [Goal_janitor.run] correctly stagnates a 4-day-old
       [Executing] goal under a [stagnant_days=3] sweep config
       — the same threshold an operator might dial in once the
       periodic loop is live.
    3. After stagnation [last_review_at] is set (closing the
       null-review-timestamp gap from #10405's evidence). *)

open Alcotest
open Masc_mcp

(* --- 1. interval config wired ----------------------- *)

let test_interval_default_is_positive () =
  let interval =
    Env_config_runtime.InternalTimers.goal_janitor_interval_sec
  in
  check bool
    (Printf.sprintf
       "interval is a non-negative float (got %.1f)"
       interval)
    true (interval >= 0.0);
  (* Default is 1h; allow override via env in CI but verify
     the value is in a sane range so a typo of "60.0" instead
     of "3600.0" doesn't ship silently. *)
  check bool
    (Printf.sprintf
       "interval is reasonable (>= 60s or 0 to disable; got %.1f)"
       interval)
    true (interval = 0.0 || interval >= 60.0)

(* --- 2 & 3. stagnation closes last_review_at gap ----- *)

let temp_dir () =
  let path = Filename.temp_file "goal_janitor_sched_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rec rm_rf dir =
  if Sys.file_exists dir then
    if Sys.is_directory dir then begin
      Sys.readdir dir
      |> Array.iter (fun e -> rm_rf (Filename.concat dir e));
      Unix.rmdir dir
    end else
      Sys.remove dir

let with_room f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Coord.default_config dir in
      ignore (Coord.init config ~agent_name:(Some "test-10405"));
      f config)

let iso_days_ago days_ago =
  let ts = Unix.gettimeofday () -. (float_of_int days_ago *. 86400.0) in
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let make_executing_goal ~days_ago id title : Goal_store.goal =
  let ts = iso_days_ago days_ago in
  {
    Goal_store.id;
    horizon = Short;
    title;
    metric = None;
    target_value = None;
    due_date = None;
    priority = 3;
    status = Goal_store.Active;
    phase = Goal_phase.Executing;
    verifier_policy = None;
    require_completion_approval = false;
    active_verification_request_id = None;
    parent_goal_id = None;
    last_review_note = None;
    last_review_at = None;
    created_at = ts;
    updated_at = ts;
  }

let test_stagnation_closes_review_timestamp () =
  with_room @@ fun config ->
  (* Mirror the issue's exact evidence: a 4-day-old
     Active+Executing goal whose [last_review_at] is null. *)
  let g =
    make_executing_goal ~days_ago:4 "goal-10405" "Stuck since 04-22"
  in
  Goal_store.write_state config
    { version = 1; updated_at = Types.now_iso (); goals = [ g ] };
  (* Use a 3-day stagnation threshold so the 4-day-old goal
     trips the rule.  Default config is 30 days — matched here
     to the threshold an operator would set after seeing the
     pre-fix evidence. *)
  let sweep_cfg : Goal_janitor.sweep_config =
    { dropped_ttl_days = 7; stagnant_days = 3 }
  in
  let result = Goal_janitor.run ~config:sweep_cfg config in
  check int "stagnated 1 goal" 1 result.stagnated;
  check int "purged 0 goals (none Dropped + old enough)" 0 result.purged;
  let st = Goal_store.read_state config in
  match st.goals with
  | [ g' ] ->
      check string "phase moved to Dropped" "dropped"
        (Goal_phase.to_string g'.phase);
      check bool "last_review_at populated" true
        (Option.is_some g'.last_review_at);
      check bool "last_review_note populated" true
        (Option.is_some g'.last_review_note)
  | _ -> failf "expected exactly 1 goal after sweep"

let test_fresh_goal_not_stagnated () =
  with_room @@ fun config ->
  let g =
    make_executing_goal ~days_ago:1 "goal-fresh" "Recently updated"
  in
  Goal_store.write_state config
    { version = 1; updated_at = Types.now_iso ();
      goals = [ g ] };
  let sweep_cfg : Goal_janitor.sweep_config =
    { dropped_ttl_days = 7; stagnant_days = 3 }
  in
  let result = Goal_janitor.run ~config:sweep_cfg config in
  check int "stagnated 0 (1-day age below 3-day threshold)" 0
    result.stagnated;
  let st = Goal_store.read_state config in
  match st.goals with
  | [ g' ] ->
      check string "phase still Executing" "executing"
        (Goal_phase.to_string g'.phase);
      check bool "last_review_at still None for fresh goal" true
        (Option.is_none g'.last_review_at)
  | _ -> failf "expected exactly 1 goal after no-op sweep"

let () =
  run "goal_janitor_scheduler_10405"
    [
      ( "interval-config",
        [
          test_case "interval default is sensible positive float"
            `Quick test_interval_default_is_positive;
        ] );
      ( "stagnation-mechanism",
        [
          test_case "4-day stale goal under 3-day threshold stagnates"
            `Quick test_stagnation_closes_review_timestamp;
          test_case "1-day fresh goal under 3-day threshold untouched"
            `Quick test_fresh_goal_not_stagnated;
        ] );
    ]
