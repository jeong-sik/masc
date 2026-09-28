module Endpoint = Ws_direct_core.Endpoint
module Message = Ws_direct_core.Connection.Message
module Wsd = Ws_direct_core.Endpoint.Wsd

(* Resource bounds: 512 KiB snapshot chunks (stack 3) plus seal overhead and
   envelope fit comfortably; anything larger is a buggy or hostile peer. *)
let max_message_bytes = 1_048_576
let max_frame_bytes = 262_144

type connection = {
  wsd : Wsd.t;
  write_mutex : Stdlib.Mutex.t;
}

type room_key = Collab_relay.room_id
type guest_key = Collab_relay.room_id * Collab_relay.peer

type local_host = {
  on_frame : string -> unit;
  on_peer_joined : Collab_relay.peer -> unit;
  on_peer_left : Collab_relay.peer -> unit;
}

type host_endpoint =
  | Socket of connection
  | Local of local_host

let relay = Collab_relay.create ()
let relay_mutex = Stdlib.Mutex.create ()
let host_conns : (room_key, host_endpoint) Hashtbl.t = Hashtbl.create 16
let guest_conns : (guest_key, connection) Hashtbl.t = Hashtbl.create 64

let with_relay f = Stdlib.Mutex.protect relay_mutex f

(* One wire op at a time per connection; wire ops never nest. A failed send
   to a gone peer is routine (the other side already closed): anything but
   Eio cancellation is logged at debug and swallowed. *)
let attempt_wire_op conn label op =
  Stdlib.Mutex.protect conn.write_mutex (fun () ->
      if Wsd.is_closed conn.wsd
      then ()
      else (
        match op conn.wsd with
        | () -> ()
        | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
        | exception ex ->
          Log.Server.debug
            "collab %s failed: %s"
            label
            (Printexc.to_string ex)))
;;

let send_text conn text =
  attempt_wire_op conn "send_text" (fun wsd -> Wsd.send_text wsd text)
;;

let send_binary conn bytes =
  attempt_wire_op conn "send_binary" (fun wsd -> Wsd.send_binary wsd bytes)
;;

let send_close conn ~code ~reason =
  attempt_wire_op conn "send_close" (fun wsd ->
      Wsd.send_close wsd ~code ~reason ())
;;

(* A raising host callback must not kill the guest fiber that triggered it.
   Cancellation still propagates; anything else is logged and dropped. *)
let run_host_callback label f =
  match f () with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex ->
    Log.Server.debug
      "collab host callback %s failed: %s"
      label
      (Printexc.to_string ex)
;;

let host_send_binary host envelope =
  match host with
  | Socket conn -> send_binary conn envelope
  | Local local ->
    run_host_callback "on_frame" (fun () -> local.on_frame envelope)
;;

let host_peer_joined host peer =
  match host with
  | Socket conn ->
    send_text conn (Collab_wire.control_json (Collab_wire.Peer_joined { peer }))
  | Local local ->
    run_host_callback "on_peer_joined" (fun () -> local.on_peer_joined peer)
;;

let host_peer_left host peer =
  match host with
  | Socket conn ->
    send_text conn (Collab_wire.control_json (Collab_wire.Peer_left { peer }))
  | Local local ->
    run_host_callback "on_peer_left" (fun () -> local.on_peer_left peer)
;;

let drop_reason_label = function
  | Collab_relay.Malformed_envelope -> "malformed envelope"
  | Collab_relay.Route_no_such_room -> "unknown room"
  | Collab_relay.Route_guest_not_in_room { peer } ->
    Printf.sprintf "guest %d not in room" peer
  | Collab_relay.Sender_id_out_of_range { peer } ->
    Printf.sprintf "sender id %d out of range" peer
;;

(* Shared teardown for socket hosts (their close) and local hosts
   ({!host_leave_local}). Idempotent: a second call finds no room and no
   guests. *)
let close_room ~room =
  let guests =
    with_relay (fun () ->
        let peers = Collab_relay.host_left relay ~room in
        Hashtbl.remove host_conns room;
        List.filter_map
          (fun peer ->
            match Hashtbl.find_opt guest_conns (room, peer) with
            | None -> None
            | Some conn ->
              Hashtbl.remove guest_conns (room, peer);
              Some conn)
          peers)
  in
  let notice = Collab_wire.control_json Collab_wire.Room_closed in
  let code = Collab_wire.close_code Collab_wire.Close_room_closed in
  let reason = Collab_wire.close_message Collab_wire.Close_room_closed in
  List.iter
    (fun conn ->
      send_text conn notice;
      send_close conn ~code ~reason)
    guests
;;

(* Removes one guest from both tables. True when the guest was actually
   present. Split from the peer-left notify so the upgrade-failure path can
   unwind a join that was never announced (F6: no left-without-join).
   [_locked] assumes the relay mutex is held (the mutex is not reentrant). *)
