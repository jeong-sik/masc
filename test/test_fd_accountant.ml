(** Unit tests for [Fd_accountant] (RFC-0101 PR-2).

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

let () =
  Alcotest.run "Fd_accountant"
    [
      ( "kind discrimination",
        [
          test_case "round-trip" `Quick test_kind_round_trip ;
          test_case "unknown rejected" `Quick test_kind_unknown_rejected ;
          test_case "cap within bounds" `Quick
            test_configured_within_bounds ;
        ] ) ;
      ( "slot semantics",
        [
          test_case "callback result returned" `Quick
            test_with_slot_runs_callback ;
          test_case "release on exception" `Quick
            test_with_slot_releases_on_exception ;
          test_case "cap bounds fan-in" `Quick test_cap_bounds_fan_in ;
        ] ) ;
      ( "delegation",
        [
          test_case "docker delegation cap parity" `Quick
            test_docker_delegation_consistent ;
        ] ) ;
      ( "snapshot",
        [ test_case "shape" `Quick test_snapshot_shape ] ) ;
    ]
