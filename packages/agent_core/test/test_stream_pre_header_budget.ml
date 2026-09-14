(** The phase before the response headers is bounded.

    A server that accepts the request and never answers held
    [Http_client.with_post_stream] for as long as the socket stayed open
    unless the provider declared a connect budget: the first-event budget is
    armed on the reader, and such a server never lets the caller reach the
    reader. These cases run the real client against loopback listeners that
    accept and stay silent, and read the elapsed time off the clock, so a
    hang is a failure at [outer_budget_s] and not a wait. *)

module Http_client = Llm_provider.Http_client

let outer_budget_s = 10.0

(* Generous against a loaded CI runner; the budgets under test are well
   under a second, so the elapsed window still separates "the budget ended
   it" from "the outer guard ended it". *)
let slack_s = 2.5

(* Accepts one connection and never writes a byte: the TCP handshake
   completes, whatever the peer sends is read and dropped, and no status
   line, and no TLS ServerHello, ever follows. Returns when the peer goes
   away, which is what the client's timeout does. *)
let start_silent_server ~sw ~net =
  let listening =
    Eio.Net.listen ~sw ~backlog:5 ~reuse_addr:true net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Net.accept_fork ~sw listening ~on_error:(fun _ -> ()) (fun flow _addr ->
      let buf = Cstruct.create 4096 in
      try
        while true do
          ignore (Eio.Flow.single_read flow buf)
        done
      with
      | End_of_file | Eio.Io _ -> ()));
  match Eio.Net.listening_addr listening with
  | `Tcp (_, port) -> port
  | `Unix _ -> invalid_arg "expected a TCP listening socket"
;;

type outcome =
  | Ended of (unit, Http_client.http_error) result
  | Hung

let run ~clock ~net ~scheme ~port ?connect_timeout_s ?first_event_timeout_s () =
  let started = Eio.Time.now clock in
  let outcome =
    try
      Eio.Time.with_timeout_exn clock outer_budget_s (fun () ->
        Ended
          (Http_client.with_post_stream
             ~clock
             ?connect_timeout_s
             ?first_event_timeout_s
             ~net
             ~url:(Printf.sprintf "%s://127.0.0.1:%d/v1/chat/completions" scheme port)
             ~headers:[ "content-type", "application/json" ]
             ~body:"{}"
             ~f:(fun _reader -> ())
             ()))
    with
    | Eio.Time.Timeout -> Hung
  in
  outcome, Eio.Time.now clock -. started
;;

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

let check_timeout_phase ~label ~expected ~budget_s (outcome, elapsed) =
  (match outcome with
   | Ended (Error (Http_client.TimeoutError { phase; _ }))
     when
       String.equal
         (Http_client.timeout_phase_to_label phase)
         (Http_client.timeout_phase_to_label expected) -> ()
   | other ->
     Alcotest.failf
       "[%s] expected TimeoutError phase=%s, got %s after %.2fs"
       label
       (Http_client.timeout_phase_to_label expected)
       (describe other)
       elapsed);
  if elapsed < budget_s || elapsed >= budget_s +. slack_s
  then
    Alcotest.failf
      "[%s] ended at %.2fs; the %.1fs budget should have ended it inside [%.1f, %.1f)"
      label
      elapsed
      budget_s
      budget_s
      (budget_s +. slack_s)
;;

let with_env f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  f ~sw ~clock:(Eio.Stdenv.clock env) ~net:(Eio.Stdenv.net env)
;;

(* Nine of the ten live providers declare no connect budget. Before this
   the request below had no bound at all. *)
let test_the_first_event_budget_stands_in_front_of_the_headers () =
  with_env @@ fun ~sw ~clock ~net ->
  let port = start_silent_server ~sw ~net in
  run ~clock ~net ~scheme:"http" ~port ~first_event_timeout_s:0.5 ()
  |> check_timeout_phase
       ~label:"first-event budget only"
       ~expected:Http_client.First_token
       ~budget_s:0.5
;;

let test_a_narrower_connect_budget_names_itself () =
  with_env @@ fun ~sw ~clock ~net ->
  let port = start_silent_server ~sw ~net in
  run ~clock ~net ~scheme:"http" ~port ~connect_timeout_s:0.3 ~first_event_timeout_s:5.0 ()
  |> check_timeout_phase
       ~label:"connect budget narrower"
       ~expected:Http_client.Http_operation
       ~budget_s:0.3
;;

let test_a_wider_connect_budget_yields_to_the_first_event_budget () =
  with_env @@ fun ~sw ~clock ~net ->
  let port = start_silent_server ~sw ~net in
  run ~clock ~net ~scheme:"http" ~port ~connect_timeout_s:5.0 ~first_event_timeout_s:0.4 ()
  |> check_timeout_phase
       ~label:"first-event budget narrower"
       ~expected:Http_client.First_token
       ~budget_s:0.4
;;

(* The connection is made inside the window. A peer that completes the TCP
   handshake and never sends a ServerHello stalls the TLS handshake, which
   ran before the budget started until 2026-09-14. *)
let test_the_budget_covers_the_tls_handshake () =
  match Llm_provider.Api_common.make_https_result () with
  | Error reason ->
    Printf.eprintf
      "TLS is not available on this host, skipping: %s\n%!"
      (Llm_provider.Api_common.https_init_error_to_string reason);
    Alcotest.skip ()
  | Ok _ ->
    with_env @@ fun ~sw ~clock ~net ->
    let port = start_silent_server ~sw ~net in
    run ~clock ~net ~scheme:"https" ~port ~connect_timeout_s:0.5 ()
    |> check_timeout_phase
         ~label:"TLS handshake stall"
         ~expected:Http_client.Http_operation
         ~budget_s:0.5
;;

let () =
  Alcotest.run
    "stream pre-header budget"
    [ ( "before the headers"
      , [ Alcotest.test_case
            "the first-event budget stands in front of the headers"
            `Quick
            test_the_first_event_budget_stands_in_front_of_the_headers
        ; Alcotest.test_case
            "a narrower connect budget names itself"
            `Quick
            test_a_narrower_connect_budget_names_itself
        ; Alcotest.test_case
            "a wider connect budget yields to the first-event budget"
            `Quick
            test_a_wider_connect_budget_yields_to_the_first_event_budget
        ; Alcotest.test_case
            "the budget covers the TLS handshake"
            `Quick
            test_the_budget_covers_the_tls_handshake
        ] )
    ]
;;
