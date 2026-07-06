(* Admission fd-pressure gate (C12 perf fix).

   The gate must skip the per-call [/dev/fd] directory scan when no threshold
   is configured.  Before this change the threshold was the sentinel [max_int],
   which admitted every call (no real fd count reaches [max_int * 9 / 10]) yet
   still ran [Otel_metric_process.approximate_open_fd_count] — a directory
   scan — on every admission.

   Pinned here:
   1. Disabled ([None]) admits without ever forcing the fd-count thunk, i.e.
      the scan is not run on the hot admission path while gating is off.
   2. Enabled ([Some n]) forces the thunk exactly once and applies the 90%
      rejection boundary: below 90% admits, at/above 90% rejects.

   The thunk is the dependency-injected stand-in for the real fd scan; a call
   counter makes the "scan skipped while disabled" guarantee observable. *)

open Alcotest

module A = Masc.Admission_queue
module M = Masc.Admission_queue_metrics

(* Returns a thunk and the ref recording how many times the gate forced it. *)
let counting_fd ~returns =
  let calls = ref 0 in
  let thunk () =
    incr calls;
    returns
  in
  (thunk, calls)

(* The rejection path of the underlying [check_host_resources_with] records
   fd-growth history under an [Eio.Mutex], so the gate must run inside an Eio
   scheduler (as it always does in production, under [with_permit]). *)
let gate ~threshold ~fd_count =
  Eio_main.run @@ fun _env ->
  A.For_testing.check_host_resources_for_threshold ~surface:M.With_permit
    ~keeper_name:"test-keeper" ~threshold ~fd_count

let is_ok = function Ok () -> true | Error _ -> false
let is_saturated = function Error (`Host_resource_saturated _) -> true | Ok () -> false

let test_disabled_skips_scan () =
  (* A huge fd value would reject if it were ever read; it must not be. *)
  let fd_count, calls = counting_fd ~returns:999_999 in
  let r = gate ~threshold:None ~fd_count in
  check bool "disabled admits" true (is_ok r);
  check int "disabled never runs the fd scan" 0 !calls

let test_below_threshold_admits () =
  let fd_count, calls = counting_fd ~returns:50 in
  let r = gate ~threshold:(Some 100) ~fd_count in
  check bool "below 90% admits" true (is_ok r);
  check int "scan forced exactly once" 1 !calls

let test_at_threshold_rejects () =
  (* 100 * 9 / 10 = 90; an fd count of 90 reaches the boundary. *)
  let fd_count, calls = counting_fd ~returns:90 in
  let r = gate ~threshold:(Some 100) ~fd_count in
  check bool "at 90% rejects" true (is_saturated r);
  check int "scan forced exactly once" 1 !calls

let test_just_below_threshold_admits () =
  let fd_count, calls = counting_fd ~returns:89 in
  let r = gate ~threshold:(Some 100) ~fd_count in
  check bool "just below 90% admits" true (is_ok r);
  check int "scan forced exactly once" 1 !calls

(* Counter-state tests: the previous implementation silently clamped negative
   active counts to zero inside [bump_active].  These tests pin the explicit
   underflow result and the acquire/release accounting. *)

let test_apply_active_delta_underflow () =
  match A.For_testing.apply_active_delta ~active:0 ~delta:(-1) with
  | Error (`Counter_underflow (-1)) ->
    check bool "reports explicit underflow" true true
  | Ok _ -> fail "expected Counter_underflow error"
  | Error (`Counter_underflow n) ->
    failf "unexpected underflow value %d" n

let test_bump_active_underflow_leaves_counter () =
  Eio_main.run @@ fun _env ->
  A.reset_for_test ~max_slots:10;
  check int "initial active" 0 (A.For_testing.get_active ());
  match A.For_testing.bump_active ~loc:"test" (-1) with
  | Error (`Counter_underflow (-1)) ->
    check int "counter unchanged on underflow" 0 (A.For_testing.get_active ())
  | Ok _ -> fail "expected Counter_underflow error"
  | Error (`Counter_underflow n) -> failf "unexpected underflow value %d" n

let test_bump_active_advances_counter () =
  Eio_main.run @@ fun _env ->
  A.reset_for_test ~max_slots:10;
  check int "initial active" 0 (A.For_testing.get_active ());
  (match A.For_testing.bump_active ~loc:"test" 1 with
   | Ok () -> check int "active after bump" 1 (A.For_testing.get_active ())
   | Error _ -> fail "unexpected underflow");
  (match A.For_testing.bump_active ~loc:"test" (-1) with
   | Ok () -> check int "active after release" 0 (A.For_testing.get_active ())
   | Error _ -> fail "unexpected underflow")

let test_apply_active_delta_advances () =
  match A.For_testing.apply_active_delta ~active:2 ~delta:1 with
  | Ok 3 -> check bool "advances counter" true true
  | Ok n -> failf "expected active=3, got %d" n
  | Error _ -> fail "unexpected underflow"

let test_with_permit_releases_active_on_success () =
  Eio_main.run @@ fun _env ->
  A.reset_for_test ~max_slots:10;
  check int "initial active" 0 (A.For_testing.get_active ());
  let r =
    A.with_permit ~priority:Llm_provider.Request_priority.Background
      ~keeper_name:"rel-keeper" ~runtime_id:"r1" (fun () -> 42)
  in
  check bool "returns value" true (Result.is_ok r);
  check int "active released after success" 0 (A.For_testing.get_active ())

let test_with_permit_releases_active_on_exception () =
  Eio_main.run @@ fun _env ->
  A.reset_for_test ~max_slots:10;
  check int "initial active" 0 (A.For_testing.get_active ());
  (try
     A.with_permit ~priority:Llm_provider.Request_priority.Background
       ~keeper_name:"rel-keeper" ~runtime_id:"r2" (fun () -> failwith "boom")
     |> ignore
   with
   | Failure _ -> ()
   | _ -> fail "expected Failure");
  check int "active released after exception" 0 (A.For_testing.get_active ())

let test_try_with_permit_result_returns_value_without_scan_when_disabled () =
  Eio_main.run @@ fun _env ->
  A.reset_for_test ~max_slots:10;
  let fd_count, calls = counting_fd ~returns:999_999 in
  let result =
    A.For_testing.try_with_permit_result_for_threshold
      ~keeper_name:"try-keeper"
      ~runtime_id:"r-try-success"
      ~threshold:None
      ~fd_count
      (fun () -> 42)
  in
  (match result with
   | Ok value -> check int "returned value" 42 value
   | Error (`Host_resource_saturated msg) ->
     failf "unexpected saturation: %s" msg);
  check int "disabled try_with_permit_result skips fd scan" 0 !calls;
  check int "active released after result success" 0 (A.For_testing.get_active ())

