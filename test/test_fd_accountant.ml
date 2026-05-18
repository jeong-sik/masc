(** Unit tests for [Fd_accountant] (RFC-0101).

    Pins down:
    - Per-kind cap enforcement under concurrent fan-in.
    - Slot release on normal return and on exception.
    - Round-trip of [kind_to_string] / [kind_of_string].
    - Delegation: [Docker_spawn_throttle] public API still works and
      produces the same observable behaviour as direct
      [Fd_accountant.with_slot ~kind:Docker_spawn]. *)

open Alcotest
module FA = Masc_mcp.Fd_accountant
module DST = Masc_mcp.Docker_spawn_throttle

let tmpdir prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s_%d_%.0f" prefix (Unix.getpid ())
       (Unix.gettimeofday ()))

let test_kind_round_trip () =
  List.iter
    (fun k ->
      let s = FA.kind_to_string k in
      match FA.kind_of_string s with
      | Some k' when k' = k -> ()
      | _ -> Alcotest.failf "kind round-trip drift for %s" s)
    FA.all_kinds

let test_kind_unknown_rejected () =
  match FA.kind_of_string "carrier_pigeon" with
  | None -> ()
  | Some _ -> Alcotest.fail "unknown kind must return None"

let test_configured_within_bounds () =
  List.iter
    (fun k ->
      let cap = FA.configured_concurrency ~kind:k in
      if cap < 1 || cap > 1024 then
        Alcotest.failf "configured cap out of range for %s: %d"
          (FA.kind_to_string k) cap)
    FA.all_kinds

let test_fd_limit_reuses_keeper_pressure_cache () =
  let expected = 4242 in
  Atomic.set
    Masc_mcp.Keeper_fd_pressure.nofile_soft_limit_cache
    (Masc_mcp.Keeper_fd_pressure.Resolved (Some expected));
  let snapshot = FA.fd_snapshot () in
  check int "fd_limit from Keeper_fd_pressure cache" expected snapshot.fd_limit

let test_with_slot_runs_callback () =
  Eio_main.run @@ fun _env ->
  let result = FA.with_slot ~kind:Docker_spawn (fun () -> 42) in
  check int "callback result returned" 42 result

let test_with_slot_releases_on_exception () =
  Eio_main.run @@ fun _env ->
  let exn = Failure "boom" in
  (try
     FA.with_slot ~kind:Provider_http (fun () -> raise exn) |> ignore
   with Failure _ -> ()) ;
  (* Re-acquire should succeed — release happened via on_release. *)
  let v = FA.with_slot ~kind:Provider_http (fun () -> 7) in
  check int "slot reusable after exception" 7 v

let test_cap_bounds_fan_in () =
  (* Fan-out 4× the configured cap and assert that the
     simultaneous-in-flight count never exceeds the cap. Uses a
     hand-rolled high-water tracker, atomically updated. *)
  Eio_main.run @@ fun env ->
  let kind = FA.Sandbox_exec in
  let cap = FA.configured_concurrency ~kind in
  let fanout = cap * 4 in
  let in_flight = Atomic.make 0 in
  let high_water = Atomic.make 0 in
  let update_high () =
    let cur = Atomic.get in_flight in
    let rec bump () =
      let h = Atomic.get high_water in
      if cur > h then
        if Atomic.compare_and_set high_water h cur then () else bump ()
    in
    bump ()
  in
  Eio.Switch.run @@ fun sw ->
  for _ = 1 to fanout do
    Eio.Fiber.fork ~sw (fun () ->
        FA.with_slot ~kind (fun () ->
            Atomic.incr in_flight ;
            update_high () ;
            Eio.Time.sleep (Eio.Stdenv.clock env) 0.001 ;
            Atomic.decr in_flight))
  done ;
  Eio.Switch.run (fun _ -> ()) ; (* ensure all fibers complete *)
  let hw = Atomic.get high_water in
  if hw > cap then
    Alcotest.failf "peak in-flight %d exceeded cap %d" hw cap

let test_docker_delegation_consistent () =
  (* DST.configured_max () must equal
     Fd_accountant.configured_concurrency ~kind:Docker_spawn — the
     whole point of the delegation. *)
  let via_legacy = DST.configured_max () in
  let via_accountant = FA.configured_concurrency ~kind:Docker_spawn in
  check int "docker delegation cap parity" via_accountant via_legacy

