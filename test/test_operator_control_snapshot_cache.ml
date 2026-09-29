(** Behavioural tests for [Operator_control_snapshot_cache].

    These tests exercise the stale-while-revalidate operator snapshot cache
    through its public API. They are split out from
    [test_operator_control_snapshot.ml] because that file predates the cache
    refactor and its broader snapshot tests need separate runtime setup that is
    outside the scope of the cache change. *)

open Masc

let yojson =
  Alcotest.testable
    (fun fmt v -> Format.fprintf fmt "%s" (Yojson.Safe.to_string v))
    Yojson.Safe.equal
;;

let with_test_eio env sw f =
  Masc_test_deps.init_eio_clock ~sw env;
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
    f
;;

let get_or_compute = Operator_control_snapshot_cache.get_or_compute
let invalidate = Operator_control_snapshot.invalidate_snapshot_cache

let test_fresh_hit () =
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  Eio.Switch.run @@ fun sw ->
  with_test_eio env sw (fun () ->
    invalidate ();
    let compute_count = ref 0 in
    let compute () =
      incr compute_count;
      `Assoc [ ("count", `Int !compute_count) ]
    in
    let v1 = get_or_compute "cache-hit-key" ~ttl:60.0 compute in
    let v2 = get_or_compute "cache-hit-key" ~ttl:60.0 compute in
    Alcotest.(check int) "compute ran exactly once" 1 !compute_count;
    Alcotest.(check yojson) "first result" (`Assoc [ ("count", `Int 1) ]) v1;
    Alcotest.(check yojson) "second result is cached" v1 v2)
;;

let test_singleflight () =
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  Eio.Switch.run @@ fun sw ->
  with_test_eio env sw (fun () ->
    invalidate ();
    Unix.putenv "MASC_OPERATOR_CACHE_BACKGROUND_REVALIDATE" "false";
    let compute_count = ref 0 in
    let compute () =
      Eio.Time.sleep (Eio.Stdenv.clock env) 0.1;
      incr compute_count;
      `Assoc [ ("count", `Int !compute_count) ]
    in
    let p1, r1 = Eio.Promise.create () in
    let p2, r2 = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve r1 (get_or_compute "singleflight-key" ~ttl:60.0 compute));
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve r2 (get_or_compute "singleflight-key" ~ttl:60.0 compute));
    let v1 = Eio.Promise.await p1 in
    let v2 = Eio.Promise.await p2 in
    Alcotest.(check int) "concurrent callers share one compute" 1 !compute_count;
    Alcotest.(check yojson) "both waiters got the same value" v1 v2)
;;

let test_stale_while_revalidate () =
  let previous_context = Eio_context.snapshot_state () in
  (* This suite installs both clock registries together in [with_test_eio],
     so its saved Eio clock is also the Time_compat clock to restore. *)
  let previous_clock = Eio_context.get_clock_opt () in
  (* Protect the backend itself: it raises [Deadlock_detected] outside the
     callback if an inline refresh blocks before returning the stale value. *)
  Fun.protect
    ~finally:(fun () ->
      Eio_context.restore_state previous_context;
      match previous_clock with
      | Some clock -> Time_compat.set_clock clock
      | None -> Time_compat.clear_clock ())
    (fun () ->
      Eio_mock.Backend.run @@ fun () ->
      Eio_guard.enable ();
      let clock = Eio_mock.Clock.make () in
      let compute_count = ref 0 in
      let refreshing, mark_refreshing = Eio.Promise.create () in
      let finish_refresh, release_refresh = Eio.Promise.create () in
      let compute () =
        incr compute_count;
        if !compute_count = 2 then (
          Eio.Promise.resolve mark_refreshing ();
          Eio.Promise.await finish_refresh);
        `Assoc [ ("count", `Int !compute_count) ]
      in
      let ttl = 0.2 in
      let cache_clock = (clock :> float Eio.Time.clock_ty Eio.Resource.t) in
      Time_compat.set_clock cache_clock;
      Eio_context.set_clock cache_clock;
      Eio.Switch.run (fun sw ->
        Eio_context.set_switch sw;
        invalidate ();
        let v1 = get_or_compute "stale-key" ~ttl compute in
        Alcotest.(check int) "first compute" 1 !compute_count;
        Alcotest.(check yojson) "fresh value" (`Assoc [ ("count", `Int 1) ]) v1;
        (* Expire the initial value explicitly. Runner scheduling must not
           also expire the refreshed value before the final lookup. *)
        Eio_mock.Clock.set_time clock 0.25;
        let v2 = get_or_compute "stale-key" ~ttl compute in
        Alcotest.(check yojson) "stale value served immediately"
          (`Assoc [ ("count", `Int 1) ]) v2;
        Eio.Promise.await refreshing;
        let waiting = get_or_compute "stale-key" ~ttl compute in
        Alcotest.(check yojson) "another reader gets stale while refresh is blocked"
          v2 waiting;
        Alcotest.(check int) "stale readers share the background refresh" 2 !compute_count;
        Eio.Promise.resolve release_refresh ());
      (* Leaving the switch joins the background fiber, including its cache
         writeback. Logical time is still 0.25, so the new entry is fresh. *)
      let v3 = get_or_compute "stale-key" ~ttl compute in
      Alcotest.(check int) "background revalidation ran once more" 2 !compute_count;
      Alcotest.(check yojson) "refreshed value" (`Assoc [ ("count", `Int 2) ]) v3)
;;

let test_invalidation () =
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  Eio.Switch.run @@ fun sw ->
  with_test_eio env sw (fun () ->
    invalidate ();
    let compute_count = ref 0 in
    let compute () =
      incr compute_count;
      `Assoc [ ("count", `Int !compute_count) ]
    in
    let v1 = get_or_compute "invalidate-key" ~ttl:60.0 compute in
    Alcotest.(check yojson) "first value" (`Assoc [ ("count", `Int 1) ]) v1;
    invalidate ();
    let v2 = get_or_compute "invalidate-key" ~ttl:60.0 compute in
    Alcotest.(check int) "compute reran after invalidation" 2 !compute_count;
    Alcotest.(check yojson) "second value" (`Assoc [ ("count", `Int 2) ]) v2)
;;

let () =
  Alcotest.run
    "Operator_control_snapshot_cache"
    [ "fresh hit", [ Alcotest.test_case "returns cached value" `Quick test_fresh_hit ]
    ; ( "singleflight"
      , [ Alcotest.test_case "concurrent callers share one compute" `Quick test_singleflight ] )
    ; ( "stale while revalidate"
      , [ Alcotest.test_case "serves stale and refreshes in background" `Quick
            test_stale_while_revalidate ] )
    ; ( "invalidation"
      , [ Alcotest.test_case "clears entry" `Quick test_invalidation ] )
    ]
;;
