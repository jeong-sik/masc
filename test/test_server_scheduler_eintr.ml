(** Fatal-report contract tests for [Server_scheduler_eintr]. *)

open Alcotest
open Masc

module Eintr = Server_scheduler_eintr

let context ~pending_shutdown ~git_commit ~ws_sessions =
  {
    Eintr.pending_shutdown;
    uptime_s = 45296.4;
    mcp_sessions = 3;
    ws_sessions;
    ocaml_version = "5.5.1";
    masc_version = "test-build";
    git_commit;
    pid = 4242;
  }
;;

let check_contains report needle =
  check
    bool
    ("report mentions " ^ needle)
    true
    (String_util.contains_substring report needle)
;;

let test_report_carries_actionable_pointers () =
  let report =
    Eintr.describe
      (context
         ~pending_shutdown:None
         ~git_commit:(Some "abc123")
         ~ws_sessions:(Some 1))
      ~syscall:"read"
      ~backtrace:"Raised at Stdlib in file \"stdlib.ml\", line 1\n"
  in
  check_contains report "EINTR";
  check_contains report "masc#43225";
  check_contains report "ocaml-multicore/eio@9480f2a9a4e6";
  check_contains report "clear_event_fd";
  check_contains report "from read escaped";
  check_contains report "pending shutdown signal: none";
  check_contains report "pid=4242";
  check_contains report "uptime_s=45296.4";
  check_contains report "mcp_sessions=3 ws_sessions=1";
  check_contains report "ocaml=5.5.1";
  check_contains report "git=abc123"
;;

let test_report_names_pending_signal_and_unknown_git () =
  let report =
    Eintr.describe
      (context
         ~pending_shutdown:(Some Eintr.Sigterm)
         ~git_commit:None
         ~ws_sessions:None)
      ~syscall:"read"
      ~backtrace:"no trailing newline"
  in
  check_contains report "pending shutdown signal: SIGTERM";
  check_contains report "ws_sessions=busy";
  check_contains report "git=unknown.";
  check bool "report ends with newline" true (String.ends_with ~suffix:"\n" report)
;;

let test_shutdown_signal_names () =
  check string "sigterm" "SIGTERM" (Eintr.shutdown_signal_name Eintr.Sigterm);
  check string "sigint" "SIGINT" (Eintr.shutdown_signal_name Eintr.Sigint)
;;

let () =
  run
    "server_scheduler_eintr"
    [
      ( "report",
        [
          test_case "carries actionable pointers" `Quick test_report_carries_actionable_pointers;
          test_case
            "names pending signal and unknown git"
            `Quick
            test_report_names_pending_signal_and_unknown_git;
          test_case "shutdown signal names" `Quick test_shutdown_signal_names;
        ] );
    ]
;;