let test_snapshot_shape () =
  let s = FA.fd_snapshot () in
  (* per_kind must include all kinds *)
  check int "snapshot covers all kinds" (List.length FA.all_kinds)
    (List.length s.per_kind) ;
  List.iter
    (fun k ->
      match List.assoc_opt k s.per_kind with
      | Some v when v >= 0 -> ()
      | Some v ->
          Alcotest.failf "negative in_flight for %s: %d"
            (FA.kind_to_string k) v
      | None ->
          Alcotest.failf "missing kind in snapshot: %s"
            (FA.kind_to_string k))
    FA.all_kinds ;
  (* pressure_active matches Keeper_fd_pressure.active *)
  let expected = Masc_mcp.Keeper_fd_pressure.active () in
  check bool "pressure_active mirrors Keeper_fd_pressure" expected
    s.pressure_active

let log_writer_in_flight () =
  let snapshot = FA.fd_snapshot () in
  List.assoc FA.Log_writer snapshot.per_kind

let kind_in_flight kind =
  let snapshot = FA.fd_snapshot () in
  List.assoc kind snapshot.per_kind

let wait_until ~clock ~attempts predicate =
  let rec loop remaining =
    if predicate () then true
    else if remaining <= 0 then false
    else (
      Eio.Time.sleep clock 0.001 ;
      loop (remaining - 1))
  in
  loop attempts

let test_with_slot_reentrant_same_kind () =
  Eio_main.run @@ fun _env ->
  FA.with_slot ~kind:FA.Sandbox_exec (fun () ->
      check int "outer sandbox slot held" 1
        (kind_in_flight FA.Sandbox_exec) ;
      FA.with_slot ~kind:FA.Sandbox_exec (fun () ->
          check int "inner sandbox slot reuses outer slot" 1
            (kind_in_flight FA.Sandbox_exec))) ;
	  check int "sandbox slot released" 0 (kind_in_flight FA.Sandbox_exec)

let test_with_slot_nested_cross_kind_under_fd_pressure () =
  Eio_main.run @@ fun _env ->
  Masc_mcp.Keeper_fd_pressure.reset_for_tests () ;
  Fun.protect
    ~finally:Masc_mcp.Keeper_fd_pressure.reset_for_tests
    (fun () ->
      Masc_mcp.Keeper_fd_pressure.note ~site:"fd_accountant_test"
        ~detail:"too many open files" () ;
      FA.with_slot ~kind:FA.Docker_spawn (fun () ->
          check int "outer docker slot held" 1
            (kind_in_flight FA.Docker_spawn) ;
          FA.with_slot ~kind:FA.Sandbox_exec (fun () ->
              check int "nested sandbox slot held" 1
                (kind_in_flight FA.Sandbox_exec))) ;
      check int "docker slot released" 0 (kind_in_flight FA.Docker_spawn) ;
      check int "sandbox slot released" 0 (kind_in_flight FA.Sandbox_exec))

let test_dated_jsonl_append_uses_log_writer_slot () =
  Eio_main.run @@ fun env ->
  Eio_guard.enable () ;
  let dir = tmpdir "fd_accountant_dated_jsonl_log_writer" in
  Fs_compat.mkdir_p dir ;
  Fs_compat.set_fs (Eio.Stdenv.fs env) ;
  Fun.protect ~finally:Eio_guard.disable (fun () ->
      Dated_jsonl.For_testing.reset_append_guard () ;
      FA.install_dated_jsonl_log_writer_guard () ;
      let store = Dated_jsonl.create ~base_dir:dir () in
      let mutex = Dated_jsonl.For_testing.mutex store in
      let clock = Eio.Stdenv.clock env in
      let () =
        Eio.Switch.run @@ fun sw ->
        Eio.Mutex.use_rw ~protect:true mutex (fun () ->
            Eio.Fiber.fork ~sw (fun () ->
                Dated_jsonl.append store (`Assoc [ ("i", `Int 1) ])) ;
            check bool "append waits while holding log writer slot" true
              (wait_until ~clock ~attempts:100 (fun () ->
                   log_writer_in_flight () > 0)))
      in
      check int "log writer slot released" 0 (log_writer_in_flight ()))

