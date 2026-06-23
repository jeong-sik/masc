(* RFC-0203 Phase 1.2b.2 + 1.4b, RFC-0287 — TLS+WSS connection for the
   Discord Gateway, driven by the masc-owned ws-direct stack.

   masc still owns the TLS setup (DNS, TCP connect, [Tls_eio.client_of_flow])
   and hands the resulting flow to [Ws_direct_eio.Client], which performs the
   RFC 6455 §4 opening handshake and drives the frame loop. ws-direct speaks a
   plain [Eio.Flow.two_way], so it composes with a TLS flow (which has no fd)
   directly — removing the impedance that made the httpun-ws client unusable
   here (the httpun-ws client constructor wants an fd-backed socket; see
   RFC-0203 §Why and RFC-0287).

   Lifecycle (1.4b, unchanged): the socket, TLS flow, and ws-direct driver
   fibers all live inside a per-session [Eio.Switch] created inside an outer
   fork. [close] resolves a promise, which lets that inner [Switch.run]
   return, which cancels the driver fibers and closes the socket + TLS flow.
   No fiber leaks across reconnect cycles.

   The ws-direct Endpoint reassembles fragments, validates UTF-8, and
   auto-replies to Ping, so the former per-frame opcode handling collapses
   into a typed [inbound] event pushed onto an [Eio.Stream]; [read] is an
   [Eio.Stream.take] translated back into the exceptions the gateway reader
   already handles. *)

module Ws_endpoint = Ws_direct_core.Endpoint
module Ws_wsd = Ws_direct_core.Endpoint.Wsd
module Ws_msg = Ws_direct_core.Connection.Message

(* RNG init is required for both the TLS handshake (ephemeral key exchange)
   and ws-direct's per-frame masking key (its default [random] is
   [Mirage_crypto_rng.generate], which needs a seeded generator).
   [use_default] only installs if no generator is set, so repeated calls are
   safe. *)
let rng_initialized = ref false

let init_rng () =
  if not !rng_initialized
  then (
    Mirage_crypto_rng_unix.use_default ();
    rng_initialized := true)
;;

(** Application-level inbound event delivered to the gateway reader. The
    endpoint auto-replies to Ping, treats Pong observationally, and reassembles
    fragments, so only complete data messages and the peer Close surface. *)
type inbound =
  | Message of string
  | Closed of
      { code : int
      ; reason : string
      }

(* Event carried on the internal bridge stream: the public [inbound] cases
   plus the two terminal signals that [read] turns into the exceptions the
   gateway reader already maps ([End_of_file] -> Wss_closed 1006, any other ->
   Wss_closed 1011). *)
type event =
  | Ev_message of string
  | Ev_closed of
      { code : int
      ; reason : string
      }
  | Ev_eof
  | Ev_error of string

type conn =
  { wsd : Ws_wsd.t
  ; events : event Eio.Stream.t
  ; close : unit -> unit
  }

(* RFC 6455 §7.4: a Close frame with no body maps to status code 1005
   ("no status received"). The endpoint surfaces that as [code = None]. *)
let close_code_no_status = 1005

(* Bounded so a slow consumer applies TCP backpressure (the reader fiber
   blocks in [on_message] -> the socket stops being drained) rather than
   buffering inbound frames without limit. The gateway reader drains promptly. *)
let inbound_capacity = 64

let client_tls_config () =
  match Ca_certs.authenticator () with
  | Error (`Msg m) -> failwith ("discord_wss_connection: ca-certs: " ^ m)
  | Ok authenticator ->
    (match Tls.Config.client ~authenticator () with
     | Error (`Msg m) -> failwith ("discord_wss_connection: Tls.Config.client: " ^ m)
     | Ok cfg -> cfg)
;;

let host_domain host =
  match Domain_name.of_string host with
  | Error _ -> None
  | Ok dn ->
    (match Domain_name.host dn with
     | Error _ -> None
     | Ok h -> Some h)
;;

