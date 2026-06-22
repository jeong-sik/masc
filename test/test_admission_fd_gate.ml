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
    ]
