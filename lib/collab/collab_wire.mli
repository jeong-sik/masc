(** Relay wire protocol: roles, control messages, close codes (RFC-0471 §2.3).

    Peers connect to [GET /r/<room>?role=host|guest] and upgrade to
    WebSocket. Binary messages carry {!Collab_envelope} envelopes with sealed
    payloads; text messages carry relay control JSON, relay to peer only —
    the relay never reads inbound text. Control carries no session data.

    The room id in the path is public routing material. The room key never
    reaches the relay: a peer without the key joins fine but only ever sees
    ciphertext. *)

val proto_version : int
(** [1]. MASC collab protocol version, carried in the sealed [hello]
    (stack 4); the host rejects mismatches. Numbered separately from omp. *)

val room_id_bytes : int
(** [16]. Decoded room id size in bytes. *)

type role =
  | Host
  | Guest

val role_of_string : string -> role option
(** [Some] for exactly ["host"] / ["guest"], [None] otherwise. *)

val string_of_role : role -> string

type control =
  | Peer_joined of { peer : int }
  | Peer_left of { peer : int }
  | Room_closed
(** Relay to peer control. [Peer_joined]/[Peer_left] go to the host;
    [Room_closed] goes to every guest ahead of the 4001 close. *)

val control_json : control -> string
(** [control_json c] renders [c] as TEXT JSON:
    [{"t":"peer-joined","peer":N}] / [{"t":"peer-left","peer":N}] /
    [{"t":"room-closed"}]. *)

val control_of_string : string -> control option
(** Strict decode of {!control_json}. [None] on malformed JSON, an unknown
    [t], or a peer id outside the guest range (below 1). Unknown extra
    fields are ignored. *)

type close_reason =
  | Close_room_closed
  | Close_no_such_room
  | Close_host_conflict
  | Close_room_full

val close_code : close_reason -> int
(** 4001 / 4004 / 4009 / 4029, mirroring omp's relay close codes so browser
    guests (which cannot see HTTP statuses on a refused upgrade) stay
    diagnosable. *)

val close_message : close_reason -> string
(** Human reason carried in the close frame, mirroring omp's strings. *)

type request_error =
  | Bad_path
  | Bad_room_id
  | Missing_role
  | Bad_role
  | Duplicate_role

val parse_request_target
  :  target:string
  -> (string * role, request_error) result
(** [parse_request_target ~target] parses [/r/<b64url-room>?role=...] and
    returns the decoded 16-byte room id with the role. The path suffix must
    be non-empty, hold no [/], and base64url-decode to {!room_id_bytes};
    [role=] must appear exactly once. Non-role query params are ignored. *)
