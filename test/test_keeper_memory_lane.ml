(** Tests for Keeper_memory_lane (RFC-0257).

    The lane owns one FIFO worker per active keeper. Tests use promises for all
    scheduling boundaries; no assertion depends on scheduler yields or mutex
    waiter order. *)

module Lane = Masc.Keeper_memory_lane
module Metrics = Masc.Otel_metric_store

exception Test_boom
exception Cancel_lane_test
exception Foreign_cancel

let base_path = Filename.concat (Filename.get_temp_dir_name ()) "test-memory-lane"

let expect_ok label = function
  | Ok () -> ()
  | Error error ->
    Alcotest.failf "%s: %s" label (Lane.admission_error_to_string error)
;;

let check_state ~keeper_name ~pending ~queued ~workers =
  let check field expected = function
    | Some actual -> Alcotest.(check int) field expected actual
    | None -> Alcotest.failf "%s: keeper entry missing" field
  in
  check "pending" pending (Lane.For_testing.pending ~base_path ~keeper_name);
  check "queued" queued (Lane.For_testing.queued ~base_path ~keeper_name);
  check "active workers" workers
    (Lane.For_testing.active_workers ~base_path ~keeper_name)
;;

let metric_value metric ~labels =
  Metrics.metric_value_or_zero Masc.Keeper_metrics.(to_string metric) ~labels ()
;;

let check_metric_delta label metric ~labels ~before expected =
  let after = metric_value metric ~labels in
  Alcotest.(check (float 0.0)) label expected (after -. before)
;;

let test_uninitialized_rejects_without_running () =
  Lane.For_testing.reset ();
  let keeper_name = "uninitialized" in
  let labels = [ "keeper", keeper_name; "reason", "executor_not_initialized" ] in
  let before = metric_value MemoryLaneAdmissionRejected ~labels in
  let ran = ref false in
  (match Lane.submit ~base_path ~keeper_name (fun () -> ran := true) with
   | Error Lane.Executor_not_initialized -> ()
   | Error error ->
     Alcotest.failf "unexpected rejection: %s" (Lane.admission_error_to_string error)
   | Ok () -> Alcotest.fail "uninitialized executor accepted work");
  Alcotest.(check bool) "unit did not run in turn fiber" false !ran;
  Alcotest.(check bool)
    "no lane entry allocated"
    true
    (Option.is_none (Lane.For_testing.pending ~base_path ~keeper_name));
  check_metric_delta
    "rejection counted once"
    MemoryLaneAdmissionRejected
    ~labels
    ~before
    1.0
;;

let test_serializes_fifo_with_one_worker () =
  Lane.For_testing.reset ();
  let keeper_name = "fifo" in
  let order = ref [] in
  let add value = order := value :: !order in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let first_started, set_first_started = Eio.Promise.create () in
      let release_first, set_release_first = Eio.Promise.create () in
      let second_done, set_second_done = Eio.Promise.create () in
      expect_ok "first"
        (Lane.submit ~base_path ~keeper_name (fun () ->
           add "first-start";
           Eio.Promise.resolve set_first_started ();
           Eio.Promise.await release_first;
           add "first-end"));
      Eio.Promise.await first_started;
      expect_ok "second"
        (Lane.submit ~base_path ~keeper_name (fun () ->
           add "second";
           Eio.Promise.resolve set_second_done ()));
      check_state ~keeper_name ~pending:2 ~queued:1 ~workers:1;
      Eio.Promise.resolve set_release_first ();
      Eio.Promise.await second_done));
  Alcotest.(check (list string))
    "FIFO order"
    [ "first-start"; "first-end"; "second" ]
    (List.rev !order);
  check_state ~keeper_name ~pending:0 ~queued:0 ~workers:0
;;