let remove_guest_locked ~room ~peer =
  let departure = Collab_relay.guest_left relay ~room ~peer in
  Hashtbl.remove guest_conns (room, peer);
  match departure with
  | Collab_relay.Guest_departed -> true
  | Collab_relay.Leave_no_such_room | Collab_relay.Leave_no_such_guest -> false
;;

let remove_guest ~room ~peer =
  with_relay (fun () -> remove_guest_locked ~room ~peer)
;;

(* F7: teardown is keyed by (room, peer), not connection identity. Peer ids
   restart at 1 when a room id is recreated, so a delayed duplicate terminal
   callback could destroy a new generation's guest. Same-room-id reuse never
   happens today (fresh id per /collab); recheck with a generation counter or
   conn-identity compare-and-remove when host-rejoin-same-link lands. *)
let teardown_guest ~room ~peer =
  let departed = remove_guest ~room ~peer in
  if departed
  then (
    let host = with_relay (fun () -> Hashtbl.find_opt host_conns room) in
    match host with
    | None -> ()
    | Some host -> host_peer_left host peer)
;;

let host_send_local ~room envelope =
  let delivery =
    with_relay (fun () ->
        Collab_relay.route relay ~room ~sender:Collab_relay.Host ~envelope)
  in
  match delivery with
  | Collab_relay.To_guests { peers; envelope } ->
    let conns =
      with_relay (fun () ->
          List.filter_map
            (fun peer -> Hashtbl.find_opt guest_conns (room, peer))
            peers)
    in
    List.iter (fun conn -> send_binary conn envelope) conns
  | Collab_relay.To_host _ ->
    Log.Server.debug "collab host frame routed to host; dropping"
  | Collab_relay.Drop { reason } ->
    Log.Server.debug "collab host frame dropped: %s" (drop_reason_label reason)
;;

let on_guest_message ~room ~peer envelope =
  let delivery =
    with_relay (fun () ->
        Collab_relay.route
          relay
          ~room
          ~sender:(Collab_relay.Guest peer)
          ~envelope)
  in
  match delivery with
  | Collab_relay.To_host { envelope } ->
    let host = with_relay (fun () -> Hashtbl.find_opt host_conns room) in
    (match host with
     | None -> Log.Server.debug "collab guest frame dropped: host gone"
     | Some host -> host_send_binary host envelope)
  | Collab_relay.To_guests _ ->
    Log.Server.debug "collab guest frame routed to guests; dropping"
  | Collab_relay.Drop { reason } ->
    Log.Server.debug
      "collab guest %d frame dropped: %s"
      peer
      (drop_reason_label reason)
;;

let on_binary_message on_binary msg =
  match msg.Message.kind with
  | Message.Binary -> on_binary (Bigstringaf.to_string msg.Message.payload)
  | Message.Text -> ()
;;

