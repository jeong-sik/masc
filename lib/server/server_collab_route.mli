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
