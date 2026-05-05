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

let test_purge_old_dropped () =
  with_room @@ fun config ->
  let g1 = make_goal ~status:Dropped ~days_ago:10 "g1" "Old dropped" in
  let g2 = make_goal ~status:Dropped ~days_ago:3 "g2" "Recent dropped" in
  let g3 = make_goal ~status:Active ~days_ago:1 "g3" "Active" in
  Goal_store.write_state config
    { version = 1; updated_at = Types.now_iso ();
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
    { version = 1; updated_at = Types.now_iso ();
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
    { version = 1; updated_at = Types.now_iso ();
      goals = [g1; g2] };
  let result = Goal_janitor.run config in
  check int "no purge" 0 result.purged;
  check int "no stagnation" 0 result.stagnated;
  check int "no orphans" 0 result.orphans

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
    ];
    "prune", [
      test_case "prune orphaned active_goal_ids" `Quick test_prune_orphaned_ids;
    ];
  ]
