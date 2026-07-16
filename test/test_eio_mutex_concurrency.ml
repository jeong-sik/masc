(** Eio.Mutex Migration — Concurrency Correctness Tests

    Verifies that modules migrated from OS Mutex to Eio.Mutex
    behave correctly under concurrent fiber access.

    Modules tested:
    - Rate_limit (token bucket under contention)
    - Circuit_breaker (state transitions under contention)
    - Otel_metric_store (metric increments under contention)
    - Streamable_http.Session (session CRUD under contention)
    - Client_registry_eio (identity resolution under contention)
*)

open Alcotest

module RL = Masc.Rate_limit
module CB = Circuit_breaker
module Metrics = Masc.Otel_metric_store
module SH = Masc.Streamable_http

(** {1 Rate Limit Concurrency} *)

let test_rate_limit_concurrent () =
  let limiter = RL.create ~rate:100.0 ~burst:50 () in
  (* 10 fibers, each checking the same key 100 times *)
  Eio.Fiber.all (List.init 10 (fun _i -> fun () ->
    for _ = 1 to 100 do
      ignore (RL.check limiter ~key:"shared")
    done
  ));
  (* burst=50, 1000 checks consumed tokens; remaining must be <= burst *)
  let rem = RL.remaining limiter ~key:"shared" in
  check bool "remaining <= burst" true (rem <= 50);
  check bool "remaining >= 0" true (rem >= 0)

let test_rate_limit_independent_keys () =
  let limiter = RL.create ~rate:1000.0 ~burst:100 () in
  (* Each fiber uses its own key — no contention on data, but hashtbl mutation *)
  Eio.Fiber.all (List.init 10 (fun i -> fun () ->
    let key = Printf.sprintf "fiber-%d" i in
    for _ = 1 to 50 do
      ignore (RL.check limiter ~key)
    done
  ));
  (* All keys should exist with non-negative remaining *)
  List.iter (fun i ->
    let key = Printf.sprintf "fiber-%d" i in
    let rem = RL.remaining limiter ~key in
    check bool (Printf.sprintf "%s remaining >= 0" key) true (rem >= 0)
  ) (List.init 10 Fun.id)

(** {1 Circuit Breaker Concurrency} *)

let test_failure_observation_concurrent () =
  let cb = CB.create ~failure_threshold:50 ~cooldown:1.0 () in
  (* Concurrent failure recording + observation reads. *)
  Eio.Fiber.all [
    (fun () -> for _ = 1 to 30 do
      CB.record_failure cb ~agent_id:"test-agent" ~reason:"concurrent-test"
    done);
    (fun () -> for _ = 1 to 30 do
      let _s = CB.get_status cb ~agent_id:"test-agent" in ()
    done);
  ];
  let status = CB.get_status cb ~agent_id:"test-agent" in
  check int "all failures observed" 30 status.recent_failures

let test_circuit_breaker_multi_agent () =
  let cb = CB.create () in
  (* Different agents recording failures concurrently *)
  Eio.Fiber.all (List.init 5 (fun i -> fun () ->
    let agent_id = Printf.sprintf "agent-%d" i in
    for _ = 1 to 20 do
      CB.record_failure cb ~agent_id ~reason:"test";
    done
  ));
  let all = CB.list_all_breakers cb in
  check int "5 breakers exist" 5 (List.length all)

(** {1 Otel_metric_store Concurrency} *)

let test_otel_metric_store_concurrent () =
  Eio.Fiber.all (List.init 10 (fun i -> fun () ->
    for _ = 1 to 100 do
      Metrics.inc_counter "test_concurrent_metric"
        ~labels:[("fiber", string_of_int i)] ()
    done
  ));
  check (float 0.0001) "counter total" 1000.0
    (Metrics.metric_total "test_concurrent_metric")

let test_otel_metric_store_gauge_concurrent () =
  Eio.Fiber.all (List.init 5 (fun i -> fun () ->
    for j = 1 to 50 do
      Metrics.set_gauge "test_concurrent_gauge"
        ~labels:[("fiber", string_of_int i)]
        (float_of_int j)
    done
  ));
  check (float 0.0001) "gauge total" 250.0
    (Metrics.metric_total "test_concurrent_gauge")

(** {1 Streamable HTTP Session Concurrency} *)

let test_session_concurrent_create_find () =
  Mirage_crypto_rng_unix.use_default ();
  let created_ids = Array.make 20 "" in
  (* Create 20 sessions concurrently *)
  Eio.Fiber.all (List.init 20 (fun i -> fun () ->
    let session = SH.Session.create ~transport:SH.Streamable_HTTP in
    created_ids.(i) <- session.id
  ));
  (* All sessions should be findable *)
  Array.iter (fun id ->
    check bool "session findable" true (Option.is_some (SH.Session.find id))
  ) created_ids;
  (* Cleanup *)
  Array.iter (fun id -> SH.Session.remove id) created_ids

(** {1 Test Runner} *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "Eio.Mutex Migration Concurrency" [
    "Rate Limit", [
      test_case "concurrent same key" `Quick test_rate_limit_concurrent;
      test_case "concurrent independent keys" `Quick test_rate_limit_independent_keys;
    ];
    "Circuit Breaker", [
      test_case "concurrent failure observation" `Quick
        test_failure_observation_concurrent;
      test_case "concurrent multi-agent" `Quick test_circuit_breaker_multi_agent;
    ];
    "Otel_metric_store", [
      test_case "concurrent counter" `Quick test_otel_metric_store_concurrent;
      test_case "concurrent gauge" `Quick test_otel_metric_store_gauge_concurrent;
    ];
    "Streamable HTTP Session", [
      test_case "concurrent create/find" `Quick test_session_concurrent_create_find;
    ];
  ]