let resource_of_uri uri =
  let path =
    match Uri.path uri with
    | "" -> "/"
    | p -> p
  in
  match Uri.verbatim_query uri with
  | None -> path
  | Some q -> path ^ "?" ^ q
;;

(* Translate the next bridge event into the public [inbound], raising the same
   exceptions the gateway reader already handles. Exposed for unit tests. *)
let read_event = function
  | Ev_message s -> Message s
  | Ev_closed { code; reason } -> Closed { code; reason }
  | Ev_eof -> raise End_of_file
  | Ev_error msg -> failwith msg
;;

(* Map one endpoint message to a bridge event. Discord with compress=false
   sends only Text on application frames; a Binary frame is unexpected and the
   gateway FSM has no use for it, so it is dropped (the prior websocket-based
   path ignored Binary the same way). Exposed for unit tests. *)
let message_to_event (m : Ws_msg.t) =
  match m.Ws_msg.kind with
  | Ws_msg.Text -> Some (Ev_message (Bigstringaf.to_string m.Ws_msg.payload))
  | Ws_msg.Binary -> None
;;

let close_to_event ~code ~reason =
  Ev_closed { code = Option.value code ~default:close_code_no_status; reason }
;;

(* Builds the session-local resources (socket, TLS flow, ws-direct driver
   fibers) on the given inner switch. Returns the writer descriptor and the
   inbound event stream; [close] is wired by the outer [connect] via the
   promise pair. *)
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
      failwith ("discord_wss_connection: getaddrinfo returned no result for " ^ host)
    | a :: _ -> a
  in
  let socket = Eio.Net.connect ~sw net addr in
  let tls_cfg = client_tls_config () in
  let host_dn = host_domain host in
  let flow = Tls_eio.client_of_flow tls_cfg ?host:host_dn socket in
  let events = Eio.Stream.create inbound_capacity in
  let builder (_wsd : Ws_wsd.t) =
    Ws_endpoint.handlers
      ~on_message:(fun (m : Ws_msg.t) ->
        match message_to_event m with
        | Some ev -> Eio.Stream.add events ev
        | None -> ())
      ~on_close:(fun ~code ~reason -> Eio.Stream.add events (close_to_event ~code ~reason))
      ~on_error:(fun msg -> Eio.Stream.add events (Ev_error msg))
      ~on_eof:(fun () -> Eio.Stream.add events Ev_eof)
      ()
  in
  let wsd = Ws_direct_eio.Client.connect ~sw ~host ~resource flow builder in
  wsd, events
;;

let connect ~sw ~env ~url =
  init_rng ();
  let setup_promise, setup_resolver = Eio.Promise.create () in
  let close_signal, close_trigger = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run (fun session_sw ->
      let result =
        try Ok (build_session ~sw:session_sw ~env ~url) with
        | e -> Error e
      in
      Eio.Promise.resolve setup_resolver result;
      match result with
      | Error _ -> () (* let session_sw exit; socket/flow get released *)
      | Ok _ -> Eio.Promise.await close_signal));
  match Eio.Promise.await setup_promise with
  | Error e -> raise e
  | Ok (wsd, events) ->
    let close () =
      match Eio.Promise.peek close_signal with
      | Some () -> () (* idempotent *)
      | None -> Eio.Promise.resolve close_trigger ()
    in
    { wsd; events; close }
;;

let read c = read_event (Eio.Stream.take c.events)
let send_text c s = Ws_wsd.send_text c.wsd s
let close c = c.close ()

module For_testing = struct
  type nonrec inbound = inbound =
    | Message of string
    | Closed of
        { code : int
        ; reason : string
        }

  type nonrec event = event =
    | Ev_message of string
    | Ev_closed of
        { code : int
        ; reason : string
        }
    | Ev_eof
    | Ev_error of string

  let read_event = read_event
  let message_to_event = message_to_event
  let close_to_event = close_to_event
  let close_code_no_status = close_code_no_status
end
