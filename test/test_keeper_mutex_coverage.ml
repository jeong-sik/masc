open Alcotest
open Masc

let tr_ok body = Tool_result.ok ~tool_name:"keeper-test" ~start_time:0.0 body
let caller = "keeper-msg-test-caller"

let accepted_request_id = function
  | Ok request_id -> request_id
  | Error error ->
    Alcotest.failf
      "keeper_msg submission rejected: %s"
      (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string)
;;

let wait_for_done_with_clock clock ~base_path request_id =
  let rec loop remaining =
    match Keeper_msg_async.poll ~base_path ~caller request_id with
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

let wait_for_running ~base_path request_id =
  let rec loop remaining =
    match Keeper_msg_async.poll ~base_path ~caller request_id with
    | Keeper_msg_async.Found ({ status = Running; _ } as entry) -> entry
    | _ when remaining <= 0 ->
      failwith (Printf.sprintf "request %s did not start" request_id)
    | _ ->
      Eio.Fiber.yield ();
      loop (remaining - 1)
  in
  loop 200
;;

let wait_for_lost ~base_path request_id =
  let rec loop remaining =
    match Keeper_msg_async.poll ~base_path ~caller request_id with
    | Keeper_msg_async.Found ({ status = Lost _; _ } as entry) -> entry
    | _ when remaining <= 0 ->
      failwith (Printf.sprintf "request %s did not become lost" request_id)
    | _ ->
      Eio.Fiber.yield ();
      loop (remaining - 1)
  in
  loop 200
;;

let wait_for_cancelled ~base_path request_id =
  let rec loop remaining =
    match Keeper_msg_async.poll ~base_path ~caller request_id with
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
      ~background_sw:sw
      ~base_path
      ~caller
      ~keeper_name:"alpha"
      ~f:(fun _request_sw ->
        Eio.Fiber.yield ();
        tr_ok (Yojson.Safe.to_string (`Assoc [ "kind", `String "done" ])))
      ()
    |> accepted_request_id
  in
  let entry = wait_for_done_with_clock clock ~base_path request_id in
  Alcotest.(check string) "submitted_by persisted in memory" caller entry.submitted_by;
  Alcotest.(check string)
    "base_path stored as canonical identity"
    (Fs_compat.realpath base_path)
    entry.base_path;
  Alcotest.(check bool)
    "request completed"
    true
    (match entry.Keeper_msg_async.status with
     | Done { ok = true; body; _ } -> String.length body > 0
     | _ -> false);
  Alcotest.(check int)
    "one pending entry"
    1
    (match
       Keeper_msg_async.list_for_keeper
         ~base_path ~caller ~keeper_name:"alpha" ()
     with
     | Ok entries -> List.length entries
     | Error rejection ->
       Alcotest.failf
         "queue access rejected: %s"
         (Keeper_msg_async.access_rejection_to_json rejection
          |> Yojson.Safe.to_string))
  ;
  (match Keeper_msg_async.poll ~base_path ~caller:"different-caller" request_id with
   | Keeper_msg_async.Rejected Keeper_msg_async.Caller_mismatch -> ()
   | _ -> Alcotest.fail "cross-caller poll must be rejected");
  (match
     Keeper_msg_async.list_for_keeper
       ~base_path ~caller:"different-caller" ~keeper_name:"alpha" ()
   with
   | Ok [] -> ()
   | Ok _ -> Alcotest.fail "cross-caller queue entries must be omitted"
   | Error _ -> Alcotest.fail "valid different caller identity should produce an empty queue")
;;

