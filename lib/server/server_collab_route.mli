(** WebSocket driver for collab relay rooms (RFC-0471 stack 2).

    Serves [GET /r/<room>?role=host|guest], registered by the frontend
    routes via {!Http_server_eio.Router.ws_prefix_get}. Join rejects close
    with the relay close codes ({!Collab_wire.close_code}) so browser
    guests — which cannot see HTTP statuses on a refused upgrade — stay
    diagnosable; malformed requests are answered plain HTTP 400/404 without
    upgrading.

    The relay table is shared process-wide and serialized under one mutex.
    Sends never nest inside it: handlers compute a delivery under the lock,
    then send outside it, one connection write mutex at a time.

    The relay never opens sealed payloads and never reads inbound text. A
    room id in the path is public routing material; peers without the room
    key only ever see ciphertext. *)

val ws_handler
  :  upgrade:(Gluten.impl -> unit)
  -> Httpun.Request.t
  -> Httpun.Reqd.t
  -> unit
(** [ws_handler ~upgrade request reqd] parses the room and role, joins the
    relay room, and drives the post-101 connection to teardown. *)

(** {1 Local (in-process) hosts}

    Server-side host sessions (see {!Server_collab_host}) join without a
    socket: the driver calls back instead of writing frames. Relay
    semantics are identical either way — one host per room, guests never
    peer — and teardown fans out to guest sockets the same. *)

type local_host = {
  on_frame : string -> unit;
      (** Sealed guest frames for this room: full envelopes with the sender
          id rewritten in. Must return promptly; a raise is logged and the
          frame is dropped (cancellation still propagates). *)
  on_peer_joined : Collab_relay.peer -> unit;
  on_peer_left : Collab_relay.peer -> unit;
}

val host_join_local
  :  room:Collab_relay.room_id
  -> local_host
  -> (unit, Collab_relay.join_error) result
(** [host_join_local ~room local] joins [room] as an in-process host. Joins
    a missing room by creating it; an occupied room is
    [Host_already_connected]. *)

val host_leave_local : room:Collab_relay.room_id -> unit
(** [host_leave_local ~room] tears the room down: guests get [room-closed]
    plus the 4001 close, same as a socket host's close. Idempotent. *)

val host_send_local : room:Collab_relay.room_id -> string -> unit
(** [host_send_local ~room envelope] routes one host envelope to its guests:
    target 0 broadcasts, target N unicasts, unknown targets drop with a
    debug log. *)
