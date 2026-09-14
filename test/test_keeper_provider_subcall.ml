(* The sub-call boundary is the only bound on a provider call made from inside
   a tool: the attempt watchdog exempts a tool in flight, and a non-streaming
   call shows no progress until it completes. These cases pin which declared
   setting bounds such a call, and that the bound reaches the HTTP client. *)

open Alcotest
open Masc
module Subcall = Keeper_provider_subcall

let declared_body_deadline_s = 120.0
let declared_provider_call_deadline_s = 900.0
let deadline = option (float 0.0)

let test_a_declared_body_deadline_is_the_narrower_statement () =
  check
    deadline
    "the body deadline wins"
    (Some declared_body_deadline_s)
    (Subcall.deadline_s
       ~body_timeout_override_sec:(Some declared_body_deadline_s)
       ~provider_call_deadline_sec:(Some declared_provider_call_deadline_s))
;;

let test_the_keeper_no_progress_threshold_bounds_an_undeclared_body () =
  check
    deadline
    "the provider-call deadline applies"
    (Some declared_provider_call_deadline_s)
    (Subcall.deadline_s
       ~body_timeout_override_sec:None
       ~provider_call_deadline_sec:(Some declared_provider_call_deadline_s))
;;

let test_nothing_declared_is_the_operator_choice_of_no_bound () =
  check
    deadline
    "no bound"
    None
    (Subcall.deadline_s ~body_timeout_override_sec:None ~provider_call_deadline_sec:None)
;;

(* [turn.provider_call_deadline_sec] is clamped to [30, 3600] where it is
   read, so thirty seconds is the shortest deadline a declared threshold can
   produce. This case pays it once: it is the only proof that the threshold
   reaches the HTTP client through the boundary rather than stopping at the
   resolver. *)
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

let test_the_declared_threshold_reaches_the_http_client () =
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
              ()
          in
          let started = Eio.Time.now clock in
          (match Subcall.complete ~sw ~net ~clock ~config ~messages:fixture_messages () with
           | Error
               (Llm_provider.Http_client.TimeoutError
                  { phase = Llm_provider.Http_client.Non_streaming_body; _ }) ->
             let elapsed = Eio.Time.now clock -. started in
             check
               bool
               "the call ended at the declared threshold"
               true
               (elapsed >= shortest_declared_threshold_s
                && elapsed < shortest_declared_threshold_s +. threshold_slack_s)
           | Error _ -> fail "the call did not end as a non-streaming body deadline"
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
            "a declared body deadline is the narrower statement"
            `Quick
            test_a_declared_body_deadline_is_the_narrower_statement
        ; test_case
            "the keeper no-progress threshold bounds an undeclared body"
            `Quick
            test_the_keeper_no_progress_threshold_bounds_an_undeclared_body
        ; test_case
            "nothing declared is the operator choice of no bound"
            `Quick
            test_nothing_declared_is_the_operator_choice_of_no_bound
        ; test_case
            "the declared threshold reaches the HTTP client"
            `Slow
            test_the_declared_threshold_reaches_the_http_client
        ] )
    ]
;;