let test_process_eio_run_argv_uses_sandbox_slot () =
  Eio_main.run @@ fun env ->
  Eio_guard.enable () ;
  Fun.protect
    ~finally:(fun () ->
      Process_eio.reset_for_testing () ;
      Eio_guard.disable ())
    (fun () ->
      Process_eio.reset_for_testing () ;
      Process_eio.init
        ~cwd_default:(Eio.Stdenv.fs env)
        ~proc_mgr:(Eio.Stdenv.process_mgr env)
        ~clock:(Eio.Stdenv.clock env) ;
      FA.install_process_eio_sandbox_exec_guard () ;
      let clock = Eio.Stdenv.clock env in
      let () =
        Eio.Switch.run @@ fun sw ->
        Eio.Fiber.fork ~sw (fun () ->
            ignore
              (Process_eio.run_argv_with_status ~timeout_sec:2.0
                 [ "/bin/sleep"; "0.05" ])) ;
        check bool "Process_eio holds sandbox slot while child runs" true
          (wait_until ~clock ~attempts:100 (fun () ->
               kind_in_flight FA.Sandbox_exec > 0))
      in
      check int "Process_eio sandbox slot released" 0
        (kind_in_flight FA.Sandbox_exec))

let test_with_process_uses_sandbox_slot () =
  Eio_main.run @@ fun _env ->
  Eio_guard.enable () ;
  Fun.protect
    ~finally:(fun () ->
      With_process.reset_process_guard_for_testing () ;
      Eio_guard.disable ())
    (fun () ->
      With_process.reset_process_guard_for_testing () ;
      FA.install_with_process_sandbox_exec_guard () ;
      let (observed, lines), status =
        With_process.with_process_args_in "/bin/echo"
          [| "/bin/echo" ; "with-process-slot" |]
          (fun ic ->
            let observed = kind_in_flight FA.Sandbox_exec in
            (observed, With_process.drain_lines ic))
      in
      check int "With_process holds sandbox slot during callback" 1
        observed ;
      check (list string) "With_process stdout" [ "with-process-slot" ]
        lines ;
      (match status with
      | Unix.WEXITED 0 -> ()
      | _ -> Alcotest.fail "expected With_process child to exit 0") ;
      check int "With_process sandbox slot released" 0
        (kind_in_flight FA.Sandbox_exec))

let test_autonomy_exec_run_uses_sandbox_slot () =
  Eio_main.run @@ fun env ->
  Eio_guard.enable () ;
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp_cdal_runtime.Autonomy_exec.reset_run_guard_for_testing () ;
      Eio_guard.disable ())
    (fun () ->
      Masc_mcp_cdal_runtime.Autonomy_exec.reset_run_guard_for_testing () ;
      FA.install_autonomy_exec_sandbox_exec_guard () ;
      let clock = Eio.Stdenv.clock env in
      let () =
        Eio.Switch.run @@ fun sw ->
        Eio.Fiber.fork ~sw (fun () ->
            ignore
              (Masc_mcp_cdal_runtime.Autonomy_exec.run
                 ~sw
                 ~clock
                 ~config:Masc_mcp_cdal_runtime.Autonomy_exec.default_config
                 ~argv:[ "/bin/sleep"; "0.05" ]
                 ~timeout_s:2.0)) ;
        check bool "Autonomy_exec holds sandbox slot while child runs" true
          (wait_until ~clock ~attempts:100 (fun () ->
               kind_in_flight FA.Sandbox_exec > 0))
      in
      check int "Autonomy_exec sandbox slot released" 0
        (kind_in_flight FA.Sandbox_exec))

let test_bg_task_uses_sandbox_lifetime_slot () =
  Eio_main.run @@ fun env ->
  Eio_guard.enable () ;
  Fun.protect
    ~finally:(fun () ->
      Bg_task.reset_lifetime_guard_for_testing () ;
      Eio_guard.disable ())
    (fun () ->
      Bg_task.reset_lifetime_guard_for_testing () ;
      FA.install_bg_task_sandbox_exec_guard () ;
      let tid =
        match
          Bg_task.spawn ~keeper:"fd-accountant-bg-task"
            ~argv:[ "/bin/sleep"; "0.05" ]
            ~cwd:"" ~envp:(Unix.environment ()) ~timeout_sec:0.0 ()
        with
        | Ok tid -> tid
        | Error _ -> Alcotest.fail "Bg_task spawn failed"
      in
      check int "Bg_task holds sandbox slot after spawn" 1
        (kind_in_flight FA.Sandbox_exec) ;
      let clock = Eio.Stdenv.clock env in
      check bool "Bg_task eventually closes" true
        (wait_until ~clock ~attempts:200 (fun () ->
             match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
             | Ok snapshot -> snapshot.closed
             | Error _ -> false)) ;
      check int "Bg_task sandbox slot released on close" 0
        (kind_in_flight FA.Sandbox_exec))

