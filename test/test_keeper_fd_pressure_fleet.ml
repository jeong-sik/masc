(** test_keeper_fd_pressure_fleet — verifies the fleet-baseline rename,
    monotonic CAS for [cooldown_until] / [last_log_at], and single-flight
    semantics for [process_nofile_soft_limit].

    Covers the fleet FD pressure behavior:
    - [min_nofile_for_fleet] default
    - T1-C: [cas_monotonic_max] never loses larger writers under race
    - T1-D: [nofile_soft_limit_cache] 3-state variant gives one [Resolved]
            answer regardless of concurrent first-touches *)

module FD = Keeper_fd_pressure

let test_fleet_default_at_or_above_12288 () =
  (* The rename ships with a 64-keeper-class default: 64 * 96 + 128 + margin.
     Floor of 256 only kicks in if an operator sets a tiny override; the
     out-of-the-box value must comfortably hold a 64-keeper fleet. *)
  let v = FD.min_nofile_for_fleet () in
  Alcotest.(check bool)
    (Printf.sprintf "min_nofile_for_fleet () = %d >= 12288" v)
    true
    (v >= 12288)

let test_low_nofile_blocks_synthetic_24_keeper_start () =
  FD.reset_for_tests ();
  let json =
    FD.runtime_state_json
      ~soft_limit:(Some 256)
      ~open_fds:(Some 16)
      ~system_fds:(Some { open_files = 1024; max_files = 1_000_000; max_files_per_process = None })
      ~active_keepers:0
      ~starting_keepers:0
      ~requested_keepers:24
      ()
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "status" "blocked" (json |> member "status" |> to_string);
  Alcotest.(check string)
    "reason"
    "projected_fd_budget_exhausted"
    (json |> member "reason" |> to_string);
  Alcotest.(check int)
    "projected 24-keeper start"
    24
    (json |> member "projected_starting_keepers" |> to_int);
  Alcotest.(check bool)
    "operator action required"
    true
    (json |> member "operator_action_required" |> to_bool)

let test_cas_monotonic_max_advances () =
  let a = Atomic.make 0.0 in
  let advanced = FD.cas_monotonic_max ~atom:a 10.0 in
  Alcotest.(check bool) "first write advances" true advanced;
  Alcotest.(check (float 0.001)) "atom is 10.0" 10.0 (Atomic.get a);
  let advanced2 = FD.cas_monotonic_max ~atom:a 5.0 in
  Alcotest.(check bool) "smaller write does NOT advance" false advanced2;
  Alcotest.(check (float 0.001)) "atom still 10.0" 10.0 (Atomic.get a);
  let advanced3 = FD.cas_monotonic_max ~atom:a 20.0 in
  Alcotest.(check bool) "larger write advances" true advanced3;
  Alcotest.(check (float 0.001)) "atom is 20.0" 20.0 (Atomic.get a)

let test_cas_monotonic_max_never_loses_larger_writer () =
  (* Fan-in 64 writers with monotonically increasing values. Final atomic
     value MUST equal the largest write. Pre-CAS implementation could lose
     a larger value to a stale smaller one between read and set. *)
  Eio_main.run @@ fun _env ->
  let a = Atomic.make 0.0 in
  let fan = 64 in
  Eio.Switch.run @@ fun sw ->
  let promises =
    List.init fan (fun i ->
      Eio.Fiber.fork_promise ~sw (fun () ->
        let v = float_of_int (i + 1) in
        (* Yield so the OS / Eio scheduler interleaves CAS attempts. *)
        Eio.Fiber.yield ();
        ignore (FD.cas_monotonic_max ~atom:a v)))
  in
  List.iter Eio.Promise.await_exn promises;
  Alcotest.(check (float 0.001))
    "final value is the maximum"
    (float_of_int fan)
    (Atomic.get a)

let test_note_under_concurrency_keeps_breaker_active () =
  (* After 64 concurrent [note] calls the breaker MUST be tripped and the
     remaining cooldown MUST be at least [cooldown_sec () - epsilon]. The
     pre-CAS implementation could clobber a larger [until_ts] with a smaller
     one, allowing the breaker to clear prematurely. *)
  FD.reset_for_tests ();
  Eio_main.run @@ fun _env ->
  let fan = 64 in
  Eio.Switch.run @@ fun sw ->
  let promises =
    List.init fan (fun i ->
      Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Fiber.yield ();
        FD.note ~site:(Printf.sprintf "test-%d" i) ~detail:"emfile probe" ()))
  in
  List.iter Eio.Promise.await_exn promises;
  Alcotest.(check bool) "breaker active after concurrent note" true (FD.active ());
  let remaining = FD.remaining_sec () in
  let floor = FD.cooldown_sec () -. 1.0 in
  Alcotest.(check bool)
    (Printf.sprintf "remaining %.3f >= floor %.3f" remaining floor)
    true
    (remaining >= floor);
  FD.reset_for_tests ()

