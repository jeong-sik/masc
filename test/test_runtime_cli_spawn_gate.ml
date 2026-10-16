(** Admission-gate contract tests for [Runtime_cli_spawn_gate]. *)

open Alcotest
open Masc

module Gate = Runtime_cli_spawn_gate
module FA = Fd_accountant

let test_bounds_are_pinned () =
  (* Derivations live in the .mli; pin the numbers so a drift lands in
     review, not silently. *)
  check int "max concurrent CLI spawns" 8 Gate.max_concurrent_cli_spawns;
  check int "child fd ceiling" 16000 Gate.child_fd_ceiling
;;

let test_slot_returns_and_releases () =
  Eio_main.run @@ fun _env ->
  let result =
    Gate.with_cli_spawn_slot (fun () ->
      check int "active inside slot" 1 (Gate.active_cli_spawns ());
      check
        int
        "Fd_accountant observes the slot"
        1
        (FA.active_count ~kind:FA.Provider_cli);
      42)
  in
  check int "slot result" 42 result;
  check int "released after return" 0 (Gate.active_cli_spawns ());
  check
    int
    "Fd_accountant released after return"
    0
    (FA.active_count ~kind:FA.Provider_cli)
;;

let test_nested_slots_stack_to_the_limit () =
  Eio_main.run @@ fun _env ->
  let rec hold depth =
    if depth = 0
    then (
      check int "all slots held" 8 (Gate.active_cli_spawns ());
      check
        int
        "Fd_accountant counts every slot"
        8
        (FA.active_count ~kind:FA.Provider_cli))
    else Gate.with_cli_spawn_slot (fun () -> hold (depth - 1))
  in
  hold Gate.max_concurrent_cli_spawns;
  check int "all slots released" 0 (Gate.active_cli_spawns ())
;;

let test_exception_releases_the_slot () =
  Eio_main.run @@ fun _env ->
  let raised =
    match Gate.with_cli_spawn_slot (fun () -> raise (Failure "callback failure")) with
    | _ -> false
    | exception Failure "callback failure" -> true
  in
  check bool "callback exception propagates" true raised;
  check int "slot released after exception" 0 (Gate.active_cli_spawns ())
;;

let test_lsof_parser_counts_data_lines () =
  let output =
    "COMMAND     PID   USER   FD      TYPE DEVICE SIZE/OFF     NODE NAME\n"
    ^ "agy       73694 dancer  cwd       DIR  253,2      224  2/private/tmp/x\n"
    ^ "agy       73694 dancer  txt       REG  253,2  1048576 99/bin/agy\n"
    ^ "\n"
    ^ "agy       73694 dancer    3u      REG  253,2        0 101/.git-cookie-stale\n"
  in
  check
    int
    "header and blank lines skipped"
    3
    (Gate.For_testing.count_lsof_lines output);
  check int "empty output" 0 (Gate.For_testing.count_lsof_lines "");
  check int "header only" 0 (Gate.For_testing.count_lsof_lines "COMMAND PID\n")
;;

let test_proc_reader_matches_platform () =
  (* /proc exists on Linux CI, not on macOS: the test asserts the reader
     agrees with the platform instead of either outcome. *)
  let pid = Unix.getpid () in
  (match Gate.For_testing.count_proc_fds ~pid with
   | Some count ->
     check bool "/proc self count is positive" true (count > 0);
     check
       bool
       "/proc is really there"
       true
       (Sys.file_exists (Printf.sprintf "/proc/%d/fd" pid))
   | None ->
     check
       bool
       "/proc is really absent"
       false
       (Sys.file_exists (Printf.sprintf "/proc/%d/fd" pid)));
  check
    (option int)
    "non-positive pid is unobservable"
    None
    (Gate.For_testing.count_proc_fds ~pid:0);
  check
    (option int)
    "dead pid is unobservable"
    None
    (Gate.For_testing.count_proc_fds ~pid:424242424)
;;

let test_child_count_of_dead_pid_is_none () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let cwd = Eio.Stdenv.cwd env in
  (* /proc misses and lsof exits nonzero (or is absent): every path agrees. *)
  check
    (option int)
    "dead pid"
    None
    (Gate.child_fd_count ~mgr ~cwd ~pid:424242424);
  check
    (option int)
    "non-positive pid never spawns a probe"
    None
    (Gate.child_fd_count ~mgr ~cwd ~pid:0)
;;

let () =
  run
    "runtime_cli_spawn_gate"
    [ ( "gate"
      , [ test_case "bounds are pinned" `Quick test_bounds_are_pinned
        ; test_case "slot returns and releases" `Quick test_slot_returns_and_releases
        ; test_case
            "nested slots stack to the limit"
            `Quick
            test_nested_slots_stack_to_the_limit
        ; test_case
            "exception releases the slot"
            `Quick
            test_exception_releases_the_slot
        ] )
    ; ( "child-fds"
      , [ test_case
            "lsof parser counts data lines"
            `Quick
            test_lsof_parser_counts_data_lines
        ; test_case
            "proc reader matches platform"
            `Quick
            test_proc_reader_matches_platform
        ; test_case
            "child count of dead pid is none"
            `Quick
            test_child_count_of_dead_pid_is_none
        ] )
    ]
