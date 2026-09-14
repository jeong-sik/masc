(** The sync path bounds the wait for the response headers with the
    provider's connect budget.

    [Provider_config.connect_timeout_s] is the connect and
    initial-response-headers budget, and the streaming path hands it to the
    client. The sync path did not: [Complete_sync.complete_http] dispatched
    with neither the budget nor the clock, so a server that accepted the
    request and never answered held a sync call for as long as the socket
    stayed open unless the caller declared a body deadline as well. These
    cases run the real client against a loopback listener that never writes
    a byte and read the elapsed time off the clock, so a hang is a failure
    at [outer_budget_s] and not a wait. *)

module Http_client = Llm_provider.Http_client

let outer_budget_s = 10.0
let connect_budget_s = 0.5

(* Room for a loaded runner's scheduling between the budget ending the call
   and the call returning; well under the guard, so the window still tells
   "the budget ended it" from "the guard ended it". *)
let slack_s = 2.5

(* Accepts one connection and never writes a byte: the TCP handshake
   completes, whatever the peer sends is read and dropped, and no status
   line ever follows. Returns when the peer goes away, which is what the
   client's budget does. A daemon, so a case in which nothing dials it does
   not hold the switch open on the accept. *)
let start_silent_server ~sw ~net =
  let listening =
    Eio.Net.listen ~sw ~backlog:5 ~reuse_addr:true net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio.Net.accept_fork ~sw listening ~on_error:(fun _ -> ()) (fun flow _addr ->
      let buf = Cstruct.create 4096 in
      try
        while true do
          ignore (Eio.Flow.single_read flow buf)
        done
      with
      | End_of_file | Eio.Io _ -> ());
    `Stop_daemon);
  match Eio.Net.listening_addr listening with
  | `Tcp (_, port) -> port
  | `Unix _ -> invalid_arg "expected a TCP listening socket"
;;

type outcome =
  | Ended of (unit, Http_client.http_error) result
  | Hung

let describe = function
  | Hung -> Printf.sprintf "hung past the %.0fs guard" outer_budget_s
  | Ended (Ok ()) -> "returned Ok"
  | Ended (Error (Http_client.TimeoutError { phase; message })) ->
    Printf.sprintf "TimeoutError phase=%s (%s)" (Http_client.timeout_phase_to_label phase) message
  | Ended (Error (Http_client.NetworkError { message; _ })) -> "NetworkError " ^ message
  | Ended (Error (Http_client.AcceptRejected { reason })) -> "AcceptRejected " ^ reason
  | Ended (Error (Http_client.HttpError { code; _ })) -> Printf.sprintf "HttpError %d" code
  | Ended (Error (Http_client.ProviderTerminal _ | Http_client.ProviderFailure _)) ->
    "a provider error"
;;

let config_for ~port ~connect_timeout_s =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id:"silent"
    ~base_url:(Printf.sprintf "http://127.0.0.1:%d" port)
    ~request_path:"/v1/chat/completions"
    ~temperature:0.0
    ~max_tokens:16
    ?connect_timeout_s
    ()
;;

let complete ~sw ~net ?clock ~config () =
  Result.map
    (fun (_ : Llm_provider.Types.api_response) -> ())
    (Llm_provider.Complete.complete
       ~sw
       ~net
       ?clock
       ~config
       ~messages:[ Llm_provider.Types.user_msg "hello" ]
       ())
;;

let with_env f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let net = Eio.Stdenv.net env in
  f ~sw ~clock ~net
;;

(* No body deadline: the connect budget is the only bound the caller gave,
   and it is the provider's. *)
let test_a_silent_server_ends_the_sync_call_at_the_connect_budget () =
  with_env
  @@ fun ~sw ~clock ~net ->
  let port = start_silent_server ~sw ~net in
  let config = config_for ~port ~connect_timeout_s:(Some connect_budget_s) in
  let started = Eio.Time.now clock in
  let outcome =
    try
      Eio.Time.with_timeout_exn clock outer_budget_s (fun () ->
        Ended (complete ~sw ~net ~clock ~config ()))
    with
    | Eio.Time.Timeout -> Hung
  in
  let elapsed = Eio.Time.now clock -. started in
  (match outcome with
   | Ended (Error (Http_client.TimeoutError { phase = Http_client.Http_operation; _ })) -> ()
   | other ->
     Alcotest.failf
       "expected TimeoutError phase=http_operation, got %s after %.2fs"
       (describe other)
       elapsed);
  if elapsed < connect_budget_s || elapsed >= connect_budget_s +. slack_s
  then
    Alcotest.failf
      "ended at %.2fs; the %.1fs connect budget should have ended it inside [%.1f, %.1f)"
      elapsed
      connect_budget_s
      connect_budget_s
      (connect_budget_s +. slack_s)
;;

(* A budget the caller cannot enforce is refused before any byte is sent,
   as the streaming path refuses it, rather than dropped. Nothing listens on
   the port: had the client dialled, the result would be a NetworkError. *)
let closed_port = 9

let test_a_connect_budget_without_a_clock_is_refused_before_dispatch () =
  with_env
  @@ fun ~sw ~clock:_ ~net ->
  let config = config_for ~port:closed_port ~connect_timeout_s:(Some connect_budget_s) in
  match complete ~sw ~net ~config () with
  | Error (Http_client.AcceptRejected { reason }) ->
    Alcotest.(check string)
      "the refusal names the budget and the missing clock"
      "post_sync_once: connect_timeout_s was supplied without the clock required to enforce it"
      reason
  | other -> Alcotest.failf "expected AcceptRejected, got %s" (describe (Ended other))
;;

let () =
  Alcotest.run
    "complete sync connect budget"
    [ ( "connect_timeout_s"
      , [ Alcotest.test_case
            "a silent server ends the sync call at the connect budget"
            `Quick
            test_a_silent_server_ends_the_sync_call_at_the_connect_budget
        ; Alcotest.test_case
            "a connect budget without a clock is refused before dispatch"
            `Quick
            test_a_connect_budget_without_a_clock_is_refused_before_dispatch
        ] )
    ]
;;
