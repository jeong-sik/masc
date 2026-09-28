(* Guest relay session: dial, hello, and drive the join. Mirrors the
   discord_wss_connection session shape (session switch + close signal +
   fail-to-teardown), but every failure is a closed variant: this is a
   guest CLI, and a failwith would print a backtrace at an operator who
   only mistyped a link. *)

module Ws_endpoint = Ws_direct_core.Endpoint
module Ws_wsd = Ws_direct_core.Endpoint.Wsd
module Ws_msg = Ws_direct_core.Connection.Message

type connect_error =
  | Dial_failed of string
  | Tls_failed of string
  | Handshake_failed of string

let connect_error_to_string = function
  | Dial_failed detail -> "relay unreachable: " ^ detail
  | Tls_failed detail -> "relay TLS failed: " ^ detail
  | Handshake_failed detail -> "relay handshake failed: " ^ detail
;;

type send_error =
  | View_only
  | Not_connected of string

let send_error_to_string = function
  | View_only -> "view-only link: steering needs the control link"
  | Not_connected detail -> "not connected: " ^ detail
;;

type session_event =
  | Frame_event of Collab_guest_join.event
  | Transport_closed of {
      code : int;
      reason : string;
    }

type inbound =
  | Message of string
  | Closed of {
      code : int;
      reason : string;
    }
  | Eof
  | Driver_error of string

let inbound_capacity = 64
let close_code_no_status = 1006

type handle = {
  wsd : Ws_wsd.t;
  target : Collab_guest_join.target;
  close_signal : unit Eio.Promise.t;
  close_trigger : unit Eio.Promise.u;
}

let capability handle = handle.target.Collab_guest_join.capability

(* A requested close is not an error: failing the session switch with
   this cancels the driver and reader, and the fork's handler swallows
   it. A plain return would only wait for them. *)
exception Session_closed

let tls_config () =
  match Ca_certs.authenticator () with
  | Error (`Msg message) -> Error ("ca-certs: " ^ message)
  | Ok authenticator -> (
    match Tls.Config.client ~authenticator () with
    | Error (`Msg message) -> Error ("tls client config: " ^ message)
    | Ok config -> Ok config)
;;

