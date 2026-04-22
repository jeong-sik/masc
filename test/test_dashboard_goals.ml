open Alcotest
open Masc_mcp
open Yojson.Safe.Util

let temp_dir () =
  let path = Filename.temp_file "dashboard_goals_test" "" in
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
      ignore (Coord.init config ~agent_name:(Some "planner"));
      f config)

let test_blocked_phase_projects_blocked_health () =
  with_room @@ fun config ->
  let _goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Blocked goal"
        ~phase:Goal_phase.Blocked ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let json = Dashboard_goals.dashboard_goals_tree_json ~config in
  let node =
    match json |> member "tree" |> to_list with
    | node :: _ -> node
    | [] -> fail "expected one goal in tree"
  in
  check string "legacy status remains paused" "paused"
    (node |> member "status" |> to_string);
  check string "phase remains blocked" "blocked"
    (node |> member "phase" |> to_string);
  check string "health follows blocked phase" "blocked"
    (node |> member "health" |> to_string);
  check int "blocked summary count" 1
    (json |> member "summary" |> member "blocked_goals" |> to_int);
  check int "paused summary count" 0
    (json |> member "summary" |> member "paused_goals" |> to_int)

let () =
  run "Dashboard_goals"
    [
      ( "tree",
        [
          test_case "blocked phase maps to blocked health" `Quick
            test_blocked_phase_projects_blocked_health;
        ] );
    ]
