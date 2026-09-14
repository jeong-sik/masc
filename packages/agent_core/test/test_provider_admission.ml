(** Tests for per-endpoint admission of concurrent provider requests.

    Each test uses a distinct base_url so schedulers registered by one test
    never leak into another — the admission registry is process-global by
    design and exposes no reset. *)

open Alcotest
open Llm_provider


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

(* Neither declaration outranks the other, so keeping the one that dispatched
   first made the effective allowance a function of runtime order. It is a
   configuration error, and it is raised before the permit is taken. *)
let test_conflicting_declaration_is_rejected () =
  Eio_main.run
  @@ fun _env ->
  let base_url = "http://conflict.test:1" in
  let first = make_config ~base_url ~max_concurrent_requests:1 () in
  let second = make_config ~base_url ~max_concurrent_requests:5 () in
  Provider_admission.with_admission ~config:first (fun () -> ());
  let ran_under_conflict = ref false in
  (match
     Provider_admission.with_admission ~config:second (fun () ->
       ran_under_conflict := true)
   with
   | () -> fail "a conflicting declaration must not be admitted"
   | exception Invalid_argument _ -> ());
  check bool "the body never ran" false !ran_under_conflict;
  match Provider_admission.snapshot_for ~config:second with
  | None -> fail "scheduler must exist after first admitted dispatch"
  | Some snap ->
    check
      int
      "the rejected declaration did not resize the scheduler"
      1
      snap.Slot_scheduler.max_slots
;;

(* agent-core boundary: the conflict warning names the endpoint, and a custom base_url can
   carry userinfo or a `?token=`/`?password=` query credential. Assert the
   emitted diagnostic is routed through sanitize_url_for_log so no raw secret
   reaches the Diag sink, matching the sibling log sites in complete_common and
   complete_sync. *)
let test_conflict_error_sanitizes_base_url () =
  Eio_main.run
  @@ fun _env ->
  let base_url = "http://user:secret@leak.test:1/v1?token=abc" in
  let first = make_config ~base_url ~max_concurrent_requests:1 () in
  let second = make_config ~base_url ~max_concurrent_requests:5 () in
  Provider_admission.with_admission ~config:first (fun () -> ());
  let logged =
    match Provider_admission.with_admission ~config:second (fun () -> ()) with
    | () -> fail "a conflicting declaration must not be admitted"
    | exception Invalid_argument message -> message
  in
  check
    bool
    "the conflict names the field"
    true
    (Agent_core_strings.contains_substring ~needle:"conflicting max_concurrent_requests" ~haystack:logged);
  check bool "sanitized host survives" true (Agent_core_strings.contains_substring ~needle:"leak.test:1" ~haystack:logged);
  check
    bool
    "userinfo credential is stripped from the message"
    false
    (Agent_core_strings.contains_substring ~needle:"secret" ~haystack:logged);
  check
    bool
    "query credential is stripped from the message"
    false
    (Agent_core_strings.contains_substring ~needle:"token=abc" ~haystack:logged)
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
      (Agent_core_strings.contains_substring ~needle:"max_concurrent_requests" ~haystack:reason)
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

(* Call deadlines: [call_timeout_s] bounds the wait for a permit and the round
   trip after it as one span. Values are wide enough that a deadline which
   restarted after admission, or one that ignored the queue, lands clearly
   outside the asserted window. *)
let call_deadline_s = 1.0
let call_deadline_slack_s = 0.5

let slow_declining_transport ~clock ~on_dispatch ~provider_takes_s : Llm_transport.t =
  { complete_sync =
      (fun _ ->
        on_dispatch ();
        Eio.Time.sleep clock provider_takes_s;
        { Llm_transport.response =
            Error
              (Http_client.NetworkError
                 { message = "test transport declines"; kind = Http_client.Unknown })
        ; latency_ms = None
        })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _ -> fail "sync test must not stream")
  }
;;

let within_call_deadline ~started ~clock =
  let elapsed = Eio.Time.now clock -. started in
  elapsed >= call_deadline_s && elapsed < call_deadline_s +. call_deadline_slack_s
;;

