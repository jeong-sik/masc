open Alcotest
open Masc

let tr_ok body = Tool_result.ok ~tool_name:"keeper-test" ~start_time:0.0 body

let wait_for_done_with_clock clock request_id =
  let rec loop remaining =
    match Keeper_msg_async.poll request_id with
    | Keeper_msg_async.Found ({ status = Done _; _ } as entry) -> entry
    | _ when remaining <= 0 ->
      failwith (Printf.sprintf "request %s did not complete" request_id)
    | _ ->
      Eio.Time.sleep clock 0.01;
      loop (remaining - 1)
  in
  loop 100
;;

let wait_for_persisted_done_with_clock clock ~base_path request_id =
  let rec loop remaining =
    match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
    | Keeper_msg_async.Found ({ status = Done _; _ } as entry) -> entry
    | _ when remaining <= 0 ->
      failwith (Printf.sprintf "request %s did not persist done" request_id)
    | _ ->
      Eio.Time.sleep clock 0.01;
      loop (remaining - 1)
  in
  loop 100
;;

let wait_for_active_switch_count clock expected =
  let rec loop remaining =
    let actual = Keeper_msg_async.For_testing.active_switch_count () in
    if actual = expected
    then ()
    else if remaining <= 0
    then Alcotest.failf "active_switch_count expected %d, got %d" expected actual
    else (
      Eio.Time.sleep clock 0.01;
      loop (remaining - 1))
  in
  loop 100
;;

let wait_for_running request_id =
  let rec loop remaining =
    match Keeper_msg_async.poll request_id with
    | Keeper_msg_async.Found ({ status = Running; _ } as entry) -> entry
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
    | Keeper_msg_async.Found ({ status = Lost _; _ } as entry) -> entry
    | _ when remaining <= 0 ->
      failwith (Printf.sprintf "request %s did not become lost" request_id)
    | _ ->
      Eio.Fiber.yield ();
      loop (remaining - 1)
  in
  loop 200
;;

let wait_for_cancelled request_id =
  let rec loop remaining =
    match Keeper_msg_async.poll request_id with
    | Keeper_msg_async.Found ({ status = Cancelled _; _ } as entry) -> entry
    | _ when remaining <= 0 ->
      failwith (Printf.sprintf "request %s did not become cancelled" request_id)
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

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       really_input_string ic len)
;;

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()
;;

let source_file path = Filename.concat (source_root ()) path

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
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let base_path = temp_dir "keeper-msg-async-roundtrip-" in
  let request_id =
    Keeper_msg_async.submit
      ~sw
      ~base_path
      ~keeper_name:"alpha"
      ~f:(fun () ->
        Eio.Fiber.yield ();
        tr_ok (Yojson.Safe.to_string (`Assoc [ "kind", `String "done" ])))
      ()
  in
  let entry = wait_for_done_with_clock clock request_id in
  Alcotest.(check bool)
    "request completed"
    true
    (match entry.Keeper_msg_async.status with
     | Done { ok = true; body } -> String.length body > 0
     | _ -> false);
  Alcotest.(check int)
    "one pending entry"
    1
    (List.length (Keeper_msg_async.list_for_keeper ~keeper_name:"alpha" ()))
;;

