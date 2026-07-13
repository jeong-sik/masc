open Alcotest
open Masc

let tr_ok body = Tool_result.ok ~tool_name:"keeper-test" ~start_time:0.0 body
let caller = "keeper-msg-test-caller"

let accepted_request_id = function
  | Ok
      ({ acceptance = Keeper_msg_async.Durably_accepted; request_id }
        : Keeper_msg_async.submit_outcome) ->
      request_id
  | Ok outcome ->
    Alcotest.failf
      "keeper_msg submission requires reconciliation: %s"
      (Keeper_msg_async.submit_outcome_to_json outcome |> Yojson.Safe.to_string)
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
     | Done { ok = true; body } -> String.length body > 0
     | _ -> false);
  Alcotest.(check int)
    "terminal entry leaves active memory index"
    0
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
  let release_a, resolve_release_a = Eio.Promise.create () in
  let release_b, resolve_release_b = Eio.Promise.create () in
  let submit base_path keeper_name release =
    Keeper_msg_async.submit
      ~background_sw:sw
      ~base_path
      ~caller
      ~keeper_name
      ~f:(fun _request_sw ->
        Eio.Promise.await release;
        tr_ok "{}")
      ()
    |> accepted_request_id
  in
  let request_a = submit base_a "alpha" release_a in
  let request_b = submit base_b "beta" release_b in
  let request_ids base_path =
    match Keeper_msg_async.list_for_keeper ~base_path ~caller () with
    | Ok entries -> List.map (fun (entry : Keeper_msg_async.entry) -> entry.request_id) entries
    | Error rejection ->
      Alcotest.failf
        "queue access rejected: %s"
        (Keeper_msg_async.access_rejection_to_json rejection |> Yojson.Safe.to_string)
  in
  Alcotest.(check (list string)) "base A sees only its owner lane" [ request_a ] (request_ids base_a);
  Alcotest.(check (list string)) "base B sees only its owner lane" [ request_b ] (request_ids base_b);
  Eio.Promise.resolve resolve_release_a ();
  Eio.Promise.resolve resolve_release_b ();
  ignore (wait_for_done_with_clock clock ~base_path:base_a request_a : Keeper_msg_async.entry);
  ignore (wait_for_done_with_clock clock ~base_path:base_b request_b : Keeper_msg_async.entry)
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
      ~background_sw:sw
      ~base_path
      ~caller
      ~keeper_name:"beta"
      ~f:(fun _request_sw ->
        Eio.Fiber.yield ();
        tr_ok (Yojson.Safe.to_string (`Assoc [ "kind", `String "done" ])))
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
  | Keeper_msg_async.Found { Keeper_msg_async.status = Done { ok = true; body }; _ } ->
    Alcotest.(check bool) "body persisted" true (String.length body > 0)
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
       | Ok outcome ->
         Alcotest.failf
           "request was not durably rejected: %s"
           (Keeper_msg_async.submit_outcome_to_json outcome |> Yojson.Safe.to_string))
;;

let fail_once_on_write_stage expected =
  let armed = Atomic.make true in
  fun actual ->
    if actual = expected && Atomic.compare_and_set armed true false
    then failwith "synthetic durable write failure"
;;

let test_keeper_msg_async_request_id_collision_uses_reservation_index () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-reservation-collision-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_msg_async.For_testing.clear ();
      Keeper_persistence_admission.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let generated = Atomic.make 0 in
       Keeper_msg_async.For_testing.set_request_id_hook
         (Some
            (fun () ->
               match Atomic.fetch_and_add generated 1 with
               | 0 | 1 -> "kmsg-reserved-collision"
               | ordinal -> Printf.sprintf "kmsg-reserved-unique-%d" ordinal));
       let first_at_write, resolve_first_at_write = Eio.Promise.create () in
       let release_mutex = Mutex.create () in
       let release_condition = Condition.create () in
       let release_first = ref false in
       let release_first_write () =
         Stdlib.Mutex.protect release_mutex (fun () ->
           if not !release_first
           then (
             release_first := true;
             Condition.broadcast release_condition))
       in
       let block_first = Atomic.make true in
       Keeper_msg_async.For_testing.set_durable_write_hook
         (Some
            (fun stage ->
               if
                 stage = Keeper_fs.Payload_write
                 && Atomic.compare_and_set block_first true false
               then (
                 Eio.Promise.resolve resolve_first_at_write ();
                 Mutex.lock release_mutex;
                 Fun.protect
                   ~finally:(fun () -> Mutex.unlock release_mutex)
                   (fun () ->
                      while not !release_first do
                        Condition.wait release_condition release_mutex
                      done))));
       let first_result, resolve_first_result = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         Eio.Promise.resolve
           resolve_first_result
           (Keeper_msg_async.submit
              ~background_sw:sw
              ~base_path
              ~caller
              ~keeper_name:"reservation-first"
              ~f:(fun _ -> tr_ok "{}")
              ()));
       Fun.protect
         ~finally:release_first_write
         (fun () ->
            Eio.Promise.await first_at_write;
            let second_request_id =
              Keeper_msg_async.submit
                ~background_sw:sw
                ~base_path
                ~caller
                ~keeper_name:"reservation-second"
                ~f:(fun _ -> tr_ok "{}")
                ()
              |> accepted_request_id
            in
            release_first_write ();
            let first_request_id =
              Eio.Promise.await first_result |> accepted_request_id
            in
            Alcotest.(check string)
              "first request keeps deterministic id"
              "kmsg-reserved-collision"
              first_request_id;
            Alcotest.(check bool)
              "second request skips in-memory collision before disk publication"
              true
              (not (String.equal first_request_id second_request_id));
            Alcotest.(check bool) "generator retried collision" true
              (Atomic.get generated >= 3)))
;;

let fail_once_on_remove_stage expected =
  let armed = Atomic.make true in
  fun actual ->
    if actual = expected && Atomic.compare_and_set armed true false
    then failwith "synthetic durable remove failure"
;;

let test_keeper_msg_async_initial_post_publish_failure_rolls_back () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun background_sw ->
  let base_path = temp_dir "keeper-msg-initial-rollback-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_msg_async.For_testing.clear ();
      Keeper_persistence_admission.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let worker_ran = Atomic.make false in
       Keeper_msg_async.For_testing.set_durable_write_hook
         (Some
            (fail_once_on_write_stage
               Keeper_fs.Parent_directory_fsync_after_rename));
       match
         Keeper_msg_async.submit
           ~background_sw
           ~base_path
           ~caller
           ~keeper_name:"initial-rollback"
           ~f:(fun _request_sw ->
             Atomic.set worker_ran true;
             tr_ok "{}")
           ()
       with
       | Error (Keeper_msg_async.Initial_persistence_failed _) ->
         Alcotest.(check bool) "worker was not started" false
           (Atomic.get worker_ran)
       | Error error ->
         Alcotest.failf
           "unexpected initial failure: %s"
           (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string)
       | Ok outcome ->
         Alcotest.failf
           "durable rollback was reported uncertain: %s"
           (Keeper_msg_async.submit_outcome_to_json outcome |> Yojson.Safe.to_string))
;;

let test_keeper_msg_async_initial_rollback_failure_preserves_request_id () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun background_sw ->
  let base_path = temp_dir "keeper-msg-initial-uncertain-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_msg_async.For_testing.clear ();
      Keeper_persistence_admission.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let worker_ran = Atomic.make false in
       Keeper_msg_async.For_testing.set_durable_write_hook
         (Some
            (fail_once_on_write_stage
               Keeper_fs.Parent_directory_fsync_after_rename));
       Keeper_msg_async.For_testing.set_durable_remove_hook
         (Some (fail_once_on_remove_stage Keeper_fs.Unlink));
       match
         Keeper_msg_async.submit
           ~background_sw
           ~base_path
           ~caller
           ~keeper_name:"initial-uncertain"
           ~f:(fun _request_sw ->
             Atomic.set worker_ran true;
             tr_ok "{}")
           ()
       with
       | Ok
           ({ acceptance = Keeper_msg_async.Reconciliation_required _; request_id }
             as outcome) ->
         Alcotest.(check bool) "worker was not started" false
           (Atomic.get worker_ran);
         let json = Keeper_msg_async.submit_outcome_to_json outcome in
         Alcotest.(check (option string))
           "uncertain request id is projected"
           (Some request_id)
           (Json_field.string json "request_id" |> Json_field.to_option);
         (match Keeper_msg_async.poll ~base_path ~caller request_id with
          | Keeper_msg_async.Found { status = Queued; _ } -> ()
          | _ -> Alcotest.fail "published uncertain request cannot be reconciled")
       | Ok outcome ->
         Alcotest.failf
           "uncertain write was reported durable: %s"
           (Keeper_msg_async.submit_outcome_to_json outcome |> Yojson.Safe.to_string)
       | Error error ->
         Alcotest.failf
           "uncertain request id was discarded: %s"
         (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string))