let test_nofile_cache_single_flight_resolves_once () =
  (* Reset cache, fire 32 concurrent reads, every fiber must observe the
     same answer (either [Some n] or [None] depending on host). The cache
     ends in [Resolved], not [In_flight]. *)
  FD.reset_for_tests ();
  Eio_main.run @@ fun _env ->
  let fan = 32 in
  let results = Atomic.make [] in
  Eio.Switch.run @@ fun sw ->
  let promises =
    List.init fan (fun _ ->
      Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Fiber.yield ();
        let r = FD.process_nofile_soft_limit () in
        let rec push () =
          let cur = Atomic.get results in
          if not (Atomic.compare_and_set results cur (r :: cur)) then push ()
        in
        push ()))
  in
  List.iter Eio.Promise.await_exn promises;
  let collected = Atomic.get results in
  Alcotest.(check int) "all fibers returned a result" fan (List.length collected);
  (match collected with
   | [] -> Alcotest.fail "no results collected"
   | head :: rest ->
     List.iter
       (fun r ->
         Alcotest.(check bool)
           "all results identical (cache coherent)"
           true
           (r = head))
       rest);
  (match Atomic.get FD.nofile_soft_limit_cache with
   | FD.Resolved _ -> ()
   | FD.Uninitialized | FD.In_flight ->
     Alcotest.fail "cache must be Resolved after concurrent first-touch");
  FD.reset_for_tests ()

let test_nofile_probe_resolves_on_unix () =
  if Sys.os_type = "Unix"
  then (
    FD.reset_for_tests ();
    match FD.process_nofile_soft_limit () with
    | Some limit when limit > 0 -> ()
    | Some limit -> Alcotest.failf "expected positive native nofile limit, got %d" limit
    | None -> Alcotest.fail "expected native nofile probe to resolve on Unix")

(* RFC-0137 — external engage from host FD pressure (PR-1). *)

let test_engage_external_crit_advances_cooldown () =
  FD.reset_for_tests ();
  Alcotest.(check bool) "inactive before engage" false (FD.active ());
  let ts = Time_compat.now () in
  FD.engage_external ~reason:"sysmon fd=75%" ~level:FD.External_crit ~ts ();
  Alcotest.(check bool) "active after CRIT engage" true (FD.active ());
  let remaining = FD.remaining_sec () in
  (* default CRIT cooldown = 1800s; allow slack for slow CI scheduling. *)
  Alcotest.(check bool)
    (Printf.sprintf "remaining %.0fs ≈ 1800 (within [1700, 1801])" remaining)
    true
    (remaining >= 1700.0 && remaining <= 1801.0);
  FD.reset_for_tests ()

let test_engage_external_stale_ts_is_noop () =
  FD.reset_for_tests ();
  let now = Time_compat.now () in
  FD.engage_external ~reason:"current WARN" ~level:FD.External_warn ~ts:now ();
  let after_first = FD.remaining_sec () in
  (* Engage with a [ts] 120s in the past — produces a smaller [until_ts]
     than the existing cooldown, so [cas_monotonic_max] must reject it.
     No separate last_external_ts atomic exists by design — the monotonic
     CAS on [cooldown_until] is the only ordering primitive. *)
  FD.engage_external
    ~reason:"stale WARN — should be no-op"
    ~level:FD.External_warn
    ~ts:(now -. 120.0)
    ();
  let after_stale = FD.remaining_sec () in
  Alcotest.(check bool)
    (Printf.sprintf
       "stale ts did not shorten cooldown (before=%.0f after=%.0f)"
       after_first
       after_stale)
    true
    (after_stale >= after_first -. 1.0);
  FD.reset_for_tests ()

let test_engage_external_crit_extends_warn () =
  FD.reset_for_tests ();
  let ts = Time_compat.now () in
  FD.engage_external ~reason:"WARN first" ~level:FD.External_warn ~ts ();
  let after_warn = FD.remaining_sec () in
  FD.engage_external ~reason:"CRIT escalates" ~level:FD.External_crit ~ts ();
  let after_crit = FD.remaining_sec () in
  Alcotest.(check bool)
    (Printf.sprintf "CRIT %.0fs extends WARN %.0fs" after_crit after_warn)
    true
    (after_crit > after_warn);
  FD.reset_for_tests ()

(* F4 — system FD probe offloaded to a systhread.

   [system_fd_snapshot] (reached via [admit_turn] with no [~system_fds]) runs the
   darwin [sysctl] subprocess, which does a blocking [input_line] drain. The fix
   offloads that detect via [Eio_guard.run_in_systhread] so the blocking read does
   not freeze the owning Eio domain's event-loop thread, and drops the
   [Stdlib.Mutex] that previously wrapped the detect (would be held across the
   offload yield).

   Test 1 is darwin-gated on the same predicate production uses
   ([SystemVersion.plist]) because the freeze is darwin-only: the linux path uses a
   non-spawning [read_first_line] and never reaches the subprocess guard. *)

