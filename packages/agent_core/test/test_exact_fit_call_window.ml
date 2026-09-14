(** The call deadline is one window across the exact-fit path.

    A provider whose requests are measured before they are sent takes the
    exact-fit arm of the non-streaming route: a count-tokens request, then
    the completion, each behind the binding's admission permit. The call
    deadline the caller set bounds that whole path from the call: the
    measurement's permit wait and round trip spend from it, and the
    completion arms what they left, its own permit wait included. These
    cases run the real route against a loopback count-tokens listener and
    an injected completion transport, and read the elapsed time off the
    clock, so a hang is a failure at [outer_budget_s] and not a wait. *)
open Alcotest
open Llm_provider

let call_deadline_s = 1.0

(* Where one window ends. A deadline restarted after the count-tokens round
   trip would end at [count_tokens_delay_s +. call_deadline_s]; the slack
   keeps the window below that total so the case tells them apart. *)
let slack_s = 0.5
let count_tokens_delay_s = 0.6
let two_windows_total_s = count_tokens_delay_s +. call_deadline_s
let provider_takes_s = 5.0
let outer_budget_s = 10.0

let within_one_window elapsed = elapsed >= call_deadline_s && elapsed < call_deadline_s +. slack_s

type count_tokens_behaviour =
  | Answers_at_once
  | Answers_after of float
  | Never_answers

let fresh_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt socket Unix.SO_REUSEADDR true;
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | _ -> fail "loopback socket did not expose a TCP port"
  in
  Unix.close socket;
  port
;;

type listener =
  { base_url : string
  ; count_posts : int Atomic.t
  ; first_count_request : unit Eio.Promise.t
  }

(* Answers the count-tokens measurement as the case says, and says when the
   first one arrives. The completion itself goes through the injected
   transport, so any other path reaching this listener is a fault the case
   reports. *)