let test_bg_task_lifetime_serializes_under_fd_pressure () =
  Eio_main.run @@ fun env ->
  Eio_guard.enable () ;
  Masc_mcp.Keeper_fd_pressure.reset_for_tests () ;
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_fd_pressure.reset_for_tests () ;
      Bg_task.reset_lifetime_guard_for_testing () ;
      Eio_guard.disable ())
    (fun () ->
      Bg_task.reset_lifetime_guard_for_testing () ;
      FA.install_bg_task_sandbox_exec_guard () ;
      Masc_mcp.Keeper_fd_pressure.note ~site:"fd_accountant_test"
        ~detail:"too many open files" () ;
      let clock = Eio.Stdenv.clock env in
      let first =
        match
          Bg_task.spawn ~keeper:"fd-accountant-pressure-a"
            ~argv:[ "/bin/sleep"; "0.05" ]
            ~cwd:"" ~envp:(Unix.environment ()) ~timeout_sec:0.0 ()
        with
        | Ok tid -> tid
        | Error _ -> Alcotest.fail "first Bg_task spawn failed"
      in
      check int "first Bg_task holds sandbox slot" 1
        (kind_in_flight FA.Sandbox_exec) ;
      let second_started = Atomic.make false in
      Eio.Switch.run @@ fun sw ->
      Eio.Fiber.fork ~sw (fun () ->
          match
            Bg_task.spawn ~keeper:"fd-accountant-pressure-b"
              ~argv:[ "/bin/sleep"; "0.01" ]
              ~cwd:"" ~envp:(Unix.environment ()) ~timeout_sec:0.0 ()
          with
          | Ok tid ->
              Atomic.set second_started true ;
              ignore
                (wait_until ~clock ~attempts:200 (fun () ->
                   match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
                   | Ok snapshot -> snapshot.closed
                   | Error _ -> false))
          | Error _ -> Alcotest.fail "second Bg_task spawn failed") ;
      Eio.Time.sleep clock 0.005 ;
      check bool "second Bg_task waits for pressure slot" false
        (Atomic.get second_started) ;
      check bool "first Bg_task eventually closes" true
        (wait_until ~clock ~attempts:200 (fun () ->
           match Bg_task.read first ~since_stdout:0 ~since_stderr:0 with
           | Ok snapshot -> snapshot.closed
           | Error _ -> false)) ;
      check bool "second Bg_task starts after pressure slot release" true
        (wait_until ~clock ~attempts:200 (fun () -> Atomic.get second_started)) ;
      check bool "Bg_task sandbox slots eventually release" true
        (wait_until ~clock ~attempts:200 (fun () ->
           kind_in_flight FA.Sandbox_exec = 0)))

let test_bg_task_lifetime_releases_after_exit_without_read () =
  Eio_main.run @@ fun env ->
  Eio_guard.enable () ;
  Fun.protect
    ~finally:(fun () ->
      Bg_task.reset_lifetime_guard_for_testing () ;
      Eio_guard.disable ())
    (fun () ->
      Bg_task.reset_lifetime_guard_for_testing () ;
      FA.install_bg_task_sandbox_exec_guard () ;
      let tid =
        match
          Bg_task.spawn ~keeper:"fd-accountant-exit-watch"
            ~argv:[ "/bin/sleep"; "0.01" ]
            ~cwd:"" ~envp:(Unix.environment ()) ~timeout_sec:0.0 ()
        with
        | Ok tid -> tid
        | Error _ -> Alcotest.fail "Bg_task spawn failed"
      in
      check int "Bg_task holds sandbox slot after spawn" 1
        (kind_in_flight FA.Sandbox_exec) ;
      let clock = Eio.Stdenv.clock env in
      check bool "Bg_task sandbox slot releases after process exit" true
        (wait_until ~clock ~attempts:500 (fun () ->
           kind_in_flight FA.Sandbox_exec = 0)) ;
      ignore (Bg_task.read tid ~since_stdout:0 ~since_stderr:0))

