(** Request cancellation must reach Dashboard fill and payload preparation. *)

let check_json msg expected actual =
  Alcotest.(check string) msg
    (Yojson.Safe.to_string expected) (Yojson.Safe.to_string actual)

let check_payload_consistent (payload : Dashboard_cache.cached_payload) =
  check_json "bytes decode to the published AST" payload.json
    (Yojson.Safe.from_string payload.raw_json);
  let digest = Digest.to_hex (Digest.string payload.raw_json) in
  Alcotest.(check string) "ETag describes the published bytes"
    ("W/\"" ^ String.sub digest 0 12 ^ "\"") payload.etag

let test_request_timeout_stops_worker ~clock ~sw ~dm ~materialize () =
  let pool = Eio.Executor_pool.create ~sw ~domain_count:1 dm in
  Executor_pool_ref.For_testing.with_pool pool (fun () ->
      Dashboard_cache.invalidate_all ();
      let key = if materialize then "cancel-lazy-worker" else "cancel-fill-worker" in
      let value = `String "worker-value" in
      if materialize then
        ignore (Dashboard_cache.get_or_compute key ~ttl:60. (fun () -> value));
      let release, release_worker = Eio.Promise.create () in
      let finished, finish_worker = Eio.Promise.create () in
      let calls = Atomic.make 0 and cancelled = Atomic.make false in
      let suspend () =
        Atomic.incr calls;
        Fun.protect ~finally:(fun () -> Eio.Promise.resolve finish_worker ())
          (fun () ->
            try Eio.Promise.await release with
            | Eio.Cancel.Cancelled _ as exn ->
                Atomic.set cancelled true;
                raise exn)
      in
      Fun.protect
        ~finally:(fun () ->
          Eio.Promise.resolve release_worker ();
          Executor_pool_ref.submit_or_inline (fun () -> ()))
        (fun () ->
          Dashboard_cache.For_testing.with_payload_prepared_hook
            (fun payload ->
              if materialize && payload.Dashboard_cache.json = value then suspend ())
            (fun () ->
              let result = Dashboard_cache.get_or_compute_payload_with_timeout key
                ~ttl:60. ~clock ~timeout_sec:0.03
                (fun () -> if not materialize then suspend (); value) in
              Alcotest.(check bool) "request returns a timeout envelope" true
                (Dashboard_cache.is_timeout_envelope result.json);
              let stopped =
                try
                  Eio.Time.with_timeout_exn clock 1.0
                    (fun () -> Eio.Promise.await finished);
                  true
                with Eio.Time.Timeout -> false
              in
              Alcotest.(check bool) "request timeout stops its worker" true stopped;
              Alcotest.(check bool) "worker receives cancellation" true
                (Atomic.get cancelled);
              Alcotest.(check int) "worker is not replayed inline" 1
                (Atomic.get calls));
          Alcotest.(check bool) "interrupted worker publishes no payload" true
            (Option.is_none (Dashboard_cache.peek_payload key));
          if materialize then
            check_json "lazy materialization preserves the cached AST" value
              (Option.get (Dashboard_cache.peek key))
          else
            Alcotest.(check bool) "timed out fill is not cached" true
              (Option.is_none (Dashboard_cache.peek key));
          let recovered = Dashboard_cache.get_or_compute_payload_with_timeout key
            ~ttl:60. ~clock ~timeout_sec:2. (fun () -> value) in
          check_json "later request recovers" value recovered.json;
          check_payload_consistent recovered))

let () =
  Eio_main.run (fun env ->
    Eio_guard.enable ();
    Eio.Switch.run (fun sw ->
      Alcotest.run ~and_exit:false "Dashboard cache cancellation"
        [ "offload",
          [ Alcotest.test_case "request timeout stops a fill worker" `Quick
              (test_request_timeout_stops_worker ~clock:(Eio.Stdenv.clock env)
                 ~sw ~dm:(Eio.Stdenv.domain_mgr env) ~materialize:false);
            Alcotest.test_case "request timeout stops a lazy payload worker" `Quick
              (test_request_timeout_stops_worker ~clock:(Eio.Stdenv.clock env)
                 ~sw ~dm:(Eio.Stdenv.domain_mgr env) ~materialize:true) ] ]))