let start_count_tokens_server ~sw ~net ~clock ~behaviour =
  let port = fresh_port () in
  let count_posts = Atomic.make 0 in
  let first_count_request, arrived = Eio.Promise.create () in
  let handler _conn request body =
    ignore (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) : string);
    let path = Cohttp.Request.uri request |> Uri.path in
    if String.ends_with ~suffix:"/count_tokens" path
    then (
      if Atomic.fetch_and_add count_posts 1 = 0 then Eio.Promise.resolve arrived ();
      (match behaviour with
       | Answers_at_once -> ()
       | Answers_after delay_s -> Eio.Time.sleep clock delay_s
       | Never_answers -> Eio.Fiber.await_cancel ());
      Cohttp_eio.Server.respond_string ~status:`OK ~body:{|{"input_tokens":10}|} ())
    else
      Cohttp_eio.Server.respond_string
        ~status:`Internal_server_error
        ~body:"the completion must not reach the listener"
        ()
  in
  let socket =
    Eio.Net.listen net ~sw ~backlog:4 ~reuse_addr:true (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  { base_url = Printf.sprintf "http://127.0.0.1:%d" port; count_posts; first_count_request }
;;

(* Who else holds the binding's one permit, and from when. *)
type holder =
  | Nobody
  | From_the_start
  | Once_the_measurement_is_in_flight
    (** joins the FIFO while the measurement holds the permit, so the
        permit passes to the holder and the completion queues behind it *)

(* An Anthropic-kind binding: measured before dispatch, one permit. *)
let config base_url =
  Provider_config.make
    ~kind:Provider_config.Anthropic
    ~model_id:"exact-fit-call-window"
    ~base_url
    ~api_key:"test-key"
    ~headers:[ "Content-Type", "application/json"; "anthropic-version", "2023-06-01" ]
    ~request_path:"/v1/messages"
    ~max_tokens:64
    ~max_context:200000
    ~max_concurrent_requests:1
    ()
;;

let response =
  { Types.id = "exact-fit-response"
  ; model = "exact-fit-call-window"
  ; stop_reason = Types.EndTurn
  ; content = [ Types.Text "accepted" ]
  ; usage = None
  ; telemetry = None
  }
;;

(* Records the dispatch, then takes longer than any call here has left. *)
let slow_transport ~clock ~dispatched : Llm_transport.t =
  { complete_sync =
      (fun _ ->
        dispatched := true;
        Eio.Time.sleep clock provider_takes_s;
        { Llm_transport.response = Ok response; latency_ms = None })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _ -> fail "the route is non-streaming")
  }
;;

let build_agent ~net ~provider_config ~transport =
  Agent_core.Builder.create ~net ~model:provider_config.Provider_config.model_id
  |> Agent_core.Builder.with_provider_config provider_config
  |> Agent_core.Builder.with_context_fit_admission Agent_core.Agent.Require_exact_fit
  |> Agent_core.Builder.without_event_bus
  |> Agent_core.Builder.with_transport transport
  |> Agent_core.Builder.with_call_timeout call_deadline_s
  |> Agent_core.Builder.build_safe
  |> function
  | Ok agent -> agent
  | Error error -> fail (Agent_core.Error.to_string error)
;;

type outcome =
  | Ended of (Types.api_response, Agent_core.Error.t) result
  | Hung

let describe = function
  | Hung -> Printf.sprintf "hung past the %.0fs guard" outer_budget_s
  | Ended (Ok _) -> "returned Ok"
  | Ended (Error error) -> Agent_core.Error.to_string error
;;

let run_case ~behaviour ~holder f =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let net = Eio.Stdenv.net env in
  Eio.Switch.run
  @@ fun sw ->
  let listener = start_count_tokens_server ~sw ~net ~clock ~behaviour in
  let provider_config = config listener.base_url in
  let release, resolve_release = Eio.Promise.create () in
  let hold () =
    Provider_admission.with_admission ~config:provider_config (fun () ->
      Eio.Promise.await release)
  in
  (match holder with
   | Nobody -> ()
   | From_the_start -> Eio.Fiber.fork ~sw hold
   | Once_the_measurement_is_in_flight ->
     Eio.Fiber.fork ~sw (fun () ->
       Eio.Promise.await listener.first_count_request;
       hold ()));
  let dispatched = ref false in
  let agent =
    build_agent ~net ~provider_config ~transport:(slow_transport ~clock ~dispatched)
  in
  let started = Eio.Time.now clock in
  let outcome =
    try
      Eio.Time.with_timeout_exn clock outer_budget_s (fun () ->
        Ended (Agent_core.Agent.run ~sw ~clock agent "measure, then complete"))
    with
    | Eio.Time.Timeout -> Hung
  in
  let elapsed = Eio.Time.now clock -. started in
  f ~outcome ~elapsed ~dispatched:!dispatched ~count_posts:(Atomic.get listener.count_posts);
  Eio.Promise.resolve resolve_release ()
;;

(* The phase, and the stage the message names, together say where the
   window was spent. *)
let check_timeout ~expected ~stage outcome elapsed =
  match outcome with
  | Ended
      (Error
         (Agent_core.Error.Provider (Error.Timeout { timeout_phase = Some phase; detail; _ })))
    when phase = expected ->
    if not (Agent_core_strings.contains_substring ~needle:stage ~haystack:detail)
    then failf "the %s timeout does not say %S: %s" (Http_client.timeout_phase_to_label expected) stage detail
  | other ->
    failf
      "expected a %s timeout, got %s after %.2fs"
      (Http_client.timeout_phase_to_label expected)
      (describe other)
      elapsed
;;

let check_one_window elapsed =
  if not (within_one_window elapsed)
  then
    failf
      "ended at %.2fs; one %.1fs window from the call should have ended it inside [%.1f, %.1f)"
      elapsed
      call_deadline_s
      call_deadline_s
      (call_deadline_s +. slack_s)
;;

(* The permit is held before the case starts. The measurement is first in
   line for it and never gets it: the call deadline ends that wait with
   nothing measured and nothing sent. *)
let test_the_measurements_permit_wait_ends_at_the_call_deadline () =
  run_case ~behaviour:Answers_at_once ~holder:From_the_start
  @@ fun ~outcome ~elapsed ~dispatched ~count_posts ->
  check_timeout ~expected:Http_client.Queue ~stage:"count-tokens request" outcome elapsed;
  check_one_window elapsed;
  check int "nothing was measured" 0 count_posts;
  check bool "the completion was never dispatched" false dispatched
;;

(* The measurement gets the permit and answers late but inside the window;
   the holder joined the FIFO meanwhile, so the completion queues behind it
   under what the measurement left, not under a fresh window. *)
let test_the_completions_permit_wait_runs_under_what_the_measurement_left () =
  run_case
    ~behaviour:(Answers_after count_tokens_delay_s)
    ~holder:Once_the_measurement_is_in_flight
  @@ fun ~outcome ~elapsed ~dispatched ~count_posts ->
  check_timeout ~expected:Http_client.Queue ~stage:"(Complete.complete)" outcome elapsed;
  check_one_window elapsed;
  if elapsed >= two_windows_total_s
  then failf "ended at %.2fs: the completion was given a second window" elapsed;
  check int "the request was measured once" 1 count_posts;
  check bool "the completion was never dispatched" false dispatched
;;

(* Nobody else wants the permit. The measurement answers late but inside
   the window; the completion then runs under what the measurement left. *)
let test_the_count_tokens_round_trip_spends_from_the_window () =
  run_case ~behaviour:(Answers_after count_tokens_delay_s) ~holder:Nobody
  @@ fun ~outcome ~elapsed ~dispatched ~count_posts:_ ->
  check_timeout
    ~expected:Http_client.Non_streaming_body
    ~stage:"during the provider round trip"
    outcome
    elapsed;
  check_one_window elapsed;
  if elapsed >= two_windows_total_s
  then failf "ended at %.2fs: the completion was given a second window" elapsed;
  check bool "the completion was dispatched under the remainder" true dispatched
;;

(* The measurement never answers and no body budget is declared: the call
   deadline is what ends it. *)
let test_a_measurement_that_never_answers_ends_at_the_call_deadline () =
  run_case ~behaviour:Never_answers ~holder:Nobody
  @@ fun ~outcome ~elapsed ~dispatched ~count_posts ->
  check_timeout
    ~expected:Http_client.Non_streaming_body
    ~stage:"during the count-tokens round trip"
    outcome
    elapsed;
  check_one_window elapsed;
  check int "the measurement was sent" 1 count_posts;
  check bool "the completion was never dispatched" false dispatched
;;

let () =
  Alcotest.run
    "exact-fit call window"
    [ ( "one window from the call"
      , [ test_case
            "the measurement's permit wait ends at the call deadline"
            `Quick
            test_the_measurements_permit_wait_ends_at_the_call_deadline
        ; test_case
            "the completion's permit wait runs under what the measurement left"
            `Quick
            test_the_completions_permit_wait_runs_under_what_the_measurement_left
        ; test_case
            "the count-tokens round trip spends from the window"
            `Quick
            test_the_count_tokens_round_trip_spends_from_the_window
        ; test_case
            "a measurement that never answers ends at the call deadline"
            `Quick
            test_a_measurement_that_never_answers_ends_at_the_call_deadline
        ] )
    ]
;;