let darwin_host () =
  Sys.file_exists "/System/Library/CoreServices/SystemVersion.plist"

(* A [With_process] guard whose [run] blocks the calling thread for [delay]
   seconds before delegating. With the fix, the whole detect (guard + subprocess)
   runs on a systhread, so this blocks the systhread, not the event loop. *)
let blocking_process_guard ~delay : With_process.process_guard =
  { run =
      (fun f ->
        Unix.sleepf delay;
        f ())
  }

let test_probe_offload_keeps_domain_alive () =
  if not (darwin_host ())
  then
    (* Linux short-circuits before the subprocess guard; freeze is darwin-only. *)
    ()
  else (
    let blocking_delay = 1.5 in
    Eio_main.run (fun _env ->
      Eio_guard.enable ();
      Fun.protect
        ~finally:(fun () ->
          With_process.reset_process_guard_for_testing ();
          FD.reset_for_tests ();
          Eio_guard.disable ())
        (fun () ->
          FD.reset_for_tests ();
          With_process.set_process_guard (blocking_process_guard ~delay:blocking_delay);
          let sentinel = Atomic.make 0 in
          let stop = Atomic.make false in
          Eio.Fiber.both
            (fun () ->
              (* Triggers the offloaded probe (no [~system_fds] supplied). With
                 the offload, this fiber suspends on the systhread and yields the
                 domain; without it, the domain is frozen for [blocking_delay]. *)
              let _ : bool = FD.admit_turn ~active_keepers:1 () in
              Atomic.set stop true)
            (fun () ->
              while not (Atomic.get stop) do
                Atomic.incr sentinel;
                Eio.Fiber.yield ()
              done);
          (* With the fix the sentinel spins freely while the probe blocks on the
             systhread, so it advances well past a handful of iterations. With the
             old (event-loop-thread) blocking probe it would be ~0. *)
          let observed = Atomic.get sentinel in
          Alcotest.(check bool)
            (Printf.sprintf
               "sentinel advanced during blocked probe (observed=%d > 10)"
               observed)
            true
            (observed > 10))))

let test_concurrent_snapshot_no_relock () =
  (* Portable: after the mutex drop there is nothing to relock, so N concurrent
     probes must complete without raising and each return a bool decision. With
     the old [Stdlib.Mutex] held across a yielding guard this was the relock /
     [Sys_error] hazard. *)
  Eio_main.run (fun _env ->
    Eio_guard.enable ();
    Fun.protect
      ~finally:(fun () ->
        FD.reset_for_tests ();
        Eio_guard.disable ())
      (fun () ->
        FD.reset_for_tests ();
        let fan = 16 in
        Eio.Switch.run (fun sw ->
          let promises =
            List.init fan (fun _ ->
              Eio.Fiber.fork_promise ~sw (fun () ->
                Eio.Fiber.yield ();
                FD.admit_turn ~active_keepers:1 ()))
          in
          let results = List.map Eio.Promise.await_exn promises in
          Alcotest.(check int)
            "all concurrent probes returned a decision"
            fan
            (List.length results))))

let () =
  Alcotest.run
    "keeper_fd_pressure_fleet"
    [ ( "fleet-baseline"
      , [ Alcotest.test_case "default >= 12288" `Quick
            test_fleet_default_at_or_above_12288
        ; Alcotest.test_case "nofile=256 blocks synthetic 24-keeper start" `Quick
            test_low_nofile_blocks_synthetic_24_keeper_start
        ] )
    ; ( "cas-monotonic"
      , [ Alcotest.test_case "advances and rejects smaller" `Quick
            test_cas_monotonic_max_advances
        ; Alcotest.test_case "fan-in 64 → max wins" `Quick
            test_cas_monotonic_max_never_loses_larger_writer
        ; Alcotest.test_case "note() keeps breaker active under fan-in" `Quick
            test_note_under_concurrency_keeps_breaker_active
        ] )
    ; ( "nofile-single-flight"
      , [ Alcotest.test_case "concurrent first-touch returns one answer" `Quick
            test_nofile_cache_single_flight_resolves_once
        ; Alcotest.test_case "nofile probe resolves on Unix" `Quick
            test_nofile_probe_resolves_on_unix
        ] )
    ; ( "external-engage"
      , [ Alcotest.test_case "CRIT advances cooldown to ~1800s" `Quick
            test_engage_external_crit_advances_cooldown
        ; Alcotest.test_case "stale ts is no-op (monotonic rejection)" `Quick
            test_engage_external_stale_ts_is_noop
        ; Alcotest.test_case "CRIT extends WARN cooldown" `Quick
            test_engage_external_crit_extends_warn
        ] )
    ; ( "system-fd-probe-offload"
      , [ Alcotest.test_case "blocked probe does not freeze the domain (darwin)" `Quick
            test_probe_offload_keeps_domain_alive
        ; Alcotest.test_case "concurrent probes do not relock after mutex drop" `Quick
            test_concurrent_snapshot_no_relock
        ] )
    ]
