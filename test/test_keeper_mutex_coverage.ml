open Alcotest
open Masc

let tr_ok body = Tool_result.ok ~tool_name:"keeper-test" ~start_time:0.0 body
let caller = "keeper-msg-test-caller"

let keeper_request ?(prompt = "test invocation") keeper_name =
  match Keeper_invocation_types.keeper_turn ~keeper_name ~prompt with
  | Ok request -> request
  | Error reason -> Alcotest.fail reason
;;

let test_direct_invocation_request_roundtrip () =
  let payload : Keeper_direct_invocation.t =
    { execution_prompt = "inspect the attached context"
    ; attachments = []
    ; user_blocks = [ Keeper_direct_invocation.User_text "inspect this" ]
    ; turn_instructions = Some "reply on the captured route"
    ; connector_context = None
    ; continuation_channel = Keeper_continuation_channel.Dashboard { thread_id = "keeper:k" }
    ; projection =
        { user_content = "inspect this"
        ; surface = Surface_ref.Dashboard { session_id = Some "session" }
        ; conversation_id = None
        ; external_message_id = None
        ; speaker =
            { speaker_id = None
            ; speaker_name = None
            ; speaker_authority = Keeper_direct_invocation.Owner
            }
        }
    }
  in
  let request =
    match Keeper_invocation_types.direct_turn ~keeper_name:"k" payload with
    | Ok request -> request
    | Error detail -> fail detail
  in
  let decoded =
    match
      request
      |> Keeper_invocation_types.request_to_json
      |> Keeper_invocation_types.request_of_json
    with
    | Ok request -> request
    | Error detail -> fail detail
  in
  check bool "direct request roundtrips exactly" true
    (Keeper_invocation_types.request_equal request decoded);
  check bool "direct request retains its executor payload" true
    (Option.is_some (Keeper_invocation_types.request_direct_delivery decoded))
;;

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
  Unix.realpath path
;;

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | stat when stat.Unix.st_kind = Unix.S_DIR ->
    Sys.readdir path |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
    Unix.rmdir path
  | _ -> Unix.unlink path
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