;;

let test_keeper_msg_async_reconciliation_fences_only_ambiguous_lane () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun background_sw ->
  let base_path = temp_dir "keeper-msg-reconciliation-fence-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_msg_async.For_testing.clear ();
      Keeper_persistence_admission.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let generated = Atomic.make 0 in
       Keeper_msg_async.For_testing.set_request_id_hook
         (Some
            (fun () ->
               Printf.sprintf
                 "kmsg-reconciliation-%d"
                 (Atomic.fetch_and_add generated 1)));
       let first_at_fsync, resolve_first_at_fsync = Eio.Promise.create () in
       let release_first, resolve_release_first = Eio.Promise.create () in
       let fail_first = Atomic.make true in
       Keeper_msg_async.For_testing.set_durable_write_hook
         (Some
            (fun stage ->
               if
                 stage = Keeper_fs.Parent_directory_fsync_after_rename
                 && Atomic.compare_and_set fail_first true false
               then (
                 Eio.Promise.resolve resolve_first_at_fsync ();
                 Eio.Promise.await release_first;
                 failwith "synthetic ambiguous initial commit")));
       Keeper_msg_async.For_testing.set_durable_remove_hook
         (Some (fail_once_on_remove_stage Keeper_fs.Unlink));
       let results :
           ( Keeper_msg_async.submit_outcome
           , Keeper_msg_async.submit_error )
           result
           Eio.Stream.t =
         Eio.Stream.create 5
       in
       let submit_same_lane () =
         Keeper_msg_async.submit
           ~background_sw
           ~base_path
           ~caller
           ~keeper_name:"ambiguous-lane"
           ~f:(fun _ -> tr_ok "{}")
           ()
         |> Eio.Stream.add results
       in
       Eio.Fiber.fork ~sw:background_sw submit_same_lane;
       Eio.Promise.await first_at_fsync;
       for _ = 1 to 4 do
         Eio.Fiber.fork ~sw:background_sw submit_same_lane
       done;
       for _ = 1 to 10 do
         Eio.Fiber.yield ()
       done;
       Alcotest.(check int) "concurrent waiters allocate no extra ids" 1
         (Atomic.get generated);
       Alcotest.(check int) "only first in-flight id is reserved" 1
         (Keeper_msg_async.For_testing.reserved_request_id_count ());
       Eio.Promise.resolve resolve_release_first ();
       let outcomes = List.init 5 (fun _ -> Eio.Stream.take results) in
       let reconciliations, blocked, first_request_id =
         List.fold_left
           (fun (reconciliations, blocked, first_request_id) -> function
              | Ok
                  { Keeper_msg_async.acceptance =
                      Keeper_msg_async.Reconciliation_required _
                  ; request_id
                  } ->
                reconciliations + 1, blocked, Some request_id
              | Error
                  (Keeper_msg_async.Submit_admission_blocked
                     { reason = Keeper_persistence_admission.Reconciliation_required
                     ; _
                     }) ->
                reconciliations, blocked + 1, first_request_id
              | Ok outcome ->
                Alcotest.failf
                  "concurrent ambiguity was reported durable: %s"
                  (Keeper_msg_async.submit_outcome_to_json outcome
                   |> Yojson.Safe.to_string)
              | Error error ->
                Alcotest.failf
                  "concurrent ambiguity returned wrong error: %s"
                  (Keeper_msg_async.submit_error_to_json error
                   |> Yojson.Safe.to_string))
           (0, 0, None)
           outcomes
       in
       Alcotest.(check int) "exactly one ambiguity owns reconciliation" 1
         reconciliations;
       Alcotest.(check int) "all same-lane waiters fail closed" 4 blocked;
       let first_request_id =
         match first_request_id with
         | Some request_id -> request_id
         | None -> Alcotest.fail "reconciliation request id was lost"
       in
       Alcotest.(check int) "concurrent fence keeps reservation bounded" 1
         (Keeper_msg_async.For_testing.reserved_request_id_count ());
       let healthy_request_id =
         Keeper_msg_async.submit
           ~background_sw
           ~base_path
           ~caller
           ~keeper_name:"healthy-lane"
           ~f:(fun _ -> tr_ok "{}")
           ()
         |> accepted_request_id
       in
       ignore
         (wait_for_done_with_clock
            (Eio.Stdenv.clock env)
            ~base_path
            healthy_request_id
           : Keeper_msg_async.entry);
       Alcotest.(check bool) "ambiguous request id remains distinct" true
         (not (String.equal first_request_id healthy_request_id));
       Alcotest.(check int) "healthy lane releases its reservation" 1
         (Keeper_msg_async.For_testing.reserved_request_id_count ()))
;;

let test_keeper_msg_async_running_double_write_failure_is_terminal_in_memory () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun background_sw ->
  let base_path = temp_dir "keeper-msg-running-double-write-failure-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_msg_async.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let payload_writes = Atomic.make 0 in
       let worker_ran = Atomic.make false in
       let settlements = ref [] in
       Keeper_msg_async.For_testing.set_durable_write_hook
         (Some
            (fun stage ->
               if stage = Keeper_fs.Payload_write
               then (
                 let ordinal = Atomic.fetch_and_add payload_writes 1 + 1 in
                 if ordinal >= 2
                 then failwith "synthetic repeated request persistence failure")));
       let request_id =
         Keeper_msg_async.submit
           ~on_worker_settled:(fun settlement ->
             settlements := settlement :: !settlements)
           ~background_sw
           ~base_path
           ~caller
           ~keeper_name:"running-double-write-failure"
           ~f:(fun _request_sw ->
             Atomic.set worker_ran true;
             tr_ok "{}")
           ()
         |> accepted_request_id
       in
       let rec await_terminal remaining =
         match Keeper_msg_async.poll ~base_path ~caller request_id with
         | Keeper_msg_async.Found { status = Persistence_failed _; _ } -> ()
         | _ when remaining > 0 ->
           Eio.Time.sleep (Eio.Stdenv.clock env) 0.01;
           await_terminal (remaining - 1)
         | _ -> Alcotest.fail "double write failure remained non-terminal"
       in
       await_terminal 100;
       Alcotest.(check bool) "worker body was not entered" false
         (Atomic.get worker_ran);
       Alcotest.(check int) "volatile settlement projected once" 1
         (List.length !settlements))
;;

