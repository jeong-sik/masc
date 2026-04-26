(* test/test_keeper_autoboot_supervisor_start_10125.ml

   #10125 root-cause fix: [keeper_autoboot] now starts the
   supervisor sweep at the end of its boot pass, instead of
   leaving it dormant until the first [masc_keeper_msg] tool
   call.

   A full integration test would require a real Eio switch
   plus a process manager plus a clock and a server context,
   which is heavier than a unit test should be.  These tests
   cover the contract the fix relies on: the supervisor-sweep
   running predicate behaves correctly for "never started"
   and the stop helper is a noop on that state — both
   properties together let the autoboot fiber call
   [start_supervisor_sweep] unconditionally with no risk of
   double-starting on the (later) first-tool-call path.
*)

let () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-keeper-autoboot-sup-10125-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir
;;

module R = Masc_mcp.Keeper_runtime

(* Fresh base_path: the running predicate must say [false]
   so [start_supervisor_sweep] can take the "actually start
   a Pulse" branch and emit the
   [keeper supervisor sweep started] log line / counter +1.
   If a future refactor flipped the default to true (e.g. by
   using a sentinel Pulse handle), the autoboot fix below
   would silently noop and #10125 would re-emerge. *)
let test_running_predicate_false_on_fresh_base_path () =
  let bp = "/tmp/test-keeper-autoboot-sup-10125-fresh" in
  Alcotest.(check bool)
    "supervisor_sweep_running on never-touched base_path is false"
    false
    (R.supervisor_sweep_running bp)
;;

(* [stop_supervisor_sweep] must be a noop on a base_path
   that never started a sweep.  The autoboot fix calls
   [start_supervisor_sweep] inside an exception handler;
   any sweep-related cleanup elsewhere must not throw on
   the "no entry" case or autoboot crashes propagate as
   server bootstrap failures. *)
let test_stop_is_noop_on_fresh_base_path () =
  let bp = "/tmp/test-keeper-autoboot-sup-10125-noop-stop" in
  (* Should not raise *)
  R.stop_supervisor_sweep bp;
  Alcotest.(check bool)
    "after stop on never-started: still not running"
    false
    (R.supervisor_sweep_running bp)
;;

let () =
  Alcotest.run
    "keeper_autoboot_supervisor_start_10125"
    [ ( "running-predicate"
      , [ Alcotest.test_case
            "false on fresh base_path"
            `Quick
            test_running_predicate_false_on_fresh_base_path
        ] )
    ; ( "stop-helper"
      , [ Alcotest.test_case
            "noop on fresh base_path"
            `Quick
            test_stop_is_noop_on_fresh_base_path
        ] )
    ]
;;
