(** The phase before the first body read is bounded.

    A server that accepts the request and never answers held
    [Http_client.with_post_stream] for as long as the socket stayed open
    unless the provider declared a connect budget: the first-event budget is
    armed on the reader, and such a server never lets the caller reach the
    reader. A server that answers with a refusing status line and no body
    held it the same way, past the headers. These cases run the real client
    against loopback listeners that stall at one of those points, and read
    the elapsed time off the clock, so a hang is a failure at
    [outer_budget_s] and not a wait. The last group crosses the headers: the
    reader arms what the pre-header phase left of the first-event budget,
    not a second full one. *)

module Http_client = Llm_provider.Http_client

let outer_budget_s = 10.0

(* On the gate (run 34845109557, 2026-09-14) the suite's seven cases took
   2.733 s together against 2.7 s of budgets; the slack is for a loaded
   runner's scheduling, and stays well under the guard so the window still
   separates "the budget ended it" from "the guard ended it". *)
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

(* Length the refusing server promises and never delivers, and the body it
   delivers when told to. The number only has to be non-zero so the client
   waits for bytes that never come. *)
let refusal_body = {|{"error":{"message":"slow down","type":"rate_limit_error"}}|}

(* The Retry-After the refusing listener sends, so a case can see that a
   refusal keeps its headers even when its body never comes. *)
let refusal_retry_after_s = 60

(* Accepts one connection, reads the request until the blank line that ends
   its headers, answers with a 429 status line and headers that promise
   [refusal_body], and then either sends that body or nothing more. The
   status line reaches the client, so this peer stalls AFTER the headers,
   where the silent server above never gets. *)
let start_refusing_server ~sw ~net ~sends_body =
  let listening =
    Eio.Net.listen ~sw ~backlog:5 ~reuse_addr:true net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Net.accept_fork ~sw listening ~on_error:(fun _ -> ()) (fun flow _addr ->
      let reader = Eio.Buf_read.of_flow ~max_size:65536 flow in
      let rec drop_request_headers () =
        match Eio.Buf_read.line reader with
        | "" -> ()
        | _ -> drop_request_headers ()
      in
      try
        drop_request_headers ();
        Eio.Flow.copy_string
          (Printf.sprintf
             "HTTP/1.1 429 Too Many Requests\r\n\
              Content-Type: application/json\r\n\
              Retry-After: %d\r\n\
              Content-Length: %d\r\n\
              \r\n"
             refusal_retry_after_s
             (String.length refusal_body))
          flow;
        if sends_body then Eio.Flow.copy_string refusal_body flow;
        let buf = Cstruct.create 4096 in
        while true do
          ignore (Eio.Flow.single_read flow buf)
        done
      with
      | End_of_file | Eio.Io _ -> ()));
  match Eio.Net.listening_addr listening with
  | `Tcp (_, port) -> port
  | `Unix _ -> invalid_arg "expected a TCP listening socket"
;;

