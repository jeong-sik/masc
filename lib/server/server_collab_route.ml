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

let relay = Collab_relay.create ()
let relay_mutex = Stdlib.Mutex.create ()
let host_conns : (room_key, connection) Hashtbl.t = Hashtbl.create 16
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
        | exception (EioCancel.Cancelled _ as ex) -> raise ex
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

let drop_reason_label = function
  | Collab_relay.Malformed_envelope -> "malformed envelope"
  | Collab_relay.Route_no_such_room -> "unknown room"
  | Collab_relay.Route_guest_not_in_room { peer } ->
    Printf.sprintf "guest %d not in room" peer
  | Collab_relay.Sender_id_out_of_range { peer } ->
    Printf.sprintf "sender id %d out of range" peer
;;

let teardown_host ~room =
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

let teardown_guest ~room ~peer =
  let host =
    with_relay (fun () ->
        let departure = Collab_relay.guest_left relay ~room ~peer in
        Hashtbl.remove guest_conns (room, peer);
        match departure with
        | Collab_relay.Guest_departed -> Hashtbl.find_opt host_conns room
        | Collab_relay.Leave_no_such_room | Collab_relay.Leave_no_such_guest ->
          None)
  in
  match host with
  | None -> ()
  | Some conn ->
    send_text conn (Collab_wire.control_json (Collab_wire.Peer_left { peer }))
;;

let on_host_message ~room envelope =
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
     | Some conn -> send_binary conn envelope)
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
      ~on_message:(on_binary_message (on_host_message ~room))
      ~on_close:(fun _code _reason -> teardown_host ~room)
      ~on_error:(fun msg ->
        Log.Server.debug "collab host conn error: %s" msg;
        teardown_host ~room)
      ~on_eof:(fun () -> teardown_host ~room)
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
        with_relay (fun () -> Hashtbl.replace host_conns room conn);
        handlers)
  with
  | Ok () -> ()
  | Error msg ->
    teardown_host ~room;
    respond_upgrade_error reqd msg
;;

let accept_guest ~upgrade reqd ~room ~peer =
  let handlers =
    Endpoint.handlers
      ~on_message:(on_binary_message (on_guest_message ~room ~peer))
      ~on_close:(fun _code _reason -> teardown_guest ~room ~peer)
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
        with_relay (fun () ->
            Hashtbl.replace guest_conns (room, peer) conn);
        handlers)
  with
  | Ok () ->
    let host = with_relay (fun () -> Hashtbl.find_opt host_conns room) in
    (match host with
     | None -> ()
     | Some conn ->
       send_text
         conn
         (Collab_wire.control_json (Collab_wire.Peer_joined { peer })))
  | Error msg ->
    teardown_guest ~room ~peer;
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
  let wsd_ref = ref None in
  match
    Server_mcp_transport_ws.respond_and_drive_upgrade
      ~upgrade
      ~reqd
      ~max_message:max_message_bytes
      ~max_frame:max_frame_bytes
      ~handler:(fun wsd ->
        wsd_ref := Some wsd;
        Endpoint.handlers ())
  with
  | Ok () ->
    (match !wsd_ref with
     | None -> ()
     | Some wsd ->
       let conn = { wsd; write_mutex = Stdlib.Mutex.create () } in
       send_close conn ~code ~reason:message)
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
    let outcome = with_relay (fun () -> Collab_relay.join relay ~room ~role) in
    (match outcome with
     | Error join_error -> reject_join ~upgrade reqd join_error
     | Ok Collab_relay.Host_accepted -> accept_host ~upgrade reqd ~room
     | Ok (Collab_relay.Guest_accepted { peer }) ->
       accept_guest ~upgrade reqd ~room ~peer)
;;
