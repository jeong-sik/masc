(** In-memory relay core: room registry and envelope routing (RFC-0471 §2.3).

    Pure registry over an explicit [t]: no I/O, no clock, no process globals.
    The WebSocket driver ([Server_collab_route]) and the future standalone
    relay binary share this core; tests drive it directly as the in-memory
    relay helper. Callers serialize [t] under one mutex.

    Topology: the host is the hub, guests never peer. Peer 0 is reserved
    (broadcast / host-origin); guests take ids 1, 2, ... climbing for the
    room's lifetime, never reused after a leave. A room exists exactly while
    its host is connected: the host's departure removes the room, so every
    room in the table has a host.

    The relay never opens sealed payloads. It reads the 4-byte envelope peer
    header ({!Collab_envelope}) and routes opaque bytes. *)

type room_id = string
(** Decoded 16-byte room id; opaque routing key. *)

type peer = int
(** Guest id, 1 and up. *)

val max_guests_per_room : int
(** Resource bound on fan-out per room. A guest past this cap is refused
    with [Room_full] (close 4029). *)

type t

val create : unit -> t

val room_exists : t -> room:room_id -> bool
(** [room_exists t ~room] is whether [room] currently holds a host. The
    socket driver re-checks this inside the upgrade callback: a room that
    died between relay join and upgrade must not gain a zombie guest. *)

type join_error =
  | Join_no_such_room
  | Host_already_connected
  | Room_full

type join_outcome =
  | Host_accepted
  | Guest_accepted of { peer : peer }

val join
  :  t
  -> room:room_id
  -> role:Collab_wire.role
  -> (join_outcome, join_error) result
(** [join t ~room ~role] admits a peer. A host to a missing room creates it;
    a host to a live room is [Host_already_connected] (close 4009); a guest
    to a missing room is [Join_no_such_room] (close 4004); a guest past
    {!max_guests_per_room} is [Room_full] (close 4029). *)

type guest_departure =
  | Guest_departed
  | Leave_no_such_room
  | Leave_no_such_guest

val host_left : t -> room:room_id -> peer list
(** [host_left t ~room] removes the room and returns the guest ids to close,
    ascending. Unknown rooms remove nothing and return [[]]. *)

val guest_left : t -> room:room_id -> peer:peer -> guest_departure
(** [guest_left t ~room ~peer] removes one guest. *)

type sender =
  | Host
  | Guest of peer

type drop_reason =
  | Malformed_envelope
  | Route_no_such_room
  | Route_guest_not_in_room of { peer : int }
  | Sender_id_out_of_range of { peer : int }

type delivery =
  | To_guests of { peers : peer list; envelope : string }
  | To_host of { envelope : string }
  | Drop of { reason : drop_reason }

val route : t -> room:room_id -> sender:sender -> envelope:string -> delivery
(** [route t ~room ~sender ~envelope] routes one binary message:

    - host, target 0: [To_guests] to every guest, envelope passed through
      untouched;
    - host, target N: [To_guests] to guest N, or [Drop] when N is absent;
    - guest P: [To_host] with the envelope header rewritten to P, or [Drop]
      when P is absent. The guest's incoming target is ignored: guest frames
      always go to the host.

    An envelope shorter than the header is [Malformed_envelope]; an unknown
    room is [Route_no_such_room]. *)
