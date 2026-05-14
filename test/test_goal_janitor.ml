module Types = Masc_domain

(** Tests for Goal_janitor — stale goal cleanup. *)

open Alcotest
open Masc_mcp

let temp_dir () =
  let path = Filename.temp_file "goal_janitor_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  try rm dir with _ -> ()

let with_room f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    let config = Coord.default_config dir in
    ignore (Coord.init config ~agent_name:(Some "test"));
    f config)

let old_iso days_ago =
  let ts = Unix.gettimeofday () -. (float_of_int days_ago *. 86400.0) in
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let iso_seconds_ago seconds_ago =
  let ts = Unix.gettimeofday () -. float_of_int seconds_ago in
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let make_goal ?(status = Goal_store.Active) ?(days_ago = 0) id title =
  let ts = old_iso days_ago in
  {
    Goal_store.id; horizon = Short; title;
    metric = None; target_value = None; due_date = None;
    priority = 3; status; phase = Goal_store.phase_of_goal_status status;
    verifier_policy = None; require_completion_approval = false;
    active_verification_request_id = None; parent_goal_id = None;
    last_review_note = None; last_review_at = None;
    created_at = ts; updated_at = ts;
  }

let set_task_created_at config ~title ~created_at =
  let backlog = Coord.read_backlog config in
  let tasks =
    List.map
      (fun (task : Masc_domain.task) ->
         if String.equal task.title title then { task with created_at } else task)
      backlog.tasks
  in
  Coord.write_backlog config
    { tasks; last_updated = Masc_domain.now_iso ();
      version = backlog.version + 1 }

let contains_substring haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec loop idx =
    if n_len = 0 then true
    else if idx + n_len > h_len then false
    else if String.sub haystack idx n_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let event_log_text config =
  let events_dir = Filename.concat (Coord.masc_dir config) "events" in
  let rec collect dir =
    if not (Sys.file_exists dir) then []
    else if Sys.is_directory dir then
      Sys.readdir dir
      |> Array.to_list
      |> List.concat_map (fun entry -> collect (Filename.concat dir entry))
    else if Filename.check_suffix dir ".jsonl" then [ dir ]
    else []
  in
  collect events_dir
  |> List.map (fun path ->
         let ic = open_in path in
         match really_input_string ic (in_channel_length ic) with
         | content ->
             close_in_noerr ic;
             content
         | exception exn ->
             close_in_noerr ic;
             raise exn)
  |> String.concat "\n"

let event_lines_containing config marker =
  event_log_text config
  |> String.split_on_char '\n'
  |> List.filter (fun line -> contains_substring line marker)
  |> String.concat "\n"

let test_purge_old_dropped () =
  with_room @@ fun config ->
  let g1 = make_goal ~status:Dropped ~days_ago:10 "g1" "Old dropped" in
  let g2 = make_goal ~status:Dropped ~days_ago:3 "g2" "Recent dropped" in
  let g3 = make_goal ~status:Active ~days_ago:1 "g3" "Active" in
  Goal_store.write_state config
    { version = 1; updated_at = Masc_domain.now_iso ();
      goals = [g1; g2; g3] };
  let result = Goal_janitor.run config in
  check int "purged old dropped" 1 result.purged;
  check int "no stagnation" 0 result.stagnated;
  let remaining = Goal_store.list_goals config () in
  check int "2 goals remain" 2 (List.length remaining);
  check bool "g1 purged" false
    (List.exists (fun (g : Goal_store.goal) -> g.id = "g1") remaining);
  check bool "g2 kept" true
    (List.exists (fun (g : Goal_store.goal) -> g.id = "g2") remaining)