let test_keeper_msg_async_running_write_failure_projects_durable_marker_once () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun background_sw ->
  let base_path = temp_dir "keeper-msg-running-write-failure-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_msg_async.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let payload_writes = Atomic.make 0 in
       let worker_ran = Atomic.make false in
       let aborts = ref [] in
       let settlements = ref [] in
       Keeper_msg_async.For_testing.set_durable_write_hook
         (Some
            (fun stage ->
               if stage = Keeper_fs.Payload_write
               then (
                 let ordinal = Atomic.fetch_and_add payload_writes 1 + 1 in
                 if ordinal = 2
                 then failwith "synthetic Running persistence failure")));
       let request_id =
         Keeper_msg_async.submit
           ~on_worker_aborted:(fun reason ->
             aborts := reason :: !aborts;
             Ok ())
           ~on_worker_settled:(fun settlement ->
             settlements := settlement :: !settlements)
           ~background_sw
           ~base_path
           ~caller
           ~keeper_name:"running-write-failure"
           ~f:(fun _request_sw ->
             Atomic.set worker_ran true;
             tr_ok "{}")
           ()
         |> accepted_request_id
       in
       let rec await_settlement remaining =
         match !settlements with
         | _ :: _ -> ()
         | [] when remaining > 0 ->
           Eio.Time.sleep (Eio.Stdenv.clock env) 0.01;
           await_settlement (remaining - 1)
         | [] -> Alcotest.fail "durable failure marker was not projected"
       in
       await_settlement 100;
       Alcotest.(check bool) "worker body was not entered" false
         (Atomic.get worker_ran);
       Alcotest.(check int) "abort callback was not misclassified" 0
         (List.length !aborts);
       (match !settlements with
        | [ Keeper_msg_async.Status_settlement
              { status = Persistence_failed _
              ; durability = Keeper_msg_async.Durable
              ; origin = Keeper_msg_async.Transition_commit
              }
          ] ->
          ()
        | [ Keeper_msg_async.Status_settlement { status; _ } ] ->
          Alcotest.failf "unexpected settlement status=%s"
            (Keeper_msg_async.status_to_string status)
        | [ Keeper_msg_async.Settlement_projection_error _ ] ->
          Alcotest.fail "unexpected settlement projection error"
        | settlements ->
          Alcotest.failf
            "settlement callback count=%d, expected 1"
            (List.length settlements));
       match Keeper_msg_async.poll ~base_path ~caller request_id with
       | Keeper_msg_async.Found { status = Persistence_failed _; _ } -> ()
       | _ -> Alcotest.fail "durable failure marker is not polling truth")
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
  (match Keeper_msg_async.poll ~base_path ~caller request_id with
   | Keeper_msg_async.Found { status = Running; _ } -> ()
   | _ -> Alcotest.fail "poller incorrectly stole a disk-only worker");
  Alcotest.(check int)
    "exclusive recovery marks the disk-only worker lost"
    1
    (Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path ()).lost;
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
    (Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path ()).lost;
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
  (match Keeper_msg_async.For_testing.active_record_path ~base_path ~request_id with
   | Some path ->
     Alcotest.(check bool) "running request is stored in active partition" true
       (Sys.file_exists path)
   | None -> Alcotest.fail "expected safe active record path");
  Keeper_msg_async.For_testing.forget ~base_path ~caller ~request_id;
  Alcotest.(check int)
    "disk-only in-flight request is recovered as lost"
    1
    (Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path ()).lost;
  match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
  | Keeper_msg_async.Found { Keeper_msg_async.status = Lost { reason }; _ } ->
    Alcotest.(check bool) "lost reason retained" true (String.length reason > 0);
    (match
       Keeper_msg_async.For_testing.active_record_path ~base_path ~request_id,
       Keeper_msg_async.For_testing.terminal_record_path ~base_path ~request_id
     with
     | Some active_path, Some terminal_path ->
       Alcotest.(check bool) "recovery removes active namespace entry" false
         (Sys.file_exists active_path);
       Alcotest.(check bool) "recovery commits terminal namespace entry" true
         (Sys.file_exists terminal_path)
     | _ -> Alcotest.fail "expected safe partitioned record paths")
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
    (match Keeper_msg_async.cancel ~base_path ~caller request_id with
     | Keeper_msg_async.Cancellation_requested
         Keeper_msg_async.Durably_committed -> true
     | _ -> false);
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

let test_keeper_msg_async_live_cancel_signals_after_post_publish_failure () =
  with_eio_env
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-live-cancel-volatile-" in
  let never, _resolver = Eio.Promise.create () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_msg_async.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let request_id =
         Keeper_msg_async.submit
           ~background_sw:sw
           ~base_path
           ~caller
           ~keeper_name:"live-cancel-volatile"
           ~f:(fun _request_sw ->
             Eio.Promise.await never;
             tr_ok "{}")
           ()
         |> accepted_request_id
       in
       ignore (wait_for_running ~base_path request_id : Keeper_msg_async.entry);
       Keeper_msg_async.For_testing.set_durable_write_hook
         (Some
            (fail_once_on_write_stage
               Keeper_fs.Parent_directory_fsync_after_rename));
       let result = Keeper_msg_async.cancel ~base_path ~caller request_id in
       Keeper_msg_async.For_testing.set_durable_write_hook None;
       (match result with
        | Keeper_msg_async.Cancellation_requested
            (Keeper_msg_async.Published_unconfirmed _) -> ()
        | other ->
          Alcotest.failf
            "post-publish cancellation did not preserve volatility: %s"
            (Keeper_msg_async.cancel_result_to_json ~request_id other
             |> Yojson.Safe.to_string));
       ignore (wait_for_cancelled ~base_path request_id : Keeper_msg_async.entry))
;;

let test_keeper_msg_async_explicit_cancel_retries_failed_worker_signal () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-cancel-signal-retry-" in
  let never, _resolver = Eio.Promise.create () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_msg_async.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let settlements = ref [] in
       let aborts = ref [] in
       let request_id =
         Keeper_msg_async.submit
           ~on_worker_aborted:(fun reason ->
             aborts := reason :: !aborts;
             Ok ())
           ~on_worker_settled:(fun settlement ->
             settlements := settlement :: !settlements)
           ~background_sw:sw
           ~base_path
           ~caller
           ~keeper_name:"cancel-signal-retry"
           ~f:(fun _request_sw ->
             Eio.Promise.await never;
             tr_ok "{}")
           ()
         |> accepted_request_id
       in
       ignore (wait_for_running ~base_path request_id : Keeper_msg_async.entry);
       wait_for_active_switch_count (Eio.Stdenv.clock env) 1;
       let signal_attempts = Atomic.make 0 in
       Keeper_msg_async.For_testing.set_cancel_signal_hook
         (Some
            (fun request_sw cause ->
               let attempt = Atomic.fetch_and_add signal_attempts 1 + 1 in
               if attempt = 1
               then failwith "synthetic worker signal failure"
               else Eio.Switch.fail request_sw cause));
       (match Keeper_msg_async.cancel ~base_path ~caller request_id with
        | Keeper_msg_async.Cancel_worker_signal_failed
            { durability = Keeper_msg_async.Durably_committed; _ } ->
          ()
        | other ->
          Alcotest.failf
            "first signal failure was not explicit: %s"
            (Keeper_msg_async.cancel_result_to_json ~request_id other
             |> Yojson.Safe.to_string));
       (match Keeper_msg_async.poll ~base_path ~caller request_id with
        | Keeper_msg_async.Found { status = Cancelling _; _ } -> ()
        | _ -> Alcotest.fail "failed signal did not preserve cancelling intent");
       Alcotest.(check int) "no premature settlement callback" 0
         (List.length !settlements);
       (match Keeper_msg_async.cancel ~base_path ~caller request_id with
        | Keeper_msg_async.Cancellation_requested
            Keeper_msg_async.Durably_committed ->
          ()
        | other ->
          Alcotest.failf
            "explicit retry did not signal the owned worker: %s"
            (Keeper_msg_async.cancel_result_to_json ~request_id other
             |> Yojson.Safe.to_string));
       ignore (wait_for_cancelled ~base_path request_id : Keeper_msg_async.entry);
       Alcotest.(check int) "worker signal attempted twice" 2
         (Atomic.get signal_attempts);
       Alcotest.(check int) "abort callback projected once" 1
         (List.length !aborts);
       Alcotest.(check int) "settlement callback projected once" 1
         (List.length !settlements))
;;