let test_keeper_msg_async_persistence_lane_samples_are_unique () =
  let samples = Keeper_msg_async.For_testing.persistence_lane_samples () in
  let assert_sample metric expected_kind =
    let name = Keeper_metrics.to_string metric in
    let matching =
      List.filter
        (fun (sample : Otel_metrics.sample) ->
           String.equal sample.name name && sample.labels = [])
        samples
    in
    match matching with
    | [ sample ] ->
      check bool (name ^ " kind") true (sample.kind = expected_kind);
      check bool (name ^ " nonnegative") true (sample.value >= 0.0)
    | matches ->
      failf "%s direct sample count=%d" name (List.length matches)
  in
  assert_sample Keeper_metrics.PersistenceLaneWaits Otel_metrics.Counter;
  assert_sample Keeper_metrics.PersistenceLanePending Otel_metrics.Gauge;
  assert_sample Keeper_metrics.PersistenceLaneInFlight Otel_metrics.Gauge;
  check int "only the three direct lane samples" 3 (List.length samples)
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
      ~request:(keeper_request ~prompt:"durable dotted request" "alpha.with.dot")
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
  Alcotest.(check string) "dotted keeper name accepted" "alpha.with.dot"
    (Keeper_invocation_types.request_target_name entry.request);
  Alcotest.(check string)
    "prompt persisted in typed request"
    "durable dotted request"
    (Keeper_invocation_types.request_prompt entry.request);
  (match
     Keeper_msg_async.load_canonical_durable_entry ~base_path ~caller request_id
   with
   | Keeper_msg_async.Found durable ->
     Alcotest.(check bool)
       "canonical lookup returns the exact durable request"
       true
       (Keeper_invocation_types.request_equal entry.request durable.request)
   | Keeper_msg_async.Absent
   | Keeper_msg_async.Unreadable _
   | Keeper_msg_async.Rejected _ ->
     Alcotest.fail "canonical durable request lookup failed");
  Alcotest.(check bool)
    "request completed"
    true
    (match entry.Keeper_msg_async.status with
     | Done { ok = true; body; _ } -> String.length body > 0
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
      ~request:(keeper_request keeper_name)
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
  let expected_data = `Assoc [ "kind", `String "done" ] in
  let request_id =
    Keeper_msg_async.submit
      ~background_sw:sw
      ~base_path
      ~caller
      ~request:(keeper_request "beta")
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
        ~request:(keeper_request "root-lifetime")
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
           ~request:(keeper_request "initial-persist-failure")
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
      rm_rf base_path)
    (fun () ->
       let generated = Atomic.make 0 in
       let generate_request_id () =
         match Atomic.fetch_and_add generated 1 with
         | 0 | 1 -> "kmsg-reserved-collision"
         | ordinal -> Printf.sprintf "kmsg-reserved-unique-%d" ordinal
       in
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
       let before_durable_write stage =
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
                done))
       in
       let request_ops =
         Keeper_msg_async.For_testing.make_request_ops
           ~before_durable_write
           ~generate_request_id
           ()
       in
       let first_result, resolve_first_result = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         Eio.Promise.resolve
           resolve_first_result
           (Keeper_msg_async.For_testing.submit
              request_ops
              ~background_sw:sw
              ~base_path
              ~caller
              ~request:(keeper_request "reservation-first")
              ~f:(fun _ -> tr_ok "{}")
              ()));
       Fun.protect
         ~finally:release_first_write
         (fun () ->
            Eio.Promise.await first_at_write;
            let second_request_id =
              Keeper_msg_async.For_testing.submit
                request_ops
                ~background_sw:sw
                ~base_path
                ~caller
                ~request:(keeper_request "reservation-second")
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
      rm_rf base_path)
    (fun () ->
       let worker_ran = Atomic.make false in
       let request_ops =
         Keeper_msg_async.For_testing.make_request_ops
           ~before_durable_write:
             (fail_once_on_write_stage
                Keeper_fs.Parent_directory_fsync_after_rename)
           ()
       in
       match
         Keeper_msg_async.For_testing.submit
           request_ops
           ~background_sw
           ~base_path
           ~caller
           ~request:(keeper_request "initial-rollback")
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
      rm_rf base_path)
    (fun () ->
       let worker_ran = Atomic.make false in
       let request_ops =
         Keeper_msg_async.For_testing.make_request_ops
           ~before_durable_write:
             (fail_once_on_write_stage
                Keeper_fs.Parent_directory_fsync_after_rename)
           ~before_durable_remove:(fail_once_on_remove_stage Keeper_fs.Unlink)
           ()
       in
       match
         Keeper_msg_async.For_testing.submit
           request_ops
           ~background_sw
           ~base_path
           ~caller
           ~request:(keeper_request "initial-uncertain")
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
          | _ -> Alcotest.fail "published uncertain request cannot be reconciled");
         Alcotest.(check int)
           "uncertain request keeps only its own id reserved"
           1
           (Keeper_msg_async.For_testing.reserved_request_id_count ());
         Keeper_msg_async.For_testing.forget ~base_path ~caller ~request_id;
         (match
            (Keeper_msg_async.For_testing.recover_request_records ~base_path ())
              .candidates
          with
          | [ { provenance = Queued_before_restart; _ } ] -> ()
          | _ -> Alcotest.fail "queued restart provenance was not preserved");
         let subsequent_request_id =
           Keeper_msg_async.submit
             ~background_sw
             ~base_path
             ~caller
             ~request:(keeper_request "initial-uncertain")
             ~f:(fun _request_sw -> tr_ok "{}")
             ()
           |> accepted_request_id
         in
         Alcotest.(check bool)
           "request-local reconciliation does not fence later work"
           true
           (not (String.equal request_id subsequent_request_id))
       | Ok outcome ->
         Alcotest.failf
           "uncertain write was reported durable: %s"
           (Keeper_msg_async.submit_outcome_to_json outcome |> Yojson.Safe.to_string)
       | Error error ->
         Alcotest.failf
           "uncertain request id was discarded: %s"
         (Keeper_msg_async.submit_error_to_json error |> Yojson.Safe.to_string))
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
       let request_ops =
         Keeper_msg_async.For_testing.make_request_ops
           ~before_durable_write:(fun stage ->
             if stage = Keeper_fs.Payload_write
             then (
               let ordinal = Atomic.fetch_and_add payload_writes 1 + 1 in
               if ordinal >= 2
               then failwith "synthetic repeated request persistence failure"))
           ()
       in
       let request_id =
         Keeper_msg_async.For_testing.submit
           request_ops
           ~on_worker_settled:(fun ~request_id:_ settlement ->
             settlements := settlement :: !settlements)
           ~background_sw
           ~base_path
           ~caller
           ~request:(keeper_request "running-double-write-failure")
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
       let request_ops =
         Keeper_msg_async.For_testing.make_request_ops
           ~before_durable_write:(fun stage ->
             if stage = Keeper_fs.Payload_write
             then (
               let ordinal = Atomic.fetch_and_add payload_writes 1 + 1 in
               if ordinal = 2
               then failwith "synthetic Running persistence failure"))
           ()
       in
       let request_id =
         Keeper_msg_async.For_testing.submit
           request_ops
           ~on_worker_aborted:(fun reason ->
             aborts := reason :: !aborts;
             Ok ())
           ~on_worker_settled:(fun ~request_id:_ settlement ->
             settlements := settlement :: !settlements)
           ~background_sw
           ~base_path
           ~caller
           ~request:(keeper_request "running-write-failure")
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

