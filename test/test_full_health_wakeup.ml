open Alcotest

module Runtime = Server_routes_http_runtime

let reset () =
  Runtime.For_testing.reset_full_health_snapshot ();
  ignore (Runtime.For_testing.take_full_health_wakeup_nonblocking ())
;;

let test_non_eio_invalidation_wakes_waiter () =
  Eio_main.run (fun env ->
    reset ();
    let waiting, mark_waiting = Eio.Promise.create () in
    let non_eio = ref false in
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Fiber.both
        (fun () ->
          Eio.Promise.resolve mark_waiting ();
          Runtime.For_testing.take_full_health_wakeup ())
        (fun () ->
          Eio.Promise.await waiting;
          non_eio :=
            Eio.Domain_manager.run_raw (Eio.Stdenv.domain_mgr env) (fun () ->
              let outside_eio =
                match Fs_compat.execution_context () with
                | Non_eio -> true
                | Eio_fiber -> false
              in
              Runtime.invalidate_full_health_snapshot ();
              outside_eio)));
    check bool "invalidation ran outside Eio" true !non_eio;
    let _, _, _, _, _, requested = Runtime.For_testing.full_health_refresh_worker_stats () in
    check bool "invalidation requested a refresh" true requested)
;;

let test_non_eio_wakes_coalesce_without_blocking () =
  Eio_main.run (fun env ->
    reset ();
    let started = Atomic.make 0 and release = Atomic.make false in
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Fiber.both
        (fun () ->
          Eio.Fiber.all
            (List.init 8 (fun _ -> fun () ->
              Eio.Domain_manager.run_raw (Eio.Stdenv.domain_mgr env) (fun () ->
                Atomic.incr started;
                let deadline = Unix.gettimeofday () +. 5.0 in
                while not (Atomic.get release) && Unix.gettimeofday () < deadline do
                  Domain.cpu_relax ()
                done;
                if not (Atomic.get release) then failwith "producer barrier timed out";
                for _ = 1 to 100 do Runtime.invalidate_full_health_snapshot () done))))
        (fun () ->
          while Atomic.get started < 8 do Eio.Fiber.yield () done;
          Atomic.set release true));
    check bool "one wake was retained" true
      (Runtime.For_testing.take_full_health_wakeup_nonblocking ());
    check bool "wakes coalesced into one mailbox slot" false
      (Runtime.For_testing.take_full_health_wakeup_nonblocking ()))
;;

let test_non_eio_invalidation_runs_refresh_worker () =
  Eio_main.run (fun env ->
    reset ();
    let warm, mark_warm = Eio.Promise.create () in
    let refreshed, mark_refreshed = Eio.Promise.create () in
    let producing, mark_producing = Eio.Promise.create () in
    let never, _ = Eio.Promise.create () in
    let results = ref 0 in
    let running = Atomic.make false and stop = Atomic.make false in
    let refreshed_while_running = ref false in
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Fiber.first
        (fun () ->
          Eio.Switch.run (fun sw ->
            let config =
              { (Proactive_refresh.default_config ~label:"test-health-wakeup" ~interval_s:60.0) with
                timeout_s = 5.0
              ; wakeup = Some (Runtime.For_testing.full_health_wakeup_stream ())
              ; wakeup_coalesce_s = 0.05
              }
            in
            Proactive_refresh.start ~sw ~clock:(Eio.Stdenv.clock env)
              ~config ~compute:(fun () -> ()) ~on_result:(fun () ->
                incr results;
                if !results = 1 then Eio.Promise.resolve mark_warm ()
                else if !results = 2 then (
                  refreshed_while_running := Atomic.get running;
                  Eio.Promise.resolve mark_refreshed ()));
            Eio.Promise.await never))
        (fun () ->
          Eio.Promise.await warm;
          Eio.Fiber.both
            (fun () ->
              Eio.Domain_manager.run_raw (Eio.Stdenv.domain_mgr env) (fun () ->
                Atomic.set running true;
                Eio.Promise.resolve mark_producing ();
                let deadline = Unix.gettimeofday () +. 8.0 in
                while not (Atomic.get stop) && Unix.gettimeofday () < deadline do
                  Runtime.invalidate_full_health_snapshot ()
                done;
                Atomic.set running false))
            (fun () ->
              Eio.Promise.await producing;
              Eio.Promise.await refreshed;
              Atomic.set stop true)));
    check bool "refresh ran while the non-Eio producer remained active"
      true !refreshed_while_running)
;;

let () =
  let _ = Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ ->
    prerr_endline "full health wakeup test watchdog expired";
    Unix._exit 124)) in
  ignore (Unix.alarm 30);
  Fun.protect ~finally:(fun () -> ignore (Unix.alarm 0)) (fun () ->
    run "full_health_wakeup"
      [ "invalidation"
      , [ test_case "non-Eio invalidation wakes a waiting reader" `Quick
            test_non_eio_invalidation_wakes_waiter
        ; test_case "concurrent non-Eio wakes coalesce" `Quick
            test_non_eio_wakes_coalesce_without_blocking
        ; test_case "non-Eio invalidation runs refresh worker" `Quick
            test_non_eio_invalidation_runs_refresh_worker
        ]
      ])