let test_keeper_msg_async_terminal_record_is_durable_without_age_eviction () =
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
  ignore (wait_for_done_with_clock clock ~base_path request_id : Keeper_msg_async.entry);
  let persisted =
    wait_for_persisted_done_with_clock clock ~base_path request_id
  in
  let path =
    match Keeper_msg_async.For_testing.terminal_record_path ~base_path ~request_id with
    | Some path -> path
    | None -> Alcotest.fail "expected safe record path"
  in
  Alcotest.(check bool) "terminal record remains durable" true (Sys.file_exists path);
  (match Keeper_msg_async.For_testing.active_record_path ~base_path ~request_id with
   | Some active_path ->
     Alcotest.(check bool) "terminal commit leaves no active record" false
       (Sys.file_exists active_path)
   | None -> Alcotest.fail "expected safe active record path");
  Alcotest.(check int)
    "terminal record is absent from active memory index"
    0
    (match Keeper_msg_async.list_for_keeper ~base_path ~caller () with
     | Ok entries -> List.length entries
     | Error _ -> Alcotest.fail "owner lane list was rejected");
  match Keeper_msg_async.poll ~base_path ~caller request_id with
  | Keeper_msg_async.Found entry ->
    Alcotest.(check string)
      "exact poll reloads durable terminal result"
      (Keeper_msg_async.status_to_string persisted.status)
      (Keeper_msg_async.status_to_string entry.status)
  | Keeper_msg_async.Absent ->
    Alcotest.fail "durable terminal result disappeared"
  | Keeper_msg_async.Unreadable reason ->
    Alcotest.failf "durable terminal result became unreadable: %s" reason
  | Keeper_msg_async.Rejected rejection ->
    Alcotest.failf
      "durable terminal result was rejected: %s"
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
            (Keeper_msg_async.For_testing.active_record_path
               ~base_path
               ~request_id:max_id));
       check
         (option string)
         "129-char request id rejected"
         None
         (Keeper_msg_async.For_testing.active_record_path ~base_path ~request_id:too_long))
;;

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

type disk_record_location =
  | Active_record
  | Terminal_record
  | Legacy_record

let disk_record_path ~location ~base_path ~request_id =
  match location with
  | Active_record ->
    Keeper_msg_async.For_testing.active_record_path ~base_path ~request_id
  | Terminal_record ->
    Keeper_msg_async.For_testing.terminal_record_path ~base_path ~request_id
  | Legacy_record ->
    Keeper_msg_async.For_testing.legacy_record_path ~base_path ~request_id
;;

let write_disk_record ?(location = Legacy_record) ~base_path ~request_id content =
  match disk_record_path ~location ~base_path ~request_id with
  | None -> Alcotest.fail "expected safe record path"
  | Some path ->
    mkdir_p (Filename.dirname path);
    Fs_compat.save_file path content
;;

let request_record_json ?(keeper_name = "recovery-test") ?(submitted_at = 1.0)
    ~base_path ~request_id ~status ~status_fields () =
  `Assoc
    ([ "schema_version", `Int Keeper_msg_async.For_testing.record_schema_version
     ; "request_id", `String request_id
     ; "keeper_name", `String keeper_name
     ; "base_path", `String (Fs_compat.realpath base_path)
     ; "submitted_by", `String caller
     ; "status", `String status
     ; "submitted_at", `Float submitted_at
     ]
     @ status_fields)
;;

let write_request_record ?location ?keeper_name ?submitted_at ~base_path
    ~request_id ~status ~status_fields () =
  request_record_json
    ?keeper_name
    ?submitted_at
    ~base_path
    ~request_id
    ~status
    ~status_fields
    ()
  |> Yojson.Safe.to_string
  |> write_disk_record ?location ~base_path ~request_id
;;

let require_record_path ~location ~base_path ~request_id =
  match disk_record_path ~location ~base_path ~request_id with
  | Some path -> path
  | None -> Alcotest.fail "expected safe partitioned request path"
;;

let test_keeper_msg_async_migrates_legacy_terminal_destination_first () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-legacy-terminal-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_legacy_done_0_0" in
       write_request_record
         ~base_path
         ~request_id
         ~status:"done"
         ~status_fields:
           [ "completed_at", `Float 2.0
           ; "ok", `Bool true
           ; "body", `String {|{"result":"legacy"}|}
           ]
         ();
       (match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
        | Keeper_msg_async.Found { status = Done { ok = true; _ }; _ } -> ()
        | _ -> Alcotest.fail "legacy terminal row was not readable before migration");
       let report =
         Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path ()
       in
       Alcotest.(check int) "one legacy terminal migrated" 1 report.migrated;
       let legacy_path =
         require_record_path ~location:Legacy_record ~base_path ~request_id
       in
       let terminal_path =
         require_record_path ~location:Terminal_record ~base_path ~request_id
       in
       Alcotest.(check bool) "terminal destination committed" true
         (Sys.file_exists terminal_path);
       Alcotest.(check bool) "legacy source removed after commit" false
         (Sys.file_exists legacy_path))
;;

let test_keeper_msg_async_recovers_legacy_running_to_terminal_lost () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-legacy-running-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_legacy_running_0_0" in
       write_request_record
         ~base_path
         ~request_id
         ~status:"running"
         ~status_fields:[]
         ();
       let report =
         Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path ()
       in
       Alcotest.(check int) "one legacy in-flight row became lost" 1 report.lost;
       let legacy_path =
         require_record_path ~location:Legacy_record ~base_path ~request_id
       in
       let terminal_path =
         require_record_path ~location:Terminal_record ~base_path ~request_id
       in
       Alcotest.(check bool) "lost terminal committed" true
         (Sys.file_exists terminal_path);
       Alcotest.(check bool) "running legacy source removed" false
         (Sys.file_exists legacy_path);
       match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
       | Keeper_msg_async.Found { status = Lost _; _ } -> ()
       | _ -> Alcotest.fail "recovered legacy request did not decode as Lost")
;;

let test_keeper_msg_async_terminal_precedence_cleans_stale_active () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-stale-active-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_stale_active_0_0" in
       write_request_record
         ~location:Terminal_record
         ~base_path
         ~request_id
         ~status:"done"
         ~status_fields:
           [ "completed_at", `Float 2.0
           ; "ok", `Bool true
           ; "body", `String "terminal"
           ]
         ();
       write_request_record
         ~location:Active_record
         ~base_path
         ~request_id
         ~status:"running"
         ~status_fields:[]
         ();
       let report =
         Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path ()
       in
       Alcotest.(check int) "stale active source cleaned" 1 report.cleaned;
       let active_path =
         require_record_path ~location:Active_record ~base_path ~request_id
       in
       Alcotest.(check bool) "stale active no longer exists" false
         (Sys.file_exists active_path);
       match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
       | Keeper_msg_async.Found { status = Done { body = "terminal"; _ }; _ } -> ()
       | _ -> Alcotest.fail "terminal destination did not remain authoritative")
;;