let test_bg_task_cancelled_lifetime_acquire_releases_pending_slot () =
  Eio_main.run @@ fun env ->
  let keeper = "fd-accountant-cancelled-acquire" in
  Fun.protect
    ~finally:Bg_task.reset_lifetime_guard_for_testing
    (fun () ->
      Bg_task.set_lifetime_guard
        { Bg_task.acquire =
            (fun () -> raise (Eio.Cancel.Cancelled (Failure "synthetic")))
        } ;
      for _ = 1 to 2 do
        try
          ignore
            (Bg_task.spawn ~keeper ~argv:[ "/bin/sleep"; "0.01" ]
               ~cwd:"" ~envp:(Unix.environment ()) ~timeout_sec:0.0 ())
        with
        | Eio.Cancel.Cancelled _ -> ()
      done ;
      Bg_task.reset_lifetime_guard_for_testing () ;
      let tid =
        match
          Bg_task.spawn ~keeper ~argv:[ "/bin/sleep"; "0.01" ]
            ~cwd:"" ~envp:(Unix.environment ()) ~timeout_sec:0.0 ()
        with
        | Ok tid -> tid
        | Error (Bg_task.Too_many_tasks _) ->
            Alcotest.fail "cancelled lifetime acquire leaked pending slot"
        | Error _ -> Alcotest.fail "Bg_task spawn failed"
      in
      let clock = Eio.Stdenv.clock env in
      check bool "Bg_task closes after cancelled acquire recovery" true
        (wait_until ~clock ~attempts:500 (fun () ->
           match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
           | Ok snapshot -> snapshot.closed
           | Error _ -> false)))

let () =
  Alcotest.run "Fd_accountant"
    [
      ( "kind discrimination",
        [
          test_case "round-trip" `Quick test_kind_round_trip ;
          test_case "unknown rejected" `Quick test_kind_unknown_rejected ;
          test_case "cap within bounds" `Quick
            test_configured_within_bounds ;
          test_case "fd limit reuses Keeper_fd_pressure cache" `Quick
            test_fd_limit_reuses_keeper_pressure_cache ;
        ] ) ;
      ( "slot semantics",
        [
          test_case "callback result returned" `Quick
            test_with_slot_runs_callback ;
          test_case "release on exception" `Quick
            test_with_slot_releases_on_exception ;
          test_case "cap bounds fan-in" `Quick test_cap_bounds_fan_in ;
          test_case "reentrant same-kind slot" `Quick
            test_with_slot_reentrant_same_kind ;
          test_case "nested cross-kind slot under FD pressure" `Quick
            test_with_slot_nested_cross_kind_under_fd_pressure ;
        ] ) ;
      ( "delegation",
        [
          test_case "docker delegation cap parity" `Quick
            test_docker_delegation_consistent ;
        ] ) ;
      ( "snapshot",
        [ test_case "shape" `Quick test_snapshot_shape ] ) ;
      ( "log writer",
        [
          test_case "Dated_jsonl append uses slot" `Quick
            test_dated_jsonl_append_uses_log_writer_slot ;
        ] ) ;
      ( "process",
        [
          test_case "Process_eio run_argv uses sandbox slot" `Quick
            test_process_eio_run_argv_uses_sandbox_slot ;
          test_case "With_process uses sandbox slot" `Quick
            test_with_process_uses_sandbox_slot ;
          test_case "Autonomy_exec run uses sandbox slot" `Quick
            test_autonomy_exec_run_uses_sandbox_slot ;
          test_case "Bg_task uses sandbox lifetime slot" `Quick
            test_bg_task_uses_sandbox_lifetime_slot ;
          test_case "Bg_task lifetime serializes under FD pressure" `Quick
            test_bg_task_lifetime_serializes_under_fd_pressure ;
          test_case "Bg_task lifetime releases after process exit" `Quick
            test_bg_task_lifetime_releases_after_exit_without_read ;
          test_case "Bg_task cancelled lifetime acquire releases pending slot" `Quick
            test_bg_task_cancelled_lifetime_acquire_releases_pending_slot ;
        ] ) ;
    ]
