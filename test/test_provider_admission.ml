(** Tests for per-endpoint admission of concurrent provider requests.

    Each test uses a distinct base_url so schedulers registered by one test
    never leak into another — the admission registry is process-global by
    design and exposes no reset. *)

open Alcotest
open Llm_provider

let contains_substring ~sub text =
  let sub_len = String.length sub in
  let text_len = String.length text in
  let rec loop index =
    if index + sub_len > text_len
    then false
    else if String.sub text index sub_len = sub
    then true
    else loop (index + 1)
  in
  sub_len = 0 || loop 0
;;

let make_config
      ?(base_url = "http://admission.test:1")
      ?(api_key = "test-key")
      ?max_concurrent_requests
      ()
  =
  Provider_config.make
    ~kind:Provider_config.OpenAI_compat
    ~model_id:"admission-model"
    ~base_url
    ~request_path:"/v1/chat/completions"
    ~api_key
    ?max_concurrent_requests
    ()
;;

let test_no_declaration_runs_directly () =
  let config = make_config ~base_url:"http://undeclared.test:1" () in
  let hits = ref 0 in
  let out =
    Provider_admission.with_admission ~config (fun () ->
      incr hits;
      42)
  in
  check int "returns f's result" 42 out;
  check int "f ran exactly once" 1 !hits;
  check
    bool
    "no scheduler registered without a declaration"
    true
    (Option.is_none (Provider_admission.snapshot_for ~config))
;;

let record_max_seen ~in_flight ~max_seen =
  let now = Atomic.fetch_and_add in_flight 1 + 1 in
  let rec record () =
    let seen = Atomic.get max_seen in
    if now > seen && not (Atomic.compare_and_set max_seen seen now) then record ()
  in
  record ()
;;

let test_bounded_concurrency () =
  Eio_main.run
  @@ fun _env ->
  let config =
    make_config ~base_url:"http://bounded.test:1" ~max_concurrent_requests:2 ()
  in
  let in_flight = Atomic.make 0 in
  let max_seen = Atomic.make 0 in
  let job () =
    Provider_admission.with_admission ~config (fun () ->
      record_max_seen ~in_flight ~max_seen;
      (* Yield while holding the permit so competing fibers get their chance
         to over-admit if the bound were broken. *)
      Eio.Fiber.yield ();
      Eio.Fiber.yield ();
      Atomic.decr in_flight)
  in
  Eio.Fiber.all (List.init 8 (fun _ -> job));
  check int "every dispatch completed" 0 (Atomic.get in_flight);
  check bool "declared bound was contended" true (Atomic.get max_seen >= 2);
  check bool "declared bound was never exceeded" true (Atomic.get max_seen <= 2);
  match Provider_admission.snapshot_for ~config with
  | None -> fail "scheduler must be registered after admitted dispatches"
  | Some snap ->
    check int "all permits returned" 0 snap.Slot_scheduler.active;
    check int "no waiters left behind" 0 snap.Slot_scheduler.queue_length
;;

let test_identity_separates_api_keys () =
  Eio_main.run
  @@ fun _env ->
  let base_url = "http://identity.test:1" in
  let a = make_config ~base_url ~api_key:"key-a" ~max_concurrent_requests:1 () in
  let b = make_config ~base_url ~api_key:"key-b" ~max_concurrent_requests:1 () in
  let a_started, resolve_a_started = Eio.Promise.create () in
  let release_a, resolve_release_a = Eio.Promise.create () in
  Eio.Fiber.both
    (fun () ->
       Provider_admission.with_admission ~config:a (fun () ->
         Eio.Promise.resolve resolve_a_started ();
         Eio.Promise.await release_a))
    (fun () ->
       Eio.Promise.await a_started;
       (* If both keys shared one max=1 scheduler this would deadlock: a's
          permit is still held and nothing releases it until b completes. *)
       Provider_admission.with_admission ~config:b (fun () -> ());
       Eio.Promise.resolve resolve_release_a ())
;;

let test_conflicting_declaration_first_wins () =
  Eio_main.run
  @@ fun _env ->
  let base_url = "http://conflict.test:1" in
  let first = make_config ~base_url ~max_concurrent_requests:1 () in
  let second = make_config ~base_url ~max_concurrent_requests:5 () in
  Provider_admission.with_admission ~config:first (fun () -> ());
  Provider_admission.with_admission ~config:second (fun () -> ());
  match Provider_admission.snapshot_for ~config:second with
  | None -> fail "scheduler must exist after first admitted dispatch"
  | Some snap ->
    check int "first declaration stays authoritative" 1 snap.Slot_scheduler.max_slots
;;