let test_keeper_msg_async_preserves_conflicting_terminal_source () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-terminal-conflict-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_terminal_conflict_0_0" in
       let write_done location body =
         write_request_record
           ~location
           ~base_path
           ~request_id
           ~status:"done"
           ~status_fields:
             [ "completed_at", `Float 2.0
             ; "ok", `Bool true
             ; "body", `String body
             ]
           ()
       in
       write_done Terminal_record "canonical";
       write_done Active_record "conflicting";
       let report =
         Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path ()
       in
       Alcotest.(check int) "conflict is explicit" 1 report.failed;
       let active_path =
         require_record_path ~location:Active_record ~base_path ~request_id
       in
       Alcotest.(check bool) "conflicting evidence is preserved" true
         (Sys.file_exists active_path);
       match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
       | Keeper_msg_async.Unreadable _ -> ()
       | Keeper_msg_async.Found _ ->
         Alcotest.fail "conflicting terminal evidence was silently hidden"
       | Keeper_msg_async.Absent ->
         Alcotest.fail "conflicting terminal evidence disappeared"
       | Keeper_msg_async.Rejected _ ->
         Alcotest.fail "conflicting terminal evidence was rejected as caller input")
;;

let test_keeper_msg_async_integrity_conflict_projects_canonical_terminal () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-canonical-integrity-settlement-" in
  let release, resolve_release = Eio.Promise.create () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_msg_async.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let settlements = ref [] in
       let request_id =
         Keeper_msg_async.submit
           ~on_worker_settled:(fun settlement ->
             settlements := settlement :: !settlements)
           ~background_sw:sw
           ~base_path
           ~caller
           ~keeper_name:"canonical-integrity-settlement"
           ~f:(fun _request_sw ->
             Eio.Promise.await release;
             tr_ok {|{"worker":"result"}|})
           ()
         |> accepted_request_id
       in
       let running = wait_for_running ~base_path request_id in
       let inject_terminal = Atomic.make true in
       Keeper_msg_async.For_testing.set_durable_write_hook
         (Some
            (fun stage ->
               if
                 stage = Keeper_fs.Payload_write
                 && Atomic.compare_and_set inject_terminal true false
               then (
                 write_request_record
                   ~location:Terminal_record
                   ~keeper_name:running.keeper_name
                   ~submitted_at:running.submitted_at
                   ~base_path
                   ~request_id
                   ~status:"done"
                   ~status_fields:
                     [ "completed_at", `Float 42.0
                     ; "ok", `Bool true
                     ; "body", `String {|{"canonical":"result"}|}
                     ]
                   ();
                 failwith "synthetic terminal write failure")));
       Eio.Promise.resolve resolve_release ();
       let rec await_settlement remaining =
         match !settlements with
         | _ :: _ -> ()
         | [] when remaining > 0 ->
           Eio.Time.sleep (Eio.Stdenv.clock env) 0.01;
           await_settlement (remaining - 1)
         | [] -> Alcotest.fail "canonical integrity settlement was not projected"
       in
       await_settlement 100;
       let callback_body =
         match !settlements with
         | [ Keeper_msg_async.Status_settlement
               { status = Done { ok = true; body }
               ; durability = Keeper_msg_async.Durable
               ; origin = Keeper_msg_async.Canonical_reconciliation
               }
           ] ->
           body
         | [ Keeper_msg_async.Status_settlement { status; _ } ] ->
           Alcotest.failf
             "integrity conflict fabricated callback status=%s"
             (Keeper_msg_async.status_to_string status)
         | [ Keeper_msg_async.Settlement_projection_error _ ] ->
           Alcotest.fail "canonical terminal projected an integrity error"
         | settlements ->
           Alcotest.failf
             "integrity conflict settlement count=%d"
             (List.length settlements)
       in
       match Keeper_msg_async.poll ~base_path ~caller request_id with
       | Keeper_msg_async.Found { status = Done { ok = true; body }; _ } ->
         Alcotest.(check string) "callback equals canonical poll truth" body
           callback_body
       | Keeper_msg_async.Found entry ->
         Alcotest.failf
           "poll disagrees with canonical settlement: %s"
           (Keeper_msg_async.status_to_string entry.status)
       | Keeper_msg_async.Absent
       | Keeper_msg_async.Unreadable _
       | Keeper_msg_async.Rejected _ ->
         Alcotest.fail "canonical terminal was not exact polling truth")
;;

let test_keeper_stream_canonical_settlement_ignores_staged_worker_result () =
  let status = Keeper_msg_async.Done { ok = true; body = "canonical-disk" } in
  let project origin =
    Server_routes_http_keeper_stream.For_testing.worker_settlement_terminal_body
      ~staged_body:(Some "staged-worker")
      (Keeper_msg_async.Status_settlement
         { status; durability = Keeper_msg_async.Durable; origin })
  in
  Alcotest.(check (option string))
    "canonical reconciliation uses disk body"
    (Some "canonical-disk")
    (project Keeper_msg_async.Canonical_reconciliation);
  Alcotest.(check (option string))
    "normal transition retains staged stream body"
    (Some "staged-worker")
    (project Keeper_msg_async.Transition_commit)
;;

let test_keeper_msg_async_integrity_ambiguity_projects_exact_poll_error () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-integrity-projection-error-" in
  let release, resolve_release = Eio.Promise.create () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_msg_async.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let settlements = ref [] in
       let request_id =
         Keeper_msg_async.submit
           ~on_worker_settled:(fun settlement ->
             settlements := settlement :: !settlements)
           ~background_sw:sw
           ~base_path
           ~caller
           ~keeper_name:"integrity-projection-error"
           ~f:(fun _request_sw ->
             Eio.Promise.await release;
             tr_ok "{}")
           ()
         |> accepted_request_id
       in
       ignore (wait_for_running ~base_path request_id : Keeper_msg_async.entry);
       write_request_record
         ~location:Terminal_record
         ~keeper_name:"different-terminal-owner"
         ~base_path
         ~request_id
         ~status:"done"
         ~status_fields:
           [ "completed_at", `Float 42.0
           ; "ok", `Bool true
           ; "body", `String "conflicting"
           ]
         ();
       Eio.Promise.resolve resolve_release ();
       let rec await_settlement remaining =
         match !settlements with
         | _ :: _ -> ()
         | [] when remaining > 0 ->
           Eio.Time.sleep (Eio.Stdenv.clock env) 0.01;
           await_settlement (remaining - 1)
         | [] -> Alcotest.fail "integrity projection error callback was dropped"
       in
       await_settlement 100;
       let callback_reason =
         match !settlements with
         | [ Keeper_msg_async.Settlement_projection_error
               { poll_result = Keeper_msg_async.Unreadable reason }
           ] ->
           reason
         | [ Keeper_msg_async.Status_settlement { status; _ } ] ->
           Alcotest.failf
             "ambiguous evidence fabricated status=%s"
             (Keeper_msg_async.status_to_string status)
         | [ Keeper_msg_async.Settlement_projection_error _ ] ->
           Alcotest.fail "ambiguous evidence projected the wrong load result"
         | settlements ->
           Alcotest.failf
             "integrity projection callback count=%d"
             (List.length settlements)
       in
       match Keeper_msg_async.poll ~base_path ~caller request_id with
       | Keeper_msg_async.Unreadable reason ->
         Alcotest.(check string) "callback carries exact poll error" reason
           callback_reason
       | Keeper_msg_async.Found _
       | Keeper_msg_async.Absent
       | Keeper_msg_async.Rejected _ ->
         Alcotest.fail "callback and poll did not share integrity evidence")
;;

let test_keeper_msg_async_absent_integrity_keeps_request_id_reserved () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-integrity-absent-reservation-" in
  let release, resolve_release = Eio.Promise.create () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_msg_async.For_testing.clear ();
      Keeper_persistence_admission.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let generated = Atomic.make 0 in
       Keeper_msg_async.For_testing.set_request_id_hook
         (Some
            (fun () ->
               match Atomic.fetch_and_add generated 1 with
               | 0 | 1 -> "kmsg-integrity-absent"
               | ordinal -> Printf.sprintf "kmsg-integrity-next-%d" ordinal));
       let settlements = ref [] in
       let first_request_id =
         Keeper_msg_async.submit
           ~on_worker_settled:(fun settlement ->
             settlements := settlement :: !settlements)
           ~background_sw:sw
           ~base_path
           ~caller
           ~keeper_name:"integrity-absent"
           ~f:(fun _ ->
             Eio.Promise.await release;
             tr_ok "{}")
           ()
         |> accepted_request_id
       in
       let running = wait_for_running ~base_path first_request_id in
       write_request_record
         ~location:Terminal_record
         ~keeper_name:running.keeper_name
         ~submitted_at:running.submitted_at
         ~base_path
         ~request_id:first_request_id
         ~status:"done"
         ~status_fields:
           [ "completed_at", `Float 42.0
           ; "ok", `Bool true
           ; "body", `String "conflicting"
           ]
         ();
       let active_path =
         require_record_path
           ~location:Active_record
           ~base_path
           ~request_id:first_request_id
       in
       let terminal_path =
         require_record_path
           ~location:Terminal_record
           ~base_path
           ~request_id:first_request_id
       in
       let remove_evidence = Atomic.make true in
       Keeper_msg_async.For_testing.set_integrity_projection_hook
         (Some
            (fun () ->
               if Atomic.compare_and_set remove_evidence true false
               then (
                 if Sys.file_exists active_path then Sys.remove active_path;
                 if Sys.file_exists terminal_path then Sys.remove terminal_path)));
       Eio.Promise.resolve resolve_release ();
       let rec await_projection remaining =
         match !settlements with
         | _ :: _ -> ()
         | [] when remaining > 0 ->
           Eio.Time.sleep (Eio.Stdenv.clock env) 0.01;
           await_projection (remaining - 1)
         | [] -> Alcotest.fail "absent integrity projection was not delivered"
       in
       await_projection 100;
       (match !settlements with
        | [ Keeper_msg_async.Settlement_projection_error
              { poll_result = Keeper_msg_async.Absent }
          ] ->
          ()
        | _ -> Alcotest.fail "integrity evidence loss was not projected as Absent");
       Alcotest.(check int) "absent accepted id keeps one tombstone" 1
         (Keeper_msg_async.For_testing.reserved_request_id_count ());
       Keeper_msg_async.For_testing.set_integrity_projection_hook None;
       let generated_before_fenced_submit = Atomic.get generated in
       (match
          Keeper_msg_async.submit
            ~background_sw:sw
            ~base_path
            ~caller
            ~keeper_name:"integrity-absent"
            ~f:(fun _ -> tr_ok "{}")
            ()
        with
        | Error
            (Keeper_msg_async.Submit_admission_blocked
               { reason = Keeper_persistence_admission.Reconciliation_required
               ; _
               }) ->
          ()
        | Error error ->
          Alcotest.failf
            "absent integrity returned wrong lane fence: %s"
            (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string)
        | Ok outcome ->
          Alcotest.failf
            "absent integrity allowed another same-lane reservation: %s"
            (Keeper_msg_async.submit_outcome_to_json outcome
             |> Yojson.Safe.to_string));
       Alcotest.(check int) "same-lane fence runs before id generation"
         generated_before_fenced_submit (Atomic.get generated);
       Alcotest.(check int) "same-lane fence keeps reservation bounded" 1
         (Keeper_msg_async.For_testing.reserved_request_id_count ());
       let second_request_id =
         Keeper_msg_async.submit
           ~background_sw:sw
           ~base_path
           ~caller
           ~keeper_name:"integrity-next"
           ~f:(fun _ -> tr_ok "{}")
           ()
         |> accepted_request_id
       in
       ignore
         (wait_for_done_with_clock
            (Eio.Stdenv.clock env)
            ~base_path
            second_request_id
           : Keeper_msg_async.entry);
       Alcotest.(check bool) "same id was not reused" true
         (not (String.equal first_request_id second_request_id));
       Alcotest.(check int) "collision retried deterministic generator" 3
         (Atomic.get generated);
       Alcotest.(check int) "second request released, tombstone remains" 1
         (Keeper_msg_async.For_testing.reserved_request_id_count ()))