let test_keeper_msg_async_inventories_recovered_running () =
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
      ~request:(keeper_request "gamma")
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
  let report =
    Keeper_msg_async.For_testing.recover_request_records ~base_path ()
  in
  Alcotest.(check int) "exclusive recovery inventories the disk-only worker" 1
    (List.length report.candidates);
  (match report.candidates with
   | [ { entry; provenance = Running_before_restart } ] ->
     Alcotest.(check string) "candidate preserves request id" request_id entry.request_id
   | _ -> Alcotest.fail "expected one running restart candidate");
  match Keeper_msg_async.poll ~base_path ~caller request_id with
  | Keeper_msg_async.Found { Keeper_msg_async.status = Running; _ } ->
    Keeper_msg_async.For_testing.forget ~base_path ~caller ~request_id;
    (match Keeper_msg_async.poll ~base_path ~caller request_id with
     | Keeper_msg_async.Found { Keeper_msg_async.status = Running; _ } -> ()
     | Keeper_msg_async.Found entry ->
       Alcotest.failf
         "expected persisted running, got %s"
         (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
     | Keeper_msg_async.Absent
     | Keeper_msg_async.Unreadable _
     | Keeper_msg_async.Rejected _ ->
       Alcotest.fail "expected persisted running request")
  | Keeper_msg_async.Found entry ->
    Alcotest.failf
      "expected inventoried running, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
  | Keeper_msg_async.Absent
  | Keeper_msg_async.Unreadable _
  | Keeper_msg_async.Rejected _ ->
    Alcotest.fail "expected persisted request"
;;

let test_keeper_msg_async_inventory_excludes_live_worker () =
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
      ~request:(keeper_request "sweep")
      ~f:(fun _request_sw ->
        Eio.Promise.await promise;
        tr_ok "{}")
      ()
    |> accepted_request_id
  in
  ignore (wait_for_running ~base_path request_id : Keeper_msg_async.entry);
  Alcotest.(check int)
    "live in-memory worker is not a restart candidate"
    0
    (List.length
       (Keeper_msg_async.For_testing.recover_request_records ~base_path ()).candidates);
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
    "disk-only in-flight request becomes a restart candidate"
    1
    (List.length
       (Keeper_msg_async.For_testing.recover_request_records ~base_path ()).candidates);
  match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
  | Keeper_msg_async.Found { Keeper_msg_async.status = Running; _ } ->
    (match
       Keeper_msg_async.For_testing.active_record_path ~base_path ~request_id,
       Keeper_msg_async.For_testing.terminal_record_path ~base_path ~request_id
     with
     | Some active_path, Some terminal_path ->
       Alcotest.(check bool) "inventory preserves active namespace entry" true
         (Sys.file_exists active_path);
       Alcotest.(check bool) "inventory does not fabricate terminal state" false
         (Sys.file_exists terminal_path)
     | _ -> Alcotest.fail "expected safe partitioned record paths")
  | Keeper_msg_async.Found entry ->
    Alcotest.failf
      "expected inventoried running request, got %s"
      (Keeper_msg_async.status_to_string entry.Keeper_msg_async.status)
  | Keeper_msg_async.Absent
  | Keeper_msg_async.Unreadable _
  | Keeper_msg_async.Rejected _ ->
    Alcotest.fail "expected persisted running request"
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
        ~request:(keeper_request "cancelled")
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
      ~request:(keeper_request "operator-cancelled")
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
       let fail_cancel_persistence = Atomic.make false in
       let failed = Atomic.make false in
       let request_ops =
         Keeper_msg_async.For_testing.make_request_ops
           ~before_durable_write:(fun stage ->
             if
               Atomic.get fail_cancel_persistence
               && stage = Keeper_fs.Parent_directory_fsync_after_rename
               && Atomic.compare_and_set failed false true
             then failwith "synthetic durable write failure")
           ()
       in
       let request_id =
         Keeper_msg_async.For_testing.submit
           request_ops
           ~background_sw:sw
           ~base_path
           ~caller
           ~request:(keeper_request "live-cancel-volatile")
           ~f:(fun _request_sw ->
             Eio.Promise.await never;
             tr_ok "{}")
           ()
         |> accepted_request_id
       in
       ignore (wait_for_running ~base_path request_id : Keeper_msg_async.entry);
       Atomic.set fail_cancel_persistence true;
       let result =
         Keeper_msg_async.For_testing.cancel
           request_ops
           ~base_path
           ~caller
           request_id
       in
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
       let signal_attempts = Atomic.make 0 in
       let request_ops =
         Keeper_msg_async.For_testing.make_request_ops
           ~signal_cancel:(fun request_sw cause ->
             let attempt = Atomic.fetch_and_add signal_attempts 1 + 1 in
             if attempt = 1
             then failwith "synthetic worker signal failure"
             else Eio.Switch.fail request_sw cause)
           ()
       in
       let request_id =
         Keeper_msg_async.For_testing.submit
           request_ops
           ~on_worker_aborted:(fun reason ->
             aborts := reason :: !aborts;
             Ok ())
           ~on_worker_settled:(fun ~request_id:_ settlement ->
             settlements := settlement :: !settlements)
           ~background_sw:sw
           ~base_path
           ~caller
           ~request:(keeper_request "cancel-signal-retry")
           ~f:(fun _request_sw ->
             Eio.Promise.await never;
             tr_ok "{}")
           ()
         |> accepted_request_id
       in
       ignore (wait_for_running ~base_path request_id : Keeper_msg_async.entry);
       wait_for_active_switch_count (Eio.Stdenv.clock env) 1;
       (match
          Keeper_msg_async.For_testing.cancel
            request_ops
            ~base_path
            ~caller
            request_id
        with
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
       (match
          Keeper_msg_async.For_testing.cancel
            request_ops
            ~base_path
            ~caller
            request_id
        with
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
      ~request:(keeper_request "delta")
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

let disk_record_path ~location ~base_path ~request_id =
  match location with
  | Active_record ->
    Keeper_msg_async.For_testing.active_record_path ~base_path ~request_id
  | Terminal_record ->
    Keeper_msg_async.For_testing.terminal_record_path ~base_path ~request_id
;;

let write_disk_record ?(location = Active_record) ~base_path ~request_id content =
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
     ; "request", Keeper_invocation_types.request_to_json (keeper_request keeper_name)
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

let test_keeper_msg_async_resumes_exact_queued_candidate_once () =
  with_eio_env
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let base_path = temp_dir "keeper-msg-resume-queued-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_msg_async.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_resume_queued_0_0" in
       write_request_record
         ~base_path
         ~request_id
         ~status:"queued"
         ~status_fields:[]
         ();
       let candidate =
         match
           (Keeper_msg_async.For_testing.recover_request_records ~base_path ())
             .candidates
         with
         | [ candidate ] -> candidate
         | candidates ->
           failf "expected one restart candidate, got %d" (List.length candidates)
       in
       let entered, resolve_entered = Eio.Promise.create () in
       let release, resolve_release = Eio.Promise.create () in
       let calls = Atomic.make 0 in
       let run _request_sw =
         ignore (Atomic.fetch_and_add calls 1 : int);
         Eio.Promise.resolve resolve_entered ();
         Eio.Promise.await release;
         tr_ok "resumed"
       in
       (match
          Keeper_msg_async.resume_recovery_candidate
            ~background_sw:sw
            ~f:run
            { candidate with provenance = Running_before_restart }
        with
        | Error (Keeper_msg_async.Recovery_candidate_changed Queued) -> ()
        | Error error ->
          failf
            "forged provenance returned %s"
            (Keeper_msg_async.recovery_resume_error_to_string error)
        | Ok _ -> fail "forged recovery provenance claimed the queued request");
       (match
          Keeper_msg_async.resume_recovery_candidate
            ~background_sw:sw
            ~f:run
            candidate
        with
        | Ok outcome ->
          check string "original request identity" request_id outcome.request_id
        | Error error ->
          fail (Keeper_msg_async.recovery_resume_error_to_string error));
       Eio.Promise.await entered;
       (match
          Keeper_msg_async.resume_recovery_candidate
            ~background_sw:sw
            ~f:run
            candidate
        with
        | Error Keeper_msg_async.Recovery_candidate_already_owned -> ()
        | Error error ->
          failf
            "second claim returned %s"
            (Keeper_msg_async.recovery_resume_error_to_string error)
        | Ok _ -> fail "second claim forked a duplicate worker");
       Eio.Promise.resolve resolve_release ();
       ignore
         (wait_for_done_with_clock
            (Eio.Stdenv.clock env)
            ~base_path
            request_id
          : Keeper_msg_async.entry);
       check int "worker executed once" 1 (Atomic.get calls);
       match
         Keeper_msg_async.resume_recovery_candidate
           ~background_sw:sw
           ~f:run
           candidate
       with
       | Error (Keeper_msg_async.Recovery_candidate_terminal (Done _)) -> ()
       | Error error ->
         failf
           "stale claim returned %s"
           (Keeper_msg_async.recovery_resume_error_to_string error)
       | Ok _ -> fail "terminal candidate was restarted")
;;

let require_record_path ~location ~base_path ~request_id =
  match disk_record_path ~location ~base_path ~request_id with
  | Some path -> path
  | None -> Alcotest.fail "expected safe partitioned request path"
;;

let test_keeper_msg_async_exact_load_rejects_outside_symlink_records () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-record-symlink-base-" in
  let outside = temp_dir "keeper-msg-record-symlink-outside-" in
  Fun.protect
    ~finally:(fun () ->
      rm_rf base_path;
      rm_rf outside)
    (fun () ->
       [ Active_record; Terminal_record ]
       |> List.iteri (fun index location ->
         let request_id = Printf.sprintf "kmsg_outside_symlink_%d_0" index in
         let status, status_fields =
           match location with
           | Active_record -> "running", []
           | Terminal_record ->
             ( "done"
             , [ "completed_at", `Float 2.0
               ; "ok", `Bool true
               ; "body", `String "outside"
               ] )
         in
         let outside_path = Filename.concat outside (request_id ^ ".json") in
         let outside_content =
           request_record_json
             ~base_path
             ~request_id
             ~status
             ~status_fields
             ()
           |> Yojson.Safe.to_string
         in
         Fs_compat.save_file outside_path outside_content;
         let record_path = require_record_path ~location ~base_path ~request_id in
         mkdir_p (Filename.dirname record_path);
         Unix.symlink outside_path record_path;
         (match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
          | Keeper_msg_async.Unreadable reason ->
            Alcotest.(check bool)
              "symlink rejection is explicit"
              true
              (String.length reason > 0)
          | Keeper_msg_async.Found _ ->
            Alcotest.fail "outside symlink record crossed the BasePath boundary"
          | Keeper_msg_async.Absent ->
            Alcotest.fail "outside symlink record was silently hidden"
          | Keeper_msg_async.Rejected _ ->
            Alcotest.fail "persisted symlink was misclassified as caller input");
         Alcotest.(check bool)
           "canonical record name remains a symlink"
           true
           ((Unix.lstat record_path).st_kind = Unix.S_LNK);
         Alcotest.(check string)
           "outside evidence remains untouched"
           outside_content
           (Fs_compat.load_file outside_path)))
;;

let test_keeper_msg_async_finalizes_active_terminal_destination_first () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-active-terminal-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_active_done_0_0" in
       write_request_record
         ~base_path
         ~request_id
         ~status:"done"
         ~status_fields:
           [ "completed_at", `Float 2.0
           ; "ok", `Bool true
           ; "body", `String {|{"result":"active"}|}
           ]
         ();
       (match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
        | Keeper_msg_async.Found { status = Done { ok = true; _ }; _ } -> ()
        | _ -> Alcotest.fail "active terminal row was not readable before recovery");
       let report =
         Keeper_msg_async.For_testing.recover_request_records ~base_path ()
       in
       Alcotest.(check int) "one active terminal finalized" 1 report.finalized;
       let active_path =
         require_record_path ~location:Active_record ~base_path ~request_id
       in
       let terminal_path =
         require_record_path ~location:Terminal_record ~base_path ~request_id
       in
       Alcotest.(check bool) "terminal destination committed" true
         (Sys.file_exists terminal_path);
       Alcotest.(check bool) "active source removed after commit" false
         (Sys.file_exists active_path))
;;

let test_keeper_msg_async_inventories_active_running_without_mutation () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-active-running-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_active_running_0_0" in
       write_request_record
         ~base_path
         ~request_id
         ~status:"running"
         ~status_fields:[]
         ();
       let report =
         Keeper_msg_async.For_testing.recover_request_records ~base_path ()
       in
       Alcotest.(check int) "one active in-flight row was inventoried" 1
         (List.length report.candidates);
       let active_path =
         require_record_path ~location:Active_record ~base_path ~request_id
       in
       let terminal_path =
         require_record_path ~location:Terminal_record ~base_path ~request_id
       in
       Alcotest.(check bool) "no terminal state fabricated" false
         (Sys.file_exists terminal_path);
       Alcotest.(check bool) "running active source preserved" true
         (Sys.file_exists active_path);
       match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
       | Keeper_msg_async.Found { status = Running; _ } -> ()
       | _ -> Alcotest.fail "inventoried active request did not remain Running")
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
         Keeper_msg_async.For_testing.recover_request_records ~base_path ()
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
         Keeper_msg_async.For_testing.recover_request_records ~base_path ()
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
       let injection : (Keeper_msg_async.entry * string) option Atomic.t =
         Atomic.make None
       in
       let inject_terminal = Atomic.make true in
       let request_ops =
         Keeper_msg_async.For_testing.make_request_ops
           ~before_durable_write:(fun stage ->
             match Atomic.get injection with
             | Some (running, request_id)
               when stage = Keeper_fs.Payload_write
                    && Atomic.compare_and_set inject_terminal true false ->
               write_request_record
                 ~location:Terminal_record
                 ~keeper_name:
                   (Keeper_invocation_types.request_target_name running.request)
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
               failwith "synthetic terminal write failure"
             | Some _ | None -> ())
           ()
       in
       let request_id =
         Keeper_msg_async.For_testing.submit
           request_ops
           ~on_worker_settled:(fun ~request_id:_ settlement ->
             settlements := settlement :: !settlements)
           ~background_sw:sw
           ~base_path
           ~caller
           ~request:(keeper_request "canonical-integrity-settlement")
           ~f:(fun _request_sw ->
             Eio.Promise.await release;
             tr_ok {|{"worker":"result"}|})
           ()
         |> accepted_request_id
       in
       let running : Keeper_msg_async.entry =
         wait_for_running ~base_path request_id
       in
       Atomic.set injection (Some (running, request_id));
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
               { status = Done { ok = true; body; _ }
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
       | Keeper_msg_async.Found { status = Done { ok = true; body; _ }; _ } ->
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
  let status =
    Keeper_msg_async.Done
      { ok = true; body = "canonical-disk"; data = None }
  in
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
           ~on_worker_settled:(fun ~request_id:_ settlement ->
             settlements := settlement :: !settlements)
           ~background_sw:sw
           ~base_path
           ~caller
           ~request:(keeper_request "integrity-projection-error")
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
         Keeper_msg_async.For_testing.recover_request_records ~base_path ()
       in
       Alcotest.(check int) "identity conflict is explicit" 1 report.failed;
       let active_path =
         require_record_path ~location:Active_record ~base_path ~request_id
       in
       Alcotest.(check bool) "mismatched source evidence is preserved" true
         (Sys.file_exists active_path))
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
         Keeper_msg_async.For_testing.recover_request_records ~base_path ()
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
       let terminal_path =
         require_record_path ~location:Terminal_record ~base_path ~request_id
       in
       let terminal_artifact =
         Filename.concat
           (Filename.dirname terminal_path)
           "unrelated-terminal-artifact"
       in
       Fs_compat.save_file terminal_artifact "terminal evidence";
       let report =
         Keeper_msg_async.For_testing.recover_request_records ~base_path ()
       in
       Alcotest.(check int) "terminal history is not scanned" 0
         (List.length report.candidates
          + report.finalized + report.cleaned + report.unreadable + report.failed);
       Alcotest.(check int) "terminal staging inventory is not scanned" 0
         (report.staging_files_deleted + report.staging_files_preserved);
       Alcotest.(check bool) "terminal history row is untouched" true
         (Sys.file_exists terminal_path);
       Alcotest.(check bool) "terminal artifact is untouched" true
         (Sys.file_exists terminal_artifact))
;;

let test_keeper_msg_async_recovers_current_staging_files () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-current-staging-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let staging =
         Keeper_msg_async.For_testing.atomic_staging_dir ~base_path
       in
       Fs_compat.mkdir_p staging;
       Fs_compat.save_file (Filename.concat staging ".atomic_empty.tmp") "";
       Fs_compat.save_file
         (Filename.concat staging ".atomic_evidence.tmp")
         "unpublished v3 evidence";
       let report =
         Keeper_msg_async.For_testing.recover_request_records ~base_path ()
       in
       Alcotest.(check int) "two current staging files inspected" 2
         report.staging_files_inspected;
       Alcotest.(check int) "empty staging file deleted" 1
         report.staging_files_deleted;
       Alcotest.(check int) "non-empty staging file preserved" 1
         report.staging_files_preserved;
       Alcotest.(check int) "staging recovery succeeds" 0 report.failed)
;;

let test_keeper_msg_async_recovery_rejects_linked_request_root () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-recovery-linked-base-" in
  let outside = temp_dir "keeper-msg-recovery-linked-outside-" in
  let linked_masc = Filename.concat base_path ".masc" in
  Fun.protect
    ~finally:(fun () ->
      (match Unix.lstat linked_masc with
       | { Unix.st_kind = Unix.S_LNK; _ } -> Unix.unlink linked_masc
       | _ -> ()
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      rm_rf base_path;
      rm_rf outside)
    (fun () ->
       Fs_compat.mkdir_p (Filename.concat outside ".masc");
       Unix.symlink (Filename.concat outside ".masc") linked_masc;
       let request_id = "kmsg_linked_duplicate_0_0" in
       write_request_record
         ~location:Active_record
         ~base_path
         ~request_id
         ~status:"running"
         ~status_fields:[]
         ();
       write_request_record
         ~location:Terminal_record
         ~base_path
         ~request_id
         ~status:"done"
         ~status_fields:
           [ "completed_at", `Float 2.0
           ; "ok", `Bool true
           ; "body", `String "terminal"
           ; "data", `Null
           ]
         ();
       let active_path =
         require_record_path ~location:Active_record ~base_path ~request_id
       in
       let terminal_path =
         require_record_path ~location:Terminal_record ~base_path ~request_id
       in
       let report =
         Keeper_msg_async.For_testing.recover_request_records ~base_path ()
       in
       Alcotest.(check bool)
         "linked request root is a typed store failure"
         true
         (report.failed > 0 && report.store_errors <> []);
       Alcotest.(check bool)
         "outside active source remains untouched"
         true
         (Sys.file_exists active_path);
       Alcotest.(check bool)
         "outside terminal source remains untouched"
         true
         (Sys.file_exists terminal_path))
;;

let test_keeper_persistence_preparation_configures_queue_before_request_recovery () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-persistence-prepare-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      Server_bootstrap_loops.For_testing.reset_keeper_persistence_lifecycle ();
      rm_rf base_path)
    (fun () ->
       Server_bootstrap_loops.For_testing.reset_keeper_persistence_lifecycle ();
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
             ()
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
       Alcotest.(check int) "request inventory completed inside preparation" 1
         (List.length report.requests.candidates);
       match Keeper_msg_async.For_testing.load_record ~base_path ~request_id with
       | Keeper_msg_async.Found { status = Running; _ } -> ()
       | _ -> Alcotest.fail "prepared request was mutated during inventory")
;;

let test_keeper_persistence_preparation_observes_structural_request_store () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-persistence-structural-store-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      Server_bootstrap_loops.For_testing.reset_keeper_persistence_lifecycle ();
      rm_rf base_path)
    (fun () ->
       Server_bootstrap_loops.For_testing.reset_keeper_persistence_lifecycle ();
       let request_id = "kmsg_structural_store_0_0" in
       let active_path =
         require_record_path ~location:Active_record ~base_path ~request_id
       in
       let active_store = Filename.dirname active_path in
       mkdir_p (Filename.dirname active_store);
       Fs_compat.save_file active_store "not-a-directory";
       let prepared =
         match
         Server_bootstrap_loops.prepare_keeper_persistence
           ~config:(Workspace.default_config base_path)
           ()
         with
         | Ok prepared -> prepared
         | Error error ->
           Alcotest.failf
             "structural request observation blocked preparation: %s"
             (Server_bootstrap_loops.keeper_persistence_prepare_error_to_string
                error)
       in
       let report = Server_bootstrap_loops.keeper_persistence_report prepared in
       Alcotest.(check bool)
         "active store error remains typed"
         true
         (List.exists
            (fun (error : Keeper_msg_async.recovery_store_error) ->
               error.store = Keeper_msg_async.Active_store
               && String.equal error.path active_store)
            report.requests.store_errors);
       match
         Server_bootstrap_loops.claim_prepared_keeper_persistence
           ~config:(Workspace.default_config base_path)
           prepared
       with
       | Ok _ -> ()
       | Error error ->
         Alcotest.failf
           "typed request-store observation poisoned owner claim: %s"
           (Server_bootstrap_loops.keeper_persistence_claim_error_to_string error))
