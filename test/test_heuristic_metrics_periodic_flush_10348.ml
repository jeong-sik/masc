(** #10348: heuristic_metrics.jsonl was 0 bytes for 24 h+ despite three
    active emit sites because [record] only flushed when the in-memory
    buffer reached [buffer_cap=64] or when [shutdown_hooks] ran.  The
    keeper daemon never reaches either path quickly: post_verifier.verify
    is dead, drift_guard.verify_handoff fires only on handoffs, and
    keeper_alert_signal is env-gated.  These tests pin the time-based
    flush so a single [record] call produces visible output once the
    flush interval has elapsed. *)

module HM = Masc_mcp.Heuristic_metrics

let tmp_base () =
  let p =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "10348-flush-%06x" (Random.bits ()))
  in
  Unix.mkdir p 0o755;
  p

let ledger_path base =
  Filename.concat base (Filename.concat ".masc" "heuristic_metrics.jsonl")

let make_event ~site =
  HM.{
    module_name = "test_10348";
    site;
    raw_value = 0.5;
    threshold = 0.5;
    triggered = false;
    provenance = Drift_guard "test";
    timestamp = Unix.gettimeofday ();
  }

let count_lines path =
  if not (Sys.file_exists path) then 0
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let n = ref 0 in
      try
        while true do
          let _ = input_line ic in
          incr n
        done; !n
      with End_of_file -> !n)

(* Pre-fix behavior: with default 30 s interval and no shutdown,
   a single [record] (well under buffer_cap=64) leaves the file empty.
   Post-fix: setting interval to 0.0 flushes on every record. *)
let test_periodic_flush_below_cap () =
  let base = tmp_base () in
  HM.reset_for_test ();
  HM.set_flush_interval_for_test 0.0;
  HM.init ~base_path:base;
  HM.record (make_event ~site:"low_rate_emit");
  let path = ledger_path base in
  Alcotest.(check int) "1 record flushed without hitting cap" 1
    (count_lines path)

(* Multiple records below cap with the time-based flush enabled all
   land in the file.  Pre-fix this test would have shown 0 lines. *)
let test_multiple_records_below_cap () =
  let base = tmp_base () in
  HM.reset_for_test ();
  HM.set_flush_interval_for_test 0.0;
  HM.init ~base_path:base;
  for i = 1 to 5 do
    HM.record (make_event ~site:(Printf.sprintf "site_%d" i))
  done;
  let path = ledger_path base in
  Alcotest.(check int) "5 records flushed below cap" 5
    (count_lines path)

(* Sanity: with a large interval the time-based path is dormant, so the
   file remains empty until [flush] is called explicitly.  This pins the
   "we still batch when configured to" half of the contract. *)
let test_large_interval_still_batches () =
  let base = tmp_base () in
  HM.reset_for_test ();
  HM.set_flush_interval_for_test 1e9;
  HM.init ~base_path:base;
  HM.record (make_event ~site:"buffered");
  let path = ledger_path base in
  Alcotest.(check int) "no premature flush" 0 (count_lines path);
  HM.flush ();
  Alcotest.(check int) "explicit flush still works" 1 (count_lines path)

(* Audit regression: [record] before [init] used to leave data only in the
   volatile in-memory buffer, with no warning and no flush when [init] finally
   installed the store path.  Late init must make already-buffered rows durable. *)
let test_late_init_flushes_preinit_buffer () =
  let base = tmp_base () in
  HM.reset_for_test ();
  HM.set_flush_interval_for_test 1e9;
  HM.record (make_event ~site:"preinit");
  let path = ledger_path base in
  Alcotest.(check int) "pre-init record is not durable yet" 0
    (count_lines path);
  HM.init ~base_path:base;
  Alcotest.(check int) "late init flushes buffered record" 1
    (count_lines path)

let () =
  Random.self_init ();
  Alcotest.run "heuristic_metrics_periodic_flush_10348" [
    "time_flush", [
      Alcotest.test_case "single record flushes when interval=0"
        `Quick test_periodic_flush_below_cap;
      Alcotest.test_case "multiple records flush below buffer_cap"
        `Quick test_multiple_records_below_cap;
      Alcotest.test_case "large interval batches; explicit flush works"
        `Quick test_large_interval_still_batches;
      Alcotest.test_case "late init flushes pre-init buffer"
        `Quick test_late_init_flushes_preinit_buffer;
    ];
  ]