let test_keeper_msg_async_list_isolates_base_paths () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let base_a = temp_dir "keeper-msg-list-base-a-" in
  let base_b = temp_dir "keeper-msg-list-base-b-" in
  let submit base_path keeper_name =
    Keeper_msg_async.submit
      ~background_sw:sw
      ~base_path
      ~caller
      ~keeper_name
      ~f:(fun _request_sw -> tr_ok "{}")
      ()
    |> accepted_request_id
  in
  let request_a = submit base_a "alpha" in
  let request_b = submit base_b "beta" in
  ignore (wait_for_done_with_clock clock ~base_path:base_a request_a : Keeper_msg_async.entry);
  ignore (wait_for_done_with_clock clock ~base_path:base_b request_b : Keeper_msg_async.entry);
  let request_ids base_path =
    match Keeper_msg_async.list_for_keeper ~base_path ~caller () with
    | Ok entries -> List.map (fun (entry : Keeper_msg_async.entry) -> entry.request_id) entries
    | Error rejection ->
      Alcotest.failf
        "queue access rejected: %s"
        (Keeper_msg_async.access_rejection_to_json rejection |> Yojson.Safe.to_string)
  in
  Alcotest.(check (list string)) "base A sees only its owner lane" [ request_a ] (request_ids base_a);
  Alcotest.(check (list string)) "base B sees only its owner lane" [ request_b ] (request_ids base_b)
;;

let test_keeper_msg_async_recovers_done_from_disk () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let base_path = temp_dir "keeper-msg-async-done-" in
  let expected_data = `Assoc [ "kind", `String "done" ] in
  let request_id =
    Keeper_msg_async.submit
      ~background_sw:sw
      ~base_path
      ~caller
      ~keeper_name:"beta"
      ~f:(fun _request_sw ->
        Eio.Fiber.yield ();
        Tool_result.make_ok
          ~tool_name:"keeper-test"
          ~start_time:0.0
          ~data:expected_data
          ())
      ()
    |> accepted_request_id
  in
  let entry = wait_for_done_with_clock clock ~base_path request_id in
  Alcotest.(check bool)
    "request completed before recovery"
    true
    (match entry.Keeper_msg_async.status with
     | Done { ok = true; _ } -> true
     | _ -> false);
  ignore
    (wait_for_persisted_done_with_clock clock ~base_path request_id
      : Keeper_msg_async.entry);
  Keeper_msg_async.For_testing.forget ~base_path ~caller ~request_id;
  match Keeper_msg_async.poll ~base_path ~caller request_id with
  | Keeper_msg_async.Found
      { Keeper_msg_async.status = Done { ok = true; body; data = Some data }; _ } ->
    Alcotest.(check bool) "body persisted" true (String.length body > 0);
    Alcotest.(check bool)
      "typed data persisted"
      true
      (Yojson.Safe.equal expected_data data)
  | Keeper_msg_async.Found
      { Keeper_msg_async.status = Done { ok = true; data = None; _ }; _ } ->
    Alcotest.fail "expected persisted typed data"
  | Keeper_msg_async.Found entry ->
    Alcotest.failf
      "expected recovered done, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
  | Keeper_msg_async.Absent
  | Keeper_msg_async.Unreadable _
  | Keeper_msg_async.Rejected _ ->
    Alcotest.fail "expected persisted request"
;;

let test_keeper_msg_async_survives_submitter_turn_switch () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun root_sw ->
  let clock = Eio.Stdenv.clock env in
  let base_path = temp_dir "keeper-msg-root-lifetime-" in
  let worker_started, resolve_worker_started = Eio.Promise.create () in
  let release_worker, resolve_release_worker = Eio.Promise.create () in
  let request_switch_is_turn_switch = Atomic.make true in
  let request_id =
    Eio.Switch.run
    @@ fun turn_sw ->
    let request_id =
      Keeper_msg_async.submit
        ~background_sw:root_sw
        ~base_path
        ~caller
        ~keeper_name:"root-lifetime"
        ~f:(fun request_sw ->
          Atomic.set request_switch_is_turn_switch (request_sw == turn_sw);
          Eio.Promise.resolve resolve_worker_started ();
          Eio.Promise.await release_worker;
          tr_ok "{}")
        ()
      |> accepted_request_id
    in
    Eio.Promise.await worker_started;
    request_id
  in
  Alcotest.(check bool)
    "request uses a per-entry switch, not the submitter turn switch"
    false
    (Atomic.get request_switch_is_turn_switch);
  Eio.Promise.resolve resolve_release_worker ();
  ignore (wait_for_done_with_clock clock ~base_path request_id : Keeper_msg_async.entry)