;;

let test_keeper_msg_async_preserves_mismatched_nonterminal_source_identity () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-source-identity-conflict-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_source_identity_conflict_0_0" in
       write_request_record
         ~location:Terminal_record
         ~keeper_name:"canonical-keeper"
         ~base_path
         ~request_id
         ~status:"done"
         ~status_fields:
           [ "completed_at", `Float 2.0
           ; "ok", `Bool true
           ; "body", `String "canonical"
           ]
         ();
       write_request_record
         ~location:Active_record
         ~keeper_name:"different-keeper"
         ~base_path
         ~request_id
         ~status:"running"
         ~status_fields:[]
         ();
       (match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
        | Keeper_msg_async.Unreadable _ -> ()
        | _ -> Alcotest.fail "mismatched request identity was hidden by terminal precedence");
       let report =
         Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path ()
       in
       Alcotest.(check int) "identity conflict is explicit" 1 report.failed;
       let active_path =
         require_record_path ~location:Active_record ~base_path ~request_id
       in
       Alcotest.(check bool) "mismatched source evidence is preserved" true
         (Sys.file_exists active_path))
;;

let test_keeper_msg_async_rejects_active_legacy_ambiguity_before_mutation () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-active-legacy-conflict-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_active_legacy_conflict_0_0" in
       write_request_record
         ~location:Active_record
         ~keeper_name:"active-owner"
         ~base_path
         ~request_id
         ~status:"running"
         ~status_fields:[]
         ();
       write_request_record
         ~location:Legacy_record
         ~keeper_name:"legacy-owner"
         ~base_path
         ~request_id
         ~status:"running"
         ~status_fields:[]
         ();
       (match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
        | Keeper_msg_async.Unreadable reason ->
          Alcotest.(check bool)
            "canonical lookup exposes source ambiguity"
            true
            (contains_substring ~needle:"identities" reason)
        | _ -> Alcotest.fail "active silently won over conflicting legacy evidence");
       let report =
         Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path ()
       in
       Alcotest.(check int) "both conflicting records are reported" 2 report.failed;
       Alcotest.(check int)
         "both conflicts retain typed evidence"
         2
         (List.length report.record_errors);
       List.iter
         (fun (error : Keeper_msg_async.recovery_record_error) ->
            match error.kind with
            | Keeper_msg_async.Recovery_source_ambiguity _ -> ()
            | _ -> Alcotest.fail "source conflict lost its typed recovery kind")
         report.record_errors;
       let active_path =
         require_record_path ~location:Active_record ~base_path ~request_id
       in
       let legacy_path =
         require_record_path ~location:Legacy_record ~base_path ~request_id
       in
       let terminal_path =
         require_record_path ~location:Terminal_record ~base_path ~request_id
       in
       Alcotest.(check bool) "active evidence is preserved" true
         (Sys.file_exists active_path);
       Alcotest.(check bool) "legacy evidence is preserved" true
         (Sys.file_exists legacy_path);
       Alcotest.(check bool) "no ambiguous terminal was created" false
         (Sys.file_exists terminal_path))
;;

let test_keeper_msg_async_recovers_exact_active_legacy_duplicate_destination_first () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-active-legacy-exact-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_active_legacy_exact_0_0" in
       let json =
         request_record_json
           ~keeper_name:"exact-owner"
           ~base_path
           ~request_id
           ~status:"running"
           ~status_fields:[]
           ()
         |> Yojson.Safe.to_string
       in
       write_disk_record
         ~location:Active_record
         ~base_path
         ~request_id
         json;
       write_disk_record
         ~location:Legacy_record
         ~base_path
         ~request_id
         json;
       let report =
         Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path ()
       in
       Alcotest.(check int) "canonical active transitions once" 1 report.lost;
       Alcotest.(check int) "legacy duplicate cleans after destination" 1
         report.cleaned;
       Alcotest.(check int) "exact duplicate is not an error" 0 report.failed;
       let active_path =
         require_record_path ~location:Active_record ~base_path ~request_id
       in
       let legacy_path =
         require_record_path ~location:Legacy_record ~base_path ~request_id
       in
       let terminal_path =
         require_record_path ~location:Terminal_record ~base_path ~request_id
       in
       Alcotest.(check bool) "terminal destination exists" true
         (Sys.file_exists terminal_path);
       Alcotest.(check bool) "active source removed after destination" false
         (Sys.file_exists active_path);
       Alcotest.(check bool) "legacy source removed after destination" false
         (Sys.file_exists legacy_path))
;;

let test_keeper_msg_async_reports_json_directory_as_record_error () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-record-directory-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_record_directory_0_0" in
       let path =
         require_record_path ~location:Active_record ~base_path ~request_id
       in
       mkdir_p path;
       let report =
         Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path ()
       in
       Alcotest.(check int) "non-file record fails recovery" 1 report.failed;
       (match report.record_errors with
        | [ { Keeper_msg_async.kind = Keeper_msg_async.Recovery_record_not_file
            ; keeper_name = None
            ; _
            }
          ] ->
          ()
        | _ -> Alcotest.fail "record directory was silently skipped or misattributed");
       Alcotest.(check bool) "directory evidence is preserved" true
         (Sys.file_exists path && Sys.is_directory path))
;;

let test_keeper_msg_async_disk_cancel_refuses_unknown_worker_owner () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-disk-cancel-volatile-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_msg_async.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_disk_cancel_volatile_0_0" in
       write_request_record
         ~location:Active_record
         ~base_path
         ~request_id
         ~status:"running"
         ~status_fields:[]
         ();
       let result = Keeper_msg_async.cancel ~base_path ~caller request_id in
       (match result with
        | Keeper_msg_async.Cancel_worker_ownership_unknown Running -> ()
        | other ->
          Alcotest.failf
            "disk cancellation stole or misclassified an unknown worker: %s"
            (Keeper_msg_async.cancel_result_to_json ~request_id other
             |> Yojson.Safe.to_string));
       match Keeper_msg_async.poll ~base_path ~caller request_id with
       | Keeper_msg_async.Found { status = Running; _ } -> ()
       | _ -> Alcotest.fail "refused disk cancellation changed durable state")
;;

let test_keeper_msg_async_recovery_excludes_terminal_history () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-terminal-excluded-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_terminal_history_0_0" in
       write_request_record
         ~location:Terminal_record
         ~base_path
         ~request_id
         ~status:"running"
         ~status_fields:[]
         ();
       let report =
         Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path ()
       in
       Alcotest.(check int) "terminal history is not scanned" 0
         (report.lost + report.migrated + report.cleaned + report.unreadable + report.failed);
       let terminal_path =
         require_record_path ~location:Terminal_record ~base_path ~request_id
       in
       Alcotest.(check bool) "terminal history row is untouched" true
         (Sys.file_exists terminal_path))
;;

let test_keeper_persistence_preparation_configures_queue_before_request_recovery () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-persistence-prepare-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      Keeper_persistence_admission.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       Keeper_chat_queue.For_testing.reset ();
       let request_id = "kmsg_prepare_running_0_0" in
       write_request_record
         ~base_path
         ~request_id
         ~status:"running"
         ~status_fields:[]
         ();
       let prepared =
         match
           Server_bootstrap_loops.prepare_keeper_persistence
             ~config:(Workspace.default_config base_path)
         with
         | Ok prepared -> prepared
         | Error error ->
           Alcotest.failf
             "persistence preparation failed: %s"
             (Server_bootstrap_loops.keeper_persistence_prepare_error_to_string
                error)
       in
       Alcotest.(check bool) "queue is configured by preparation" true
         (Keeper_chat_queue.persistence_configured ());
       let report =
         Server_bootstrap_loops.keeper_persistence_report prepared
       in
       Alcotest.(check int) "request recovery completed inside preparation" 1
         report.requests.lost;
       match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
       | Keeper_msg_async.Found { status = Lost _; _ } -> ()
       | _ -> Alcotest.fail "prepared request was published before recovery")
;;

let test_keeper_persistence_preparation_rejects_structural_request_store () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-persistence-structural-store-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      Keeper_persistence_admission.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_structural_store_0_0" in
       let active_path =
         require_record_path ~location:Active_record ~base_path ~request_id
       in
       let active_store = Filename.dirname active_path in
       mkdir_p (Filename.dirname active_store);
       Fs_compat.save_file active_store "not-a-directory";
       match
         Server_bootstrap_loops.prepare_keeper_persistence
           ~config:(Workspace.default_config base_path)
       with
       | Error (Server_bootstrap_loops.Request_inventory_unavailable errors) ->
         Alcotest.(check bool)
           "active store error remains typed"
           true
           (List.exists
              (fun (error : Keeper_msg_async.recovery_store_error) ->
                 error.store = Keeper_msg_async.Active_store
                 && String.equal error.path active_store)
              errors)
       | Error error ->
         Alcotest.failf
           "unexpected preparation error: %s"
           (Server_bootstrap_loops.keeper_persistence_prepare_error_to_string
              error)
       | Ok _ -> Alcotest.fail "structural request store was published as ready")
;;

let test_keeper_persistence_preparation_preserves_unattributed_request_record () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-persistence-unattributed-record-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      Keeper_persistence_admission.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_unattributed_record_0_0" in
       write_disk_record
         ~location:Active_record
         ~base_path
         ~request_id
         "{corrupt";
       let prepared =
         match
           Server_bootstrap_loops.prepare_keeper_persistence
             ~config:(Workspace.default_config base_path)
         with
         | Ok prepared -> prepared
         | Error error ->
           Alcotest.failf
             "unattributed record blocked unrelated Keeper lanes: %s"
             (Server_bootstrap_loops.keeper_persistence_prepare_error_to_string
                error)
       in
       match
         (Server_bootstrap_loops.keeper_persistence_report prepared).requests
           .record_errors
       with
       | [ error ] ->
         Alcotest.(check string) "request id remains observable" request_id
           error.Keeper_msg_async.request_id;
         Alcotest.(check (option string)) "unattributed lane remains explicit"
           None error.keeper_name
       | _ -> Alcotest.fail "unattributed corrupt record evidence was lost")
;;

let test_keeper_persistence_preparation_defers_only_failed_lane () =
  with_eio_env
  @@ fun env ->
  let base_path = temp_dir "keeper-persistence-lane-fence-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      Keeper_persistence_admission.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       Keeper_chat_queue.For_testing.reset ();
       ignore (Keeper_chat_queue.configure_persistence ~base_path);
       let message : Keeper_chat_queue.queued_message =
         { content = "lane-a"
         ; user_blocks = []
         ; attachments = []
         ; timestamp = 1.0
         ; source = Dashboard
         }
       in
       (match Keeper_chat_queue.enqueue ~keeper_name:"lane-a" message with
        | Ok _ -> ()
        | Error error ->
          Alcotest.failf
            "failed to seed queue snapshot: %s"
            (Keeper_chat_queue.mutation_error_to_string error));
       let queue_path =
         match
           Keeper_chat_queue.For_testing.snapshot_path
             ~base_path
             ~keeper_name:"lane-a"
         with
         | Ok path -> path
         | Error reason -> Alcotest.fail reason
       in
       Fs_compat.save_file queue_path "{corrupt";
       Keeper_chat_queue.For_testing.reset ();
       let lane_a_request = "kmsg_lane_a_0_0" in
       let lane_b_request = "kmsg_lane_b_0_0" in
       write_request_record
         ~location:Active_record
         ~keeper_name:"lane-a"
         ~base_path
         ~request_id:lane_a_request
         ~status:"running"
         ~status_fields:[]
         ();
       write_request_record
         ~location:Active_record
         ~keeper_name:"lane-b"
         ~base_path
         ~request_id:lane_b_request
         ~status:"running"
         ~status_fields:[]
         ();
       let prepared =
         match
           Server_bootstrap_loops.prepare_keeper_persistence
             ~config:(Workspace.default_config base_path)
         with
         | Ok prepared -> prepared
         | Error error ->
           Alcotest.failf
             "lane-local queue failure blocked every keeper: %s"
             (Server_bootstrap_loops.keeper_persistence_prepare_error_to_string
                error)
       in
       let report =
         Server_bootstrap_loops.keeper_persistence_report prepared
       in
       Alcotest.(check (list string))
         "only the corrupt keeper is fenced"
         [ "lane-a" ]
         report.blocked_keeper_names;
       Alcotest.(check int) "failed lane request deferred" 1
         report.requests.deferred;
       Alcotest.(check int) "healthy lane request recovered" 1
         report.requests.lost;
       (match
          Server_bootstrap_loops.claim_prepared_keeper_persistence
            ~config:(Workspace.default_config base_path)
            prepared
        with
        | Ok _ -> ()
        | Error _ -> Alcotest.fail "lane recovery snapshot could not be claimed");
       Alcotest.(check bool) "failed lane admission is fenced" true
         (Keeper_persistence_admission.is_blocked
            ~base_path
            ~keeper_name:"lane-a");
       Alcotest.(check bool) "healthy lane admission remains open" false
         (Keeper_persistence_admission.is_blocked
            ~base_path
            ~keeper_name:"lane-b");
       Eio.Switch.run (fun sw ->
         let config = Workspace.default_config base_path in
         let ctx : _ Keeper_types_profile.context =
           { config
           ; agent_name = caller
           ; sw
           ; clock = Eio.Stdenv.clock env
           ; proc_mgr = None
           ; net = None
           }
         in
         let args =
           `Assoc
             [ "name", `String "lane-a"
             ; "message", `String "must remain fenced"
             ]
         in
         Alcotest.(check bool) "serialized turn entry is fenced" false
           (Tool_result.is_success (Keeper_turn.handle_keeper_msg ctx args));
         (match Keeper_turn.handle_keeper_msg_if_free ctx args with
          | `Ran result ->
            Alcotest.(check bool) "if-free turn entry is fenced" false
              (Tool_result.is_success result)
          | `Busy _ -> Alcotest.fail "persistence fence was misreported as busy");
         let worker_ran = Atomic.make false in
         (match
            Keeper_msg_async.submit
              ~background_sw:sw
              ~base_path
              ~caller
              ~keeper_name:"lane-a"
              ~f:(fun _request_sw ->
                Atomic.set worker_ran true;
                tr_ok "{}")
              ()
          with
          | Error (Keeper_msg_async.Submit_admission_blocked _) -> ()
          | Error error ->
            Alcotest.failf
              "async fence returned the wrong error: %s"
              (Keeper_msg_async.submit_error_to_json error
               |> Yojson.Safe.to_string)
          | Ok outcome ->
            Alcotest.failf
              "async submission bypassed the persistence fence: %s"
              (Keeper_msg_async.submit_outcome_to_json outcome
               |> Yojson.Safe.to_string));
         Alcotest.(check bool) "fenced async worker was not started" false
           (Atomic.get worker_ran));
       (match
          Keeper_msg_async.For_testing.load_record
            ~base_path
            ~request_id:lane_a_request
        with
        | Keeper_msg_async.Found { status = Running; _ } -> ()
        | _ -> Alcotest.fail "failed lane request did not remain active");
       match
         Keeper_msg_async.For_testing.load_record
           ~base_path
           ~request_id:lane_b_request
       with
       | Keeper_msg_async.Found { status = Lost _; _ } -> ()
       | _ -> Alcotest.fail "healthy lane request did not recover to Lost")