(* oas#2641: the conflict warning names the endpoint, and a custom base_url can
   carry userinfo or a `?token=`/`?password=` query credential. Assert the
   emitted diagnostic is routed through sanitize_url_for_log so no raw secret
   reaches the Diag sink, matching the sibling log sites in complete_common and
   complete_sync. *)
let test_conflict_warning_sanitizes_base_url () =
  Eio_main.run
  @@ fun _env ->
  let base_url = "http://user:secret@leak.test:1/v1?token=abc" in
  let first = make_config ~base_url ~max_concurrent_requests:1 () in
  let second = make_config ~base_url ~max_concurrent_requests:5 () in
  let captured = Buffer.create 256 in
  Diag.with_sink
    (fun _level ~ctx:_ msg -> Buffer.add_string captured msg)
    (fun () ->
       Provider_admission.with_admission ~config:first (fun () -> ());
       Provider_admission.with_admission ~config:second (fun () -> ()));
  let logged = Buffer.contents captured in
  check
    bool
    "the conflict warning was emitted"
    true
    (contains_substring ~sub:"conflicting max_concurrent_requests" logged);
  check bool "sanitized host survives" true (contains_substring ~sub:"leak.test:1" logged);
  check
    bool
    "userinfo credential is stripped from the log"
    false
    (contains_substring ~sub:"secret" logged);
  check
    bool
    "query credential is stripped from the log"
    false
    (contains_substring ~sub:"token=abc" logged)
;;

let reject_dispatch_transport : Llm_transport.t =
  { complete_sync = (fun _ -> fail "invalid declaration must never dispatch")
  ; complete_stream =
      (fun ?on_telemetry:_ ~on_event:_ _ ->
        fail "invalid declaration must never dispatch")
  }
;;

let test_zero_declaration_rejected_before_dispatch () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let config =
    make_config ~base_url:"http://invalid.test:1" ~max_concurrent_requests:0 ()
  in
  match
    Complete.complete
      ~sw
      ~net:(Eio.Stdenv.net env)
      ~transport:reject_dispatch_transport
      ~config
      ~messages:[]
      ()
  with
  | Error (Http_client.AcceptRejected { reason }) ->
    check
      bool
      "rejection names the offending field"
      true
      (contains_substring ~sub:"max_concurrent_requests" reason)
  | Ok _ -> fail "expected AcceptRejected for max_concurrent_requests = 0"
  | Error _ -> fail "expected AcceptRejected, got a different error kind"
;;

(* Wiring-level counterfactual: this goes through Complete.complete, so it
   fails if the with_admission call is ever removed from the dispatch path —
   unlike the module-level tests above, which would keep passing. *)
let test_complete_dispatch_is_admitted () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let config =
    make_config ~base_url:"http://wired.test:1" ~max_concurrent_requests:2 ()
  in
  let in_flight = Atomic.make 0 in
  let max_seen = Atomic.make 0 in
  let counting_transport : Llm_transport.t =
    { complete_sync =
        (fun _ ->
          record_max_seen ~in_flight ~max_seen;
          Eio.Fiber.yield ();
          Eio.Fiber.yield ();
          Atomic.decr in_flight;
          { Llm_transport.response =
              Error
                (Http_client.NetworkError
                   { message = "test transport declines"; kind = Http_client.Unknown })
          ; latency_ms = None
          })
    ; complete_stream =
        (fun ?on_telemetry:_ ~on_event:_ _ -> fail "sync test must not stream")
    }
  in
  let job () =
    ignore
      (Complete.complete
         ~sw
         ~net:(Eio.Stdenv.net env)
         ~transport:counting_transport
         ~config
         ~messages:[]
         ())
  in
  Eio.Fiber.all (List.init 6 (fun _ -> job));
  check int "every dispatch completed" 0 (Atomic.get in_flight);
  check bool "bound was contended" true (Atomic.get max_seen >= 2);
  check
    bool
    "Complete.complete respects the declared bound"
    true
    (Atomic.get max_seen <= 2)
;;

let () =
  run
    "provider_admission"
    [ ( "admission"
      , [ test_case
            "no declaration runs directly"
            `Quick
            test_no_declaration_runs_directly
        ; test_case "bounded concurrency" `Quick test_bounded_concurrency
        ; test_case "api keys admit independently" `Quick test_identity_separates_api_keys
        ; test_case
            "conflicting declaration keeps first"
            `Quick
            test_conflicting_declaration_first_wins
        ; test_case
            "conflict warning sanitizes base_url"
            `Quick
            test_conflict_warning_sanitizes_base_url
        ; test_case
            "zero declaration rejected before dispatch"
            `Quick
            test_zero_declaration_rejected_before_dispatch
        ; test_case
            "Complete.complete dispatch is admitted"
            `Quick
            test_complete_dispatch_is_admitted
        ] )
    ]
;;
