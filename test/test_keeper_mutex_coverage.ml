open Alcotest
open Masc_mcp

let temp_dir prefix =
  let path = Filename.temp_dir prefix "" in
  path

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = temp_dir prefix in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let run_in_dir dir cmd =
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Unix.chdir cwd)
    (fun () ->
      Unix.chdir dir;
      match Sys.command cmd with
      | 0 -> ()
      | code -> failwith (Printf.sprintf "command failed (%d): %s" code cmd))

let init_git_repo dir =
  run_in_dir dir "git init -q";
  run_in_dir dir "git config user.email 'test@example.com'";
  run_in_dir dir "git config user.name 'Test User'"

let wait_for_done request_id =
  let rec loop remaining =
    match Keeper_msg_async.poll request_id with
    | Some ({ status = Done _; _ } as entry) -> entry
    | _ when remaining <= 0 ->
        failwith (Printf.sprintf "request %s did not complete" request_id)
    | _ ->
        Eio.Fiber.yield ();
        loop (remaining - 1)
  in
  loop 200

let with_eio_env f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.clear_fs ();
      Eio_guard.disable ())
    (fun () -> f env)

let test_keeper_msg_async_roundtrip () =
  with_eio_env @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let request_id =
    Keeper_msg_async.submit ~sw
      ~keeper_name:"alpha"
      ~f:(fun () ->
        Eio.Fiber.yield ();
        (true, Yojson.Safe.to_string (`Assoc [ ("kind", `String "done") ])))
  in
  let entry = wait_for_done request_id in
  Alcotest.(check bool) "request completed" true
    (match entry.Keeper_msg_async.status with Done { ok = true; body } ->
       String.length body > 0
     | _ -> false);
  Alcotest.(check int) "one pending entry" 1
    (List.length (Keeper_msg_async.list_for_keeper ~keeper_name:"alpha"))

let test_keeper_file_tracker_records_collisions () =
  with_eio_env @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let make_worker keeper_name promise =
    Eio.Fiber.fork ~sw (fun () ->
        Eio.Fiber.yield ();
        let warnings =
          Keeper_file_tracker.record_turn_files ~keeper_name
            ~files:[ " M lib/shared.ml" ]
        in
        Eio.Promise.resolve promise warnings)
  in
  let p1, r1 = Eio.Promise.create () in
  let p2, r2 = Eio.Promise.create () in
  make_worker "keeper-a" r1;
  make_worker "keeper-b" r2;
  let w1 = Eio.Promise.await p1 in
  let w2 = Eio.Promise.await p2 in
  Alcotest.(check int) "exactly one collision warning" 1
    (List.length w1 + List.length w2)

let test_keeper_evidence_chain_verifies () =
  with_eio_env @@ fun _env ->
  with_temp_dir "keeper-evidence-mutex" @@ fun base_path ->
  init_git_repo base_path;
  ignore
    (Keeper_evidence.capture_turn_evidence ~base_path ~keeper_name:"alpha"
       ~trace_id:"trace-1" ~turn_number:1 ~tool_calls_made:0
       ~before_hash:None ());
  ignore
    (Keeper_evidence.capture_turn_evidence ~base_path ~keeper_name:"alpha"
       ~trace_id:"trace-1" ~turn_number:2 ~tool_calls_made:1
       ~before_hash:None ());
  match
    Keeper_evidence.verify_evidence_chain ~base_path ~keeper_name:"alpha"
      ~trace_id:"trace-1"
  with
  | Ok () -> ()
  | Error (turn, expected, actual) ->
      failwith
        (Printf.sprintf "evidence chain mismatch at turn %d: %s <> %s" turn
           expected actual)

let collision_count (json : Yojson.Safe.t option) =
  match json with
  | Some (`Assoc fields) ->
      (match List.assoc_opt "collision_warnings" fields with
       | Some (`List warnings) -> List.length warnings
       | _ -> 0)
  | _ -> 0

let test_keeper_evidence_ignores_preexisting_dirty_state_without_delta () =
  with_eio_env @@ fun _env ->
  with_temp_dir "keeper-evidence-preexisting-dirty" @@ fun base_path ->
  init_git_repo base_path;
  let gitignore = Filename.concat base_path ".gitignore" in
  let tracked = Filename.concat base_path "shared.ml" in
  Out_channel.with_open_bin gitignore (fun oc -> output_string oc ".masc/\n");
  Out_channel.with_open_bin tracked (fun oc -> output_string oc "let shared = 1\n");
  run_in_dir base_path "git add .gitignore shared.ml && git commit -q -m init";
  Out_channel.with_open_bin tracked (fun oc -> output_string oc "let shared = 2\n");
  let before_alpha =
    Keeper_evidence.snapshot_before_turn ~base_path ~keeper_name:"alpha"
  in
  let before_beta =
    Keeper_evidence.snapshot_before_turn ~base_path ~keeper_name:"beta"
  in
  let ev1 =
    Keeper_evidence.capture_turn_evidence ~base_path ~keeper_name:"alpha"
      ~trace_id:"trace-a" ~turn_number:1 ~tool_calls_made:0
      ~before_hash:before_alpha ()
  in
  let ev2 =
    Keeper_evidence.capture_turn_evidence ~base_path ~keeper_name:"beta"
      ~trace_id:"trace-b" ~turn_number:1 ~tool_calls_made:0
      ~before_hash:before_beta ()
  in
  Alcotest.(check int) "first keeper sees no collision without new delta" 0
    (collision_count ev1);
  Alcotest.(check int) "second keeper also sees no collision without new delta" 0
    (collision_count ev2)

