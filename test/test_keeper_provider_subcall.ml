(* The sub-call boundary is the only bound on a provider call made from inside
   a tool: the attempt watchdog exempts a tool in flight, a non-streaming call
   shows no progress until it completes, and a call queued for its binding's
   admission permit shows none either. Agent Core's own suite pins how
   [call_timeout_s] splits between the queue and the round trip with
   sub-second values; this case pins that the keeper threshold reaches it. *)

open Alcotest
open Masc
module Subcall = Keeper_provider_subcall

let deadline = option (float 0.0)

(* [turn.provider_call_deadline_sec] is clamped to [30, 3600] where it is
   read, so thirty seconds is the shortest deadline a declared threshold can
   produce. This case pays it once. *)
let shortest_declared_threshold_s = 30.0
let threshold_slack_s = 5.0

let with_declared_provider_call_deadline seconds f =
  Config_boot_overrides.reset_for_tests ();
  Keeper_runtime_resolved.reset_for_tests ();
  Config_boot_overrides.set
    "MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC"
    (Printf.sprintf "%.0f" seconds);
  Keeper_runtime_resolved.reset_for_tests ();
  Fun.protect
    ~finally:(fun () ->
      Config_boot_overrides.reset_for_tests ();
      Keeper_runtime_resolved.reset_for_tests ())
    f
;;

(* Accepts the connection and never writes: a provider that hangs after
   taking the request. The handler holds the flow until the test's switch is
   failed. *)
let start_server_that_never_answers ~sw ~net =
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:1
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> invalid_arg "expected a TCP listening socket"
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Net.accept_fork
      ~sw
      socket
      ~on_error:(fun _ -> ())
      (fun _flow _addr -> Eio.Fiber.await_cancel ()));
  Printf.sprintf "http://127.0.0.1:%d" port
;;

let fixture_messages =
  [ { Agent_core.Types.role = Agent_core.Types.User
    ; content = [ Agent_core.Types.Text "fixture" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  ]
;;

(* The live shape: a binding declared with one concurrent request, its only
   permit held by another call (a keeper streaming a turn on it). The holder
   keeps the permit past the threshold, so a boundary that bounded only the
   round trip would wait for the permit first and end well after it. *)
let test_the_declared_threshold_bounds_the_wait_for_an_admission_permit () =
  with_declared_provider_call_deadline shortest_declared_threshold_s (fun () ->
    check
      deadline
      "the resolver saw the declared threshold"
      (Some shortest_declared_threshold_s)
      (Keeper_runtime_resolved.provider_call_deadline_sec ());
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let net = Eio.Stdenv.net env in
      try
        Eio.Switch.run (fun sw ->
          let base_url = start_server_that_never_answers ~sw ~net in
          let config =
            Llm_provider.Provider_config.make
              ~kind:Llm_provider.Provider_config.Ollama
              ~model_id:"fixture"
              ~base_url
              ~max_concurrent_requests:1
              ()
          in
          (* [Fiber.fork] runs the holder until it blocks, so it already holds
             the permit when the fork returns. *)
          Eio.Fiber.fork ~sw (fun () ->
            Llm_provider.Provider_admission.with_admission ~config (fun () ->
              Eio.Time.sleep clock (shortest_declared_threshold_s +. threshold_slack_s)));
          (match Llm_provider.Provider_admission.snapshot_for ~config with
           | Some snapshot ->
             check int "the holder has the only permit" 1 snapshot.Llm_provider.Slot_scheduler.active
           | None -> fail "the holder did not take a permit");
          let started = Eio.Time.now clock in
          (match Subcall.complete ~sw ~net ~clock ~config ~messages:fixture_messages () with
           | Error
               (Llm_provider.Http_client.TimeoutError
                  { phase = Llm_provider.Http_client.Queue; _ }) ->
             let elapsed = Eio.Time.now clock -. started in
             check
               bool
               "the call ended at the declared threshold while still queued"
               true
               (elapsed >= shortest_declared_threshold_s
                && elapsed < shortest_declared_threshold_s +. threshold_slack_s)
           | Error (Llm_provider.Http_client.TimeoutError { phase; _ }) ->
             failf
               "the call ended in phase %s, not while waiting for the permit"
               (Llm_provider.Http_client.timeout_phase_to_label phase)
           | Error _ -> fail "the call did not end as a timeout"
           | Ok _ -> fail "a server that never answers completed the call");
          Eio.Switch.fail sw Exit)
      with
      | Exit -> ()))
;;

let () =
  run
    "keeper_provider_subcall"
    [ ( "deadline"
      , [ test_case
            "the declared threshold bounds the wait for an admission permit"
            `Slow
            test_the_declared_threshold_bounds_the_wait_for_an_admission_permit
        ] )
    ]
;;
