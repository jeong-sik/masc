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

let wait_for_done_with_clock clock request_id =
  let rec loop remaining =
    match Keeper_msg_async.poll request_id with
    | Some ({ status = Done _; _ } as entry) -> entry
    | _ when remaining <= 0 ->
      failwith (Printf.sprintf "request %s did not complete" request_id)
    | _ ->
      Eio.Time.sleep clock 0.01;
      loop (remaining - 1)
  in
  loop 100
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

let wait_for_lost request_id =
  let rec loop remaining =
    match Keeper_msg_async.poll request_id with
    | Some ({ status = Lost _; _ } as entry) -> entry
    | _ when remaining <= 0 ->
      failwith (Printf.sprintf "request %s did not become lost" request_id)
    | _ ->
      Eio.Fiber.yield ();
      loop (remaining - 1)
  in
  loop 200
;;

let contains_substring ~needle value =
  let needle_len = String.length needle in
  let value_len = String.length value in
  if needle_len = 0
  then true
  else if needle_len > value_len
  then false
  else (
    let rec loop i =
      if i + needle_len > value_len
      then false
      else if String.equal (String.sub value i needle_len) needle
      then true
      else loop (i + 1)
    in
    loop 0)
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
    Keeper_msg_async.submit
      ~sw
      ~base_path
      ~keeper_name:"alpha"
      ~f:(fun () ->
        Eio.Fiber.yield ();
        true, Yojson.Safe.to_string (`Assoc [ "kind", `String "done" ]))
      ()
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
    Keeper_msg_async.submit
      ~sw
      ~base_path
      ~keeper_name:"beta"
      ~f:(fun () ->
        Eio.Fiber.yield ();
        true, Yojson.Safe.to_string (`Assoc [ "kind", `String "done" ]))
      ()
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
    Keeper_msg_async.submit
      ~sw
      ~base_path
      ~keeper_name:"gamma"
      ~f:(fun () ->
        Eio.Promise.await promise;
        true, "{}")
      ()
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

let test_keeper_msg_async_marks_cancelled_worker_lost () =
  with_eio_env
  @@ fun _env ->
  let request_id =
    Eio.Switch.run
    @@ fun sw ->
    let never, _resolver = Eio.Promise.create () in
    let request_id =
      Keeper_msg_async.submit
        ~sw
        ~base_path:(temp_dir "keeper-msg-async-cancel-")
        ~keeper_name:"cancelled"
        ~f:(fun () ->
          Eio.Promise.await never;
          true, "{}")
        ()
    in
    ignore (wait_for_running request_id : Keeper_msg_async.entry);
    request_id
  in
  match wait_for_lost request_id with
  | { Keeper_msg_async.status = Lost { reason }; completed_at = Some _; _ } ->
    Alcotest.(check bool) "lost reason mentions cancellation" true
      (contains_substring ~needle:"cancelled" (String.lowercase_ascii reason))
  | { Keeper_msg_async.status = Lost _; completed_at = None; _ } ->
    Alcotest.fail "expected cancelled request to have completed_at"
  | entry ->
    Alcotest.failf
      "expected cancelled request to be lost, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
;;

let test_keeper_msg_async_timeout_is_terminal_error () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let base_path = temp_dir "keeper-msg-async-timeout-" in
  let release_late, notify_release_late = Eio.Promise.create () in
  let request_id =
    Keeper_msg_async.submit
      ~clock
      ~timeout_sec:0.02
      ~sw
      ~base_path
      ~keeper_name:"timeout"
      ~f:(fun () ->
        Eio.Promise.await release_late;
        true, Yojson.Safe.to_string (`Assoc [ "kind", `String "late" ]))
      ()
  in
  let entry = wait_for_done_with_clock clock request_id in
  let timeout_body =
    match entry.Keeper_msg_async.status with
    | Done { ok = false; body } ->
      Alcotest.(check bool)
        "timeout completion timestamp"
        true
        (Option.is_some entry.completed_at);
      body
    | Done { ok = true; body } ->
      Alcotest.failf "expected timeout error, got ok body=%s" body
    | status ->
      Alcotest.failf
        "expected timeout error, got %s"
        (Keeper_msg_async.status_to_string status)
  in
  (match Yojson.Safe.from_string timeout_body with
   | `Assoc fields ->
     Alcotest.(check (option string))
       "timeout error code"
       (Some "keeper_msg_timeout")
       (Option.bind
          (List.assoc_opt "error" fields)
          (function
          | `String value -> Some value
          | _ -> None))
   | _ -> Alcotest.fail "expected timeout body JSON object");
  Eio.Promise.resolve notify_release_late ();
  Eio.Time.sleep clock 0.05;
  match Keeper_msg_async.poll request_id with
  | Some { Keeper_msg_async.status = Done { ok = false; body }; _ } ->
    Alcotest.(check string) "late worker result cannot overwrite timeout" timeout_body body
  | Some entry ->
    Alcotest.failf
      "expected timeout to remain terminal, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
  | None -> Alcotest.fail "expected timeout request to remain pollable"
;;

let test_keeper_msg_async_gc_removes_stale_terminal_disk_record () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-async-gc-" in
  let request_id =
    Keeper_msg_async.submit
      ~sw
      ~base_path
      ~keeper_name:"delta"
      ~f:(fun () ->
        Eio.Fiber.yield ();
        true, "{}")
      ()
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

let test_voice_output_turn_serializes_speakers () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let first_entered, notify_first_entered = Eio.Promise.create () in
  let release_first, notify_release_first = Eio.Promise.create () in
  let second_done, notify_second_done = Eio.Promise.create () in
  let second_entered = Atomic.make false in
  Eio.Fiber.fork ~sw (fun () ->
    Voice_bridge_core.with_voice_output_turn ~agent_id:"first" (fun () ->
      Eio.Promise.resolve notify_first_entered ();
      Eio.Promise.await release_first));
  Eio.Promise.await first_entered;
  Eio.Fiber.fork ~sw (fun () ->
    Voice_bridge_core.with_voice_output_turn ~agent_id:"second" (fun () ->
      Atomic.set second_entered true;
      Eio.Promise.resolve notify_second_done ()));
  for _ = 1 to 10 do
    Eio.Fiber.yield ()
  done;
  Alcotest.(check bool)
    "second speaker waits while first holds the output turn"
    false
    (Atomic.get second_entered);
  Eio.Promise.resolve notify_release_first ();
  Eio.Promise.await second_done;
  Alcotest.(check bool)
    "second speaker enters after first releases"
    true
    (Atomic.get second_entered)
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
            "cancelled worker is terminal lost"
            `Quick
            test_keeper_msg_async_marks_cancelled_worker_lost
        ; test_case
            "timeout is terminal error"
            `Quick
            test_keeper_msg_async_timeout_is_terminal_error
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
    ; ( "voice_bridge"
      , [ test_case
            "output turn serializes speakers"
            `Quick
            test_voice_output_turn_serializes_speakers
        ] )
    ]
;;