;;

let test_keeper_persistence_preparation_preserves_unattributed_request_record () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-persistence-unattributed-record-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      Server_bootstrap_loops.For_testing.reset_keeper_persistence_lifecycle ();
      rm_rf base_path)
    (fun () ->
       Server_bootstrap_loops.For_testing.reset_keeper_persistence_lifecycle ();
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
             ()
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


let test_keeper_persistence_ready_rejects_second_preparation () =
  with_eio_env
  @@ fun _env ->
  let base_a = temp_dir "keeper-persistence-ready-a-" in
  let base_b = temp_dir "keeper-persistence-ready-b-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      Server_bootstrap_loops.For_testing.reset_keeper_persistence_lifecycle ();
      rm_rf base_a;
      rm_rf base_b)
    (fun () ->
       Server_bootstrap_loops.For_testing.reset_keeper_persistence_lifecycle ();
       let config_a = Workspace.default_config base_a in
       let config_b = Workspace.default_config base_b in
       let request_id = "kmsg_ready_reject_b_0_0" in
       write_request_record
         ~base_path:base_b
         ~request_id
         ~status:"running"
         ~status_fields:[]
         ();
       (match Server_bootstrap_loops.prepare_keeper_persistence ~config:config_a () with
        | Ok _ -> ()
        | Error error ->
          Alcotest.failf
            "first persistence preparation failed: %s"
            (Server_bootstrap_loops.keeper_persistence_prepare_error_to_string
               error));
       (match Server_bootstrap_loops.prepare_keeper_persistence ~config:config_b () with
        | Error Server_bootstrap_loops.Preparation_awaiting_claim -> ()
        | Error error ->
          Alcotest.failf
            "ready preparation returned the wrong second-owner error: %s"
            (Server_bootstrap_loops.keeper_persistence_prepare_error_to_string
               error)
        | Ok _ -> Alcotest.fail "ready persistence preparation was replaced");
       match
         Keeper_msg_async.For_testing.load_record
           ~base_path:base_b
           ~request_id
       with
       | Keeper_msg_async.Found { status = Running; _ } -> ()
       | _ -> Alcotest.fail "rejected second preparation mutated its BasePath")