let test_keeper_msg_async_recovers_done_from_disk () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let base_path = temp_dir "keeper-msg-async-done-" in
  let request_id =
    Keeper_msg_async.submit
      ~sw
      ~base_path
      ~keeper_name:"beta"
      ~f:(fun () ->
        Eio.Fiber.yield ();
        tr_ok (Yojson.Safe.to_string (`Assoc [ "kind", `String "done" ])))
      ()
  in
  let entry = wait_for_done_with_clock clock request_id in
  Alcotest.(check bool)
    "request completed before recovery"
    true
    (match entry.Keeper_msg_async.status with
     | Done { ok = true; _ } -> true
     | _ -> false);
  ignore
    (wait_for_persisted_done_with_clock clock ~base_path request_id
      : Keeper_msg_async.entry);
  Keeper_msg_async.For_testing.forget request_id;
  match Keeper_msg_async.poll ~base_path request_id with
  | Keeper_msg_async.Found { Keeper_msg_async.status = Done { ok = true; body }; _ } ->
    Alcotest.(check bool) "body persisted" true (String.length body > 0)
  | Keeper_msg_async.Found entry ->
    Alcotest.failf
      "expected recovered done, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
  | Keeper_msg_async.Absent | Keeper_msg_async.Unreadable _ ->
    Alcotest.fail "expected persisted request"
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
        tr_ok "{}")
      ()
  in
  ignore (wait_for_running request_id : Keeper_msg_async.entry);
  Keeper_msg_async.For_testing.forget request_id;
  match Keeper_msg_async.poll ~base_path request_id with
  | Keeper_msg_async.Found { Keeper_msg_async.status = Lost { reason }; _ } ->
    Alcotest.(check bool) "lost reason retained" true (String.length reason > 0);
    Keeper_msg_async.For_testing.forget request_id;
    (match Keeper_msg_async.poll ~base_path request_id with
     | Keeper_msg_async.Found { Keeper_msg_async.status = Lost _; _ } -> ()
     | Keeper_msg_async.Found entry ->
       Alcotest.failf
         "expected persisted lost, got %s"
         (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
     | Keeper_msg_async.Absent | Keeper_msg_async.Unreadable _ ->
       Alcotest.fail "expected persisted lost request")
  | Keeper_msg_async.Found entry ->
    Alcotest.failf
      "expected recovered lost, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
  | Keeper_msg_async.Absent | Keeper_msg_async.Unreadable _ ->
    Alcotest.fail "expected persisted request"
;;

let test_keeper_msg_async_recovery_sweep_marks_only_disk_only_inflight_lost () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-async-recover-sweep-" in
  let promise, _resolver = Eio.Promise.create () in
  let request_id =
    Keeper_msg_async.submit
      ~sw
      ~base_path
      ~keeper_name:"sweep"
      ~f:(fun () ->
        Eio.Promise.await promise;
        tr_ok "{}")
      ()
  in
  ignore (wait_for_running request_id : Keeper_msg_async.entry);
  Alcotest.(check int)
    "live in-memory worker is not recovered as lost"
    0
    (Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path);
  (match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
   | Keeper_msg_async.Found { Keeper_msg_async.status = Running; _ } -> ()
   | Keeper_msg_async.Found entry ->
     Alcotest.failf
       "expected live request to remain running, got %s"
       (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
   | Keeper_msg_async.Absent | Keeper_msg_async.Unreadable _ ->
     Alcotest.fail "expected persisted running request");
  Keeper_msg_async.For_testing.forget request_id;
  Alcotest.(check int)
    "disk-only in-flight request is recovered as lost"
    1
    (Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path);
  match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
  | Keeper_msg_async.Found { Keeper_msg_async.status = Lost { reason }; _ } ->
    Alcotest.(check bool) "lost reason retained" true (String.length reason > 0)
  | Keeper_msg_async.Found entry ->
    Alcotest.failf
      "expected recovered lost request, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
  | Keeper_msg_async.Absent | Keeper_msg_async.Unreadable _ ->
    Alcotest.fail "expected persisted lost request"
;;

let test_keeper_msg_async_marks_cancelled_worker_cancelled () =
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
          tr_ok "{}")
        ()
    in
    ignore (wait_for_running request_id : Keeper_msg_async.entry);
    request_id
  in
  match wait_for_cancelled request_id with
  | { Keeper_msg_async.status = Cancelled { reason; cancelled_by }; completed_at = Some _; _ } ->
    Alcotest.(check string) "cancelled_by runtime" "runtime" cancelled_by;
    Alcotest.(check bool) "cancelled reason mentions cancellation" true
      (contains_substring ~needle:"cancelled" (String.lowercase_ascii reason))
  | { Keeper_msg_async.status = Cancelled _; completed_at = None; _ } ->
    Alcotest.fail "expected cancelled request to have completed_at"
  | entry ->
    Alcotest.failf
      "expected cancelled request to be cancelled, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
;;

let test_keeper_msg_async_operator_cancel_is_terminal_cancelled () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-async-operator-cancel-" in
  let never, _resolver = Eio.Promise.create () in
  let request_id =
    Keeper_msg_async.submit
      ~sw
      ~base_path
      ~keeper_name:"operator-cancelled"
      ~f:(fun () ->
        Eio.Promise.await never;
        tr_ok "{}")
      ()
  in
  ignore (wait_for_running request_id : Keeper_msg_async.entry);
  Alcotest.(check bool)
    "cancel returns true"
    true
    (Keeper_msg_async.cancel ~base_path request_id);
  (match wait_for_cancelled request_id with
   | { Keeper_msg_async.status = Cancelled { reason; cancelled_by }; completed_at = Some _; _ } ->
     Alcotest.(check string) "cancelled_by operator" "operator" cancelled_by;
     Alcotest.(check bool) "reason mentions operator" true
       (contains_substring ~needle:"operator" (String.lowercase_ascii reason))
   | { Keeper_msg_async.status = Cancelled _; completed_at = None; _ } ->
     Alcotest.fail "expected operator-cancelled request to have completed_at"
   | entry ->
     Alcotest.failf
       "expected operator cancel to be cancelled, got %s"
       (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status));
  Keeper_msg_async.For_testing.forget request_id;
  (match Keeper_msg_async.poll ~base_path request_id with
   | Keeper_msg_async.Found { Keeper_msg_async.status = Cancelled { cancelled_by; _ }; _ } ->
     Alcotest.(check string) "persisted cancelled_by operator" "operator" cancelled_by
   | Keeper_msg_async.Found entry ->
     Alcotest.failf
       "expected persisted cancelled, got %s"
       (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
   | Keeper_msg_async.Absent | Keeper_msg_async.Unreadable _ ->
     Alcotest.fail "expected persisted cancelled request");
  Alcotest.(check bool)
    "second cancel returns false"
    false
    (Keeper_msg_async.cancel ~base_path request_id)
;;

let test_keeper_msg_async_timeout_is_terminal_error () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let base_path = temp_dir "keeper-msg-async-timeout-" in
  Alcotest.(check int)
    "no active switches before timeout request"
    0
    (Keeper_msg_async.For_testing.active_switch_count ());
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
        tr_ok (Yojson.Safe.to_string (`Assoc [ "kind", `String "late" ])))
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
  Alcotest.(check bool)
    "cancel after terminal timeout returns false"
    false
    (Keeper_msg_async.cancel ~base_path request_id);
  wait_for_active_switch_count clock 0;
  Eio.Promise.resolve notify_release_late ();
  Eio.Time.sleep clock 0.05;
  match Keeper_msg_async.poll request_id with
  | Keeper_msg_async.Found { Keeper_msg_async.status = Done { ok = false; body }; _ } ->
    Alcotest.(check string) "late worker result cannot overwrite timeout" timeout_body body
  | Keeper_msg_async.Found entry ->
    Alcotest.failf
      "expected timeout to remain terminal, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
  | Keeper_msg_async.Absent | Keeper_msg_async.Unreadable _ ->
    Alcotest.fail "expected timeout request to remain pollable"