;;

let test_keeper_msg_async_resolves_server_root_switch () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun root_sw ->
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw:root_sw
  @@ fun () ->
  Eio.Switch.run
  @@ fun turn_sw ->
  Eio_context.with_turn_switch turn_sw
  @@ fun () ->
  match Keeper_msg_async.server_background_switch () with
  | Error error ->
      Alcotest.failf
        "server background switch rejected: %s"
        (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string)
  | Ok resolved ->
      Alcotest.(check bool) "server root is selected" true (resolved == root_sw);
      Alcotest.(check bool) "turn-local switch is not selected" false (resolved == turn_sw)
;;

let test_keeper_msg_async_does_not_accept_failed_initial_persistence () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun background_sw ->
  let base_path = Filename.temp_file "keeper-msg-non-directory-base-" "" in
  Fun.protect
    ~finally:(fun () -> Sys.remove base_path)
    (fun () ->
       let worker_ran = Atomic.make false in
       match
         Keeper_msg_async.submit
           ~background_sw
           ~base_path
           ~caller
           ~keeper_name:"initial-persist-failure"
           ~f:(fun _request_sw ->
             Atomic.set worker_ran true;
             tr_ok "{}")
           ()
       with
       | Error (Keeper_msg_async.Initial_persistence_failed _) ->
         Alcotest.(check bool) "worker was not started" false (Atomic.get worker_ran)
       | Error error ->
         Alcotest.failf
           "expected initial persistence failure, got %s"
           (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string)
       | Ok request_id ->
         Alcotest.failf "request %s was ACKed without initial persistence" request_id)
;;

let test_keeper_msg_async_rejects_invalid_timeout_before_acceptance () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun background_sw ->
  let base_path = temp_dir "keeper-msg-invalid-timeout-" in
  let worker_ran = Atomic.make false in
  List.iter
    (fun timeout_sec ->
       match
         Keeper_msg_async.submit
           ~background_sw
           ~base_path
           ~caller
           ~timeout_sec
           ~keeper_name:"invalid-timeout"
           ~f:(fun _request_sw ->
             Atomic.set worker_ran true;
             tr_ok "{}")
           ()
       with
       | Error (Keeper_msg_async.Invalid_timeout _) -> ()
       | Error error ->
           Alcotest.failf
             "expected invalid timeout rejection, got %s"
             (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string)
       | Ok request_id ->
           Alcotest.failf
             "invalid timeout was accepted as request %s"
             request_id)
    [ 0.0; -1.0; Float.nan; Float.infinity; Float.neg_infinity ];
  Alcotest.(check bool) "invalid timeout never starts a worker" false (Atomic.get worker_ran);
  match Keeper_msg_async.list_for_keeper ~base_path ~caller () with
  | Ok [] -> ()
  | Ok _ -> Alcotest.fail "invalid timeout created an in-memory request"
  | Error rejection ->
      Alcotest.failf
        "valid owner lane rejected after invalid timeout: %s"
        (Keeper_msg_async.access_rejection_to_json rejection |> Yojson.Safe.to_string)
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
      ~background_sw:sw
      ~base_path
      ~caller
      ~keeper_name:"gamma"
      ~f:(fun _request_sw ->
        Eio.Promise.await promise;
        tr_ok "{}")
      ()
    |> accepted_request_id
  in
  ignore (wait_for_running ~base_path request_id : Keeper_msg_async.entry);
  (match
     Keeper_msg_async.cancel ~base_path ~caller:"different-caller" request_id
   with
   | Keeper_msg_async.Cancel_rejected Keeper_msg_async.Caller_mismatch -> ()
   | _ -> Alcotest.fail "cross-caller cancellation must be rejected before switch failure");
  (match Keeper_msg_async.poll ~base_path ~caller request_id with
   | Keeper_msg_async.Found { status = Running; _ } -> ()
   | _ -> Alcotest.fail "rejected cross-caller cancellation must leave worker running");
  Keeper_msg_async.For_testing.forget ~base_path ~caller ~request_id;
  match Keeper_msg_async.poll ~base_path ~caller request_id with
  | Keeper_msg_async.Found { Keeper_msg_async.status = Lost { reason }; _ } ->
    Alcotest.(check bool) "lost reason retained" true (String.length reason > 0);
    Keeper_msg_async.For_testing.forget ~base_path ~caller ~request_id;
    (match Keeper_msg_async.poll ~base_path ~caller request_id with
     | Keeper_msg_async.Found { Keeper_msg_async.status = Lost _; _ } -> ()
     | Keeper_msg_async.Found entry ->
       Alcotest.failf
         "expected persisted lost, got %s"
         (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
     | Keeper_msg_async.Absent
     | Keeper_msg_async.Unreadable _
     | Keeper_msg_async.Rejected _ ->
       Alcotest.fail "expected persisted lost request")
  | Keeper_msg_async.Found entry ->
    Alcotest.failf
      "expected recovered lost, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
  | Keeper_msg_async.Absent
  | Keeper_msg_async.Unreadable _
  | Keeper_msg_async.Rejected _ ->
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
      ~background_sw:sw
      ~base_path
      ~caller
      ~keeper_name:"sweep"
      ~f:(fun _request_sw ->
        Eio.Promise.await promise;
        tr_ok "{}")
      ()
    |> accepted_request_id
  in
  ignore (wait_for_running ~base_path request_id : Keeper_msg_async.entry);
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
   | Keeper_msg_async.Absent
   | Keeper_msg_async.Unreadable _
   | Keeper_msg_async.Rejected _ ->
     Alcotest.fail "expected persisted running request");
  Keeper_msg_async.For_testing.forget ~base_path ~caller ~request_id;
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
  | Keeper_msg_async.Absent
  | Keeper_msg_async.Unreadable _
  | Keeper_msg_async.Rejected _ ->
    Alcotest.fail "expected persisted lost request"
