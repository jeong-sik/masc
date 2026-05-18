(** test_keeper_fd_pressure_fleet — verifies the fleet-baseline rename,
    monotonic CAS for [cooldown_until] / [last_log_at], and single-flight
    semantics for [process_nofile_soft_limit].

    Covers the four T1 changes that landed together:
    - T1-A: [min_nofile_for_fleet] default + [min_nofile_for_24_keepers] alias
    - T1-C: [cas_monotonic_max] never loses larger writers under race
    - T1-D: [nofile_soft_limit_cache] 3-state variant gives one [Resolved]
            answer regardless of concurrent first-touches *)

module FD = Masc_mcp.Keeper_fd_pressure

let test_fleet_default_at_or_above_12288 () =
  (* The rename ships with a 64-keeper-class default: 64 * 96 + 128 + margin.
     Floor of 256 only kicks in if an operator sets a tiny override; the
     out-of-the-box value must comfortably hold a 64-keeper fleet. *)
  let v = FD.min_nofile_for_fleet () in
  Alcotest.(check bool)
    (Printf.sprintf "min_nofile_for_fleet () = %d >= 12288" v)
    true
    (v >= 12288)

let test_legacy_alias_matches_fleet () =
  (* [min_nofile_for_24_keepers] is preserved as a compat alias so external
     readers don't break; it must resolve to the same value. *)
  Alcotest.(check int)
    "min_nofile_for_24_keepers = min_nofile_for_fleet"
    (FD.min_nofile_for_fleet ())
    (FD.min_nofile_for_24_keepers ())

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

let () =
  Alcotest.run
    "keeper_fd_pressure_fleet"
    [ ( "fleet-baseline"
      , [ Alcotest.test_case "default >= 12288" `Quick
            test_fleet_default_at_or_above_12288
        ; Alcotest.test_case "legacy alias matches fleet" `Quick
            test_legacy_alias_matches_fleet
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
        ] )
    ]