;;

let test_keeper_msg_async_default_timeout_uses_turn_timeout () =
  let expected = Keeper_runtime_resolved.turn_timeout_sec () in
  Alcotest.(check (float 0.0001))
    "default async worker timeout"
    expected
    (Keeper_msg_async.For_testing.effective_timeout_sec ());
  Alcotest.(check (float 0.0001))
    "explicit async worker timeout wins"
    42.0
    (Keeper_msg_async.For_testing.effective_timeout_sec ~timeout_sec:42.0 ())
;;

let test_keeper_msg_async_gc_removes_stale_terminal_disk_record () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let base_path = temp_dir "keeper-msg-async-gc-" in
  let request_id =
    Keeper_msg_async.submit
      ~sw
      ~base_path
      ~keeper_name:"delta"
      ~f:(fun () ->
        Eio.Fiber.yield ();
        tr_ok "{}")
      ()
  in
  let entry = wait_for_done_with_clock clock request_id in
  ignore
    (wait_for_persisted_done_with_clock clock ~base_path request_id
      : Keeper_msg_async.entry);
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
  | Keeper_msg_async.Absent -> ()
  | Keeper_msg_async.Unreadable reason ->
    Alcotest.failf "expected stale disk record to be gone, got unreadable: %s" reason
  | Keeper_msg_async.Found entry ->
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

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let write_disk_record ~base_path ~request_id content =
  match Keeper_msg_async.For_testing.record_path ~base_path ~request_id with
  | None -> Alcotest.fail "expected safe record path"
  | Some path ->
    mkdir_p (Filename.dirname path);
    Fs_compat.save_file path content
;;

let test_keeper_msg_async_load_record_absent_id () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-load-absent-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       match
         Keeper_msg_async.For_testing.load_record
           ~base_path
           ~request_id:"kmsg_never_existed_0_0"
       with
       | Keeper_msg_async.Absent -> ()
       | Keeper_msg_async.Found _ -> Alcotest.fail "expected absent, got found"
       | Keeper_msg_async.Unreadable reason ->
         Alcotest.failf "expected absent, got unreadable: %s" reason)
;;

