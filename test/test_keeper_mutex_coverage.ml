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
      ];
    ]
