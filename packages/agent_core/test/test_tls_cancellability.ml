(** Agent Core contract §10.1 regression guard: TLS read cancellability.

    [test_eio_cancellability.ml] proves [Eio.Time.with_timeout_exn]
    interrupts [Eio.Buf_read.line] over a RAW TCP loopback flow. Every
    production https provider (ollama.com, api.anthropic.com, ...) runs
    the same [Buf_read.line] over a TLS-wrapped flow. Agent Core contract §10.1
    flags it as medium-confidence/unverified that [with_timeout_exn]
    cancellation actually propagates into a [single_read] blocked inside
    a TLS session — the TLS layer may buffer or hold the read in a way
    that does not propagate cancellation to the underlying socket.

    If TLS read cancellation does NOT propagate, the AGENT_CORE stream-idle
    deadline (Agent Core contract F1) is armed at the typed-error layer but the
    physical interrupt never lands — a stalled https stream hangs past
    the configured idle deadline. This test wraps the slow-drip server
    in TLS (self-signed cert) and asserts the timeout still fires within
    tolerance, so a future Eio/tls-eio bump that breaks TLS cancellation
    fails CI instead of silently regressing into a keeper hang.

    Budget 2.0s; overshoot must stay under [overshoot_tolerance_s]
    (slightly higher than the raw-TCP test to absorb TLS handshake +
    record-buffering overhead). *)

let timeout_budget_s = 2.0
let overshoot_tolerance_s = 0.7

(* ── self-signed cert/key (x509 1.0.6 / mirage-crypto 1.2.0) ────────── *)

let make_self_signed () : X509.Certificate.t * X509.Private_key.t =
  let key = X509.Private_key.generate ~bits:2048 `RSA in
  let dn =
    X509.Distinguished_name.[ Relative_distinguished_name.singleton (CN "localhost") ]
  in
  let csr =
    match X509.Signing_request.create dn key with
    | Ok c -> c
    | Error (`Msg m) -> failwith ("csr create: " ^ m)
  in
  let valid_from = Ptime.epoch in
  let valid_until =
    match Ptime.of_float_s 4102444800. (* 2100-01-01 *) with
    | Some t -> t
    | None -> Ptime.epoch
  in
  match X509.Signing_request.sign csr ~valid_from ~valid_until key dn with
  | Ok cert -> cert, key
  | Error _ -> failwith "self-signed cert sign failed"
;;

let server_config (cert, key) : Tls.Config.server =
  match Tls.Config.server ~certificates:(`Single ([ cert ], key)) () with
  | Ok s -> s
  | Error (`Msg m) -> failwith ("tls server config: " ^ m)
;;

(* Null authenticator: this is a cancellation test, not a trust test —
   accept the self-signed peer unconditionally. *)
let client_config () : Tls.Config.client =
  match Tls.Config.client ~authenticator:(fun ?ip:_ ~host:_ _ -> Ok None) () with
  | Ok c -> c
  | Error (`Msg m) -> failwith ("tls client config: " ^ m)
;;

let localhost_name = Domain_name.(host_exn (of_string_exn "localhost"))

(* ── TLS slow-drip line server ─────────────────────────────────────── *)

(* Accept TCP, complete a server-side TLS handshake, read the request
   header lines, then send an SSE response header and drip [payload]
   every [gap_ms] forever over the TLS flow. *)
let tls_line_server ~sw ~net port ~gap_ms ~payload certkey =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let socket = Eio.Net.listen ~sw ~backlog:5 ~reuse_addr:true net addr in
  let cfg = server_config certkey in
  Eio.Fiber.fork ~sw (fun () ->
    let rec accept_loop () =
      Eio.Net.accept_fork
        ~sw
        socket
        ~on_error:(fun _ -> ())
        (fun flow _addr ->
           try
             let tls = Tls_eio.server_of_flow cfg flow in
             let buf = Eio.Buf_read.of_flow tls ~max_size:8192 in
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
             Eio.Flow.copy_string resp tls;
             for _ = 1 to 100_000 do
               Eio.Flow.copy_string payload tls;
               Eio_unix.sleep (float_of_int gap_ms /. 1000.0)
             done
           with
           | _ -> ());
      accept_loop ()
    in
    try accept_loop () with
    | _ -> ())
;;

let tls_connect_and_consume_headers ~sw ~net port =
  let saddr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let conn = Eio.Net.connect ~sw net saddr in
  let tls = Tls_eio.client_of_flow (client_config ()) ~host:localhost_name conn in
  let req = "GET /drip HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" in
  Eio.Flow.copy_string req tls;
  let reader = Eio.Buf_read.of_flow tls ~max_size:1_000_000 in
  let rec drain () =
    let line = Eio.Buf_read.line reader in
    if line = "" then () else drain ()
  in
  drain ();
  reader
;;

(* read_sse loop structure (mirrors lib/llm_provider/http_client.ml). *)
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
      "[%s] TLS cancellation regression: elapsed=%.3fs budget=%.3fs overshoot=%.3fs > \
       tolerance=%.3fs"
      label
      elapsed
      budget
      overshoot
      overshoot_tolerance_s
;;

let with_rng_and_server ~port ~payload ~gap_ms ~label callback =
  Eio_main.run
  @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  let net = env#net in
  let clock = env#clock in
  let certkey = make_self_signed () in
  Eio.Switch.run (fun sw ->
    tls_line_server ~sw ~net port ~gap_ms ~payload certkey;
    Eio_unix.sleep 0.3;
    Eio.Switch.run (fun inner_sw ->
      let reader = tls_connect_and_consume_headers ~sw:inner_sw ~net port in
      callback ~clock ~reader ~label);
    raise Exit)
;;

(* Test 1: slow byte drip over TLS, no newline.
   The TLS server holds the connection and produces 1 byte/sec with no
   line terminator, so [Buf_read.line] blocks in single_read inside the
   TLS session. with_timeout_exn must interrupt it. *)
let test_tls_buf_read_line_cancellable () =
  try
    with_rng_and_server
      ~port:18851
      ~payload:"x"
      ~gap_ms:1000
      ~label:"tls + buf_read.line + slow drip"
      (fun ~clock ~reader ~label ->
         measure_timeout ~clock ~budget:timeout_budget_s ~label (fun () ->
           ignore (Eio.Buf_read.line reader)))
  with
  | Exit -> ()
;;

(* Test 2: fast SSE-style stream over TLS forever; the read_sse loop
   must remain cancellable across the TLS flow. *)
let test_tls_read_sse_cancellable () =
  try
    with_rng_and_server
      ~port:18852
      ~payload:"data: x\n"
      ~gap_ms:100
      ~label:"tls + read_sse + fast stream"
      (fun ~clock ~reader ~label ->
         measure_timeout ~clock ~budget:timeout_budget_s ~label (fun () ->
           read_sse_loop reader ~on_data:(fun _ -> ())))
  with
  | Exit -> ()
;;

let () =
  let open Alcotest in
  run
    "tls_cancellability"
    [ ( "tls_body_read_cancellation"
      , [ test_case
            "tls + buf_read.line + slow drip"
            `Quick
            test_tls_buf_read_line_cancellable
        ; test_case "tls + read_sse + fast stream" `Quick test_tls_read_sse_cancellable
        ] )
    ]
;;