let test_keeper_msg_async_load_record_corrupt_json_is_unreadable () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-load-corrupt-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_corrupt_0_0" in
       write_disk_record ~base_path ~request_id "{ this is not json";
       (match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
        | Keeper_msg_async.Unreadable reason ->
          Alcotest.(check bool)
            "unreadable reason non-empty"
            true
            (String.length reason > 0)
        | Keeper_msg_async.Found _ -> Alcotest.fail "expected unreadable, got found"
        | Keeper_msg_async.Absent -> Alcotest.fail "expected unreadable, got absent");
       (* poll must surface the same distinction to callers. *)
       match Keeper_msg_async.poll ~base_path request_id with
       | Keeper_msg_async.Unreadable _ -> ()
       | Keeper_msg_async.Found _ -> Alcotest.fail "expected poll unreadable, got found"
       | Keeper_msg_async.Absent -> Alcotest.fail "expected poll unreadable, got absent")
;;

let test_keeper_msg_async_load_record_missing_status_is_unreadable () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-load-missing-status-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_missing_status_0_0" in
       write_disk_record
         ~base_path
         ~request_id
         (Yojson.Safe.to_string
            (`Assoc
                [ "request_id", `String request_id
                ; "keeper_name", `String "alpha"
                ; "submitted_at", `Float 1.0
                ]));
       match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
       | Keeper_msg_async.Unreadable reason ->
         Alcotest.(check bool)
           "reason mentions missing fields"
           true
           (contains_substring ~needle:"missing required fields" reason)
       | Keeper_msg_async.Found _ -> Alcotest.fail "expected unreadable, got found"
       | Keeper_msg_async.Absent -> Alcotest.fail "expected unreadable, got absent")
;;

let test_keeper_msg_async_load_record_unknown_status_is_unreadable () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-load-unknown-status-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_unknown_status_0_0" in
       write_disk_record
         ~base_path
         ~request_id
         (Yojson.Safe.to_string
            (`Assoc
                [ "request_id", `String request_id
                ; "keeper_name", `String "alpha"
                ; "status", `String "sideways"
                ; "submitted_at", `Float 1.0
                ]));
       match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
       | Keeper_msg_async.Unreadable reason ->
         Alcotest.(check bool)
           "reason mentions unknown status"
           true
           (contains_substring ~needle:"unknown status" reason)
       | Keeper_msg_async.Found _ -> Alcotest.fail "expected unreadable, got found"
       | Keeper_msg_async.Absent -> Alcotest.fail "expected unreadable, got absent")
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

let test_keeper_msg_async_persists_outside_global_mutex () =
  let source = read_file (source_file "lib/keeper/keeper_msg_async.ml") in
  Alcotest.(check bool)
    "set_status computes optional persist entry"
    true
    (contains_substring ~needle:"let to_persist =" source);
  Alcotest.(check bool)
    "persist happens after lock returns"
    true
    (contains_substring ~needle:"Option.iter persist_entry to_persist" source);
  Alcotest.(check bool)
    "status update does not persist while holding lock"
    false
    (contains_substring
       ~needle:"Hashtbl.replace pending request_id updated;\n      persist_entry updated"
       source)
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
            "recovery sweep marks only disk-only in-flight lost"
            `Quick
            test_keeper_msg_async_recovery_sweep_marks_only_disk_only_inflight_lost
        ; test_case
            "cancelled worker is terminal cancelled"
            `Quick
            test_keeper_msg_async_marks_cancelled_worker_cancelled
        ; test_case
            "operator cancel is terminal cancelled"
            `Quick
            test_keeper_msg_async_operator_cancel_is_terminal_cancelled
        ; test_case
            "timeout is terminal error"
            `Quick
            test_keeper_msg_async_timeout_is_terminal_error
        ; test_case
            "default timeout follows keeper turn timeout"
            `Quick
            test_keeper_msg_async_default_timeout_uses_turn_timeout
        ; test_case
            "gc removes stale terminal disk record"
            `Quick
            test_keeper_msg_async_gc_removes_stale_terminal_disk_record
        ; test_case
            "oversized request id rejected"
            `Quick
            test_keeper_msg_async_rejects_oversized_request_id
        ; test_case
            "load_record absent id is Absent"
            `Quick
            test_keeper_msg_async_load_record_absent_id
        ; test_case
            "load_record corrupt JSON is Unreadable"
            `Quick
            test_keeper_msg_async_load_record_corrupt_json_is_unreadable
        ; test_case
            "load_record missing status field is Unreadable"
            `Quick
            test_keeper_msg_async_load_record_missing_status_is_unreadable
        ; test_case
            "load_record unknown status is Unreadable"
            `Quick
            test_keeper_msg_async_load_record_unknown_status_is_unreadable
        ; test_case
            "persistence outside global mutex"
            `Quick
            test_keeper_msg_async_persists_outside_global_mutex
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
