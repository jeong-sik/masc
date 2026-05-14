open Alcotest
open Masc_mcp

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
;;

let wait_for_running request_id =
  let rec loop remaining =
    match Keeper_msg_async.poll request_id with
    | Some ({ status = Running; _ } as entry) -> entry
    | _ when remaining <= 0 ->
      failwith (Printf.sprintf "request %s did not start" request_id)
    | _ ->
      Eio.Fiber.yield ();
      loop (remaining - 1)
  in
  loop 200
;;

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_eio_env f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.clear_fs ();
      Eio_guard.disable ())
    (fun () -> f env)
;;

let test_keeper_msg_async_roundtrip () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-async-roundtrip-" in
  let request_id =
    Keeper_msg_async.submit ~sw ~base_path ~keeper_name:"alpha" ~f:(fun () ->
      Eio.Fiber.yield ();
      true, Yojson.Safe.to_string (`Assoc [ "kind", `String "done" ]))
  in
  let entry = wait_for_done request_id in
  Alcotest.(check bool)
    "request completed"
    true
    (match entry.Keeper_msg_async.status with
     | Done { ok = true; body } -> String.length body > 0
     | _ -> false);
  Alcotest.(check int)
    "one pending entry"
    1
    (List.length (Keeper_msg_async.list_for_keeper ~keeper_name:"alpha"))
;;

let test_keeper_msg_async_recovers_done_from_disk () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-async-done-" in
  let request_id =
    Keeper_msg_async.submit ~sw ~base_path ~keeper_name:"beta" ~f:(fun () ->
      Eio.Fiber.yield ();
      true, Yojson.Safe.to_string (`Assoc [ "kind", `String "done" ]))
  in
  let entry = wait_for_done request_id in
  Alcotest.(check bool)
    "request completed before recovery"
    true
    (match entry.Keeper_msg_async.status with
     | Done { ok = true; _ } -> true
     | _ -> false);
  Keeper_msg_async.For_testing.forget request_id;
  match Keeper_msg_async.poll ~base_path request_id with
  | Some { Keeper_msg_async.status = Done { ok = true; body }; _ } ->
    Alcotest.(check bool) "body persisted" true (String.length body > 0)
  | Some entry ->
    Alcotest.failf
      "expected recovered done, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
  | None -> Alcotest.fail "expected persisted request"
;;

let test_keeper_msg_async_marks_recovered_inflight_lost () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-async-lost-" in
  let promise, _resolver = Eio.Promise.create () in
  let request_id =
    Keeper_msg_async.submit ~sw ~base_path ~keeper_name:"gamma" ~f:(fun () ->
      Eio.Promise.await promise;
      true, "{}")
  in
  ignore (wait_for_running request_id : Keeper_msg_async.entry);
  Keeper_msg_async.For_testing.forget request_id;
  match Keeper_msg_async.poll ~base_path request_id with
  | Some { Keeper_msg_async.status = Lost { reason }; _ } ->
    Alcotest.(check bool) "lost reason retained" true (String.length reason > 0);
    Keeper_msg_async.For_testing.forget request_id;
    (match Keeper_msg_async.poll ~base_path request_id with
     | Some { Keeper_msg_async.status = Lost _; _ } -> ()
     | Some entry ->
       Alcotest.failf
         "expected persisted lost, got %s"
         (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
     | None -> Alcotest.fail "expected persisted lost request")
  | Some entry ->
    Alcotest.failf
      "expected recovered lost, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
  | None -> Alcotest.fail "expected persisted request"
;;

let test_keeper_msg_async_gc_removes_stale_terminal_disk_record () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-async-gc-" in
  let request_id =
    Keeper_msg_async.submit ~sw ~base_path ~keeper_name:"delta" ~f:(fun () ->
      Eio.Fiber.yield ();
      true, "{}")
  in
  let entry = wait_for_done request_id in
  let path =
    match Keeper_msg_async.For_testing.record_path ~base_path ~request_id with
    | Some path -> path
    | None -> Alcotest.fail "expected safe record path"
  in
  let stale_ts = entry.Keeper_msg_async.submitted_at -. 7200.0 in
  Fs_compat.save_file
    path
    (Yojson.Safe.to_string
       (`Assoc
           [ "request_id", `String request_id
           ; "keeper_name", `String entry.keeper_name
           ; "base_path", `String base_path
           ; "status", `String "done"
           ; "submitted_at", `Float stale_ts
           ; "completed_at", `Float stale_ts
           ; "ok", `Bool true
           ; "body", `String "{}"
           ]));
  Keeper_msg_async.For_testing.forget request_id;
  let removed = Keeper_msg_async.For_testing.gc_stale_disk ~base_path in
  Alcotest.(check int) "removed stale disk record" 1 removed;
  Alcotest.(check bool) "record file removed" false (Sys.file_exists path);
  match Keeper_msg_async.poll ~base_path request_id with
  | None -> ()
  | Some entry ->
    Alcotest.failf
      "expected stale disk record to be gone, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
;;

let test_keeper_msg_async_rejects_oversized_request_id () =
  let base_path = temp_dir "keeper-msg-id-limit-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let max_id = String.make 128 'a' in
       let too_long = String.make 129 'a' in
       check
         bool
         "128-char request id accepted"
         true
         (Option.is_some
            (Keeper_msg_async.For_testing.record_path ~base_path ~request_id:max_id));
       check
         (option string)
         "129-char request id rejected"
         None
         (Keeper_msg_async.For_testing.record_path ~base_path ~request_id:too_long))
;;

let test_yield_meter_noops_without_runnable_fiber () =
  let meter = Eio_guard.create_yield_meter ~interval:0 () in
  Eio_guard.enable ();
  Fun.protect ~finally:Eio_guard.disable (fun () ->
    Eio_guard.yield_step meter;
    Eio_guard.yield_step meter)
;;

let test_yield_meter_can_be_shared_across_fibers () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let meter = Eio_guard.create_yield_meter ~interval:2 () in
  for _ = 1 to 8 do
    Eio.Fiber.fork ~sw (fun () ->
      for _ = 1 to 50 do
        Eio_guard.yield_step meter
      done)
  done
;;

let () =
  run
    "keeper_mutex_coverage"
    [ ( "keeper_msg_async"
      , [ test_case "submit/poll roundtrip" `Quick test_keeper_msg_async_roundtrip
        ; test_case
            "recover completed request from disk"
            `Quick
            test_keeper_msg_async_recovers_done_from_disk
        ; test_case
            "recover in-flight request as lost"
            `Quick
            test_keeper_msg_async_marks_recovered_inflight_lost
        ; test_case
            "gc removes stale terminal disk record"
            `Quick
            test_keeper_msg_async_gc_removes_stale_terminal_disk_record
        ; test_case
            "oversized request id rejected"
            `Quick
            test_keeper_msg_async_rejects_oversized_request_id
        ] )
    ; ( "eio_guard"
      , [ test_case
            "yield meter noops without runnable fiber"
            `Quick
            test_yield_meter_noops_without_runnable_fiber
        ; test_case
            "yield meter can be shared across fibers"
            `Quick
            test_yield_meter_can_be_shared_across_fibers
        ] )
    ]
;;