let test_try_with_permit_result_surfaces_rejection () =
  Eio_main.run @@ fun _env ->
  A.reset_for_test ~max_slots:10;
  let fd_count, calls = counting_fd ~returns:90 in
  let body_called = ref false in
  let result =
    A.For_testing.try_with_permit_result_for_threshold
      ~keeper_name:"try-keeper"
      ~runtime_id:"r-try-reject"
      ~threshold:(Some 100)
      ~fd_count
      (fun () ->
         body_called := true;
         42)
  in
  (match result with
   | Error (`Host_resource_saturated msg) ->
     check bool "rejection message present" true (String.length msg > 0)
   | Ok _ -> fail "expected Host_resource_saturated");
  check int "scan forced exactly once" 1 !calls;
  check bool "body not called on rejection" false !body_called;
  check int "active unchanged on rejection" 0 (A.For_testing.get_active ())

let () =
  run "admission_fd_gate"
    [
      ( "scan-skip",
        [ test_case "disabled skips fd scan" `Quick test_disabled_skips_scan ] );
      ( "threshold",
        [
          test_case "below threshold admits" `Quick test_below_threshold_admits;
          test_case "at threshold rejects" `Quick test_at_threshold_rejects;
          test_case "just below threshold admits" `Quick
            test_just_below_threshold_admits;
        ] );
      ( "counter-state",
        [
          test_case "apply delta underflow is explicit" `Quick
            test_apply_active_delta_underflow;
          test_case "bump active underflow leaves counter" `Quick
            test_bump_active_underflow_leaves_counter;
          test_case "bump active advances and releases" `Quick
            test_bump_active_advances_counter;
          test_case "apply delta advances" `Quick test_apply_active_delta_advances;
          test_case "release active on success" `Quick
            test_with_permit_releases_active_on_success;
          test_case "release active on exception" `Quick
            test_with_permit_releases_active_on_exception;
        ] );
      ( "try-with-permit-result",
        [
          test_case "disabled threshold returns value without fd scan" `Quick
            test_try_with_permit_result_returns_value_without_scan_when_disabled;
          test_case "saturation returns explicit rejection" `Quick
            test_try_with_permit_result_surfaces_rejection;
        ] );
    ]
