open Alcotest

(** Unit tests for [Domain_pool] — RFC-0059 Phase 2 PR-6.

    Each test runs inside [Eio_main.run] + [Eio.Switch.run] because
    [Domain_pool.create] requires an active switch and a real
    [Eio.Domain_manager.t] from [Eio.Stdenv].  Worker domains are torn
    down when the switch finishes — every test is isolated. *)

module D = Domain_pool

(* ── recommended_domain_count ──────────────────────────── *)

let test_recommended_domain_count_floor () =
  let n = D.recommended_domain_count () in
  check bool "floor of 2 holds even on 1-core systems" true (n >= 2)

let test_recommended_domain_count_reserves_main () =
  (* Sanity: on any host with >= 3 recommended domains we expect
     [recommended_domain_count] to subtract one for the main fiber.
     On a 1- or 2-core system the floor of 2 dominates and this
     property reduces to [n >= 2], which the prior test covers. *)
  let raw = Domain.recommended_domain_count () in
  let ours = D.recommended_domain_count () in
  if raw >= 3 then
    check int "subtract one main domain" (raw - 1) ours
  else
    check bool "floor applies on small hosts" true (ours = 2)

(* ── create ────────────────────────────────────────────── *)

let test_create_default () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw dm in
      check int "default count matches recommended"
        (D.recommended_domain_count ()) (D.domain_count pool)))

let test_create_explicit () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      check int "explicit count honoured" 1 (D.domain_count pool)))

let test_create_zero_rejected () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      check_raises "zero domain_count raises Invalid_argument"
        (Invalid_argument
           "Domain_pool.create: domain_count must be >= 1, got 0")
        (fun () -> ignore (D.create ~sw ~domain_count:0 dm))))

let test_create_negative_rejected () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      check_raises "negative domain_count raises Invalid_argument"
        (Invalid_argument
           "Domain_pool.create: domain_count must be >= 1, got -2")
        (fun () -> ignore (D.create ~sw ~domain_count:(-2) dm))))

(* ── submit ────────────────────────────────────────────── *)

let test_submit_cpu_returns_value () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      let result = D.submit_cpu pool (fun () -> 1 + 2) in
      check int "blocking cpu submit returns value" 3 result))

let test_submit_io_returns_value () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      let result = D.submit_io pool (fun () -> "hello") in
      check string "blocking io submit returns value" "hello" result))

let test_submit_cpu_propagates_exception () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      check_raises "cpu submit re-raises handler exception"
        (Failure "boom")
        (fun () -> D.submit_cpu pool (fun () -> failwith "boom"))))

(* ── async submit ──────────────────────────────────────── *)

let test_submit_cpu_async_resolves () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      let promise = D.submit_cpu_async ~sw pool (fun () -> 42) in
      check int "async cpu promise resolves" 42
        (Eio.Promise.await_exn promise)))

let test_submit_io_async_resolves () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      let promise = D.submit_io_async ~sw pool (fun () -> "ok") in
      check string "async io promise resolves" "ok"
        (Eio.Promise.await_exn promise)))

let test_submit_async_propagates_exception () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      let promise = D.submit_cpu_async ~sw pool (fun () -> failwith "boom") in
      check_raises "async submit propagates exception"
        (Failure "boom")
        (fun () -> ignore (Eio.Promise.await_exn promise))))

(* ── multi-domain dispatch ──────────────────────────────── *)

let test_jobs_run_on_worker_domains () =
  (* The submitting fiber runs on the main Domain.  Jobs submitted to
     a 2-domain pool must execute on a different Domain.  We don't
     assert which worker (Eio chooses), only that it is not the
     main. *)
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:2 dm in
      let main_domain = (Domain.self () :> int) in
      let worker_domain =
        D.submit_cpu pool (fun () -> (Domain.self () :> int))
      in
      check bool "worker job runs off main domain" true
        (worker_domain <> main_domain)))

(* ── escape hatch ──────────────────────────────────────── *)

let test_executor_pool_accessor () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      let raw = D.executor_pool pool in
      let result =
        Eio.Executor_pool.submit_exn raw ~weight:0.5 (fun () -> "via_raw")
      in
      check string "executor_pool exposes underlying pool" "via_raw" result))

(* ── Suite ──────────────────────────────────────────────── *)

let () =
  Alcotest.run "Domain_pool" [
    "recommended", [
      test_case "floor 2" `Quick test_recommended_domain_count_floor;
      test_case "reserves main" `Quick
        test_recommended_domain_count_reserves_main;
    ];
    "create", [
      test_case "default count" `Quick test_create_default;
      test_case "explicit count" `Quick test_create_explicit;
      test_case "zero rejected" `Quick test_create_zero_rejected;
      test_case "negative rejected" `Quick test_create_negative_rejected;
    ];
    "submit_blocking", [
      test_case "cpu returns value" `Quick test_submit_cpu_returns_value;
      test_case "io returns value" `Quick test_submit_io_returns_value;
      test_case "cpu propagates exn" `Quick
        test_submit_cpu_propagates_exception;
    ];
    "submit_async", [
      test_case "cpu promise resolves" `Quick test_submit_cpu_async_resolves;
      test_case "io promise resolves" `Quick test_submit_io_async_resolves;
      test_case "async propagates exn" `Quick
        test_submit_async_propagates_exception;
    ];
    "multi_domain", [
      test_case "jobs run off main domain" `Quick
        test_jobs_run_on_worker_domains;
    ];
    "escape_hatch", [
      test_case "executor_pool accessor" `Quick test_executor_pool_accessor;
    ];
  ]
