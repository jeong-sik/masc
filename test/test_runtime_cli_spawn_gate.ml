(** Admission-gate contract tests for [Runtime_cli_spawn_gate]. *)

open Alcotest
open Masc

module Gate = Runtime_cli_spawn_gate
module FA = Fd_accountant

exception Cancel_waiter

let test_bounds_are_pinned () =
  (* Derivations live in the .mli; pin the numbers so a drift lands in
     review, not silently. *)
  check int "max concurrent CLI spawns" 8 Gate.max_concurrent_cli_spawns;
  check int "child fd ceiling" 16000 Gate.child_fd_ceiling;
  check (float 0.001) "max slot wait" 120.0 Gate.max_slot_wait_s;
  check (float 0.001) "probe timeout" 5.0 Gate.child_fd_probe_timeout_s
;;

let test_slot_returns_and_releases () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let result =
    Gate.with_cli_spawn_slot ~clock (fun () ->
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
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let rec hold depth =
    if depth = 0
    then (
      check int "all slots held" 8 (Gate.active_cli_spawns ());
      check
        int
        "Fd_accountant counts every slot"
        8
        (FA.active_count ~kind:FA.Provider_cli))
    else Gate.with_cli_spawn_slot ~clock (fun () -> hold (depth - 1))
  in
  hold Gate.max_concurrent_cli_spawns;
  check int "all slots released" 0 (Gate.active_cli_spawns ())
;;

let test_exception_releases_the_slot () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let raised =
    match
      Gate.with_cli_spawn_slot ~clock (fun () -> raise (Failure "callback failure"))
    with
    | _ -> false
    | exception Failure detail when detail = "callback failure" -> true
  in
  check bool "callback exception propagates" true raised;
  check int "slot released after exception" 0 (Gate.active_cli_spawns ())
;;

let test_ninth_waits_then_acquires_on_release () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let rec hold depth =
    if depth = 0
    then (
      let waiter =
        Eio.Fiber.fork_promise ~sw (fun () ->
          Gate.with_cli_spawn_slot ~clock ~wait_timeout_s:30.0 (fun () -> `Acquired))
      in
      (* The waiter needs a scheduling beat to reach the semaphore; 0.2s
         against its 30s budget cannot flake the other way. *)
      Eio.Time.sleep clock 0.2;
      check int "one waiter visible" 1 (Gate.waiting_cli_spawns ());
      check
        bool
        "oldest wait visible"
        true
        (Option.is_some (Gate.oldest_cli_spawn_wait_s ()));
      waiter)
    else Gate.with_cli_spawn_slot ~clock (fun () -> hold (depth - 1))
  in
  let waiter = hold Gate.max_concurrent_cli_spawns in
  check
    bool
    "waiter acquires after release"
    true
    (Eio.Promise.await_exn waiter = `Acquired);
  check int "no waiters left" 0 (Gate.waiting_cli_spawns ());
  check int "no slots left" 0 (Gate.active_cli_spawns ())
;;

let test_wait_budget_refuses () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let rec hold depth =
    if depth = 0
    then (
      match
        Gate.with_cli_spawn_slot ~clock ~wait_timeout_s:0.05 (fun () -> `Acquired)
      with
      | `Acquired -> fail "9th slot acquired despite a full gate"
      | exception Gate.Slot_timeout { waited_s; limit_s } ->
        check (float 0.001) "limit echoed" 0.05 limit_s;
        check
          bool
          "waited about the budget"
          true
          (waited_s >= 0.04 && waited_s < 5.0))
    else Gate.with_cli_spawn_slot ~clock (fun () -> hold (depth - 1))
  in
  hold Gate.max_concurrent_cli_spawns;
  check int "no waiters left" 0 (Gate.waiting_cli_spawns ());
  check int "no slots left" 0 (Gate.active_cli_spawns ())
;;

let test_cancelled_waiter_holds_no_slot () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  (* Outer switch holds the test fiber and the 8 slots; only the waiter's
     inner switch fails, so the assertions after it still run. *)
  Eio.Switch.run @@ fun _sw ->
  let rec hold depth =
    if depth = 0
    then (
      (match
         Eio.Switch.run (fun waiter_sw ->
           let waiter =
             Eio.Fiber.fork_promise ~sw:waiter_sw (fun () ->
               Gate.with_cli_spawn_slot ~clock ~wait_timeout_s:30.0 (fun () ->
                 `Acquired))
           in
           Eio.Time.sleep clock 0.2;
           check int "waiter queued" 1 (Gate.waiting_cli_spawns ());
           Eio.Switch.fail waiter_sw Cancel_waiter;
           (* Awaiting synchronizes with the waiter's death: no race on
              the gauges below. *)
           (match Eio.Promise.await waiter with
            | Ok `Acquired -> fail "cancelled waiter acquired a slot"
            | Error (Eio.Cancel.Cancelled _) -> ()
            | Error exn ->
              fail ("unexpected waiter error: " ^ Printexc.to_string exn)))
       with
       | () -> fail "switch failure did not surface"
       | exception Cancel_waiter -> ());
      check int "waiter gone" 0 (Gate.waiting_cli_spawns ());
      check int "no slot leaked" 0 (Gate.active_cli_spawns () - 8))
    else Gate.with_cli_spawn_slot ~clock (fun () -> hold (depth - 1))
  in
  hold Gate.max_concurrent_cli_spawns;
  check int "all released" 0 (Gate.active_cli_spawns ())
;;

let test_lsof_parser_counts_numeric_fds () =
  let output =
    "COMMAND     PID   USER   FD      TYPE DEVICE SIZE/OFF     NODE NAME\n"
    ^ "agy       73694 dancer  cwd       DIR  253,2      224  2/private/tmp/x\n"
    ^ "agy       73694 dancer  txt       REG  253,2  1048576 99/bin/agy\n"
    ^ "agy       73694 dancer  mem       REG  253,2  1048576 100/lib/libc.dylib\n"
    ^ "\n"
    ^ "agy       73694 dancer    3u      REG  253,2        0 101/file with spaces.txt\n"
    ^ "agy       73694 dancer   12r      REG  253,2      224 102/other\n"
    ^ "short line\n"
  in
  check
    int
    "only numeric FD rows"
    2
    (Gate.For_testing.count_lsof_lines output);
  check int "empty output" 0 (Gate.For_testing.count_lsof_lines "");
  check int "header only" 0 (Gate.For_testing.count_lsof_lines "COMMAND PID\n")
;;

let test_proc_reader_matches_platform () =
  (* /proc exists on Linux CI, not on macOS: the test asserts the reader
     agrees with the platform instead of either outcome. *)
  let pid = Unix.getpid () in
  let self_dir = Printf.sprintf "/proc/%d/fd" pid in
  (match Gate.For_testing.count_proc_fds ~pid with
   | Gate.Fd_count count ->
     check bool "/proc self count is positive" true (count > 0);
     check bool "/proc is really there" true (Sys.file_exists self_dir)
   | Gate.Fds_pressured ->
     check bool "/proc is really there" true (Sys.file_exists self_dir)
   | Gate.Fds_unobservable ->
     check bool "/proc is really absent" false (Sys.file_exists self_dir));
  check
    bool
    "non-positive pid is unobservable"
    true
    (Gate.For_testing.count_proc_fds ~pid:0 = Gate.Fds_unobservable);
  check
    bool
    "dead pid is unobservable"
    true
    (Gate.For_testing.count_proc_fds ~pid:424242424 = Gate.Fds_unobservable)
;;

let test_pressure_classifier () =
  let open Gate.For_testing in
  check bool "EMFILE" true (error_signals_pressure Unix.EMFILE);
  check bool "ENFILE" true (error_signals_pressure Unix.ENFILE);
  check bool "ENOENT" false (error_signals_pressure Unix.ENOENT);
  check bool "EACCES" false (error_signals_pressure Unix.EACCES);
  check bool "EINTR" false (error_signals_pressure Unix.EINTR);
  check bool "EINVAL" false (error_signals_pressure Unix.EINVAL)
;;

let test_sample_of_dead_pid_is_unobservable () =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let cwd = Eio.Stdenv.cwd env in
  (* /proc misses and lsof exits nonzero (or is absent): every path agrees. *)
  check
    bool
    "dead pid"
    true
    (Gate.sample_child_fds ~mgr ~cwd ~pid:424242424 = Gate.Fds_unobservable);
  check
    bool
    "non-positive pid never spawns a probe"
    true
    (Gate.sample_child_fds ~mgr ~cwd ~pid:0 = Gate.Fds_unobservable)
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
        ; test_case
            "ninth waits then acquires on release"
            `Quick
            test_ninth_waits_then_acquires_on_release
        ; test_case "wait budget refuses" `Quick test_wait_budget_refuses
        ; test_case
            "cancelled waiter holds no slot"
            `Quick
            test_cancelled_waiter_holds_no_slot
        ] )
    ; ( "child-fds"
      , [ test_case
            "lsof parser counts numeric fds"
            `Quick
            test_lsof_parser_counts_numeric_fds
        ; test_case
            "proc reader matches platform"
            `Quick
            test_proc_reader_matches_platform
        ; test_case "pressure classifier" `Quick test_pressure_classifier
        ; test_case
            "sample of dead pid is unobservable"
            `Quick
            test_sample_of_dead_pid_is_unobservable
        ] )
    ]