;;

let test_keeper_persistence_claim_is_latest_and_one_shot () =
  with_eio_env
  @@ fun _env ->
  let base_a = temp_dir "keeper-persistence-claim-a-" in
  let base_b = temp_dir "keeper-persistence-claim-b-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      Keeper_persistence_admission.For_testing.clear ();
      rm_rf base_a;
      rm_rf base_b)
    (fun () ->
       let config_a = Workspace.default_config base_a in
       let config_b = Workspace.default_config base_b in
       let prepare config =
         match Server_bootstrap_loops.prepare_keeper_persistence ~config with
         | Ok prepared -> prepared
         | Error error ->
           Alcotest.failf
             "claim fixture preparation failed: %s"
             (Server_bootstrap_loops.keeper_persistence_prepare_error_to_string
                error)
       in
       let prepared_a = prepare config_a in
       (match
          Server_bootstrap_loops.claim_prepared_keeper_persistence
            ~config:config_b
            prepared_a
        with
        | Error Server_bootstrap_loops.Claim_base_path_mismatch -> ()
        | _ -> Alcotest.fail "BasePath mismatch was not typed");
       (match
          Server_bootstrap_loops.claim_prepared_keeper_persistence
            ~config:config_a
            prepared_a
        with
        | Ok _ -> ()
        | Error _ -> Alcotest.fail "latest preparation could not be claimed");
       (match
          Server_bootstrap_loops.claim_prepared_keeper_persistence
            ~config:config_a
            prepared_a
        with
        | Error Server_bootstrap_loops.Claim_already_claimed -> ()
        | _ -> Alcotest.fail "second claim was not rejected");
       let _prepared_b = prepare config_b in
       match
         Server_bootstrap_loops.claim_prepared_keeper_persistence
           ~config:config_a
           prepared_a
       with
       | Error Server_bootstrap_loops.Claim_superseded -> ()
       | _ -> Alcotest.fail "superseded preparation became claimable again")
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
       (match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
        | Keeper_msg_async.Unreadable reason ->
          Alcotest.(check bool)
            "v1 hard cut is explicit"
            true
            (contains_substring
               ~needle:"unsupported keeper_msg request schema_version=1"
               reason)
        | Keeper_msg_async.Found _ -> Alcotest.fail "ownerless v1 record must not load"
        | Keeper_msg_async.Absent ->
          Alcotest.fail "ownerless v1 record unexpectedly absent"
        | Keeper_msg_async.Rejected _ -> Alcotest.fail "ownerless v1 is a schema error");
       let report =
         Keeper_msg_async.For_testing.recover_lost_disk_records ~base_path ()
       in
       Alcotest.(check int) "ownerless legacy row is reported unreadable" 1
         report.unreadable;
       let legacy_path =
         require_record_path ~location:Legacy_record ~base_path ~request_id
       in
       Alcotest.(check bool) "ownerless evidence is preserved" true
         (Sys.file_exists legacy_path))
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
            "request id collision uses reservation index"
            `Quick
            test_keeper_msg_async_request_id_collision_uses_reservation_index
        ; test_case
            "initial post-publish failure rolls back durably"
            `Quick
            test_keeper_msg_async_initial_post_publish_failure_rolls_back
        ; test_case
            "initial rollback failure preserves request id"
            `Quick
            test_keeper_msg_async_initial_rollback_failure_preserves_request_id
        ; test_case
            "reconciliation fences only ambiguous lane"
            `Quick
            test_keeper_msg_async_reconciliation_fences_only_ambiguous_lane
        ; test_case
            "running double write failure remains terminal in memory"
            `Quick
            test_keeper_msg_async_running_double_write_failure_is_terminal_in_memory
        ; test_case
            "running write failure projects durable marker once"
            `Quick
            test_keeper_msg_async_running_write_failure_projects_durable_marker_once
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
            "live cancel signals after post-publish failure"
            `Quick
            test_keeper_msg_async_live_cancel_signals_after_post_publish_failure
        ; test_case
            "explicit cancel retries failed worker signal"
            `Quick
            test_keeper_msg_async_explicit_cancel_retries_failed_worker_signal
        ; test_case
            "terminal record stays durable without age eviction"
            `Quick
            test_keeper_msg_async_terminal_record_is_durable_without_age_eviction
        ; test_case
            "legacy terminal migrates destination first"
            `Quick
            test_keeper_msg_async_migrates_legacy_terminal_destination_first
        ; test_case
            "legacy running recovers to terminal lost"
            `Quick
            test_keeper_msg_async_recovers_legacy_running_to_terminal_lost
        ; test_case
            "terminal precedence cleans stale active"
            `Quick
            test_keeper_msg_async_terminal_precedence_cleans_stale_active
        ; test_case
            "conflicting terminal source is preserved"
            `Quick
            test_keeper_msg_async_preserves_conflicting_terminal_source
        ; test_case
            "mismatched nonterminal source identity is preserved"
            `Quick
            test_keeper_msg_async_preserves_mismatched_nonterminal_source_identity
        ; test_case
            "persistence marker integrity conflict projects canonical terminal"
            `Quick
            test_keeper_msg_async_integrity_conflict_projects_canonical_terminal
        ; test_case
            "canonical settlement ignores staged worker result"
            `Quick
            test_keeper_stream_canonical_settlement_ignores_staged_worker_result
        ; test_case
            "integrity ambiguity projects exact poll error"
            `Quick
            test_keeper_msg_async_integrity_ambiguity_projects_exact_poll_error
        ; test_case
            "absent integrity fences lane and keeps request id reserved"
            `Quick
            test_keeper_msg_async_absent_integrity_keeps_request_id_reserved
        ; test_case
            "active legacy ambiguity is rejected before mutation"
            `Quick
            test_keeper_msg_async_rejects_active_legacy_ambiguity_before_mutation
        ; test_case
            "exact active legacy duplicate migrates destination first"
            `Quick
            test_keeper_msg_async_recovers_exact_active_legacy_duplicate_destination_first
        ; test_case
            "json directory is a typed record error"
            `Quick
            test_keeper_msg_async_reports_json_directory_as_record_error
        ; test_case
            "disk cancel refuses unknown worker owner"
            `Quick
            test_keeper_msg_async_disk_cancel_refuses_unknown_worker_owner
        ; test_case
            "recovery excludes terminal history"
            `Quick
            test_keeper_msg_async_recovery_excludes_terminal_history
        ; test_case
            "persistence preparation configures queue then recovers requests"
            `Quick
            test_keeper_persistence_preparation_configures_queue_before_request_recovery
        ; test_case
            "persistence preparation rejects structural request store"
            `Quick
            test_keeper_persistence_preparation_rejects_structural_request_store
        ; test_case
            "persistence preparation preserves unattributed request record"
            `Quick
            test_keeper_persistence_preparation_preserves_unattributed_request_record
        ; test_case
            "persistence preparation defers only failed lane"
            `Quick
            test_keeper_persistence_preparation_defers_only_failed_lane
        ; test_case
            "persistence claim is latest and one-shot"
            `Quick
            test_keeper_persistence_claim_is_latest_and_one_shot
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