let test_backlog_uses_one_worker_and_preserves_fifo () =
  Lane.For_testing.reset ();
  let keeper_name = "backlog" in
  let count = 64 in
  let order = ref [] in
  let labels = [ "keeper", keeper_name ] in
  let submitted_before = metric_value MemoryLaneSubmitted ~labels in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let first_started, set_first_started = Eio.Promise.create () in
      let release_first, set_release_first = Eio.Promise.create () in
      let all_done, set_all_done = Eio.Promise.create () in
      expect_ok "backlog head"
        (Lane.submit ~base_path ~keeper_name (fun () ->
           Eio.Promise.resolve set_first_started ();
           Eio.Promise.await release_first));
      Eio.Promise.await first_started;
      for index = 0 to count - 1 do
        expect_ok "backlog item"
          (Lane.submit ~base_path ~keeper_name (fun () ->
             order := index :: !order;
             if index = count - 1 then Eio.Promise.resolve set_all_done ()))
      done;
      check_state ~keeper_name ~pending:(count + 1) ~queued:count ~workers:1;
      check_metric_delta
        "every admitted unit counted once"
        MemoryLaneSubmitted
        ~labels
        ~before:submitted_before
        (Float.of_int (count + 1));
      Alcotest.(check (float 0.0))
        "pending gauge includes current and queued units"
        (Float.of_int (count + 1))
        (metric_value MemoryLanePending ~labels);
      Alcotest.(check (float 0.0))
        "one unit in flight"
        1.0
        (metric_value MemoryLaneInFlight ~labels);
      Eio.Promise.resolve set_release_first ();
      Eio.Promise.await all_done));
  Alcotest.(check (list int))
    "explicit queue preserves submission order"
    (List.init count Fun.id)
    (List.rev !order);
  check_state ~keeper_name ~pending:0 ~queued:0 ~workers:0;
  Alcotest.(check (float 0.0))
    "pending gauge returned to zero"
    0.0
    (metric_value MemoryLanePending ~labels);
  Alcotest.(check (float 0.0))
    "in-flight gauge returned to zero"
    0.0
    (metric_value MemoryLaneInFlight ~labels)
;;

let test_independent_across_keepers () =
  Lane.For_testing.reset ();
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let k1_started, set_k1_started = Eio.Promise.create () in
      let release_k1, set_release_k1 = Eio.Promise.create () in
      let k2_done, set_k2_done = Eio.Promise.create () in
      expect_ok "k1"
        (Lane.submit ~base_path ~keeper_name:"independent-k1" (fun () ->
           Eio.Promise.resolve set_k1_started ();
           Eio.Promise.await release_k1));
      Eio.Promise.await k1_started;
      expect_ok "k2"
        (Lane.submit ~base_path ~keeper_name:"independent-k2" (fun () ->
           Eio.Promise.resolve set_k2_done ()));
      Eio.Promise.await k2_done;
      check_state ~keeper_name:"independent-k1" ~pending:1 ~queued:0 ~workers:1;
      check_state ~keeper_name:"independent-k2" ~pending:0 ~queued:0 ~workers:0;
      Eio.Promise.resolve set_release_k1 ()))
;;

let test_raising_unit_recovers_and_counts_once () =
  Lane.For_testing.reset ();
  let keeper_name = "raise" in
  let labels = [ "keeper", keeper_name ] in
  let before = metric_value MemoryLaneUnitFailures ~labels in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      expect_ok "raising unit"
        (Lane.submit ~base_path ~keeper_name (fun () -> raise Test_boom));
      let recovered, set_recovered = Eio.Promise.create () in
      expect_ok "recovery unit"
        (Lane.submit ~base_path ~keeper_name (fun () ->
           Eio.Promise.resolve set_recovered ()));
      Eio.Promise.await recovered));
  check_state ~keeper_name ~pending:0 ~queued:0 ~workers:0;
  check_metric_delta
    "unit failure counted once"
    MemoryLaneUnitFailures
    ~labels
    ~before
    1.0
;;

let test_foreign_cancelled_result_does_not_drain_fifo () =
  Lane.For_testing.reset ();
  let keeper_name = "foreign-cancel" in
  let labels = [ "keeper", keeper_name ] in
  let failures_before = metric_value MemoryLaneUnitFailures ~labels in
  let cancellations_before = metric_value MemoryLaneCancelledUnits ~labels in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let foreign, set_foreign = Eio.Promise.create () in
      Eio.Promise.resolve_error set_foreign (Eio.Cancel.Cancelled Foreign_cancel);
      expect_ok "foreign cancellation"
        (Lane.submit ~base_path ~keeper_name (fun () ->
           Eio.Promise.await_exn foreign));
      let next_done, set_next_done = Eio.Promise.create () in
      expect_ok "unit after foreign cancellation"
        (Lane.submit ~base_path ~keeper_name (fun () ->
           Eio.Promise.resolve set_next_done ()));
      Eio.Promise.await next_done));
  check_metric_delta
    "foreign cancellation is a unit failure"
    MemoryLaneUnitFailures
    ~labels
    ~before:failures_before
    1.0;
  check_metric_delta
    "executor cancellation counter unchanged"
    MemoryLaneCancelledUnits
    ~labels
    ~before:cancellations_before
    0.0
;;