(* Accepts one connection, reads the request until the blank line that ends
   its headers, waits [headers_after_s] on [clock], answers with a 200 status
   line and an event-stream content type, and then sends nothing more. The
   headers land inside the pre-header window; whatever the first-event
   budget has left after them is the reader's. *)
let start_late_headers_server ~sw ~net ~clock ~headers_after_s =
  let listening =
    Eio.Net.listen ~sw ~backlog:5 ~reuse_addr:true net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Net.accept_fork ~sw listening ~on_error:(fun _ -> ()) (fun flow _addr ->
      let reader = Eio.Buf_read.of_flow ~max_size:65536 flow in
      let rec drop_request_headers () =
        match Eio.Buf_read.line reader with
        | "" -> ()
        | _ -> drop_request_headers ()
      in
      try
        drop_request_headers ();
        Eio.Time.sleep clock headers_after_s;
        Eio.Flow.copy_string
          "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
          flow;
        let buf = Cstruct.create 4096 in
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
             ~f:(fun ~pre_header_elapsed_s:_ _reader -> ())
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
   | Ended (Error (Http_client.TimeoutError { phase; _ })) when phase = expected -> ()
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

(* A provider that declares no connect budget: the first-event budget is
   what stands in front of the headers. *)
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

(* The connection is made inside the window: a peer that completes the TCP
   handshake and never sends a ServerHello stalls the TLS handshake, and the
   budget ends it. The address is an IP literal on purpose: an https endpoint
   written as an address is a TLS peer named by its address, and this case
   holds that it reaches the handshake as one. *)
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

(* The refusal body is read under what the window has left, and the status
   line already is the provider's answer: when the window closes the caller
   gets that answer -- the status and its Retry-After, with no body -- and
   not a timeout that says the provider was silent. *)
let test_a_refusal_whose_body_never_arrives_is_still_the_refusal () =
  with_env @@ fun ~sw ~clock ~net ->
  let port = start_refusing_server ~sw ~net ~sends_body:false in
  let budget_s = 0.5 in
  match run ~clock ~net ~scheme:"http" ~port ~first_event_timeout_s:budget_s () with
  | Ended (Error (Http_client.HttpError { code = 429; body; retry_after_header })), elapsed ->
    Alcotest.(check string) "no body arrived, none is reported" "" body;
    Alcotest.(check (option (float 0.001)))
      "the Retry-After the peer sent is kept"
      (Some (float_of_int refusal_retry_after_s))
      retry_after_header;
    if elapsed < budget_s || elapsed >= budget_s +. slack_s
    then
      Alcotest.failf
        "ended at %.2fs; the %.1fs budget should have ended the wait for the body inside [%.1f, %.1f)"
        elapsed
        budget_s
        budget_s
        (budget_s +. slack_s)
  | other, elapsed ->
    Alcotest.failf
      "expected HttpError 429 with no body, got %s after %.2fs"
      (describe other)
      elapsed
;;

let test_a_complete_refusal_is_still_the_typed_http_error () =
  with_env @@ fun ~sw ~clock ~net ->
  let port = start_refusing_server ~sw ~net ~sends_body:true in
  match run ~clock ~net ~scheme:"http" ~port ~first_event_timeout_s:5.0 () with
  | Ended (Error (Http_client.HttpError { code = 429; body; _ })), elapsed ->
    Alcotest.(check string) "the refusal body is the one the peer sent" refusal_body body;
    if elapsed >= slack_s
    then Alcotest.failf "a complete refusal took %.2fs; it must not wait on the budget" elapsed
  | other, elapsed ->
    Alcotest.failf "expected HttpError 429 with the peer's body, got %s after %.2fs" (describe other) elapsed
;;

(* One window. The headers arrive late but inside the first-event budget;
   the reader is handed what is left of that budget, so the silence after
   the headers ends at the budget counted from the request, not at a second
   full budget counted from the first body read. The upper bound of the
   window is below the two-window total, so the case tells them apart.

   The accounting is split between [with_post_stream], which spends the
   pre-header part and hands over what is left, and the streaming
   completion, which arms that remainder on the reader; only the streaming
   completion observes both halves, so this case drives it.

   Two things separate "the reader ended it" from "the pre-header window
   ended it at the same instant", which a loaded runner can otherwise blur:
   the headers are late by [slack_s], the same allowance the other cases
   grant a loaded runner, so the pre-header window closing first would need
   the headers delayed past that; and the reader's entry is observed, since
   [Types.Connected] is emitted only once [f] is entered. *)
let late_headers_after_s = slack_s
let one_window_budget_s = slack_s +. 0.5
let two_windows_total_s = late_headers_after_s +. one_window_budget_s

let test_the_first_event_budget_is_one_window_across_the_headers () =
  with_env @@ fun ~sw ~clock ~net ->
  let port = start_late_headers_server ~sw ~net ~clock ~headers_after_s:late_headers_after_s in
  let config =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"one-window"
      ~base_url:(Printf.sprintf "http://127.0.0.1:%d" port)
      ~request_path:"/v1/chat/completions"
      ~temperature:0.0
      ~max_tokens:16
      ()
  in
  let started = Eio.Time.now clock in
  let reader_entered = ref false in
  let outcome =
    try
      Eio.Time.with_timeout_exn clock outer_budget_s (fun () ->
        Ended
          (Result.map
             (fun (_ : Llm_provider.Types.api_response) -> ())
             (Llm_provider.Complete.complete_stream
                ~sw
                ~net
                ~clock
                ~first_event_timeout_s:one_window_budget_s
                ~config
                ~messages:[ Llm_provider.Types.user_msg "hello" ]
                ~on_event:(function
                  | Llm_provider.Types.Connected -> reader_entered := true
                  | _ -> ())
                ())))
    with
    | Eio.Time.Timeout -> Hung
  in
  let elapsed = Eio.Time.now clock -. started in
  (match outcome with
   | Ended (Error (Http_client.TimeoutError { phase = Http_client.First_token; _ })) -> ()
   | other ->
     Alcotest.failf "expected TimeoutError phase=first_token, got %s after %.2fs" (describe other) elapsed);
  if not !reader_entered
  then
    Alcotest.failf
      "the pre-header window ended the call at %.2fs before the reader was entered; the case \
       proves nothing about the reader's budget"
      elapsed;
  if elapsed < one_window_budget_s || elapsed >= two_windows_total_s
  then
    Alcotest.failf
      "ended at %.2fs; one %.1fs window from the request should have ended it inside [%.1f, %.1f)"
      elapsed
      one_window_budget_s
      one_window_budget_s
      two_windows_total_s
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
    ; ( "across the headers"
      , [ Alcotest.test_case
            "the first-event budget is one window across the headers"
            `Quick
            test_the_first_event_budget_is_one_window_across_the_headers
        ] )
    ; ( "after a refusing status line"
      , [ Alcotest.test_case
            "a refusal whose body never arrives is still the refusal"
            `Quick
            test_a_refusal_whose_body_never_arrives_is_still_the_refusal
        ; Alcotest.test_case
            "a complete refusal is still the typed HTTP error"
            `Quick
            test_a_complete_refusal_is_still_the_typed_http_error
        ] )
    ]
;;