let test_call_deadline_ends_the_wait_for_a_permit () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let config =
    make_config ~base_url:"http://call-deadline-queue.test:1" ~max_concurrent_requests:1 ()
  in
  let release, resolve_release = Eio.Promise.create () in
  (* [Fiber.fork] runs the holder until it blocks, so it holds the only permit
     when the fork returns. *)
  Eio.Fiber.fork ~sw (fun () ->
    Provider_admission.with_admission ~config (fun () -> Eio.Promise.await release));
  let dispatched = ref false in
  let started = Eio.Time.now clock in
  (match
     Complete.complete
       ~sw
       ~net:(Eio.Stdenv.net env)
       ~clock
       ~transport:
         (slow_declining_transport
            ~clock
            ~on_dispatch:(fun () -> dispatched := true)
            ~provider_takes_s:0.0)
       ~config
       ~messages:[]
       ~call_timeout_s:call_deadline_s
       ()
   with
   | Error (Http_client.TimeoutError { phase = Http_client.Queue; message }) ->
     check
       bool
       "the message names the call deadline"
       true
       (Agent_core_strings.contains_substring ~needle:"call_timeout_s" ~haystack:message)
   | Error (Http_client.TimeoutError { phase; _ }) ->
     failf "the wait ended in phase %s, not Queue" (Http_client.timeout_phase_to_label phase)
   | Error _ | Ok _ -> fail "expected a queue timeout while the permit was held");
  check bool "the wait ended at the call deadline" true (within_call_deadline ~started ~clock);
  check bool "nothing was sent" false !dispatched;
  (match Provider_admission.snapshot_for ~config with
   | Some snapshot ->
     check int "the expired waiter left the queue" 0 snapshot.Slot_scheduler.queue_length;
     check int "the holder still has its permit" 1 snapshot.Slot_scheduler.active
   | None -> fail "the scheduler must be registered");
  Eio.Promise.resolve resolve_release ()
;;

let test_call_deadline_bounds_the_round_trip_with_what_the_wait_left () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let config =
    make_config ~base_url:"http://call-deadline-rest.test:1" ~max_concurrent_requests:1 ()
  in
  (* The holder gives the permit up after 0.6 s; the provider then takes far
     longer than the call has left. A deadline restarted at admission would
     end near 1.6 s. *)
  let holder_keeps_permit_s = 0.6 in
  Eio.Fiber.fork ~sw (fun () ->
    Provider_admission.with_admission ~config (fun () ->
      Eio.Time.sleep clock holder_keeps_permit_s));
  let dispatched = ref false in
  let started = Eio.Time.now clock in
  (match
     Complete.complete
       ~sw
       ~net:(Eio.Stdenv.net env)
       ~clock
       ~transport:
         (slow_declining_transport
            ~clock
            ~on_dispatch:(fun () -> dispatched := true)
            ~provider_takes_s:5.0)
       ~config
       ~messages:[]
       ~call_timeout_s:call_deadline_s
       ()
   with
   | Error (Http_client.TimeoutError { phase = Http_client.Non_streaming_body; message }) ->
     check
       bool
       "the message names the call deadline"
       true
       (Agent_core_strings.contains_substring ~needle:"call_timeout_s" ~haystack:message)
   | Error (Http_client.TimeoutError { phase; _ }) ->
     failf
       "the round trip ended in phase %s, not Non_streaming_body"
       (Http_client.timeout_phase_to_label phase)
   | Error _ | Ok _ -> fail "expected the round trip to end at the call deadline");
  check bool "the request was sent once the permit came" true !dispatched;
  check bool "the whole call ended at the call deadline" true (within_call_deadline ~started ~clock)
;;

let test_a_narrower_body_deadline_fires_inside_the_call_deadline () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let config =
    make_config ~base_url:"http://call-deadline-nested.test:1" ~max_concurrent_requests:1 ()
  in
  let body_deadline_s = 0.2 in
  let started = Eio.Time.now clock in
  (match
     Complete.complete
       ~sw
       ~net:(Eio.Stdenv.net env)
       ~clock
       ~transport:
         (slow_declining_transport ~clock ~on_dispatch:ignore ~provider_takes_s:5.0)
       ~config
       ~messages:[]
       ~body_timeout_s:body_deadline_s
       ~call_timeout_s:call_deadline_s
       ()
   with
   | Error (Http_client.TimeoutError { phase = Http_client.Non_streaming_body; message }) ->
     check
       bool
       "the message names the body deadline that fired"
       true
       (Agent_core_strings.contains_substring ~needle:"body_timeout_s" ~haystack:message)
   | Error (Http_client.TimeoutError { phase; _ }) ->
     failf "ended in phase %s, not Non_streaming_body" (Http_client.timeout_phase_to_label phase)
   | Error _ | Ok _ -> fail "expected the body deadline to fire");
  check
    bool
    "the narrower bound fired first"
    true
    (Eio.Time.now clock -. started < call_deadline_s)
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
            "conflicting declaration is rejected"
            `Quick
            test_conflicting_declaration_is_rejected
        ; test_case
            "conflict error sanitizes base_url"
            `Quick
            test_conflict_error_sanitizes_base_url
        ; test_case
            "zero declaration rejected before dispatch"
            `Quick
            test_zero_declaration_rejected_before_dispatch
        ; test_case
            "Complete.complete dispatch is admitted"
            `Quick
            test_complete_dispatch_is_admitted
        ] )
    ; ( "call_deadline"
      , [ test_case
            "ends the wait for a permit"
            `Quick
            test_call_deadline_ends_the_wait_for_a_permit
        ; test_case
            "bounds the round trip with what the wait left"
            `Quick
            test_call_deadline_bounds_the_round_trip_with_what_the_wait_left
        ; test_case
            "a narrower body deadline fires inside it"
            `Quick
            test_a_narrower_body_deadline_fires_inside_the_call_deadline
        ] )
    ]
;;