let test_shutdown_cancels_current_and_queued_units_observably () =
  Lane.For_testing.reset ();
  let keeper_name = "cancel" in
  let labels = [ "keeper", keeper_name ] in
  let before = metric_value MemoryLaneCancelledUnits ~labels in
  let queued_ran = ref false in
  (try
     Eio_main.run (fun _env ->
       Eio.Switch.run (fun sw ->
         Lane.init ~sw;
         let started, set_started = Eio.Promise.create () in
         let never, _set_never = Eio.Promise.create () in
         expect_ok "current"
           (Lane.submit ~base_path ~keeper_name (fun () ->
              Eio.Promise.resolve set_started ();
              Eio.Promise.await never));
         Eio.Promise.await started;
         expect_ok "queued"
           (Lane.submit ~base_path ~keeper_name (fun () -> queued_ran := true));
         check_state ~keeper_name ~pending:2 ~queued:1 ~workers:1;
         Eio.Switch.fail sw Cancel_lane_test))
   with
   | Cancel_lane_test -> ());
  check_state ~keeper_name ~pending:0 ~queued:0 ~workers:0;
  Alcotest.(check bool) "queued unit did not run" false !queued_ran;
  check_metric_delta
    "current and queued cancellations counted"
    MemoryLaneCancelledUnits
    ~labels
    ~before
    2.0
;;

let test_cancelling_switch_rejects_without_silent_fork () =
  Lane.For_testing.reset ();
  let ran = ref false in
  let result = ref None in
  (try
     Eio_main.run (fun _env ->
       Eio.Switch.run (fun sw ->
         Lane.init ~sw;
         Eio.Switch.fail sw Cancel_lane_test;
         result := Some (Lane.submit ~base_path ~keeper_name:"stopping" (fun () -> ran := true))))
   with
   | Cancel_lane_test -> ());
  (match !result with
   | Some (Error Lane.Executor_stopping) -> ()
   | Some (Error error) ->
     Alcotest.failf "unexpected rejection: %s" (Lane.admission_error_to_string error)
   | Some (Ok ()) -> Alcotest.fail "cancelling switch accepted work"
   | None -> Alcotest.fail "missing admission result");
  Alcotest.(check bool) "callback never ran" false !ran
;;

let test_finished_switch_rejects_without_silent_fork () =
  Lane.For_testing.reset ();
  let ran = ref false in
  let finished_sw = ref None in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      finished_sw := Some sw));
  let sw =
    match !finished_sw with
    | Some sw -> sw
    | None -> Alcotest.fail "missing captured switch"
  in
  Lane.init ~sw;
  (match Lane.submit ~base_path ~keeper_name:"finished" (fun () -> ran := true) with
   | Error Lane.Executor_stopping -> ()
   | Error error ->
     Alcotest.failf "unexpected rejection: %s" (Lane.admission_error_to_string error)
   | Ok () -> Alcotest.fail "finished switch accepted work");
  Alcotest.(check bool) "callback never ran" false !ran
;;

let test_executor_domain_mismatch_is_typed () =
  Lane.For_testing.reset ();
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let domain =
        Domain.spawn (fun () ->
          Lane.submit ~base_path ~keeper_name:"wrong-domain" (fun () -> ()))
      in
      match Domain.join domain with
      | Error Lane.Executor_domain_mismatch -> ()
      | Error error ->
        Alcotest.failf "unexpected rejection: %s" (Lane.admission_error_to_string error)
      | Ok () -> Alcotest.fail "non-owner domain accepted work"))
;;

let () =
  Alcotest.run
    "keeper_memory_lane"
    [ ( "lane"
      , [ Alcotest.test_case
            "uninitialized rejects without running"
            `Quick
            test_uninitialized_rejects_without_running
        ; Alcotest.test_case
            "serializes FIFO with one worker"
            `Quick
            test_serializes_fifo_with_one_worker
        ; Alcotest.test_case
            "backlog uses one worker and preserves FIFO"
            `Quick
            test_backlog_uses_one_worker_and_preserves_fifo
        ; Alcotest.test_case
            "independent across keepers"
            `Quick
            test_independent_across_keepers
        ; Alcotest.test_case
            "raising unit recovers and counts once"
            `Quick
            test_raising_unit_recovers_and_counts_once
        ; Alcotest.test_case
            "foreign cancellation does not drain FIFO"
            `Quick
            test_foreign_cancelled_result_does_not_drain_fifo
        ; Alcotest.test_case
            "shutdown cancellations are observable"
            `Quick
            test_shutdown_cancels_current_and_queued_units_observably
        ; Alcotest.test_case
            "cancelling switch rejects without silent fork"
            `Quick
            test_cancelling_switch_rejects_without_silent_fork
        ; Alcotest.test_case
            "finished switch rejects without silent fork"
            `Quick
            test_finished_switch_rejects_without_silent_fork
        ; Alcotest.test_case
            "executor domain mismatch is typed"
            `Quick
            test_executor_domain_mismatch_is_typed
        ] )
    ]
;;