(* Regression: three keepers sharing the same working tree each observing
   51 pre-existing dirty files. Without the per-turn delta, every keeper
   after the first would mis-report each of the 51 shared files as a
   collision (measurement artifact, task-236). With before_lines threaded
   through, only files newly dirtied by this turn (here: one file per
   keeper) can trigger a collision. *)
let test_keeper_evidence_collision_uses_per_turn_delta () =
  with_eio_env @@ fun _env ->
  with_temp_dir "keeper-evidence-per-turn-delta" @@ fun base_path ->
  init_git_repo base_path;
  let gitignore = Filename.concat base_path ".gitignore" in
  Out_channel.with_open_bin gitignore (fun oc -> output_string oc ".masc/\n");
  (* Create 51 shared files + one per-keeper file, all committed clean. *)
  for i = 0 to 50 do
    let f = Filename.concat base_path (Printf.sprintf "shared_%02d.ml" i) in
    Out_channel.with_open_bin f (fun oc ->
      output_string oc (Printf.sprintf "let v_%d = 0\n" i))
  done;
  run_in_dir base_path "git add . && git commit -q -m init";
  (* Simulate a long-running pre-existing dirty state: 51 files touched
     before any keeper turn starts. *)
  for i = 0 to 50 do
    let f = Filename.concat base_path (Printf.sprintf "shared_%02d.ml" i) in
    Out_channel.with_open_bin f (fun oc ->
      output_string oc (Printf.sprintf "let v_%d = 1\n" i))
  done;
  let snapshot name =
    Keeper_evidence.snapshot_before_turn_with_lines ~base_path ~keeper_name:name
  in
  let run_turn ~name ~trace ~new_file snap =
    (* This keeper's turn dirties exactly one additional file. *)
    let path = Filename.concat base_path new_file in
    Out_channel.with_open_bin path (fun oc ->
      output_string oc "let k = 1\n");
    Keeper_evidence.capture_turn_evidence ~base_path ~keeper_name:name
      ~trace_id:trace ~turn_number:1 ~tool_calls_made:0
      ~before_hash:(Option.map fst snap)
      ?before_lines:(Option.map snd snap)
      ()
  in
  let snap_a = snapshot "janitor" in
  let ev_a = run_turn ~name:"janitor" ~trace:"t-a"
               ~new_file:"new_a.ml" snap_a in
  let snap_b = snapshot "masc-improver" in
  let ev_b = run_turn ~name:"masc-improver" ~trace:"t-b"
               ~new_file:"new_b.ml" snap_b in
  let snap_c = snapshot "ani1999" in
  let ev_c = run_turn ~name:"ani1999" ~trace:"t-c"
               ~new_file:"new_c.ml" snap_c in
  (* Each keeper introduces one genuinely new path. Since new_a/b/c do not
     overlap, no cross-keeper collision should be reported — certainly not
     51 shared pre-existing files per keeper. *)
  Alcotest.(check int) "janitor sees 0 collisions (51 shared dirty files)"
    0 (collision_count ev_a);
  Alcotest.(check int) "masc-improver sees 0 collisions (only new_b changed)"
    0 (collision_count ev_b);
  Alcotest.(check int) "ani1999 sees 0 collisions (only new_c changed)"
    0 (collision_count ev_c)

let () =
  run "keeper_mutex_coverage"
    [
      "keeper_msg_async", [
        test_case "submit/poll roundtrip" `Quick test_keeper_msg_async_roundtrip;
      ];
      "keeper_file_tracker", [
        test_case "records collision warnings under parallel fibers" `Quick
          test_keeper_file_tracker_records_collisions;
      ];
      "keeper_evidence", [
        test_case "hash chain verifies in git repo" `Quick
          test_keeper_evidence_chain_verifies;
        test_case "ignores preexisting dirty state without delta" `Quick
          test_keeper_evidence_ignores_preexisting_dirty_state_without_delta;
        test_case "collision detection uses per-turn delta (task-236)" `Quick
          test_keeper_evidence_collision_uses_per_turn_delta;
      ];
    ]