;;

let test_keeper_persistence_canonical_start_token_is_affine () =
  with_eio_env
  @@ fun _env ->
  let parent = temp_dir "keeper-persistence-canonical-" in
  let real_a = Filename.concat parent "real-a" in
  let real_b = Filename.concat parent "real-b" in
  let alias = Filename.concat parent "owner" in
  mkdir_p real_a;
  mkdir_p real_b;
  Unix.symlink real_a alias;
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      Server_bootstrap_loops.For_testing.reset_keeper_persistence_lifecycle ();
      rm_rf parent)
    (fun () ->
       Server_bootstrap_loops.For_testing.reset_keeper_persistence_lifecycle ();
       let canonical_config = Workspace.default_config (Unix.realpath real_a) in
       let config =
         { canonical_config with base_path = alias; workspace_path = alias }
       in
       let prepared =
         match
           Server_bootstrap_loops.prepare_keeper_persistence
             ~requested_base_path:alias
             ~config:canonical_config
             ()
         with
         | Ok prepared -> prepared
         | Error error ->
           Alcotest.failf
             "canonical fixture preparation failed: %s"
             (Server_bootstrap_loops.keeper_persistence_prepare_error_to_string
                error)
       in
       let requested, canonical =
         Server_bootstrap_loops.For_testing.prepared_base_paths prepared
       in
       Alcotest.(check string) "requested alias is retained" config.base_path requested;
       Alcotest.(check string) "canonical BasePath is frozen" (Unix.realpath real_a)
         canonical;
       Sys.remove alias;
       Unix.symlink real_b alias;
       (match
          Server_bootstrap_loops.claim_prepared_keeper_persistence ~config prepared
        with
        | Error Server_bootstrap_loops.Claim_base_path_mismatch -> ()
        | Error error ->
          Alcotest.failf
            "retargeted claim returned the wrong error: %s"
            (Server_bootstrap_loops.keeper_persistence_claim_error_to_string error)
       | Ok _ -> Alcotest.fail "retargeted BasePath claimed stale recovery");
       Sys.remove alias;
       Unix.symlink real_a alias;
       let claimed =
         match
           Server_bootstrap_loops.claim_prepared_keeper_persistence
             ~config:canonical_config
             prepared
         with
         | Ok claimed -> claimed
         | Error error ->
           Alcotest.failf
             "restored canonical claim failed: %s"
             (Server_bootstrap_loops.keeper_persistence_claim_error_to_string error)
       in
       Sys.remove alias;
       Unix.symlink real_b alias;
       (match
          Server_bootstrap_loops.claim_prepared_keeper_persistence ~config prepared
        with
        | Error Server_bootstrap_loops.Claim_already_claimed -> ()
        | Error error ->
          Alcotest.failf
            "terminal claim state was hidden by retargeted path: %s"
            (Server_bootstrap_loops.keeper_persistence_claim_error_to_string error)
        | Ok _ -> Alcotest.fail "claimed token was reused after path retarget");
       (match
          Server_bootstrap_loops.For_testing.begin_keeper_loops_start
            ~config
            claimed
        with
        | Error (Server_bootstrap_loops.Start_base_path_mismatch _) -> ()
        | Error error ->
          Alcotest.failf
            "retargeted start returned the wrong error: %s"
            (Server_bootstrap_loops.keeper_persistence_start_error_to_string error)
        | Ok _ -> Alcotest.fail "retargeted BasePath started stale recovery");
       Sys.remove alias;
       Unix.symlink real_a alias;
       let ownership =
         match
           Server_bootstrap_loops.For_testing.begin_keeper_loops_start
             ~config:canonical_config
             claimed
         with
         | Ok ownership -> ownership
         | Error error ->
           Alcotest.failf
             "canonical start ownership failed: %s"
             (Server_bootstrap_loops.keeper_persistence_start_error_to_string error)
       in
       (match
          Server_bootstrap_loops.For_testing.begin_keeper_loops_start
            ~config
            claimed
        with
        | Error Server_bootstrap_loops.Start_in_progress -> ()
        | Error error ->
          Alcotest.failf
            "concurrent start returned the wrong error: %s"
            (Server_bootstrap_loops.keeper_persistence_start_error_to_string error)
        | Ok _ -> Alcotest.fail "claimed token started twice concurrently");
       (match
          Server_bootstrap_loops.For_testing.finish_keeper_loops_start ownership
        with
        | Ok () -> ()
        | Error error ->
          Alcotest.failf
            "canonical start ownership did not finish: %s"
            (Server_bootstrap_loops.keeper_persistence_start_error_to_string error));
       Sys.remove alias;
       Unix.symlink real_b alias;
       match
         Server_bootstrap_loops.For_testing.begin_keeper_loops_start ~config claimed
       with
       | Error Server_bootstrap_loops.Start_already_started -> ()
       | Error error ->
         Alcotest.failf
           "reused start token returned the wrong error: %s"
           (Server_bootstrap_loops.keeper_persistence_start_error_to_string error)
       | Ok _ -> Alcotest.fail "claimed token started Keeper loops twice")