;;

let test_keeper_msg_async_marks_cancelled_worker_cancelled () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-async-cancel-" in
  let request_id =
    Eio.Switch.run
    @@ fun sw ->
    let never, _resolver = Eio.Promise.create () in
    let request_id =
      Keeper_msg_async.submit
        ~background_sw:sw
        ~base_path
        ~caller
        ~keeper_name:"cancelled"
        ~f:(fun _request_sw ->
          Eio.Promise.await never;
          tr_ok "{}")
        ()
      |> accepted_request_id
    in
    ignore (wait_for_running ~base_path request_id : Keeper_msg_async.entry);
    request_id
  in
  match wait_for_cancelled ~base_path request_id with
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
      ~background_sw:sw
      ~base_path
      ~caller
      ~keeper_name:"operator-cancelled"
      ~f:(fun _request_sw ->
        Eio.Promise.await never;
        tr_ok "{}")
      ()
    |> accepted_request_id
  in
  ignore (wait_for_running ~base_path request_id : Keeper_msg_async.entry);
  Alcotest.(check bool)
    "cancel returns true"
    true
    (Keeper_msg_async.cancel ~base_path ~caller request_id
     = Keeper_msg_async.Cancelled_request);
  (match wait_for_cancelled ~base_path request_id with
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
  Keeper_msg_async.For_testing.forget ~base_path ~caller ~request_id;
  (match Keeper_msg_async.poll ~base_path ~caller request_id with
   | Keeper_msg_async.Found { Keeper_msg_async.status = Cancelled { cancelled_by; _ }; _ } ->
     Alcotest.(check string) "persisted cancelled_by operator" "operator" cancelled_by
   | Keeper_msg_async.Found entry ->
     Alcotest.failf
       "expected persisted cancelled, got %s"
       (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
   | Keeper_msg_async.Absent
   | Keeper_msg_async.Unreadable _
   | Keeper_msg_async.Rejected _ ->
     Alcotest.fail "expected persisted cancelled request");
  Alcotest.(check bool)
    "second cancel returns false"
    false
    (match Keeper_msg_async.cancel ~base_path ~caller request_id with
     | Keeper_msg_async.Cancel_already_terminal _ -> false
     | _ -> true)
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
      ~background_sw:sw
      ~base_path
      ~caller
      ~keeper_name:"timeout"
      ~f:(fun _request_sw ->
        Eio.Promise.await release_late;
        tr_ok (Yojson.Safe.to_string (`Assoc [ "kind", `String "late" ])))
      ()
    |> accepted_request_id
  in
  let entry = wait_for_done_with_clock clock ~base_path request_id in
  let timeout_body =
    match entry.Keeper_msg_async.status with
    | Done { ok = false; body; _ } ->
      Alcotest.(check bool)
        "timeout completion timestamp"
        true
        (Option.is_some entry.completed_at);
      body
    | Done { ok = true; body; _ } ->
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
    (match Keeper_msg_async.cancel ~base_path ~caller request_id with
     | Keeper_msg_async.Cancel_already_terminal _ -> false
     | _ -> true);
  wait_for_active_switch_count clock 0;
  Eio.Promise.resolve notify_release_late ();
  Eio.Time.sleep clock 0.05;
  match Keeper_msg_async.poll ~base_path ~caller request_id with
  | Keeper_msg_async.Found { Keeper_msg_async.status = Done { ok = false; body; _ }; _ } ->
    Alcotest.(check string) "late worker result cannot overwrite timeout" timeout_body body
  | Keeper_msg_async.Found entry ->
    Alcotest.failf
      "expected timeout to remain terminal, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
  | Keeper_msg_async.Absent
  | Keeper_msg_async.Unreadable _
  | Keeper_msg_async.Rejected _ ->
    Alcotest.fail "expected timeout request to remain pollable"
;;

let test_keeper_msg_async_timeout_is_explicit_only () =
  Alcotest.(check (option (float 0.0001)))
    "default async worker has no outer timeout"
    None
    (Keeper_msg_async.For_testing.effective_timeout_sec ());
  Alcotest.(check (option (float 0.0001)))
    "explicit async worker timeout is preserved"
    (Some 42.0)
    (Keeper_msg_async.For_testing.effective_timeout_sec ~timeout_sec:42.0 ())
;;

let test_keeper_msg_async_explicit_timeout_requires_clock () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun background_sw ->
  let base_path = temp_dir "keeper-msg-async-clock-required-" in
  match
    Keeper_msg_async.submit
      ~timeout_sec:1.0
      ~background_sw
      ~base_path
      ~caller
      ~keeper_name:"clock-required"
      ~f:(fun _request_sw -> tr_ok "{}")
      ()
  with
  | Error (Keeper_msg_async.Invalid_timeout { reason }) ->
    Alcotest.(check string)
      "typed clock requirement"
      "keeper_msg explicit timeout_sec requires an Eio clock"
      reason
  | Error error ->
    Alcotest.failf
      "expected explicit-timeout clock rejection, got %s"
      (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string)
  | Ok request_id ->
    Alcotest.failf "explicit timeout without clock was accepted as %s" request_id
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
      ~background_sw:sw
      ~base_path
      ~caller
      ~keeper_name:"delta"
      ~f:(fun _request_sw ->
        Eio.Fiber.yield ();
        tr_ok "{}")
      ()
    |> accepted_request_id
  in
  let entry = wait_for_done_with_clock clock ~base_path request_id in
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
           [ "schema_version", `Int Keeper_msg_async.For_testing.record_schema_version
           ; "request_id", `String request_id
           ; "keeper_name", `String entry.keeper_name
           ; "base_path", `String entry.base_path
           ; "submitted_by", `String caller
           ; "status", `String "done"
           ; "submitted_at", `Float stale_ts
           ; "completed_at", `Float stale_ts
           ; "ok", `Bool true
           ; "body", `String "{}"
           ]));
  Keeper_msg_async.For_testing.forget ~base_path ~caller ~request_id;
  let removed = Keeper_msg_async.For_testing.gc_stale_disk ~base_path in
  Alcotest.(check int) "removed stale disk record" 1 removed;
  Alcotest.(check bool) "record file removed" false (Sys.file_exists path);
  match Keeper_msg_async.poll ~base_path ~caller request_id with
  | Keeper_msg_async.Absent -> ()
  | Keeper_msg_async.Unreadable reason ->
    Alcotest.failf "expected stale disk record to be gone, got unreadable: %s" reason
  | Keeper_msg_async.Found entry ->
    Alcotest.failf
      "expected stale disk record to be gone, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
  | Keeper_msg_async.Rejected rejection ->
    Alcotest.failf
      "expected stale disk record to be gone, got rejected: %s"
      (Keeper_msg_async.access_rejection_to_json rejection |> Yojson.Safe.to_string)
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

