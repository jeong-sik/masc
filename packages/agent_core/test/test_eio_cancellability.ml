(** Regression guard for AGENT_CORE HTTP cancellation assumption.

    AGENT_CORE streaming code (lib/llm_provider/http_client.ml [read_sse],
    [read_ndjson], [post_sync], [with_post_stream]) relies on
    [Eio.Time.with_timeout_exn] to interrupt slow / hung HTTP body reads.
    For that to actually work, [Eio.Buf_read.line] / [Buf_read.take_all]
    on top of [Eio.Net]-backed flows must propagate cancellation into
    the underlying socket [single_read].

    A 2026-04-27 forensic investigation produced reproducers (originally
    at /tmp/agent_core-cancel-research/repro/) that confirmed cancellation is
    intact across four scenarios.  This test ports those reproducers
    so a future Eio/cohttp-eio dependency bump that breaks cancellation
    fails CI immediately, instead of silently regressing into 3585s
    keeper hangs in masc-mcp. boundary-allow: cross-repo regression context.

    Cross-ref: planning/claude-plans/agent_core-execution-cancellability.md
                (in jeong-sik/me) — falsified self-confession comment in
                masc-mcp [keeper_llm_bridge.ml:35-39]. boundary-allow.

    All four cases use a 2.0s timeout budget; overshoot must stay under
    [overshoot_tolerance_s].  CI jitter is bounded by [tolerance];
    raise it only if you understand why. *)

let timeout_budget_s = 2.0
let overshoot_tolerance_s = 0.5

(* In-process slow line server. Sends initial HTTP/1.1 200 response with
   a large Content-Length, then drips lines (or bytes) on a fixed cadence
   forever. Closes when client disconnects. *)
let line_server ~sw ~net port ~gap_ms ~payload =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let socket = Eio.Net.listen ~sw ~backlog:5 ~reuse_addr:true net addr in
  Eio.Fiber.fork ~sw (fun () ->
    let rec accept_loop () =
      Eio.Net.accept_fork
        ~sw
        socket
        ~on_error:(fun _ -> ())
        (fun flow _addr ->
           let buf = Eio.Buf_read.of_flow flow ~max_size:8192 in
           (try
              let rec consume () =
                let line = Eio.Buf_read.line buf in
                if line = "" then () else consume ()
              in
              consume ()
            with
            | _ -> ());
           let resp =
             "HTTP/1.1 200 OK\r\n\
              Content-Length: 1000000\r\n\
              Content-Type: text/event-stream\r\n\
              Connection: close\r\n\
              \r\n"
           in
           try
             Eio.Flow.copy_string resp flow;
             for _ = 1 to 100_000 do
               Eio.Flow.copy_string payload flow;
               Eio_unix.sleep (float_of_int gap_ms /. 1000.0)
             done
           with
           | _ -> ());
      accept_loop ()
    in
    try accept_loop () with
    | _ -> ())
;;

let connect_and_consume_headers ~sw ~net port =
  let saddr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let conn = Eio.Net.connect ~sw net saddr in
  let req = "GET /drip HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" in
  Eio.Flow.copy_string req conn;
  let reader = Eio.Buf_read.of_flow conn ~max_size:1_000_000 in
  let rec drain () =
    let line = Eio.Buf_read.line reader in
    if line = "" then () else drain ()
  in
  drain ();
  reader
;;

(* AGENT_CORE read_sse loop structure (mirrors lib/llm_provider/http_client.ml). *)
let read_sse_loop reader ~on_data =
  let rec loop () =
    match Eio.Buf_read.line reader with
    | line ->
      let len = String.length line in
      if len > 6 && String.sub line 0 6 = "data: "
      then on_data (String.sub line 6 (len - 6));
      loop ()
    | exception End_of_file -> ()
  in
  loop ()
;;

(* Run [f] inside [with_timeout_exn budget]; return elapsed wall time
   on Eio.Time.Timeout.  Fails the test if any other outcome occurs. *)
let measure_timeout ~clock ~budget ~label fn =
  let t0 = Eio.Time.now clock in
  let outcome =
    try
      Eio.Time.with_timeout_exn clock budget fn;
      `Completed
    with
    | Eio.Time.Timeout -> `Timeout
    | Eio.Cancel.Cancelled exn -> `Cancelled exn
    | exn -> `Other exn
  in
  let elapsed = Eio.Time.now clock -. t0 in
  (match outcome with
   | `Timeout -> ()
   | `Completed ->
     Alcotest.failf "[%s] expected timeout, got completion in %.3fs" label elapsed
   | `Cancelled exn ->
     Alcotest.failf
       "[%s] expected Eio.Time.Timeout, got Cancelled(%s) in %.3fs"
       label
       (Printexc.to_string exn)
       elapsed
   | `Other exn ->
     Alcotest.failf
       "[%s] expected Eio.Time.Timeout, got %s in %.3fs"
       label
       (Printexc.to_string exn)
       elapsed);
  let overshoot = elapsed -. budget in
  if overshoot > overshoot_tolerance_s
  then
    Alcotest.failf
      "[%s] cancellation regression: elapsed=%.3fs budget=%.3fs overshoot=%.3fs > \
       tolerance=%.3fs"
      label
      elapsed
      budget
      overshoot
      overshoot_tolerance_s