let respond_upgrade_error reqd msg =
  Http_server_eio.Response.text ~status:`Bad_request msg reqd
;;

let accept_host ~upgrade reqd ~room =
  let handlers =
    Endpoint.handlers
      ~on_message:(on_binary_message (host_send_local ~room))
      ~on_close:(fun ~code:_ ~reason:_ -> close_room ~room)
      ~on_error:(fun msg ->
        Log.Server.debug "collab host conn error: %s" msg;
        close_room ~room)
      ~on_eof:(fun () -> close_room ~room)
      ()
  in
  match
    Server_mcp_transport_ws.respond_and_drive_upgrade
      ~upgrade
      ~reqd
      ~max_message:max_message_bytes
      ~max_frame:max_frame_bytes
      ~handler:(fun wsd ->
        let conn = { wsd; write_mutex = Stdlib.Mutex.create () } in
        with_relay (fun () -> Hashtbl.replace host_conns room (Socket conn));
        handlers)
  with
  | Ok () -> ()
  | Error msg ->
    close_room ~room;
    respond_upgrade_error reqd msg
;;

let host_join_local ~room local =
  with_relay (fun () ->
      match Collab_relay.join relay ~room ~role:Collab_wire.Host with
      | Error err -> Error err
      | Ok Collab_relay.Host_accepted ->
        Hashtbl.replace host_conns room (Local local);
        Ok ()
      | Ok (Collab_relay.Guest_accepted { peer }) ->
        (* [join] answers a host role with [Host_accepted] by contract; a
           guest outcome here would be a relay defect. Unwind it and refuse
           loudly rather than registering half a room. *)
        (match Collab_relay.guest_left relay ~room ~peer with
         | Collab_relay.Guest_departed -> ()
         | Collab_relay.Leave_no_such_room
         | Collab_relay.Leave_no_such_guest ->
           Log.Server.warn
             "collab local join unwound a phantom guest (room %d bytes, peer %d)"
             (String.length room)
             peer);
        Error Collab_relay.Host_already_connected)
;;

let host_leave_local ~room = close_room ~room

(* Outcome of registering a guest socket inside the upgrade callback. The
   callback runs after the 101 flush, strictly after [respond_and_drive_upgrade]
   returns, so everything the join implies (registration, peer-joined) happens
   here, not after [Ok]. *)
type guest_registration =
  | Reg_room_gone
  | Reg_host_pending
  | Reg_announce of host_endpoint

let accept_guest ~upgrade reqd ~room ~peer =
  let handlers =
    Endpoint.handlers
      ~on_message:(on_binary_message (on_guest_message ~room ~peer))
      ~on_close:(fun ~code:_ ~reason:_ -> teardown_guest ~room ~peer)
      ~on_error:(fun msg ->
        Log.Server.debug "collab guest %d conn error: %s" peer msg;
        teardown_guest ~room ~peer)
      ~on_eof:(fun () -> teardown_guest ~room ~peer)
      ()
  in
  match
    Server_mcp_transport_ws.respond_and_drive_upgrade
      ~upgrade
      ~reqd
      ~max_message:max_message_bytes
      ~max_frame:max_frame_bytes
      ~handler:(fun wsd ->
        let conn = { wsd; write_mutex = Stdlib.Mutex.create () } in
        let registration =
          with_relay (fun () ->
              if not (Collab_relay.room_exists relay ~room)
              then (
                (* F3: the room died between relay join and upgrade. Unwind
                   the join silently (never announced) and close below. *)
                ignore (remove_guest_locked ~room ~peer);
                Reg_room_gone)
              else (
                Hashtbl.replace guest_conns (room, peer) conn;
                match Hashtbl.find_opt host_conns room with
                | None -> Reg_host_pending
                | Some host -> Reg_announce host))
        in
        (match registration with
         | Reg_room_gone ->
           send_close
             conn
             ~code:(Collab_wire.close_code Collab_wire.Close_room_closed)
             ~reason:(Collab_wire.close_message Collab_wire.Close_room_closed)
         | Reg_host_pending ->
           (* Unreachable once the link exists: /collab shows it only after
              the host is established. The peer stays registered; its hello
              still reaches the host. *)
           Log.Server.debug
             "collab guest %d registered before host socket; peer-joined skipped"
             peer
         | Reg_announce host -> host_peer_joined host peer);
        handlers)
  with
  | Ok () -> ()
  | Error msg ->
    ignore (remove_guest ~room ~peer);
    respond_upgrade_error reqd msg
;;

let reject_join ~upgrade reqd join_error =
  let reason =
    match join_error with
    | Collab_relay.Join_no_such_room -> Collab_wire.Close_no_such_room
    | Collab_relay.Host_already_connected -> Collab_wire.Close_host_conflict
    | Collab_relay.Room_full -> Collab_wire.Close_room_full
  in
  let code = Collab_wire.close_code reason in
  let message = Collab_wire.close_message reason in
  (* F1: the ~handler callback runs after the 101 flush, strictly after this
     call returns, so the close MUST go out from inside the callback — a
     post-Ok send would never find the wsd. The builder is the only open
     hook (there is no on_open). *)
  match
    Server_mcp_transport_ws.respond_and_drive_upgrade
      ~upgrade
      ~reqd
      ~max_message:max_message_bytes
      ~max_frame:max_frame_bytes
      ~handler:(fun wsd ->
        let conn = { wsd; write_mutex = Stdlib.Mutex.create () } in
        send_close conn ~code ~reason:message;
        Endpoint.handlers ())
  with
  | Ok () -> ()
  | Error msg -> respond_upgrade_error reqd msg
;;

let respond_request_error reqd = function
  | Collab_wire.Bad_path | Collab_wire.Bad_room_id ->
    Http_server_eio.Response.not_found reqd
  | Collab_wire.Missing_role ->
    Http_server_eio.Response.text
      ~status:`Bad_request
      "missing ?role=host|guest"
      reqd
  | Collab_wire.Bad_role ->
    Http_server_eio.Response.text
      ~status:`Bad_request
      "role must be host or guest"
      reqd
  | Collab_wire.Duplicate_role ->
    Http_server_eio.Response.text
      ~status:`Bad_request
      "single ?role= expected"
      reqd
;;

let ws_handler ~upgrade request reqd =
  let target = request.Httpun.Request.target in
  match Collab_wire.parse_request_target ~target with
  | Error err -> respond_request_error reqd err
  | Ok (room, role) ->
    (* F5: validate the WS handshake BEFORE joining the relay, so stray
       plain-HTTP GETs (crawlers, probes) burn no peer ids and emit no
       spurious peer-left. *)
    (match Server_mcp_transport_ws.ws_upgrade_accept request with
     | Error msg -> respond_upgrade_error reqd msg
     | Ok _ ->
       let outcome =
         with_relay (fun () -> Collab_relay.join relay ~room ~role)
       in
       (match outcome with
        | Error join_error -> reject_join ~upgrade reqd join_error
        | Ok Collab_relay.Host_accepted -> accept_host ~upgrade reqd ~room
        | Ok (Collab_relay.Guest_accepted { peer }) ->
          accept_guest ~upgrade reqd ~room ~peer))
;;