let dial ws_secure ~sw ~env ~target =
  let net = Eio.Stdenv.net env in
  let addr =
    match
      Eio.Net.getaddrinfo_stream net target.Collab_guest_join.ws_host
        ~service:(string_of_int target.Collab_guest_join.ws_port)
    with
    | [] -> Error `No_address
    | addr :: _ -> Ok addr
  in
  match addr with
  | Error `No_address -> Error (Dial_failed "name did not resolve")
  | Ok addr -> (
    match
      (try Ok (Eio.Net.connect ~sw net addr) with
       | (Eio.Io _ as exn) -> Error (Dial_failed (Printexc.to_string exn)))
    with
    | Error _ as error -> error
    | Ok socket when not ws_secure ->
      Ok (socket :> Eio.Flow.two_way_ty Eio.Resource.t)
    | Ok socket -> (
      match tls_config () with
      | Error detail -> Error (Tls_failed detail)
      | Ok config -> (
        let host_dn =
          match Domain_name.of_string target.Collab_guest_join.ws_host with
          | Error message -> Error message
          | Ok dn -> Domain_name.host dn
        in
        match host_dn with
        | Error (`Msg message) -> Error (Tls_failed ("bad SNI host: " ^ message))
        | Ok host -> (
          match
            (try Ok (Tls_eio.client_of_flow config ~host socket) with
             | (Eio.Io _ as exn) -> Error (Tls_failed (Printexc.to_string exn)))
          with
          | Error _ as error -> error
          | Ok tls_flow -> Ok (tls_flow :> Eio.Flow.two_way_ty Eio.Resource.t)))))
;;

let write_token_b64 target =
  match target.Collab_guest_join.write_token with
  | None -> None
  | Some token ->
    Some (Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet token)
;;

(* Seal one guest frame for the host (peer 0; the relay rewrites the
   sender). Packing peer 0 cannot fail. *)
let send_frame wsd ~key frame =
  let sealed = Collab_seal.seal key (Collab_frame.frame_to_string frame) in
  match Collab_envelope.pack ~peer:Collab_envelope.broadcast_peer sealed with
  | Error (Collab_envelope.Peer_id_out_of_range _) -> ()
  | Ok envelope -> Ws_wsd.send_binary wsd envelope
;;

let guard_send handle f =
  if Ws_wsd.is_closed handle.wsd
  then Error (Not_connected "the socket is closed")
  else (
    try
      f ();
      Ok ()
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Not_connected (Printexc.to_string exn)))
;;

let require_control handle =
  match capability handle with
  | Collab_link.Control -> Ok ()
  | Collab_link.View -> Error View_only
;;

let send_prompt handle text =
  match require_control handle with
  | Error _ as error -> error
  | Ok () ->
    guard_send handle (fun () ->
        send_frame handle.wsd ~key:handle.target.Collab_guest_join.key
          (Collab_frame.Prompt text))
;;

let send_abort handle =
  match require_control handle with
  | Error _ as error -> error
  | Ok () ->
    guard_send handle (fun () ->
        send_frame handle.wsd ~key:handle.target.Collab_guest_join.key Collab_frame.Abort)
;;

let fetch_transcript handle ~req_id ~max_bytes =
  guard_send handle (fun () ->
      send_frame handle.wsd ~key:handle.target.Collab_guest_join.key
        (Collab_frame.Fetch_transcript { req_id; max_bytes }))
;;

let close handle =
  match Eio.Promise.peek handle.close_signal with
  | Some () -> ()
  | None -> Eio.Promise.resolve handle.close_trigger ()
;;

let deliver ~target ~join on_event payload =
  (* Anything that does not unseal, unpack, and parse is dropped: an
     honest relay only forwards host-sealed frames, and a forgery that
     fails the tag carries nothing to show. *)
  match Collab_envelope.unpack payload with
  | None -> ()
  | Some (_, sealed) -> (
    match Collab_seal.open_sealed target.Collab_guest_join.key sealed with
    | Error _ -> ()
    | Ok json -> (
      match Collab_frame.frame_of_string json with
      | None -> ()
      | Some frame ->
        List.iter
          (fun event -> on_event (Frame_event event))
          (Collab_guest_join.feed join frame)))
;;

let drive_reader ~target ~join ~events ~on_event =
  let rec loop () =
    match Eio.Stream.take events with
    | Message payload ->
      deliver ~target ~join on_event payload;
      loop ()
    | Closed { code; reason } -> on_event (Transport_closed { code; reason })
    | Eof -> on_event (Transport_closed { code = close_code_no_status; reason = "eof" })
    | Driver_error detail ->
      on_event (Transport_closed { code = close_code_no_status; reason = detail })
  in
  loop ()
;;

(* The Host header carries the port unless it is the scheme default;
   proxies and virtual hosts route on it. *)
let host_header target =
  let default = if target.Collab_guest_join.ws_secure then 443 else 80 in
  if target.Collab_guest_join.ws_port = default
  then target.Collab_guest_join.ws_host
  else
    Printf.sprintf "%s:%d" target.Collab_guest_join.ws_host target.Collab_guest_join.ws_port
;;

let build_session ~sw ~env ~target =
  match dial target.Collab_guest_join.ws_secure ~sw ~env ~target with
  | Error _ as error -> error
  | Ok flow ->
    let events = Eio.Stream.create inbound_capacity in
    let builder (_wsd : Ws_wsd.t) =
      Ws_endpoint.handlers
        ~on_message:(fun (message : Ws_msg.t) ->
          match message.Ws_msg.kind with
          | Ws_msg.Binary ->
            Eio.Stream.add events
              (Message (Bigstringaf.to_string message.Ws_msg.payload))
          | Ws_msg.Text -> ())
        ~on_close:(fun ~code ~reason ->
          let code = Option.value code ~default:close_code_no_status in
          Eio.Stream.add events (Closed { code; reason }))
        ~on_error:(fun detail -> Eio.Stream.add events (Driver_error detail))
        ~on_eof:(fun () -> Eio.Stream.add events Eof)
        ()
    in
    (try
       let wsd =
         Ws_direct_eio.Client.connect ~sw
           ~clock:(Eio.Stdenv.clock env)
           ~host:(host_header target)
           ~resource:(Collab_guest_join.resource target)
           flow builder
       in
       Ok (wsd, events)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Failure detail -> Error (Handshake_failed detail)
     | (Eio.Io _ as exn) -> Error (Handshake_failed (Printexc.to_string exn)))
;;

let connect ~sw ~env ~target ~label ~on_event =
  Crypto_rng.ensure_default ();
  let setup_promise, setup_resolver = Eio.Promise.create () in
  let close_signal, close_trigger = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      (try
         Eio.Switch.run (fun session_sw ->
             let built =
               try build_session ~sw:session_sw ~env ~target with
               | Eio.Cancel.Cancelled _ as exn -> raise exn
               | exn -> Error (Handshake_failed (Printexc.to_string exn))
             in
             Eio.Promise.resolve setup_resolver built;
             Result.iter
               (fun (wsd, events) ->
                 (* The reader lives on the session switch: [close] fails
                    it together with the driver, so no teardown path can
                    leave a fiber blocked on the stream. The join is the
                    reader fiber's alone; the caller handle only sends. *)
                 let join = Collab_guest_join.create () in
                 Eio.Fiber.fork ~sw:session_sw (fun () ->
                     drive_reader ~target ~join ~events ~on_event);
                 Eio.Promise.await close_signal;
                 Eio.Switch.fail session_sw Session_closed)
               built)
       with Session_closed -> ()));
  match Eio.Promise.await setup_promise with
  | Error _ as error -> error
  | Ok (wsd, _events) ->
    let handle = { wsd; target; close_signal; close_trigger } in
    (try
       send_frame wsd ~key:target.Collab_guest_join.key
         (Collab_frame.Hello
            { proto = Collab_wire.proto_version
            ; write_token = write_token_b64 target
            ; label
            });
       Ok handle
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       close handle;
       Error (Handshake_failed (Printexc.to_string exn)))
;;
