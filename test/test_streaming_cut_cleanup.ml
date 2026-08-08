(** Does the streaming read terminate (and release the socket) in bounded
    time when the provider cuts mid-stream (TCP FIN / half-close) or stalls
    silently after the response headers?

    Forensic context (2026-06-09): masc keepers were observed stuck in the
    [streaming] FSM state with Ollama Cloud connections (34.36.133.15:443)
    held in CLOSE_WAIT — the peer had sent FIN but the local side had not
    closed.  PR #1978 threaded an explicit stream idle timeout
    through [streaming.ml].  This regression test exercises the production
    [Http_client.with_post_stream] + [read_sse] path directly to decide
    whether the cut / silent-stall paths are now bounded, or whether the
    socket teardown still hangs (a CLOSE_WAIT leak that no idle timeout
    covers).

    Method: a raw-socket loopback origin sends a valid HTTP/1.1 200 SSE
    response, a few [data:] lines, then either (a) half-closes its write
    side (FIN) or (b) holds the connection open and sends nothing more.
    The client runs the real [with_post_stream] with a short
    [idle_timeout].  A bounded outcome means [with_post_stream] returned
    (its contract closes the fd on return).  An unbounded outcome trips the
    outer wall-clock and fails the test as a hang. *)

module Http_client = Llm_provider.Http_client

let idle_timeout_s = 1.0
let outer_budget_s = 5.0
let bounded_threshold_s = 3.0

let sse_headers =
  "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
;;

let drain_request_headers flow =
  let buf = Eio.Buf_read.of_flow flow ~max_size:8192 in
  let rec consume () =
    match Eio.Buf_read.line buf with
    | "" -> ()
    | _ -> consume ()
    | exception End_of_file -> ()
  in
  consume ()
;;

let send_prelude flow ~n_lines =
  Eio.Flow.copy_string sse_headers flow;
  for i = 1 to n_lines do
    Eio.Flow.copy_string (Printf.sprintf "data: {\"i\":%d}\n\n" i) flow
  done
;;

(* Variant (a): send prelude, then FIN the write side and keep the fd open
   on the server (mimics a peer that cut mid-stream without closing the
   whole socket). *)
let listening_port socket =
  match Eio.Net.listening_addr socket with
  | `Tcp (_, port) -> port
  | `Unix _ -> invalid_arg "expected a TCP listening socket"
;;

let half_close_server ~sw ~net ~n_lines =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 0) in
  let listening = Eio.Net.listen ~sw ~backlog:5 ~reuse_addr:true net addr in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Net.accept_fork
      ~sw
      listening
      ~on_error:(fun _ -> ())
      (fun flow _addr ->
         drain_request_headers flow;
         send_prelude flow ~n_lines;
         Eio.Flow.shutdown flow `Send;
         (* hold the (now half-closed) fd so teardown is the client's job *)
         Eio_unix.sleep (outer_budget_s +. 1.0)));
  listening_port listening
;;

(* Variant (b): send prelude, then go silent (no FIN) — the inter-event
   idle deadline is the only thing that can unstick the reader. *)
let silent_stall_server ~sw ~net ~n_lines =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 0) in
  let listening = Eio.Net.listen ~sw ~backlog:5 ~reuse_addr:true net addr in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Net.accept_fork
      ~sw
      listening
      ~on_error:(fun _ -> ())
      (fun flow _addr ->
         drain_request_headers flow;
         send_prelude flow ~n_lines;
         Eio_unix.sleep (outer_budget_s +. 1.0)));
  listening_port listening
;;

type outcome =
  | Returned_ok
  | Returned_error
  | Idle_or_hang

(* Returns (outcome, elapsed_seconds, data_lines_seen). [elapsed] separates
   a bounded idle-timeout (~idle_timeout_s) from a real hang (~outer_budget_s). *)
let run_client ~clock ~net ~port =
  let lines = ref 0 in
  let t0 = Eio.Time.now clock in
  let outcome =
    try
      Eio.Time.with_timeout_exn clock outer_budget_s (fun () ->
        match
          Http_client.with_post_stream
            ~clock
            ~net
            ~url:(Printf.sprintf "http://127.0.0.1:%d/v1/chat/completions" port)
            ~headers:[ "content-type", "application/json" ]
            ~body:"{}"
            ~f:(fun reader ->
              Http_client.read_sse
                ~clock
                ~idle_timeout:idle_timeout_s
                ~reader
                ~on_data:(fun ~event_type:_ _ -> incr lines)
                ())
            ()
        with
        | Ok () -> Returned_ok
        | Error _ -> Returned_error)
    with
    | Eio.Time.Timeout -> Idle_or_hang
  in
  let elapsed = Eio.Time.now clock -. t0 in
  outcome, elapsed, !lines
;;

let label_of_outcome = function
  | Returned_ok -> "Ok"
  | Returned_error -> "Error"
  | Idle_or_hang -> "Timeout(idle-or-hang)"
;;

let assert_bounded ~label ~elapsed ~outcome ~lines ~expect_min_lines =
  if elapsed >= bounded_threshold_s
  then
    Alcotest.failf
      "[%s] streaming read did not terminate in bounded time: elapsed=%.3fs >= %.1fs \
       (outcome=%s, lines=%d). The reader hung; the socket would leak in CLOSE_WAIT \
       until process restart."
      label
      elapsed
      bounded_threshold_s
      (label_of_outcome outcome)
      lines;
  if lines < expect_min_lines
  then
    Alcotest.failf
      "[%s] expected at least %d data lines before the cut, saw %d"
      label
      expect_min_lines
      lines
;;

let test_half_close_is_bounded () =
  Eio_main.run
  @@ fun env ->
  let net = env#net
  and clock = env#clock in
  try
    Eio.Switch.run (fun sw ->
      let port = half_close_server ~sw ~net ~n_lines:3 in
      let outcome, elapsed, lines = run_client ~clock ~net ~port in
      assert_bounded
        ~label:"half-close (FIN mid-stream)"
        ~elapsed
        ~outcome
        ~lines
        ~expect_min_lines:3;
      raise Exit)
  with
  | Exit -> ()
;;

let test_silent_stall_is_bounded () =
  Eio_main.run
  @@ fun env ->
  let net = env#net
  and clock = env#clock in
  try
    Eio.Switch.run (fun sw ->
      let port = silent_stall_server ~sw ~net ~n_lines:3 in
      let outcome, elapsed, lines = run_client ~clock ~net ~port in
      assert_bounded
        ~label:"silent stall (no FIN)"
        ~elapsed
        ~outcome
        ~lines
        ~expect_min_lines:3;
      raise Exit)
  with
  | Exit -> ()
;;

let () =
  let open Alcotest in
  run
    "streaming_cut_cleanup"
    [ ( "bounded_termination"
      , [ test_case
            "half-close (FIN) terminates bounded"
            `Quick
            test_half_close_is_bounded
        ; test_case "silent stall terminates bounded" `Quick test_silent_stall_is_bounded
        ] )
    ]
;;
