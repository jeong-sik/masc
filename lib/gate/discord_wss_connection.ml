(* RFC-0203 Phase 1.2b.2 + 1.4b — TLS+WSS handshake with explicit
   close.

   Mirrors discordml's [Httpx.Ws.connect'] reduced to our single use
   case (Discord Gateway, system trust store, no extra headers). See
   the .mli header for the stack-choice rationale.

   Lifecycle (1.4b): the socket, TLS flow, and writer fiber all live
   inside a per-session [Eio.Switch] that is created inside an outer
   fork. Closing the connection resolves a promise, which lets that
   inner [Switch.run] return, which in turn cancels child fibers and
   closes the socket. No fiber leaks across reconnect cycles. *)

(* RNG init is required for both TLS handshake (ephemeral key
   exchange) and the Sec-WebSocket-Key nonce. [use_default] is safe
   to call multiple times — it only installs if no generator is set. *)
let rng_initialized = ref false
let init_rng () =
  if not !rng_initialized then begin
    Mirage_crypto_rng_unix.use_default ();
    rng_initialized := true
  end

module Ws_io = Websocket.Make (Cohttp_eio.Private.IO)

let random_string n =
  Mirage_crypto_rng.generate n

type conn = {
  read_frame : unit -> Websocket.Frame.t;
  write_frame : Websocket.Frame.t -> unit;
  close : unit -> unit;
}

let client_tls_config () =
  match Ca_certs.authenticator () with
  | Error (`Msg m) -> failwith ("discord_wss_connection: ca-certs: " ^ m)
  | Ok authenticator ->
    match Tls.Config.client ~authenticator () with
    | Error (`Msg m) -> failwith ("discord_wss_connection: Tls.Config.client: " ^ m)
    | Ok cfg -> cfg

let host_domain host =
  match Domain_name.of_string host with
  | Error _ -> None
  | Ok dn ->
    (match Domain_name.host dn with
     | Error _ -> None
     | Ok h -> Some h)

let resource_of_uri uri =
  let path = match Uri.path uri with "" -> "/" | p -> p in
  match Uri.verbatim_query uri with
  | None -> path
  | Some q -> path ^ "?" ^ q

let drain_handshake req ic oc nonce =
  Ws_io.Request.write ~flush:true (fun _ -> ()) req oc;
  let resp =
    match Ws_io.Response.read ic with
    | `Ok r -> r
    | `Eof -> raise End_of_file
    | `Invalid s -> failwith ("ws handshake: invalid response: " ^ s)
  in
  let status = Cohttp.Response.status resp in
  if Cohttp.Code.(is_error (code_of_status status)) then
    failwith
      ("ws handshake: error status "
       ^ Cohttp.Code.string_of_status status);
  if Cohttp.Response.version resp <> `HTTP_1_1 then
    failwith "ws handshake: response is not HTTP/1.1";
  if status <> `Switching_protocols then
    failwith "ws handshake: status is not 101 Switching Protocols";
  let headers = Cohttp.Response.headers resp in
  (match Cohttp.Header.get headers "upgrade" with
   | Some s when String.lowercase_ascii s = "websocket" -> ()
   | Some other ->
     failwith ("ws handshake: Upgrade header has wrong value: " ^ other)
   | None ->
     failwith "ws handshake: Upgrade header missing");
  if not (Websocket.upgrade_present headers) then
    failwith "ws handshake: required upgrade headers missing";
  (match Cohttp.Header.get headers "sec-websocket-accept" with
   | Some accept
     when accept
          = Websocket.b64_encoded_sha1sum
              (nonce ^ Websocket.websocket_uuid) ->
     ()
   | Some _ -> failwith "ws handshake: Sec-WebSocket-Accept mismatch"
   | None -> failwith "ws handshake: Sec-WebSocket-Accept header missing")

(* Builds the session-local resources (socket, TLS flow, writer fiber)
   on the given inner switch. Returns the read/write closures only —
   close is wired by the outer [connect] via the promise pair. *)
let build_session ~sw ~env ~url =
  let uri = Uri.of_string url in
  (match Uri.scheme uri with
   | Some "wss" -> ()
   | Some other ->
     failwith ("discord_wss_connection: only wss supported, got: " ^ other)
   | None -> failwith "discord_wss_connection: url has no scheme");
  let host =
    match Uri.host uri with
    | Some h -> h
    | None -> failwith "discord_wss_connection: url has no host"
  in
  let port = Option.value (Uri.port uri) ~default:443 in
  let resource = resource_of_uri uri in

  let net = Eio.Stdenv.net env in
  let addr =
    match Eio.Net.getaddrinfo_stream net host ~service:(string_of_int port) with
    | [] ->
      failwith
        ("discord_wss_connection: getaddrinfo returned no result for " ^ host)
    | a :: _ -> a
  in
  let socket = Eio.Net.connect ~sw net addr in
  let tls_cfg = client_tls_config () in
  let host_dn = host_domain host in
  let flow = Tls_eio.client_of_flow tls_cfg ?host:host_dn socket in

  let nonce = Base64.encode_exn (random_string 16) in
  let headers =
    Cohttp.Header.of_list
      [ "Host", host
      ; "Upgrade", "websocket"
      ; "Connection", "Upgrade"
      ; "Sec-WebSocket-Key", nonce
      ; "Sec-WebSocket-Version", "13"
      ]
  in
  let req =
    Cohttp.Request.make ~meth:`GET ~headers (Uri.of_string resource)
  in

  let ic = Eio.Buf_read.of_flow ~max_size:max_int flow in
  Eio.Buf_write.with_flow flow (fun oc ->
    drain_handshake req ic oc nonce);

  let write_queue = Eio.Stream.create 16 in
  let writer () =
    try
      let rec loop () =
        let frame = Eio.Stream.take write_queue in
        let buf = Buffer.create 128 in
        Ws_io.write_frame_to_buf ~mode:(Client random_string) buf frame;
        Eio.Buf_write.with_flow flow (fun oc ->
          Eio.Buf_write.string oc (Buffer.contents buf));
        loop ()
      in
      loop ()
    with Eio.Io _ -> ()
  in
  Eio.Fiber.fork ~sw writer;

  let read_frame () =
    Eio.Buf_write.with_flow flow (fun oc ->
      Ws_io.make_read_frame ~mode:(Client random_string) ic oc ())
  in
  let write_frame frame = Eio.Stream.add write_queue frame in
  (read_frame, write_frame)

let connect ~sw ~env ~url =
  init_rng ();
  let setup_promise, setup_resolver = Eio.Promise.create () in
  let close_signal, close_trigger = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run (fun session_sw ->
      let result =
        try Ok (build_session ~sw:session_sw ~env ~url)
        with e -> Error e
      in
      Eio.Promise.resolve setup_resolver result;
      match result with
      | Error _ -> ()  (* let session_sw exit; socket/flow get released *)
      | Ok _ -> Eio.Promise.await close_signal));
  match Eio.Promise.await setup_promise with
  | Error e -> raise e
  | Ok (read_frame, write_frame) ->
    let close () =
      match Eio.Promise.peek close_signal with
      | Some () -> ()  (* idempotent *)
      | None -> Eio.Promise.resolve close_trigger ()
    in
    { read_frame; write_frame; close }

let read c = c.read_frame ()
let write c frame = c.write_frame frame
let close c = c.close ()