let test_keeper_msg_async_loads_v2_done_without_typed_data () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-load-v2-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_v2_done_0_0" in
       let body = {|{"legacy":"opaque"}|} in
       write_disk_record
         ~base_path
         ~request_id
         (Yojson.Safe.to_string
            (`Assoc
                [ "schema_version", `Int 2
                ; "request_id", `String request_id
                ; "keeper_name", `String "alpha"
                ; "base_path", `String (Fs_compat.realpath base_path)
                ; "submitted_by", `String caller
                ; "status", `String "done"
                ; "submitted_at", `Float 1.0
                ; "completed_at", `Float 2.0
                ; "ok", `Bool true
                ; "body", `String body
                ]));
       match Keeper_msg_async.poll ~base_path ~caller request_id with
       | Keeper_msg_async.Found
           ({ status = Done { ok = true; body = loaded; data = None }; _ } as entry) ->
         Alcotest.(check string) "v2 body stays opaque" body loaded;
         Alcotest.(check string)
           "v2 poll projection stays a string"
           body
           Yojson.Safe.Util.(Keeper_msg_async.entry_to_json entry |> member "result" |> to_string)
       | Keeper_msg_async.Found entry ->
         Alcotest.failf
           "expected recovered v2 done, got %s"
           (Keeper_msg_async.status_to_string entry.status)
       | Keeper_msg_async.Unreadable reason ->
         Alcotest.failf "expected v2 compatibility, got unreadable: %s" reason
       | Keeper_msg_async.Absent -> Alcotest.fail "expected v2 record"
       | Keeper_msg_async.Rejected _ -> Alcotest.fail "expected v2 owner access")
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
         Alcotest.failf "expected absent, got unreadable: %s" reason
       | Keeper_msg_async.Rejected _ -> Alcotest.fail "expected absent, got rejected")
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
        | Keeper_msg_async.Absent -> Alcotest.fail "expected unreadable, got absent"
        | Keeper_msg_async.Rejected _ -> Alcotest.fail "expected unreadable, got rejected");
       (* poll must surface the same distinction to callers. *)
       match Keeper_msg_async.poll ~base_path ~caller request_id with
       | Keeper_msg_async.Unreadable _ -> ()
       | Keeper_msg_async.Found _ -> Alcotest.fail "expected poll unreadable, got found"
       | Keeper_msg_async.Absent -> Alcotest.fail "expected poll unreadable, got absent"
       | Keeper_msg_async.Rejected _ -> Alcotest.fail "expected poll unreadable, got rejected")
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
                [ "schema_version", `Int Keeper_msg_async.For_testing.record_schema_version
                ; "request_id", `String request_id
                ; "keeper_name", `String "alpha"
                ; "base_path", `String (Fs_compat.realpath base_path)
                ; "submitted_by", `String caller
                ; "submitted_at", `Float 1.0
                ]));
       match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
       | Keeper_msg_async.Unreadable reason ->
         Alcotest.(check bool)
           "reason mentions missing fields"
           true
           (contains_substring ~needle:"missing required string field \"status\"" reason)
       | Keeper_msg_async.Found _ -> Alcotest.fail "expected unreadable, got found"
       | Keeper_msg_async.Absent -> Alcotest.fail "expected unreadable, got absent"
       | Keeper_msg_async.Rejected _ -> Alcotest.fail "expected unreadable, got rejected")
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
                [ "schema_version", `Int Keeper_msg_async.For_testing.record_schema_version
                ; "request_id", `String request_id
                ; "keeper_name", `String "alpha"
                ; "base_path", `String (Fs_compat.realpath base_path)
                ; "submitted_by", `String caller
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
       | Keeper_msg_async.Absent -> Alcotest.fail "expected unreadable, got absent"
       | Keeper_msg_async.Rejected _ -> Alcotest.fail "expected unreadable, got rejected")
;;

let test_keeper_msg_async_rejects_ownerless_v1_record () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-load-v1-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_ownerless_v1_0_0" in
       write_disk_record
         ~base_path
         ~request_id
         (Yojson.Safe.to_string
            (`Assoc
                [ "schema_version", `Int 1
                ; "request_id", `String request_id
                ; "keeper_name", `String "alpha"
                ; "base_path", `String (Fs_compat.realpath base_path)
                ; "status", `String "queued"
                ; "submitted_at", `Float 1.0
                ]));
       match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
       | Keeper_msg_async.Unreadable reason ->
         Alcotest.(check bool)
           "v1 hard cut is explicit"
           true
           (contains_substring ~needle:"unsupported keeper_msg request schema_version=1" reason)
       | Keeper_msg_async.Found _ -> Alcotest.fail "ownerless v1 record must not load"
       | Keeper_msg_async.Absent -> Alcotest.fail "ownerless v1 record unexpectedly absent"
       | Keeper_msg_async.Rejected _ -> Alcotest.fail "ownerless v1 is a schema error")
;;

let test_keeper_msg_async_rejects_filename_request_id_mismatch () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-load-id-mismatch-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_filename_id_0_0" in
       write_disk_record
         ~base_path
         ~request_id
         (Yojson.Safe.to_string
            (`Assoc
                [ "schema_version", `Int Keeper_msg_async.For_testing.record_schema_version
                ; "request_id", `String "kmsg_different_id_0_0"
                ; "keeper_name", `String "alpha"
                ; "base_path", `String (Fs_compat.realpath base_path)
                ; "submitted_by", `String caller
                ; "status", `String "queued"
                ; "submitted_at", `Float 1.0
                ]));
       match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
       | Keeper_msg_async.Unreadable reason ->
         Alcotest.(check bool)
           "filename/request id consistency is enforced"
           true
           (contains_substring ~needle:"does not match filename request_id" reason)
       | Keeper_msg_async.Found _ -> Alcotest.fail "mismatched request id must not load"
       | Keeper_msg_async.Absent -> Alcotest.fail "mismatched record unexpectedly absent"
       | Keeper_msg_async.Rejected _ -> Alcotest.fail "mismatched id is a record error")
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
            "list isolates canonical BasePath owner lanes"
            `Quick
            test_keeper_msg_async_list_isolates_base_paths
        ; test_case
            "recover completed request from disk"
            `Quick
            test_keeper_msg_async_recovers_done_from_disk
        ; test_case
            "request survives submitter turn switch"
            `Quick
            test_keeper_msg_async_survives_submitter_turn_switch
        ; test_case
            "server root switch ignores turn-local binding"
            `Quick
            test_keeper_msg_async_resolves_server_root_switch
        ; test_case
            "initial persistence failure is not accepted"
            `Quick
            test_keeper_msg_async_does_not_accept_failed_initial_persistence
        ; test_case
            "invalid timeout is rejected before acceptance"
            `Quick
            test_keeper_msg_async_rejects_invalid_timeout_before_acceptance
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
            "async worker timeout is explicit only"
            `Quick
            test_keeper_msg_async_timeout_is_explicit_only
        ; test_case
            "explicit async timeout requires a clock"
            `Quick
            test_keeper_msg_async_explicit_timeout_requires_clock
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
            "v2 terminal record preserves opaque body"
            `Quick
            test_keeper_msg_async_loads_v2_done_without_typed_data
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
            "ownerless v1 record is rejected"
            `Quick
            test_keeper_msg_async_rejects_ownerless_v1_record
        ; test_case
            "filename request id mismatch is rejected"
            `Quick
            test_keeper_msg_async_rejects_filename_request_id_mismatch
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