let test_stagnate_old_active () =
  with_room @@ fun config ->
  let g1 = make_goal ~status:Active ~days_ago:35 "g1" "Stale active" in
  let g2 = make_goal ~status:Active ~days_ago:5 "g2" "Fresh active" in
  Goal_store.write_state config
    { version = 1; updated_at = Masc_domain.now_iso ();
      goals = [g1; g2] };
  let result = Goal_janitor.run config in
  check int "stagnated 1" 1 result.stagnated;
  check int "no purge" 0 result.purged;
  let goals = Goal_store.list_goals config () in
  let g1' = List.find (fun (g : Goal_store.goal) -> g.id = "g1") goals in
  check string "g1 now dropped"
    "dropped" (match g1'.status with Dropped -> "dropped" | _ -> "not dropped");
  let g2' = List.find (fun (g : Goal_store.goal) -> g.id = "g2") goals in
  check string "g2 still active"
    "active" (match g2'.status with Active -> "active" | _ -> "not active")

let test_no_changes_when_clean () =
  with_room @@ fun config ->
  let g1 = make_goal ~status:Active ~days_ago:1 "g1" "Fresh" in
  let g2 = make_goal ~status:Done ~days_ago:60 "g2" "Done long ago" in
  Goal_store.write_state config
    { version = 1; updated_at = Masc_domain.now_iso ();
      goals = [g1; g2] };
  let result = Goal_janitor.run config in
  check int "no purge" 0 result.purged;
  check int "no stagnation" 0 result.stagnated;
  check int "no orphans" 0 result.orphans;
  check int "no orphan tasks" 0 result.orphan_tasks

let test_escalate_stale_unclaimed_tasks_without_goal_linkage () =
  with_room @@ fun config ->
  let goal = make_goal "g1" "Current goal" in
  Goal_store.write_state config
    { version = 1; updated_at = Masc_domain.now_iso (); goals = [ goal ] };
  ignore (Coord.add_task config ~title:"Stale unlinked task" ~priority:1
            ~description:"missing goal linkage");
  ignore (Coord.add_task config ~title:"Fresh unlinked task" ~priority:2
            ~description:"fresh enough to avoid escalation");
  ignore (Coord.add_task config ~title:"Legacy linked [goal:g1]" ~priority:3
            ~description:"title tag keeps legacy linkage visible");
  ignore (Coord.add_task ~goal_id:"g1" config ~title:"Explicit linked task"
            ~priority:4 ~description:"structured linkage");
  let stale = iso_seconds_ago (31 * 60) in
  set_task_created_at config ~title:"Stale unlinked task" ~created_at:stale;
  set_task_created_at config ~title:"Legacy linked [goal:g1]" ~created_at:stale;
  set_task_created_at config ~title:"Explicit linked task" ~created_at:stale;
  let result = Goal_janitor.run config in
  check int "one stale unlinked task escalated" 1 result.orphan_tasks;
  let events = event_lines_containing config "goal_orphan_task_escalation" in
  check bool "escalation event emitted" true
    (not (String.equal events ""));
  check bool "stale unlinked task id included" true
    (contains_substring events "task-001");
  check bool "legacy title-tag task not escalated" false
    (contains_substring events "task-003")

let test_prune_orphaned_ids () =
  let valid = ["g1"; "g2"; "g3"] in
  let active = ["g1"; "g4"; "g5"; "g2"] in
  let pruned, removed = Goal_janitor.prune_active_goal_ids ~valid_goal_ids:valid active in
  check int "removed 2 orphans" 2 removed;
  check int "2 remaining" 2 (List.length pruned);
  check bool "g1 kept" true (List.mem "g1" pruned);
  check bool "g2 kept" true (List.mem "g2" pruned)

let () =
  run "Goal_janitor" [
    "sweep", [
      test_case "purge old dropped goals" `Quick test_purge_old_dropped;
      test_case "stagnate old active goals" `Quick test_stagnate_old_active;
      test_case "no changes when clean" `Quick test_no_changes_when_clean;
      test_case "escalate stale unclaimed tasks without goal linkage" `Quick
        test_escalate_stale_unclaimed_tasks_without_goal_linkage;
    ];
    "prune", [
      test_case "prune orphaned active_goal_ids" `Quick test_prune_orphaned_ids;
    ];
  ]