;;

let test_keeper_persistence_claim_is_one_shot_for_process () =
  with_eio_env
  @@ fun _env ->
  let base_a = temp_dir "keeper-persistence-claim-a-" in
  let base_b = temp_dir "keeper-persistence-claim-b-" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      Server_bootstrap_loops.For_testing.reset_keeper_persistence_lifecycle ();
      rm_rf base_a;
      rm_rf base_b)
    (fun () ->
       Server_bootstrap_loops.For_testing.reset_keeper_persistence_lifecycle ();
       let config_a = Workspace.default_config base_a in
       let config_b = Workspace.default_config base_b in
       let prepare config =
         match Server_bootstrap_loops.prepare_keeper_persistence ~config () with
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
       match Server_bootstrap_loops.prepare_keeper_persistence ~config:config_b () with
       | Error Server_bootstrap_loops.Preparation_already_claimed -> ()
       | Error error ->
         Alcotest.failf
           "second startup owner returned the wrong error: %s"
           (Server_bootstrap_loops.keeper_persistence_prepare_error_to_string
              error)
       | Ok _ -> Alcotest.fail "second startup owner mutated claimed persistence")
;;

let test_keeper_msg_async_rejects_v3_record_without_compatibility () =
  with_eio_env
  @@ fun _env ->
  let base_path = temp_dir "keeper-msg-reject-v3-" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let request_id = "kmsg_unsupported_v3_0_0" in
       write_disk_record
         ~location:Active_record
         ~base_path
         ~request_id
         (Yojson.Safe.to_string
            (`Assoc
                [ "schema_version", `Int 3
                ; "request_id", `String request_id
                ; "keeper_name", `String "alpha"
                ; "base_path", `String (Fs_compat.realpath base_path)
                ; "submitted_by", `String caller
                ; "status", `String "running"
                ; "submitted_at", `Float 1.0
                ]));
       (match Keeper_msg_async.poll ~base_path ~caller request_id with
        | Keeper_msg_async.Unreadable reason ->
          Alcotest.(check bool) "schema rejection is explicit" true
            (String.length reason > 0)
        | Keeper_msg_async.Found _ ->
          Alcotest.fail "unsupported v3 record was decoded"
        | Keeper_msg_async.Absent ->
          Alcotest.fail "unsupported v3 evidence was hidden"
        | Keeper_msg_async.Rejected _ ->
          Alcotest.fail "unsupported persisted schema was classified as caller input");
       let report =
         Keeper_msg_async.For_testing.recover_request_records ~base_path ()
       in
       Alcotest.(check int) "unsupported v3 is reported unreadable" 1
         report.unreadable;
       let active_path =
         require_record_path ~location:Active_record ~base_path ~request_id
       in
       Alcotest.(check bool) "unsupported v3 evidence is preserved" true
         (Sys.file_exists active_path))
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
                ; "request", Keeper_invocation_types.request_to_json (keeper_request "alpha")
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
                ; "request", Keeper_invocation_types.request_to_json (keeper_request "alpha")
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
                ; "request", Keeper_invocation_types.request_to_json (keeper_request "alpha")
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
      , [ test_case
            "typed direct invocation roundtrips"
            `Quick
            test_direct_invocation_request_roundtrip
        ; test_case
            "persistence lane direct samples are unique"
            `Quick
            test_keeper_msg_async_persistence_lane_samples_are_unique
        ; test_case "submit/poll roundtrip" `Quick test_keeper_msg_async_roundtrip
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
            "running double write failure remains terminal in memory"
            `Quick
            test_keeper_msg_async_running_double_write_failure_is_terminal_in_memory
        ; test_case
            "running write failure projects durable marker once"
            `Quick
            test_keeper_msg_async_running_write_failure_projects_durable_marker_once
        ; test_case
            "inventory disk-only running request"
            `Quick
            test_keeper_msg_async_inventories_recovered_running
        ; test_case
            "restart inventory excludes live worker"
            `Quick
            test_keeper_msg_async_inventory_excludes_live_worker
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
            "active terminal finalizes destination first"
            `Quick
            test_keeper_msg_async_finalizes_active_terminal_destination_first
        ; test_case
            "active running inventory is non-mutating"
            `Quick
            test_keeper_msg_async_inventories_active_running_without_mutation
        ; test_case
            "queued restart candidate is claimed exactly once"
            `Quick
            test_keeper_msg_async_resumes_exact_queued_candidate_once
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
            "current staging files recover without legacy scan"
            `Quick
            test_keeper_msg_async_recovers_current_staging_files
        ; test_case
            "request recovery rejects a linked store root"
            `Quick
            test_keeper_msg_async_recovery_rejects_linked_request_root
        ; test_case
            "exact load rejects active and terminal outside symlinks"
            `Quick
            test_keeper_msg_async_exact_load_rejects_outside_symlink_records
        ; test_case
            "persistence preparation configures queue then recovers requests"
            `Quick
            test_keeper_persistence_preparation_configures_queue_before_request_recovery
        ; test_case
            "persistence preparation observes structural request store"
            `Quick
            test_keeper_persistence_preparation_observes_structural_request_store
        ; test_case
            "persistence preparation preserves unattributed request record"
            `Quick
            test_keeper_persistence_preparation_preserves_unattributed_request_record
        ; test_case
            "ready persistence preparation rejects a second owner"
            `Quick
            test_keeper_persistence_ready_rejects_second_preparation
        ; test_case
            "canonical persistence start token is affine"
            `Quick
            test_keeper_persistence_canonical_start_token_is_affine
        ; test_case
            "persistence claim is one-shot for the process"
            `Quick
            test_keeper_persistence_claim_is_one_shot_for_process
        ; test_case
            "oversized request id rejected"
            `Quick
            test_keeper_msg_async_rejects_oversized_request_id
        ; test_case
            "load_record absent id is Absent"
            `Quick
            test_keeper_msg_async_load_record_absent_id
        ; test_case
            "v3 request record is rejected without compatibility"
            `Quick
            test_keeper_msg_async_rejects_v3_record_without_compatibility
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