;;

(* Test 1: slow drip server, 1 byte/sec, no newline.
   Mirrors a server that holds the connection but produces nothing
   useful.  [Buf_read.line] blocks in [ensure_slow_path] -> [Flow.single_read]. *)
let test_buf_read_line_cancellable () =
  Eio_main.run
  @@ fun env ->
  let net = env#net in
  let clock = env#clock in
  Eio.Switch.run (fun sw ->
    line_server ~sw ~net 18741 ~gap_ms:1000 ~payload:"x";
    Eio_unix.sleep 0.2;
    Eio.Switch.run (fun sw ->
      let reader = connect_and_consume_headers ~sw ~net 18741 in
      measure_timeout
        ~clock
        ~budget:timeout_budget_s
        ~label:"buf_read.line + slow drip"
        (fun () -> ignore (Eio.Buf_read.line reader)));
    raise Exit)
;;

let run_with_server ~port ~payload ~gap_ms ~label callback =
  Eio_main.run
  @@ fun env ->
  let net = env#net in
  let clock = env#clock in
  Eio.Switch.run (fun sw ->
    line_server ~sw ~net port ~gap_ms ~payload;
    Eio_unix.sleep 0.2;
    Eio.Switch.run (fun inner_sw ->
      let reader = connect_and_consume_headers ~sw:inner_sw ~net port in
      callback ~clock ~reader ~label);
    raise Exit)
;;

(* Test 2: fast SSE-style stream + trivial on_data.
   Simulates a provider sending lines every 100ms forever. *)
let test_read_sse_fast_stream_cancellable () =
  try
    run_with_server
      ~port:18742
      ~payload:"data: x\n"
      ~gap_ms:100
      ~label:"read_sse + fast stream + trivial"
      (fun ~clock ~reader ~label ->
         measure_timeout ~clock ~budget:timeout_budget_s ~label (fun () ->
           read_sse_loop reader ~on_data:(fun _ -> ())))
  with
  | Exit -> ()
;;

(* Test 3: fast stream + on_data sleeps via Eio_unix.sleep (cooperative). *)
let test_read_sse_sleeping_callback_cancellable () =
  try
    run_with_server
      ~port:18743
      ~payload:"data: x\n"
      ~gap_ms:100
      ~label:"read_sse + fast stream + sleep callback"
      (fun ~clock ~reader ~label ->
         measure_timeout ~clock ~budget:timeout_budget_s ~label (fun () ->
           read_sse_loop reader ~on_data:(fun _ -> Eio_unix.sleep 0.05)))
  with
  | Exit -> ()
;;

(* Test 4: fast stream + on_data does CPU-bound work without yielding.
   The next [Buf_read.line] call provides the cancel point. *)
let test_read_sse_cpu_callback_cancellable () =
  try
    run_with_server
      ~port:18744
      ~payload:"data: x\n"
      ~gap_ms:100
      ~label:"read_sse + fast stream + cpu callback"
      (fun ~clock ~reader ~label ->
         measure_timeout ~clock ~budget:timeout_budget_s ~label (fun () ->
           read_sse_loop reader ~on_data:(fun _ ->
             let t_end = Unix.gettimeofday () +. 0.05 in
             while Unix.gettimeofday () < t_end do
               ()
             done)))
  with
  | Exit -> ()
;;

let () =
  let open Alcotest in
  run
    "eio_cancellability"
    [ ( "http_body_read_cancellation"
      , [ test_case "buf_read.line + slow drip" `Quick (fun () ->
            try test_buf_read_line_cancellable () with
            | Exit -> ())
        ; test_case
            "read_sse + fast stream + trivial callback"
            `Quick
            test_read_sse_fast_stream_cancellable
        ; test_case
            "read_sse + fast stream + sleep callback"
            `Quick
            test_read_sse_sleeping_callback_cancellable
        ; test_case
            "read_sse + fast stream + cpu callback"
            `Quick
            test_read_sse_cpu_callback_cancellable
        ] )
    ]
;;
